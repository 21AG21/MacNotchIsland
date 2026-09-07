import AppKit

/// Runs MediaRemoteAdapter.dylib inside /usr/bin/perl (an Apple-signed host) and reads
/// the JSON stream it produces. This is what makes Now Playing work on macOS 15.4+ for
/// every app, not just Music and Spotify.
final class AdapterBackend {
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    /// True once the helper has delivered a non-empty Now Playing payload.
    private(set) var isHealthy = false

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var stopped = true
    private var restartAttempts = 0
    private var artworkHash = ""
    private var artwork: NSImage?
    private var accent: NSColor = .white
    private let parseQueue = DispatchQueue(label: "com.macnotchisland.adapter", qos: .userInitiated)

    private static let perlScript = """
    use strict; use DynaLoader;
    my $path = shift @ARGV or die "missing path";
    my $lib = DynaLoader::dl_load_file($path, 0) or die "load: " . DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "MRAdapterMain") or die "symbol: " . DynaLoader::dl_error();
    my $sub = DynaLoader::dl_install_xsub("MRAdapter::main", $sym);
    $sub->();
    """

    static var dylibURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter.dylib"),
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return url
    }

    var isAvailable: Bool { Self.dylibURL != nil }

    func start() {
        guard stopped, let dylib = Self.dylibURL else { return }
        stopped = false
        restartAttempts = 0
        launch(dylib)
    }

    func stop() {
        stopped = true
        send("quit")
        output?.readabilityHandler = nil   // no trailing reads after we've been told to stop
        output = nil
        process?.terminate()
        process = nil
        input = nil
        isHealthy = false
    }

    // MARK: Commands

    func send(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    func refresh() { send("refresh") }

    // MARK: Process

    private func launch(_ dylib: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perlScript, dylib.path]
        let stdout = Pipe()
        let stdin = Pipe()
        p.standardOutput = stdout
        p.standardInput = stdin
        p.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: stop the handler so it doesn't spin, the termination handler restarts us.
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.parseQueue.async { self.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.processEnded() }
        }
        do {
            try p.run()
        } catch {
            NSLog("MediaRemoteAdapter failed to launch: \(error)")
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func processEnded() {
        process = nil
        input = nil
        let wasHealthy = isHealthy
        isHealthy = false   // let MediaRemote / AppleScript take over until the helper is back
        guard !stopped else { return }
        if wasHealthy { onUpdate?(nil) }
        restartAttempts += 1
        guard restartAttempts <= 5, let dylib = Self.dylibURL else {
            NSLog("MediaRemoteAdapter gave up after \(restartAttempts - 1) restarts")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restartAttempts) * 2) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            self.launch(dylib)
        }
    }

    // MARK: Parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let title = obj["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = obj["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        if title.isEmpty && artist.isEmpty {
            artworkHash = ""
            artwork = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isHealthy else { return }
                self.onUpdate?(nil)
            }
            return
        }

        let album = obj["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (obj["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (obj["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (obj["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = (obj["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let hash = obj["artworkHash"] as? String ?? ""
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0

        // Artwork cache lives on parseQueue; only the finished value crosses to the main thread.
        if !hash.isEmpty, hash != artworkHash, let b64 = obj["artworkBase64"] as? String, let data = Data(base64Encoded: b64) {
            artworkHash = hash
            artwork = NSImage(data: data)
            accent = artwork?.dominantColor() ?? .white
        } else if hash.isEmpty {
            artworkHash = ""
            artwork = nil
            accent = .white
        }
        let info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: elapsed, timestamp: timestamp,
                                  isPlaying: rate > 0, bundleID: nil,
                                  artwork: artwork, artworkID: artworkHash.hashValue, accent: accent)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var delivered = info
            if pid > 0, let app = NSRunningApplication(processIdentifier: pid) { delivered.bundleID = app.bundleIdentifier }
            self.isHealthy = true
            self.onUpdate?(delivered)
        }
    }
}

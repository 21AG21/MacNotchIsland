import AppKit
import Combine
import CoreGraphics

/// Records the screen from the island, with the time running on the pill and Stop one click
/// away — the thing the phone's Control Centre does, which on the Mac is behind a toolbar
/// and a menu bar icon somebody has to find again to stop it.
///
/// It is Apple's own `screencapture -v`, run as a child process, not a capture engine of the
/// app's own: the file it writes is the one macOS would have written, and the permission it
/// needs is Screen Recording, the one the Windows section already asks for. Stopping is a
/// Control-C, which is how `screencapture` is told to finish the movie and close it properly.
///
/// The movie goes where screenshots go (`ScreenshotMonitor.currentDirectory()`), named the way
/// macOS names its own, and when it is finished it gets the capture card a screenshot gets.
/// The screenshot watcher is told to leave it alone while it is being written: a half-made
/// movie looks exactly like a capture that has just landed.
///
/// Nothing is left running: quitting the app stops the recording first, and a recording that
/// will not stop when asked is asked less politely.
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    /// True from the moment `screencapture` starts until it has exited — including the second
    /// or two it spends finishing the file after Stop.
    @Published private(set) var isRecording = false
    /// True from Stop until `screencapture` has exited: the movie is being finished, and there
    /// is nothing left to stop — `stop()` does nothing meanwhile. Published so a menu or a
    /// button says "Saving" rather than offering a Stop that cannot do anything.
    @Published private(set) var isSaving = false
    @Published private(set) var startedAt: Date?

    /// The live activity's id, and the alert's.
    static let activityID = "screen-recording"
    static let refusedID = "screen-recording-refused"
    static let tool = "/usr/sbin/screencapture"

    /// How long `screencapture` is given to finish after Control-C before its input is closed,
    /// and then before it is terminated outright.
    static let closeInputAfter: TimeInterval = 5
    static let terminateAfter: TimeInterval = 15
    /// How long a quit waits for the movie to be finished before going anyway.
    static let quitGrace: TimeInterval = 3

    private var process: Process?
    /// Held open for as long as `screencapture` runs, and never written to. It stops on "any
    /// character" typed at it, and an app's standard input is `/dev/null` — an end of file it
    /// would read at once and take for a key. Closing this is the second way to stop it.
    private var input: Pipe?
    private var file: URL?
    private var escalation: [DispatchWorkItem] = []
    private var quitObserver: NSObjectProtocol?

    private init() {
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.stopForQuit()
        }
    }

    // MARK: - Starting and stopping

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard process == nil else { return }
        // Without the permission `screencapture` either fails or, worse, records the desktop
        // picture and nothing on it. Asking registers the app in the list, so there is a
        // switch to turn on; the island says where it is.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            refused()
            return
        }
        // The panel is not what anybody meant to record.
        ActivityCenter.shared.collapse(reason: "screen recording")

        let now = Date()
        let folder = ScreenshotMonitor.currentDirectory()
        let file = Self.unique(folder.appendingPathComponent(Self.fileName(at: now)))
        ScreenshotMonitor.claim(file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tool)
        process.arguments = Self.arguments(for: file)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { IslandLog.island.notice("screencapture: \(text, privacy: .public)") }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.finished(status: status) }
        }
        do {
            try process.run()
        } catch {
            IslandLog.island.error("could not start screencapture: \(error.localizedDescription, privacy: .public)")
            errors.fileHandleForReading.readabilityHandler = nil
            refused()
            return
        }
        IslandLog.island.notice("recording the screen to \(file.path, privacy: .private)")
        self.process = process
        self.input = input
        self.file = file
        isSaving = false
        startedAt = now
        isRecording = true
        showActivity()
    }

    /// Control-C, as the tool asks, then a wait for the movie to be finished. The card says it
    /// is saving meanwhile, since a long recording takes a moment to close.
    func stop() {
        guard let process, process.isRunning, !isSaving else { return }
        isSaving = true
        showActivity()
        process.interrupt()
        // And if it does not go: its input closed, which is the "any character" it also
        // stops on, and then a terminate — a recorder that outlives its Stop button is worse
        // than a movie that is cut short.
        let close = DispatchWorkItem { [weak self] in
            guard let self, self.process?.isRunning == true else { return }
            IslandLog.island.notice("screencapture did not stop on an interrupt; closing its input")
            try? self.input?.fileHandleForWriting.close()
        }
        let terminate = DispatchWorkItem { [weak self] in
            guard let self, let process = self.process, process.isRunning else { return }
            IslandLog.island.error("screencapture still running; terminating it")
            process.terminate()
        }
        escalation = [close, terminate]
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeInputAfter, execute: close)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminateAfter, execute: terminate)
    }

    /// The app is going: the movie is finished in the moments it has, and the tool never
    /// outlives the app that started it. What was recorded stays where it was written.
    private func stopForQuit() {
        guard let process, process.isRunning else { return }
        if !isSaving { process.interrupt() }
        let deadline = Date().addingTimeInterval(Self.quitGrace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
    }

    /// `screencapture` has exited, however it came to.
    private func finished(status: Int32) {
        escalation.forEach { $0.cancel() }
        escalation = []
        let file = self.file
        process = nil
        input = nil
        self.file = nil
        isSaving = false
        startedAt = nil
        isRecording = false
        ActivityCenter.shared.end(id: Self.activityID)

        let size = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
        switch Self.outcome(fileSize: size?.int64Value) {
        case .saved:
            guard let file else { return }
            if status != 0 { IslandLog.island.notice("screencapture ended with \(status, privacy: .public) but left a movie") }
            ScreenshotMonitor.announce(file, isRecording: true, picture: (thumbnail: nil, pixels: nil))
        case .nothingRecorded:
            IslandLog.island.error("screencapture ended with \(status, privacy: .public) and no movie")
            refused()
        }
    }

    // MARK: - What the island shows

    private func showActivity() {
        guard let since = startedAt, let file else { return }
        let folder = FileManager.default.displayName(atPath: file.deletingLastPathComponent().path)
        let custom = Self.activity(since: since, saving: isSaving, folder: folder)
        ActivityCenter.shared.upsert(IslandActivity(id: Self.activityID, kind: .custom, content: .custom(custom), priority: 90))
    }

    /// The live activity: a red dot and the time running, where the movie is going, and Stop
    /// on its card. While the file is being finished it says so, and has no Stop to press
    /// twice.
    static func activity(since: Date, saving: Bool, folder: String) -> CustomActivity {
        var custom = CustomActivity(title: saving ? "Saving Recording" : "Recording",
                                    subtitle: saving ? "Finishing the movie" : "To \(folder)",
                                    symbol: "record.circle.fill", tint: "red")
        if saving {
            custom.trailingText = "Saving"
        } else {
            custom.countsUpFrom = since
            custom.actions = [CustomAction(title: "Stop", symbol: "stop.fill", command: .stopRecording)]
        }
        return custom
    }

    /// Nothing was recorded, and the reason is nearly always the permission.
    private func refused() {
        let alert = IslandActivity(id: Self.refusedID, kind: .custom, content: .custom(Self.refusal),
                                   priority: 90, presentation: .expanded)
        ActivityCenter.shared.showAlert(alert, duration: 6)
    }

    static let refusal = CustomActivity(title: "Can't record the screen",
                                        subtitle: "Notch Island needs Screen Recording.",
                                        symbol: "record.circle", tint: "orange",
                                        actions: [CustomAction(title: "Open Settings",
                                                               url: SystemSettingsPane.screenRecording.url)])

    // MARK: - Pure rules

    /// How a recording ended, from what it left behind. A movie with anything in it is kept
    /// whatever the exit status said — Control-C is an unusual way for a tool to be asked to
    /// finish, and a recording that exists is worth more than a status that disapproves.
    enum Outcome: Equatable {
        case saved
        case nothingRecorded
    }

    static func outcome(fileSize: Int64?) -> Outcome {
        guard let fileSize, fileSize > 0 else { return .nothingRecorded }
        return .saved
    }

    static func arguments(for file: URL) -> [String] {
        ["-v", file.path]
    }

    /// "Screen Recording 2026-09-25 at 14.03.12.mov", the name macOS itself gives one.
    static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date)).mov"
    }

    /// The name itself where it is free; otherwise " 2", " 3" before the extension, the way
    /// Finder numbers a second copy.
    static func unique(_ url: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        guard exists(url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...999 {
            let candidate = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !exists(candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString)").appendingPathExtension(ext)
    }
}

import Foundation

/// Where Notch Island keeps what it has to remember between launches, and the one place that
/// decides who is allowed to read it.
///
/// Three things live in that folder: everything you have copied, where the history is kept
/// across relaunches, the notes you have jotted down, and a cache of lyrics. Two of them are
/// as personal as anything on the Mac, and all
/// three were being written with whatever permissions the process umask happened to hand out
/// — 644 on a stock Mac, which is every other account on a shared one. They belong to the
/// account that wrote them now, and so does the folder around them.
///
/// The path was also spelled out in three files, so there were three chances to spell it
/// differently.
enum IslandFiles {
    /// Readable and writable by its owner and by nobody else.
    static let ownerOnlyFile: NSNumber = 0o600
    static let ownerOnlyFolder: NSNumber = 0o700

    /// Somewhere else to put all of this, for the gallery.
    ///
    /// Rendering the gallery borrows the notes and the clipboard history to draw them, and
    /// those are stores that write themselves down. On CI that costs nothing; on the Mac of
    /// anybody who runs it to look at a change, it wrote over what they had actually jotted
    /// down. Nothing in the app ever sets this.
    static var overrideFolder: URL?

    static var folder: URL? {
        if let overrideFolder { return overrideFolder }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("MacNotchIsland", isDirectory: true)
    }

    /// The folder, made if it is not there and shut to everyone else either way — a folder
    /// left behind by an older build kept whatever it was given. Nil when it could not be
    /// made; `prepareFolder` says why.
    @discardableResult
    static func makeFolder(_ subdirectory: String? = nil) -> URL? {
        do {
            return try prepareFolder(subdirectory)
        } catch {
            IslandLog.store.error("could not make the support folder: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `makeFolder`, with the reason when the folder cannot be made. It used to swallow that
    /// and hand back the path anyway, so the write that followed failed with "no such file" —
    /// or, to a caller that did not write straight away, looked like success — when what had
    /// actually happened was a full disk or an Application Support nobody may write in.
    @discardableResult
    static func prepareFolder(_ subdirectory: String? = nil) throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let target = subdirectory.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: ownerOnlyFolder])
        // Shutting it is best effort: a folder that is there but cannot be re-permissioned is
        // still a folder the write can go in, and the write says so if it is not.
        try? FileManager.default.setAttributes([.posixPermissions: ownerOnlyFolder], ofItemAtPath: folder.path)
        if target != folder {
            try? FileManager.default.setAttributes([.posixPermissions: ownerOnlyFolder], ofItemAtPath: target.path)
        }
        return target
    }

    /// Writes to a file in the folder and shuts it to everyone else. Throws the real reason —
    /// the folder's, when it is the folder that could not be made — so a caller can say it.
    static func write(_ data: Data, to name: String, in subdirectory: String? = nil) throws {
        let target = try prepareFolder(subdirectory)
        let url = target.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        // After the write, never before: an atomic write puts a new file in place of the old
        // one, and the new one arrives with the permissions the temporary file had.
        try? FileManager.default.setAttributes([.posixPermissions: ownerOnlyFile], ofItemAtPath: url.path)
    }

    static func read(_ name: String, in subdirectory: String? = nil) -> Data? {
        guard let folder else { return nil }
        let target = subdirectory.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
        return try? Data(contentsOf: target.appendingPathComponent(name))
    }

    // MARK: - A file that is there but cannot be read

    /// What reading back one of the files kept here found.
    enum ReadBack<Value> {
        /// Nothing there: a first launch, or a feature that has never been used.
        case missing
        case value(Value)
        /// There, but not something this build can read — a newer build's format, say, or not
        /// readable at all. See `setAside`.
        case unreadable(SetAside)
    }

    /// What became of a file that could not be read.
    enum SetAside: Equatable {
        /// Renamed to this, beside where it was, before anything could be written over it.
        case moved(String)
        /// It could not be moved out of the way either. Nothing may be written over it for the
        /// rest of the run: it is somebody's history in a form this build cannot read.
        case stuck
    }

    /// Reads one of the files kept here and makes something of it, or moves it out of the way.
    ///
    /// A history that failed to read used to come back as an empty one, and the next save wrote
    /// that over the file — so an older copy of the app, opened once on a file a newer build had
    /// written, took the whole history with it. What cannot be read is now renamed aside, never
    /// deleted and never rewritten, and the rename comes before anything can be saved.
    static func readBack<Value>(_ name: String, now: Date = Date(),
                                decode: (Data) throws -> Value) -> ReadBack<Value> {
        guard let url = folder?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .value(try decode(try Data(contentsOf: url)))
        } catch {
            IslandLog.store.error("\(name, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
            return .unreadable(setAside(url, now: now))
        }
    }

    /// Moves a file that could not be read out of the way, beside where it was, under
    /// `unreadableName` — with "-2", "-3" after it when that is taken, so a second one in the
    /// same second does not land on the first. Says what it did in the log either way.
    static func setAside(_ url: URL, now: Date = Date()) -> SetAside {
        let folder = url.deletingLastPathComponent()
        let stem = unreadableName(for: url.lastPathComponent, at: now)
        var name = stem
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(n)"
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(name))
            IslandLog.store.error("\(url.lastPathComponent, privacy: .public) could not be read; moved aside as \(name, privacy: .public)")
            return .moved(name)
        } catch {
            IslandLog.store.error("\(url.lastPathComponent, privacy: .public) could not be read or moved aside: \(String(describing: error), privacy: .public)")
            return .stuck
        }
    }

    /// "notes.txt.unreadable-2026-09-25-143205": the day and the second, and a name that still
    /// says what the file was.
    static func unreadableName(for name: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(name).unreadable-\(formatter.string(from: date))"
    }

    // MARK: - A new file, never over another

    /// Writes `data` as a new file in `folder`, under the first name `named` gives that nobody
    /// has taken — asked with 1, then 2, and so on — and returns where it went.
    ///
    /// All of it or none of it, and never over anything. The bytes go to a hidden file of
    /// their own first, so a disk that fills part of the way through leaves nothing behind
    /// under the real name; that file is then hard-linked into place, and a link, unlike a
    /// rename, refuses a name that is taken — even one taken a moment ago by another write
    /// racing this one, which a look before the write cannot see. `AskReply.put` does the same.
    static func writeNew(_ data: Data, in folder: URL, attempts: Int = 500,
                         named: (Int) -> String) throws -> URL {
        let scratch = folder.appendingPathComponent(".\(UUID().uuidString).incomplete")
        // Registered before the write, so a write that fails half-way is taken away too.
        defer { unlink(scratch.path) }
        try data.write(to: scratch, options: .withoutOverwriting)
        let last = max(1, attempts)
        for attempt in 1...last {
            let candidate = folder.appendingPathComponent(named(attempt))
            if link(scratch.path, candidate.path) == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            // A disk with no hard links to give — some network homes, exFAT — refuses the
            // link outright rather than the name. The same promise is kept another way there:
            // an exclusive create refuses a taken name as a link does, and the bytes go in
            // behind it; only a disk that fills part of the way through can leave a short file.
            guard code == ENOTSUP || code == EPERM || code == EXDEV || code == EACCES || code == EINVAL else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return try createNew(data, in: folder, from: attempt, through: last, named: named)
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// `writeNew` for a disk without hard links: the first free name from `first` to `last`,
    /// taken with an exclusive create, and the bytes written into it.
    private static func createNew(_ data: Data, in folder: URL, from first: Int, through last: Int,
                                  named: (Int) -> String) throws -> URL {
        for attempt in first...max(first, last) {
            let candidate = folder.appendingPathComponent(named(attempt))
            let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd < 0 {
                let code = errno
                guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                continue
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                unlink(candidate.path)
                throw error
            }
            return candidate
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// What the permissions on a path actually are, for the test that pins this down.
    static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
    }
}

extension IslandFiles.ReadBack: Equatable where Value: Equatable {}

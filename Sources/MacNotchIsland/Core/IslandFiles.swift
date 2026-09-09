import Foundation

/// Where Notch Island keeps what it has to remember between launches, and the one place that
/// decides who is allowed to read it.
///
/// Three things live in that folder: everything you have copied, the notes you have jotted
/// down, and a cache of lyrics. Two of them are as personal as anything on the Mac, and all
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
    /// left behind by an older build kept whatever it was given.
    @discardableResult
    static func makeFolder(_ subdirectory: String? = nil) -> URL? {
        guard let folder else { return nil }
        let target = subdirectory.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: ownerOnlyFolder])
        try? FileManager.default.setAttributes([.posixPermissions: ownerOnlyFolder], ofItemAtPath: folder.path)
        if target != folder {
            try? FileManager.default.setAttributes([.posixPermissions: ownerOnlyFolder], ofItemAtPath: target.path)
        }
        return target
    }

    /// Writes to a file in the folder and shuts it to everyone else.
    static func write(_ data: Data, to name: String, in subdirectory: String? = nil) throws {
        guard let target = makeFolder(subdirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
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

    /// What the permissions on a path actually are, for the test that pins this down.
    static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
    }
}

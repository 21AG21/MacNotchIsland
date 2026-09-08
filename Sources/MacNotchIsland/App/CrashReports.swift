import Foundation

/// The crash reports macOS writes for this app, read back for a support report: how the
/// process ended, what the system said about it, and the frames of the thread that ended it.
///
/// A report is an `.ips` file: one line of JSON with the app and OS versions, a blank line,
/// then a JSON document with the termination, the exception, any "Application Specific
/// Information" (assertion messages, uncaught exception reasons, privacy kills) and every
/// thread. Only the parts that explain the end of the process are kept.
enum CrashReports {
    /// Where ReportCrash keeps the current user's reports; older ones move to `Retired`.
    static var directories: [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// The newest reports for the process, newest first.
    static func recent(limit: Int = 3, processName: String = "MacNotchIsland") -> [URL] {
        let manager = FileManager.default
        var found: [(url: URL, date: Date)] = []
        for directory in directories {
            guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                options: [.skipsHiddenFiles]) else { continue }
            for url in files where url.pathExtension == "ips" && url.lastPathComponent.hasPrefix(processName + "-") {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                found.append((url, date))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// Every recent report, summarised, newest first.
    static func recentSummaries(limit: Int = 3) -> String {
        let urls = recent(limit: limit)
        guard !urls.isEmpty else { return "no crash reports for this app" }
        return urls.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return url.lastPathComponent + "\n" + summary(ofReport: text)
        }.joined(separator: "\n\n")
    }

    /// The parts of one report that explain the end of the process.
    static func summary(ofReport text: String) -> String {
        guard let split = text.firstIndex(of: "\n") else { return "unreadable report" }
        let header = json(String(text[..<split]))
        let body = json(String(text[text.index(after: split)...]))
        guard !body.isEmpty else { return "unreadable report body" }

        var lines: [String] = []
        lines.append("reported \(header["timestamp"] ?? "?") app \(header["app_version"] ?? "?") (\(header["build_version"] ?? "?")) on \(header["os_version"] ?? "?")")
        if let termination = body["termination"] as? [String: Any] {
            var line = "termination \(termination["namespace"] ?? "?") code \(termination["code"] ?? "?")"
            if let indicator = termination["indicator"] { line += " \(indicator)" }
            if let proc = termination["byProc"] { line += " by \(proc)" }
            if let pid = termination["byPid"] { line += " pid \(pid)" }
            lines.append(line)
        }
        if let exception = body["exception"] as? [String: Any] {
            var line = "exception \(exception["type"] ?? "?")"
            if let signal = exception["signal"] { line += " \(signal)" }
            if let subtype = exception["subtype"] { line += " \(subtype)" }
            if let codes = exception["codes"] { line += " codes \(codes)" }
            lines.append(line)
        }
        if let asi = body["asi"] as? [String: Any] {
            for key in asi.keys.sorted() {
                for message in (asi[key] as? [String]) ?? [] { lines.append("\(key): \(message)") }
            }
        }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let backtrace = body["lastExceptionBacktrace"] as? [[String: Any]], !backtrace.isEmpty {
            lines.append("last exception backtrace:")
            lines += frames(backtrace, images: images)
        }
        if let threads = body["threads"] as? [[String: Any]], !threads.isEmpty {
            let index = (body["faultingThread"] as? Int)
                ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
            if index >= 0, index < threads.count {
                let thread = threads[index]
                let name = (thread["name"] as? String) ?? (thread["queue"] as? String) ?? ""
                lines.append("thread \(index) \(name):")
                lines += frames(thread["frames"] as? [[String: Any]] ?? [], images: images)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func frames(_ frames: [[String: Any]], images: [[String: Any]], limit: Int = 40) -> [String] {
        frames.prefix(limit).enumerated().map { i, frame in
            let imageIndex = frame["imageIndex"] as? Int ?? -1
            let image = (imageIndex >= 0 && imageIndex < images.count) ? (images[imageIndex]["name"] as? String ?? "?") : "?"
            if let symbol = frame["symbol"] as? String {
                return "  \(i) \(image) \(symbol) + \(frame["symbolLocation"] ?? 0)"
            }
            return "  \(i) \(image) + \(frame["imageOffset"] ?? 0)"
        }
    }

    private static func json(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

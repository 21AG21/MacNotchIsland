import AppKit

/// A support report: build, system, displays, state, and the app's recent log, put on the
/// pasteboard from the menu bar so a problem on another Mac can be described precisely.
enum Diagnostics {
    static func copyToPasteboard() {
        let header = header()
        DispatchQueue.global(qos: .userInitiated).async {
            let log = recentLog(minutes: 5)
            let trouble = troubleLog(minutes: 30)
            let crashes = CrashReports.recentSummaries()
            let text = header
                + "\n--- crash reports, newest first\n" + crashes
                + "\n--- errors and faults around the app, last 30 minutes\n" + trouble
                + "\n--- log, last 5 minutes\n" + log
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let done = CustomActivity(title: "Diagnostics copied", symbol: "doc.on.clipboard",
                                          trailingText: "Copied")
                ActivityCenter.shared.showAlert(IslandActivity(id: "diagnostics", kind: .custom, content: .custom(done), priority: 85),
                                                duration: 2, haptic: false)
            }
        }
    }

    /// Everything about this machine and this moment that the log alone does not say.
    static func header() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let center = ActivityCenter.shared
        let p = Preferences.shared
        var lines: [String] = []
        lines.append("Notch Island \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for screen in NSScreen.screens {
            let left = screen.auxiliaryTopLeftArea.map(NSStringFromRect) ?? "-"
            let right = screen.auxiliaryTopRightArea.map(NSStringFromRect) ?? "-"
            let geometry = NotchGeometry.detect(on: screen)
            lines.append("screen \(NotchPanel.displayKey(for: screen)) frame \(NSStringFromRect(screen.frame)) safeTop \(screen.safeAreaInsets.top) auxLeft \(left) auxRight \(right) notch \(geometry.notchWidth)x\(geometry.notchHeight) physical \(geometry.hasPhysicalNotch)")
        }
        lines.append("accessibility trusted \(AXIsProcessTrusted())")
        lines.append("this run started \(RunRecord.startedAt) pid \(ProcessInfo.processInfo.processIdentifier); previous run \(RunRecord.previousEnding)")
        lines.append("open \(String(describing: center.openView)) alert \(center.alert?.id ?? "-") activities \(center.activities.map(\.id)) suppressed \(center.isSuppressed)")
        lines.append("prefs hoverToExpand \(p.hoverToExpand) expandOnIdleHover \(p.expandOnIdleHover) hideInFullscreen \(p.hideInFullscreen) hiddenApps \(p.hiddenAppBundleIDs) hudReplacement \(p.hudReplacementEnabled) gestures \(p.gesturesEnabled) keepClear \(p.keepClearOfMenuBar)")
        return lines.joined(separator: "\n")
    }

    /// The app's own unified-log entries. `log show` can take a few seconds; call off the main thread.
    ///
    /// Asked for by process as well as by subsystem. `Logger` stamps the subsystem on every
    /// line; `NSLog` stamps none, so a report asking only for the subsystem left out most of
    /// what the app had said — including every failure that would explain the problem it was
    /// being collected for.
    static func recentLog(minutes: Int) -> String {
        show(minutes: minutes,
             predicate: "subsystem == \"\(IslandLog.subsystem)\" OR process == \"\(processName)\"",
             info: true)
    }

    /// This process as `log show` names it.
    private static let processName = ProcessInfo.processInfo.processName

    /// What the system logged about the app ending: errors and faults from inside the process
    /// (an uncaught exception, an assertion, a Swift runtime failure), the crash reporter's
    /// note about it, privacy denials, and the process manager's record of the exit.
    static func troubleLog(minutes: Int) -> String {
        let name = processName
        let predicate = "(process == \"\(name)\" AND (messageType == error OR messageType == fault))"
            + " OR (process == \"ReportCrash\" AND eventMessage CONTAINS \"\(name)\")"
            + " OR (process == \"tccd\" AND eventMessage CONTAINS[c] \"macnotchisland\")"
            + " OR (process == \"launchservicesd\" AND eventMessage CONTAINS \"\(name)\")"
            + " OR (process == \"runningboardd\" AND eventMessage CONTAINS \"\(name)\")"
        let text = show(minutes: minutes, predicate: predicate, info: false)
        // Keep the tail: the latest exit is what matters and the first lines are a header.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 200 else { return text }
        return "... \(lines.count - 200) earlier lines omitted\n" + lines.suffix(200).joined(separator: "\n")
    }

    private static func show(minutes: Int, predicate: String, info: Bool) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        var arguments = ["show", "--last", "\(minutes)m", "--predicate", predicate, "--style", "compact"]
        if info { arguments.append("--info") }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "log show failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A note of how each run of the app ends, so the next run (and its diagnostics) can say
/// whether the last one quit on request or simply vanished.
enum RunRecord {
    private static let stateKey = "runState"
    private static let startKey = "runStartedAt"
    private static let endKey = "runEnding"
    static let startedAt = Date()

    /// "quit: <reason>" for the last clean exit, or a note that the previous run ended without
    /// one, with when it began. Read before `begin()` overwrites it.
    private(set) static var previousEnding = "unknown"

    /// Call once at launch: records what happened to the previous run and marks this one live.
    static func begin() {
        let defaults = UserDefaults.standard
        let started = defaults.object(forKey: startKey) as? Date
        let when = started.map { " (started \($0))" } ?? ""
        switch defaults.string(forKey: stateKey) {
        case "running":
            previousEnding = "ended without a clean exit" + when
            IslandLog.island.error("previous run ended without a clean exit\(when, privacy: .public)")
        case "exited":
            previousEnding = (defaults.string(forKey: endKey) ?? "quit") + when
        default:
            previousEnding = "first run"
        }
        defaults.set("running", forKey: stateKey)
        defaults.set(startedAt, forKey: startKey)
        defaults.removeObject(forKey: endKey)
    }

    /// Call when the app is about to quit on purpose, with who asked.
    static func end(_ reason: String) {
        let defaults = UserDefaults.standard
        defaults.set("exited", forKey: stateKey)
        defaults.set("quit: " + reason, forKey: endKey)
        IslandLog.island.notice("quitting: \(reason, privacy: .public)")
    }
}

import AppKit

/// A support report: build, system, displays, state, and the app's recent log, put on the
/// pasteboard from the menu bar so a problem on another Mac can be described precisely.
enum Diagnostics {
    static func copyToPasteboard() {
        let header = header()
        DispatchQueue.global(qos: .userInitiated).async {
            let log = recentLog(minutes: 5)
            let text = header + "\n--- log, last 5 minutes\n" + log
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let done = CustomActivity(title: "Diagnostics copied")
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
        lines.append("open \(String(describing: center.openView)) alert \(center.alert?.id ?? "-") activities \(center.activities.map(\.id)) suppressed \(center.isSuppressed)")
        lines.append("prefs hoverToExpand \(p.hoverToExpand) expandOnIdleHover \(p.expandOnIdleHover) hideInFullscreen \(p.hideInFullscreen) hiddenApps \(p.hiddenAppBundleIDs) hudReplacement \(p.hudReplacementEnabled) gestures \(p.gesturesEnabled) keepClear \(p.keepClearOfMenuBar)")
        return lines.joined(separator: "\n")
    }

    /// The app's own unified-log entries. `log show` can take a few seconds; call off the main thread.
    static func recentLog(minutes: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "\(minutes)m", "--predicate", "subsystem == \"\(IslandLog.subsystem)\"",
                             "--info", "--style", "compact"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "log show failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

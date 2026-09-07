import AppKit
import SwiftUI

enum ActivityKind: String {
    case nowPlaying, timer, stopwatch, call, battery, bluetooth, focus, hud, silent, unlock, calendar, download, custom
}

enum InitialPresentation: Equatable { case compact, expanded }

enum OpenAction: Equatable {
    case app(bundleID: String)
    case url(URL)

    func perform() {
        switch self {
        case .app(let id):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }
}

/// One thing the island can show. Live activities persist until ended; alerts are transient.
struct IslandActivity: Identifiable, Equatable {
    let id: String
    var kind: ActivityKind
    var content: ActivityContent
    var priority: Int
    var startedAt: Date = Date()
    var expiresAt: Date? = nil
    var presentation: InitialPresentation = .compact
    var openAction: OpenAction? = nil
}

// MARK: - Content payloads

struct TimerState: Equatable {
    var label: String
    var total: TimeInterval
    var endDate: Date
    var pausedRemaining: TimeInterval? = nil
    var isFinished = false

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date) -> TimeInterval {
        if let p = pausedRemaining { return max(0, p) }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date) -> Double {
        guard total > 0 else { return 0 }
        return 1 - remaining(at: date) / total
    }
}

struct StopwatchState: Equatable {
    var startedAt: Date
    var accumulated: TimeInterval = 0
    var isRunning = true
    var laps: [TimeInterval] = []

    func elapsed(at date: Date) -> TimeInterval {
        isRunning ? accumulated + date.timeIntervalSince(startedAt) : accumulated
    }
}

struct DownloadState: Equatable {
    var name: String
    var bytes: Int64
    var total: Int64?
    var app: String
    var isComplete = false

    var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }

    static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var sizeText: String {
        if let total, total > 0 {
            return "\(Self.formatter.string(fromByteCount: bytes)) of \(Self.formatter.string(fromByteCount: total))"
        }
        return Self.formatter.string(fromByteCount: bytes)
    }
}

struct CallState: Equatable {
    var appName: String
    var bundleID: String
    var startedAt: Date
}

enum BatteryEvent: Equatable { case pluggedIn, unplugged, low, critical, full }

struct BatteryState: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var event: BatteryEvent
}

struct BluetoothState: Equatable {
    var name: String
    var address: String
    var symbol: String
    var batteryLeft: Int? = nil
    var batteryRight: Int? = nil
    var batteryCase: Int? = nil
    var batterySingle: Int? = nil
    var isConnected: Bool = true

    var summaryPercent: Int? {
        if let s = batterySingle { return s }
        let buds = [batteryLeft, batteryRight].compactMap { $0 }
        return buds.min()
    }
}

struct FocusState: Equatable {
    var name: String
    var symbol: String
    var isOn: Bool
    var tint: String
}

struct LevelHUD: Equatable {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind
    var level: Double
    var isMuted: Bool = false
}

struct SilentState: Equatable {
    var isSilent: Bool
}

struct CalendarState: Equatable {
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var joinURL: URL?
    var tint: String
}

struct CustomActivity: Equatable {
    var title: String
    var subtitle: String? = nil
    var symbol: String = "app.fill"
    var tint: String = "white"
    var progress: Double? = nil
    var trailingText: String? = nil
    var body: String? = nil
    var url: URL? = nil
    var showsRing: Bool = false
}

enum ActivityContent: Equatable {
    case nowPlaying(NowPlayingInfo)
    case timer(TimerState)
    case stopwatch(StopwatchState)
    case call(CallState)
    case battery(BatteryState)
    case bluetooth(BluetoothState)
    case focus(FocusState)
    case hud(LevelHUD)
    case silent(SilentState)
    case unlock
    case calendar(CalendarState)
    case download(DownloadState)
    case custom(CustomActivity)

    /// Leading / trailing widths used in the compact (pill) state, in points.
    var compactWidths: (leading: CGFloat, trailing: CGFloat) {
        switch self {
        case .nowPlaying: return (44, 44)
        case .timer: return (40, 60)
        case .stopwatch: return (40, 64)
        case .call: return (40, 60)
        case .battery: return (48, 56)
        case .bluetooth(let s): return (44, s.summaryPercent == nil ? 90 : 56)
        case .focus(let f): return (40, f.isOn ? 40 : 40)
        case .hud: return (40, 84)
        case .silent: return (40, 60)
        case .unlock: return (40, 82)
        case .calendar: return (40, 64)
        case .download(let d): return (40, d.progress != nil ? 40 : 70)
        case .custom(let c):
            if c.progress != nil && c.showsRing { return (40, 40) }
            let text = c.trailingText ?? ""
            let w = min(120, max(44, CGFloat(text.count) * 8 + 20))
            return (40, w)
        }
    }

    /// Whether this content has a dedicated expanded (large) view.
    var hasExpandedView: Bool {
        switch self {
        case .unlock, .silent: return false
        default: return true
        }
    }

    /// Size of the expanded body for this content.
    func expandedSize(notch: NotchGeometry) -> CGSize {
        let h = notch.notchHeight
        switch self {
        case .nowPlaying: return CGSize(width: 540, height: h + (Preferences.shared.lyricsEnabled ? 200 : 176))
        case .timer: return CGSize(width: 440, height: h + 84)
        case .stopwatch: return CGSize(width: 460, height: h + 84)
        case .call: return CGSize(width: 440, height: h + 84)
        case .battery: return CGSize(width: 420, height: h + 78)
        case .bluetooth: return CGSize(width: 460, height: h + 96)
        case .focus: return CGSize(width: 400, height: h + 72)
        case .hud: return CGSize(width: 400, height: h + 66)
        case .calendar: return CGSize(width: 480, height: h + 96)
        case .download: return CGSize(width: 460, height: h + 92)
        case .custom(let c):
            var extra: CGFloat = 84
            if c.body != nil { extra += 22 }
            if c.progress != nil { extra += 14 }
            return CGSize(width: 460, height: h + extra)
        case .unlock, .silent: return CGSize(width: 320, height: h + 40)
        }
    }
}

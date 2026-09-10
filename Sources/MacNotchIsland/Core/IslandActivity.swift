import AppKit
import SwiftUI

enum ActivityKind: String {
    case nowPlaying, timer, stopwatch, call, battery, bluetooth, focus, hud, silent, unlock, calendar, download, drive, capture, custom, shelf
}

enum InitialPresentation: Equatable { case compact, expanded }

enum OpenAction: Equatable {
    case app(bundleID: String)
    case url(URL)

    func perform() {
        switch self {
        case .app(let id):
            // The app is normally the one whose activity is on the island, so it is running
            // and this cannot fail. When it does, the log is the only place that can say so.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                IslandLog.island.error("nothing installed for \(id, privacy: .public)")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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

/// The file shelf while it holds something. Files stay on the shelf until they expire or are
/// cleared, so this is a live activity for as long as they do.
struct ShelfState: Equatable {
    var count: Int
    var latestName: String?
    var latestIsImage = false
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

enum BatteryEvent: Equatable {
    case pluggedIn, unplugged, low, critical, full
    /// Reached the mark somebody set to be told at — "enough, you can unplug it".
    case charged
}

struct BatteryState: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var event: BatteryEvent
    /// Minutes until empty (on battery) or until full (charging); nil while macOS is still estimating.
    var timeRemainingMinutes: Int? = nil
    /// Signed charge/discharge power in watts (positive = charging), from the IORegistry battery entry.
    var wattage: Double? = nil
    var cycleCount: Int? = nil
    /// Maximum capacity relative to design capacity, 0–100.
    var healthPercent: Int? = nil
    var temperatureCelsius: Double? = nil
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
    /// Where the sound is going, when it is not the Mac's own speakers.
    ///
    /// The system's bezel never says, and it is the one thing worth knowing when the volume
    /// keys seem to be doing nothing — because the sound is in a pair of headphones on the
    /// desk. Nil for brightness, and nil for the built-in speakers, where naming the obvious
    /// would only be clutter.
    var device: String? = nil
    /// The glyph for that device: the AirPods, the headphones, the display it is going out to.
    var deviceSymbol: String? = nil
    /// The output has no volume of its own to set — HDMI and some AirPlay targets carry the
    /// sound at whatever level the thing at the other end is at. Swallowing the key and
    /// showing nothing would leave the press looking broken.
    var isUnavailable: Bool = false

    /// The number, or what stands in for it when there is no number to give. One definition,
    /// because the pill, the banner and the card all have to say the same thing.
    static func readout(_ state: LevelHUD) -> String {
        if state.isUnavailable { return "\u{2014}" }
        return state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded()))%"
    }

    /// What to do about a level this Mac does not set. One definition, for the same reason:
    /// the pill answers the key press, and it used to answer it with the dash alone — which
    /// says "no number", not "not from here", and leaves the press looking broken after all.
    static func unavailableHint(_ state: LevelHUD) -> String {
        state.kind == .volume ? "Set on the device" : "Set on the display"
    }
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

/// A button a script asked the island to put on its activity: what it says, and the one thing
/// it does. Either a web link or a Shortcut by name — the two things a script can already do
/// for itself, offered where the person is looking rather than where the script is running.
struct CustomAction: Equatable {
    var title: String
    var symbol: String? = nil
    var url: URL? = nil
    var shortcut: String? = nil

    /// Whether it would do anything at all. A button that does nothing is not a button.
    var isUsable: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return url != nil || !(shortcut ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
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
    /// At most two: a card has room for two buttons beside its text, and a third is a toolbar.
    var actions: [CustomAction] = []
}

/// A capture the user has just taken: a screenshot or a screen recording.
///
/// macOS puts a thumbnail in the corner of the screen for a few seconds, and everything you
/// might want to do with the picture is behind opening it. The island already knew a capture
/// had happened; this is the picture itself, with the two things anybody actually wants —
/// the image on the pasteboard, and the words in it on the pasteboard.
struct CaptureState: Equatable {
    var path: String
    var isRecording = false
    /// The picture itself, small. Nil for a recording, or where the file could not be read.
    var thumbnail: NSImage? = nil
    /// Whether it was put on the shelf, which is a switch and so not always true.
    var onShelf = false
    /// How big the picture is, in pixels, where that could be read.
    var pixels: CGSize? = nil
    /// The text Vision found in it, once it has looked. Nil while it is still looking, and
    /// empty where there was nothing to find.
    var text: String? = nil
    /// Where a QR code in the picture points, when there is one and it points at the web.
    var link: URL? = nil

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var title: String { isRecording ? "Screen recording" : "Screenshot" }
    var symbol: String { isRecording ? "record.circle" : "camera.viewfinder" }

    /// The line under the title: how big the picture is and where it went. Never the file
    /// name, which for a capture begins with the word already written above it and ends in a
    /// timestamp — "Screenshot" over "Screenshot 2026-09-09 at…" said one thing twice and
    /// nothing else. A recording has no size to give, so it says only where it went.
    var subtitle: String {
        var parts: [String] = []
        if let pixels, pixels.width > 0, pixels.height > 0 {
            parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
        }
        if onShelf { parts.append("On the shelf") }
        return parts.isEmpty ? name : parts.joined(separator: " · ")
    }

    /// The word the pill shows on its trailing edge: where the capture went, when it went
    /// somewhere, and otherwise what it is.
    var trailingText: String {
        if onShelf { return "On the shelf" }
        return isRecording ? "Recorded" : "Captured"
    }

    /// Whether there are words worth offering to copy.
    var hasText: Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// An external disk: what it is called, how full it is, and what has just happened to it.
///
/// The Mac's own answer to plugging a drive in is an icon appearing on a desktop nobody can
/// see under their windows, and its answer to pulling one out is a scolding dialog. The island
/// says both where you are already looking, and puts Eject on the one it says first.
struct DriveState: Equatable {
    enum Event: Equatable {
        /// Mounted and ready.
        case connected
        /// Unmounted cleanly — the moment it is safe to unplug.
        case ejected
        /// Pulled out with the disk still mounted; macOS itself scolds, so this is the
        /// island's quieter version of that.
        case surprise
        /// Asked to eject and refused, almost always because something is still using it.
        case busy
    }

    var name: String
    /// The mount point, so the card can open it in Finder or ask for it to be ejected.
    var path: String
    var total: Int64 = 0
    var free: Int64 = 0
    var event: Event = .connected
    /// Whether the Eject button belongs on the card at all: a disk image or a card reader
    /// ejects, an internal partition does not.
    var isEjectable = true

    var used: Int64 { max(0, total - free) }

    /// How full it is, or nil where the size could not be read.
    var fill: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    /// Whether the card draws the bar. Only while the disk is still attached: how full a disk
    /// *was* is not news, and a bar under "Safe to unplug" with no buttons beside it reads as
    /// a card that has not finished loading.
    var showsFill: Bool {
        guard fill != nil else { return false }
        return event == .connected || event == .busy
    }

    static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// "238 GB free of 1 TB", or nothing at all where the size is unknown.
    var sizeText: String? {
        guard total > 0 else { return nil }
        return "\(Self.formatter.string(fromByteCount: free)) free of \(Self.formatter.string(fromByteCount: total))"
    }

    /// The line under the name: what has happened, and how much room there is.
    var subtitle: String {
        switch event {
        case .connected: return sizeText ?? "Connected"
        case .ejected: return "Safe to unplug"
        case .surprise: return "Unplugged before it was ejected"
        case .busy: return "Something is still using it"
        }
    }

    var symbol: String {
        switch event {
        case .connected: return "externaldrive.fill"
        case .ejected: return "eject.fill"
        case .surprise: return "exclamationmark.triangle.fill"
        case .busy: return "externaldrive.badge.exclamationmark"
        }
    }

    var tint: String {
        switch event {
        case .connected: return "white"
        case .ejected: return "green"
        case .surprise, .busy: return "orange"
        }
    }

    /// The word the pill shows on its trailing edge: short enough for the menu bar.
    var trailingText: String {
        switch event {
        // "238 GB" on its own could be the size of the disk as easily as the room left on it.
        case .connected: return total > 0 ? "\(Self.formatter.string(fromByteCount: free)) free" : "Ready"
        case .ejected: return "Ejected"
        case .surprise: return "Careful"
        case .busy: return "In use"
        }
    }
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
    case drive(DriveState)
    case capture(CaptureState)
    case custom(CustomActivity)
    case shelf(ShelfState)

    /// Leading / trailing widths used in the compact (pill) state, in points.
    var compactWidths: (leading: CGFloat, trailing: CGFloat) {
        // A glyph slot is 34 pt: a 16 pt symbol with even air either side.
        switch self {
        case .nowPlaying: return (40, 40)
        case .timer: return (34, 60)
        case .stopwatch: return (34, 64)
        case .call: return (34, 60)
        case .battery: return (40, 56)
        case .bluetooth(let s): return (34, s.summaryPercent == nil ? 88 : 52)
        case .focus: return (34, 40)
        // The one state that answers in words needs the room for them; squeezed into a busy
        // menu bar it falls back to the dash, which is what `compactMinimalWidths` allows for.
        case .hud(let h): return (34, h.isUnavailable ? 124 : 72)
        case .silent: return (34, 56)
        case .unlock: return (34, 72)
        case .calendar: return (34, 64)
        case .download(let d): return (34, d.progress != nil ? 40 : 70)
        case .drive(let d): return (34, d.event == .connected && d.total > 0 ? 96 : 64)
        // "On the shelf" is what the trailing half says, and it needs the room for it.
        case .capture: return (34, 88)
        case .custom(let c):
            if c.progress != nil && c.showsRing { return (34, 40) }
            let text = c.trailingText ?? ""
            let w = min(120, max(44, CGFloat(text.count) * 8 + 20))
            return (34, w)
        case .shelf(let s): return (34, s.count > 9 ? 48 : 40)
        }
    }

    /// The narrowest each side can go when the menu bar leaves little room: a glyph on the
    /// left, and on the right only what still reads at a glance (bars, a ring, a count).
    /// Zero means the side is dropped rather than squeezed.
    var compactMinimalWidths: (leading: CGFloat, trailing: CGFloat) {
        switch self {
        case .nowPlaying: return (30, 28)
        case .timer: return (28, 28)
        case .stopwatch: return (28, 0)
        case .call: return (28, 0)
        case .battery: return (36, 0)
        case .bluetooth: return (28, 0)
        case .focus: return (28, 0)
        case .hud: return (28, 40)
        case .silent: return (28, 0)
        case .unlock: return (28, 0)
        case .calendar: return (28, 0)
        case .download(let d): return (28, d.progress != nil && !d.isComplete ? 28 : 0)
        case .drive: return (28, 0)
        case .capture: return (28, 0)
        case .custom(let c): return (28, c.progress != nil && c.showsRing ? 28 : 0)
        case .shelf: return (28, 28)
        }
    }

    /// Whether this content has a dedicated expanded (large) view.
    var hasExpandedView: Bool {
        switch self {
        case .unlock, .silent: return false
        default: return true
        }
    }

    /// Height of this content's system card below the notch, derived from what it stacks: one
    /// header row (12 above, 44 tall, 16 below), a progress bar under it, or a second row.
    static let cardRow: CGFloat = 72
    static let cardRowWithBar: CGFloat = 87
    static let cardTwoRows: CGFloat = 128

    var cardHeight: CGFloat {
        switch self {
        case .nowPlaying: return Self.cardTwoRows
        // 40 pt digits under their eyebrow need 59 pt of row, not 44.
        case .timer: return Self.cardRowWithBar + IslandTimer.extraRowsHeight
        case .stopwatch, .calendar: return Self.cardRowWithBar
        case .download(let d): return d.isComplete || d.progress == nil ? Self.cardRow : Self.cardRowWithBar
        // The bar is how full the disk is, drawn only where the size could be read and only
        // while there is still a disk to be full.
        case .drive(let d): return d.showsFill ? Self.cardRowWithBar : Self.cardRow
        case .capture: return Self.cardRow
        case .custom(let c):
            if c.body != nil { return Self.cardTwoRows }
            return c.progress != nil && !c.showsRing ? Self.cardRowWithBar : Self.cardRow
        case .unlock, .silent: return 40
        case .shelf: return Self.cardTwoRows
        default: return Self.cardRow
        }
    }
}

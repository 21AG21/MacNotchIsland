import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit

/// One window on the Mac, as the island shows it.
struct IslandWindow: Identifiable, Equatable {
    let id: CGWindowID
    var title: String
    var appName: String
    var pid: pid_t
    /// Where the window is, in the window server's coordinates: origin at the top-left of the
    /// primary display, y growing downward. Accessibility uses the same space, which is what
    /// lets a window be found and moved from what the window list said about it.
    var frame: CGRect
    var icon: NSImage?
    var thumbnail: NSImage?

    /// What to show under a tile: the window's own title where there is one (reading it needs
    /// the Screen Recording permission), the app's name otherwise.
    var label: String { title.isEmpty ? appName : title }
}

/// Where a window goes when it is snapped. The zones are the ones people reach for on a
/// laptop: two halves, the whole screen, and back to a centred window.
enum SnapZone: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, full, center

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .full: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        }
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .full: return "Fill screen"
        case .center: return "Centre"
        }
    }

    /// The rect this zone means on a screen, in the window server's top-left coordinates.
    func rect(in visible: CGRect) -> CGRect {
        switch self {
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY, width: (visible.width / 2).rounded(), height: visible.height)
        case .rightHalf:
            let width = (visible.width / 2).rounded()
            return CGRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .full:
            return visible
        case .center:
            let size = CGSize(width: (visible.width * 0.62).rounded(), height: (visible.height * 0.78).rounded())
            return CGRect(x: (visible.midX - size.width / 2).rounded(),
                          y: (visible.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }
}

/// Every window open on the Mac, with a live picture of each, plus the two things you want to
/// do with one from the notch: bring it to the front, or put it somewhere.
///
/// Pictures come from ScreenCaptureKit, which needs the Screen Recording permission. Without
/// it the windows are still listed — from the window list, which needs no permission — as app
/// tiles, and the section says what is missing and where to grant it. Moving a window needs
/// the Accessibility permission, the same one the media keys already ask for.
///
/// Nothing runs unless the section is on screen: the list is refreshed and the pictures
/// retaken on a timer that only exists while somebody is looking.
final class WindowsMonitor: ObservableObject {
    static let shared = WindowsMonitor()

    @Published private(set) var windows: [IslandWindow] = []
    /// False when Screen Recording has not been granted: no titles, no pictures.
    @Published private(set) var canCapture = CGPreflightScreenCaptureAccess()
    /// False when Accessibility has not been granted: windows can be raised but not moved.
    @Published private(set) var canMove = AXIsProcessTrusted()

    private var viewers = 0
    private var timer: Timer?
    private var capturing = false
    private var thumbnails: [CGWindowID: NSImage] = [:]

    /// How often the list and the pictures are refreshed while the section is open. Slow
    /// enough to cost nothing, fast enough that a window you just moved looks right.
    static let refreshInterval: TimeInterval = 2.0
    /// The most windows shown. Beyond this the strip is a haystack, and every extra picture
    /// is a capture.
    static let maxWindows = 12
    /// Pixel width every thumbnail is captured at; the tile draws it at half that.
    static let thumbnailWidth: CGFloat = 320
    /// Windows smaller than this are palettes, HUDs and tool strips, not windows to switch to.
    static let minimumSize = CGSize(width: 120, height: 80)

    /// Owners whose "windows" are parts of the system UI rather than anything to switch to.
    static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Centre", "Control Center",
        "Notification Centre", "Notification Center", "Spotlight", "WindowManager", "Wallpaper",
    ]

    private init() {}

    // MARK: - Lifetime

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = Self.refreshInterval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Reading

    func refresh() {
        let listed = Self.list()
        let allowed = CGPreflightScreenCaptureAccess()
        if canCapture != allowed { canCapture = allowed }
        let trusted = AXIsProcessTrusted()
        if canMove != trusted { canMove = trusted }
        // Keep the picture taken last time until a fresh one arrives, so a tile never blinks.
        let merged = listed.map { window -> IslandWindow in
            var copy = window
            copy.thumbnail = thumbnails[window.id]
            return copy
        }
        if windows != merged { windows = merged }
        thumbnails = thumbnails.filter { id, _ in listed.contains { $0.id == id } }
        guard allowed else { return }
        capture(listed.map(\.id))
    }

    /// Windows worth showing, front to back, as the window server lists them.
    static func list(now: [[String: Any]]? = nil) -> [IslandWindow] {
        let info = now ?? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [IslandWindow] = []
        for window in info {
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= minimumSize.width, frame.height >= minimumSize.height else { continue }
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.1 else { continue }
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            guard !owner.isEmpty, !ignoredOwners.contains(owner) else { continue }
            let title = (window[kCGWindowName as String] as? String) ?? ""
            result.append(IslandWindow(id: id, title: title, appName: owner, pid: pid, frame: frame,
                                       icon: NSRunningApplication(processIdentifier: pid)?.icon, thumbnail: nil))
            if result.count >= maxWindows { break }
        }
        return result
    }

    // MARK: - Pictures

    private func capture(_ ids: [CGWindowID]) {
        guard !capturing, !ids.isEmpty else { return }
        capturing = true
        Task { [weak self] in
            let shots = await Self.shots(of: ids)
            await MainActor.run {
                guard let self else { return }
                self.capturing = false
                guard !shots.isEmpty else { return }
                for (id, image) in shots { self.thumbnails[id] = image }
                self.windows = self.windows.map { window in
                    guard let image = shots[window.id] else { return window }
                    var copy = window
                    copy.thumbnail = image
                    return copy
                }
            }
        }
    }

    /// One picture per window, captured off the main thread. A window that cannot be captured
    /// (it went away mid-pass, or it belongs to a Space that is not on screen) is simply left
    /// out; the tile keeps the picture it had.
    private static func shots(of ids: [CGWindowID]) async -> [CGWindowID: NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [:] }
        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows { byID[window.windowID] = window }
        var result: [CGWindowID: NSImage] = [:]
        for id in ids {
            guard let window = byID[id], window.frame.width > 1, window.frame.height > 1 else { continue }
            let configuration = SCStreamConfiguration()
            let scale = min(1, thumbnailWidth / window.frame.width)
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            result[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return result
    }

    // MARK: - Permissions

    /// Asks for Screen Recording. macOS only shows its dialog once per app, so the button in
    /// the section opens System Settings as well.
    func requestCapture() {
        if !CGRequestScreenCaptureAccess() {
            SystemSettingsPane.screenRecording.open()
        }
        refresh()
    }

    /// Asks for Accessibility, with the system's own prompt.
    func requestMove() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
            SystemSettingsPane.accessibility.open()
        }
        refresh()
    }

    // MARK: - Acting on a window

    /// Brings a window to the front and gives it the keyboard.
    func focus(_ window: IslandWindow) {
        if let element = Self.axWindow(for: window) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // Without Accessibility this is all there is: the app comes forward with whichever
        // window it had in front, which is right far more often than not.
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    /// Puts a window in a zone of the screen it is on, and brings it forward so the result is
    /// visible. Does nothing without the Accessibility permission.
    @discardableResult
    func snap(_ window: IslandWindow, to zone: SnapZone) -> Bool {
        guard let element = Self.axWindow(for: window) else {
            requestMove()
            return false
        }
        let target = zone.rect(in: Self.visibleFrame(containing: window.frame))
        Self.setFrame(element, to: target)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        // The list is now wrong by exactly the window that moved; show that at once.
        refresh()
        return true
    }

    /// Closes a window, as its own close button would.
    @discardableResult
    func close(_ window: IslandWindow) -> Bool {
        guard let element = Self.axWindow(for: window) else {
            requestMove()
            return false
        }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)   // type checked just above
        refresh()
        return true
    }

    // MARK: - Accessibility plumbing

    /// The Accessibility element for a window the window list told us about. There is no
    /// public way to ask for a window by its number, so the app's windows are matched on what
    /// both sides agree about: where the window is, then what it is called.
    static func axWindow(for window: IslandWindow) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement], !elements.isEmpty else { return nil }
        if let byFrame = elements.first(where: { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - window.frame.minX) < 4 && abs(frame.minY - window.frame.minY) < 4
                && abs(frame.width - window.frame.width) < 4 && abs(frame.height - window.frame.height) < 4
        }) { return byFrame }
        guard !window.title.isEmpty else { return elements.first }
        return elements.first { title(of: $0) == window.title } ?? elements.first
    }

    static func setFrame(_ element: AXUIElement, to rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        // Size first, then position, then size again: a window with a minimum size clamps the
        // size it is given, and one near the screen edge clamps the position, so each pass
        // corrects what the other could not do on its own.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),   // type checked just above
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Screens

    /// The usable part of the screen a window is on (menu bar and Dock excluded), in the
    /// window server's top-left coordinates.
    static func visibleFrame(containing frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let flipped = screens.map { screen -> (CGRect, CGRect) in
            let full = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
            let visible = CGRect(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY,
                                 width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            return (full, visible)
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = flipped.first(where: { $0.0.contains(centre) }) { return hit.1 }
        // A window mostly off screen: the display it overlaps most, else the main one.
        let best = flipped.max { a, b in
            a.0.intersection(frame).area < b.0.intersection(frame).area
        }
        return best?.1 ?? flipped.first?.1 ?? frame
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

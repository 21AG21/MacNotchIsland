import AppKit
import SwiftUI

/// A transparent, click-through (outside the island) panel that floats above the menu bar
/// and full-screen apps, positioned over the notch of its screen.
final class NotchPanel: NSPanel {
    static let canvasWidth: CGFloat = 760
    static let canvasHeight: CGFloat = 340

    let geometry: NotchGeometry
    private var hosting: NotchHostingView<AnyView>?

    init(screen: NSScreen, geometry: NotchGeometry) {
        self.geometry = geometry
        let frame = NotchPanel.frame(for: screen)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none

        let root = AnyView(
            IslandRootView(geometry: geometry)
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
        )
        let view = NotchHostingView(rootView: root)
        let geo = geometry
        view.hitSizeProvider = { IslandLayout.make(presentation: ActivityCenter.shared.presentation, geometry: geo).hitSize }
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        hosting = view
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func frame(for screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let w = min(canvasWidth, sf.width)
        let h = min(canvasHeight, sf.height)
        return NSRect(x: sf.midX - w / 2, y: sf.maxY - h, width: w, height: h)
    }
}

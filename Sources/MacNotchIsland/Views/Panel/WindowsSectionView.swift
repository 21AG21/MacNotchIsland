import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every window on the Mac as a strip of live tiles: click one to bring it to the front, or
/// use the row of zones that appears on it to put it somewhere. Mission Control, in the notch.
struct WindowsSectionView: View {
    @ObservedObject private var monitor = WindowsMonitor.shared
    /// Watched for the find, which lives on the panel rather than on this view.
    @ObservedObject private var center = ActivityCenter.shared
    @State private var hovered: CGWindowID?
    /// The tile a file is being held over, if any.
    @State private var dropTarget: CGWindowID?
    /// Windows picked out with a Command-click, to be laid out together.
    @State private var selection: Set<CGWindowID> = []

    /// Every window there is, before the find narrows it.
    private var allWindows: [IslandWindow] {
        RenderMode.isGallery ? WindowsSectionView.sampleWindows : monitor.windows
    }

    /// What the strip shows: everything, or what the letters typed on this section match. A
    /// window is found by its app's name as readily as by its title, because half the time
    /// what you want is "the other Safari one".
    private var windows: [IslandWindow] {
        allWindows.filter { PanelFind.matches([$0.appName, $0.label], query: center.findQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader("Windows") {
                // Each permission does half of this section: one draws the pictures, the other
                // moves and closes the windows. Whichever is missing is offered here, because
                // a tile with no picture and a zone button that quietly does nothing are not
                // explanations.
                if !monitor.canCapture {
                    PillButton(title: "Show pictures", tint: .white.opacity(0.85)) { monitor.requestCapture() }
                } else if !monitor.canMove {
                    PillButton(title: "Allow moving", tint: .white.opacity(0.85)) { monitor.requestMove() }
                } else if !allWindows.isEmpty || center.findQuery != nil {
                    // Return brings the first match forward: type "mai", press Return, and
                    // Mail is in front — a window switcher that needs no window switcher. The
                    // field stays whatever else is on this line: a find that is under way
                    // holds the keyboard, and a field that is holding the keyboard has to be
                    // somewhere you can see it.
                    FindField(matches: windows.count) {
                        guard let index = center.findTarget(of: windows.count) else { return }
                        monitor.focus(windows[index])
                    }
                    if !selected.isEmpty {
                        // Two or more is a layout; one is a selection on its way to being one,
                        // and saying so is how somebody learns the Command-click did anything.
                        if selected.count > 1 {
                            PillButton(title: "Tile \(selected.count)", symbol: "rectangle.split.2x1",
                                       prominent: true) {
                                monitor.tile(selected)
                                selection.removeAll()
                            }
                        } else {
                            Text("1 picked")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        PillButton(title: "Clear", tint: .white.opacity(0.85)) { selection.removeAll() }
                    } else if center.findQuery == nil {
                        // The field counts the matches itself while it is up, so the tally
                        // that lives here the rest of the time steps aside rather than saying
                        // the same thing twice on one line.
                        Text(allWindows.count == 1 ? "1 open" : "\(allWindows.count) open")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.viewerAppeared() }
        .onDisappear {
            monitor.viewerDisappeared()
            selection.removeAll()
        }
        // A window that closed, or an app that quit, must not stay picked out: the pill would
        // then offer to lay out something that is not there.
        .onChange(of: monitor.windows) { _, current in
            // Every capture gives the tiles new pictures, so this runs several times a second
            // while the section is open: it writes only when the selection has actually lost
            // something.
            guard !selection.isEmpty else { return }
            let kept = selection.intersection(Set(current.map(\.id)))
            if kept != selection { selection = kept }
        }
    }

    @ViewBuilder
    private var content: some View {
        if allWindows.isEmpty && !monitor.canCapture {
            SectionEmptyState(symbol: "macwindow.on.rectangle",
                              title: "Let the notch see your windows",
                              subtitle: "Screen Recording is what draws each window's picture.") {
                PillButton(title: "Allow", prominent: true) { monitor.requestCapture() }
            }
        } else if allWindows.isEmpty {
            SectionEmptyState(symbol: "macwindow", title: "No windows open",
                              subtitle: "Everything you open shows up here.")
        } else if windows.isEmpty {
            // Windows are open; none of them answers to what was typed.
            SectionEmptyState(symbol: "magnifyingglass", title: "No matches")
        } else {
            IslandScrollStrip {
                HStack(spacing: Self.tileGap) {
                    ForEach(windows) { window in
                        tile(window, isFound: found == window.id)
                    }
                }
                .padding(.bottom, Self.stripBottom)
            }
            .frame(height: Self.stripHeight)
        }
    }

    // MARK: - A tile

    /// Four tiles and the three gaps between them fill the section's width exactly, and the
    /// tile plus its name fills the body with room under the last line for the scroller. At a
    /// fixed 148 they stopped fifty points short of the right edge — where the header's count
    /// sits — so a row of exactly four read as a row that had come up short rather than as a
    /// strip that scrolls.
    static let tileGap: CGFloat = 10
    static var tileWidth: CGFloat { ((IslandLayout.panelContentWidth - 3 * tileGap) / 4).rounded(.down) }
    static let tileHeight: CGFloat = 88
    static let labelHeight: CGFloat = 15
    static let labelGap: CGFloat = 4
    static let stripBottom: CGFloat = 2
    static var stripHeight: CGFloat { tileHeight + labelGap + labelHeight + stripBottom }

    /// The tile the find's mark is on, which Return would bring forward.
    private var found: CGWindowID? {
        guard let index = center.findTarget(of: windows.count) else { return nil }
        return windows[index].id
    }

    /// The picked-out windows, in the order the strip shows them — which is the order they are
    /// laid out in, so the row on screen matches the row in the panel.
    private var selected: [IslandWindow] {
        allWindows.filter { selection.contains($0.id) }
    }

    /// A plain click brings a window forward; Command-click picks it out instead, the way it
    /// does on the shelf and in every list on the Mac.
    private func click(_ window: IslandWindow) {
        guard NSEvent.modifierFlags.contains(.command) else {
            selection.removeAll()
            monitor.focus(window)
            return
        }
        if selection.contains(window.id) { selection.remove(window.id) } else { selection.insert(window.id) }
    }

    private func tile(_ window: IslandWindow, isFound: Bool = false) -> some View {
        let showsZones = hovered == window.id
        let dropping = dropTarget == window.id
        let picked = selection.contains(window.id)
        // What Return would bring forward: marked, so walking the matches with the arrows
        // shows where you are before you commit to it.
        let marked = dropping || picked || isFound
        return VStack(alignment: .leading, spacing: Self.labelGap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                if let thumbnail = window.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.tileWidth, height: Self.tileHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(marked ? Color.accentColor : Color.white.opacity(showsZones ? 0.35 : 0.12),
                                  lineWidth: marked ? 2 : 1)
                if picked { pickedBadge }
                if showsZones { zones(window) }
            }
            .frame(width: Self.tileWidth, height: Self.tileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { click(window) }
            .onHover { inside in
                hovered = inside ? window.id : (hovered == window.id ? nil : hovered)
            }
            // "Open this in that": the same thing as dropping a file on the app's Dock icon,
            // in front of the window you want it in.
            .islandDrop(of: [UTType.fileURL], isTargeted: Binding(
                get: { dropTarget == window.id },
                set: { inside in dropTarget = inside ? window.id : (dropTarget == window.id ? nil : dropTarget) }
            )) { providers in
                DroppedFiles.paths(from: providers) { paths in
                    guard !paths.isEmpty else { return }
                    monitor.open(paths.map { URL(fileURLWithPath: $0) }, with: window)
                }
                return true
            }

            HStack(spacing: 5) {
                if let icon = window.icon, window.thumbnail != nil {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(window.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.tileWidth, height: Self.labelHeight, alignment: .leading)
        }
        .animation(IslandMotion.hover, value: showsZones)
        .animation(IslandMotion.hover, value: marked)
        // Everything a tile can do to a window, in words — including the two that belong to
        // the app rather than the window, which nothing else on the Mac offers from a picture
        // of it.
        .contextMenu { menu(window) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.appName), \(window.label)")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { monitor.focus(window) }
        .accessibilityAction(named: picked ? "Leave it out" : "Pick it out to tile") {
            if picked { selection.remove(window.id) } else { selection.insert(window.id) }
        }
    }

    /// A tile's own menu. The zones on the picture are for the pointer; this is for the
    /// person who wants to be told what the choices are, and it carries the two the zones
    /// cannot: hiding the app, and quitting it.
    @ViewBuilder
    private func menu(_ window: IslandWindow) -> some View {
        Button("Bring to Front") { monitor.focus(window) }
        Button("Minimise") { monitor.minimise(window) }
        Divider()
        ForEach(SnapZone.allCases) { zone in
            Button(zone.title) { monitor.snap(window, to: zone) }
        }
        if NSScreen.screens.count > 1 {
            Button("Next Display") { monitor.sendToNextDisplay(window) }
        }
        Divider()
        Button("Close Window") { monitor.close(window) }
        // The app's own two. Named, so nobody quits something by reaching for a glyph.
        Button("Hide \(window.appName)") { NSRunningApplication(processIdentifier: window.pid)?.hide() }
        Button("Quit \(window.appName)") { NSRunningApplication(processIdentifier: window.pid)?.terminate() }
    }

    /// The tick on a picked tile, in the corner the zones do not use.
    private var pickedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white, Color.accentColor)
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// The zones, over the picture, while the pointer is on the tile — and the one other thing
    /// you do to a window from a distance: close it.
    /// One button of the row that lays a window out: same disc, same size, whatever it does.
    private func zoneButton(symbol: String, label: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(help)
        .accessibilityLabel(label)
    }

    /// One of a tile's corner buttons: smaller than a zone, and out of the way of them.
    private func cornerButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .padding(5)
        .help(label)
        .accessibilityLabel(label)
    }

    private func zones(_ window: IslandWindow) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.55))
            HStack(spacing: 6) {
                ForEach(SnapZone.allCases) { zone in
                    zoneButton(symbol: zone.symbol, label: "\(zone.title), \(window.label)",
                               help: zone.title) { monitor.snap(window, to: zone) }
                }
                // Only where there is another display to send it to. Every other button here
                // rearranges a window on the screen it is already on.
                if NSScreen.screens.count > 1 {
                    zoneButton(symbol: "display.2", label: "Next display, \(window.label)",
                               help: "Next display") { monitor.sendToNextDisplay(window) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The tile's own two traffic lights, in the corners the real ones live in: put it
            // away on the left, close it on the right. The row of zones in the middle moves a
            // window around this screen; these two take it off the screen.
            cornerButton(symbol: "minus", label: "Minimise \(window.label)") { monitor.minimise(window) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            cornerButton(symbol: "xmark", label: "Close \(window.label)") { monitor.close(window) }
        }
        .transition(.opacity)
    }

    /// Windows for the gallery, which has no permission to see real ones.
    static let sampleWindows: [IslandWindow] = [
        IslandWindow(id: 1, title: "IslandBodyView.swift", appName: "Xcode", pid: 0,
                     frame: CGRect(x: 0, y: 0, width: 1440, height: 900), icon: nil, thumbnail: nil),
        IslandWindow(id: 2, title: "Inbox — 3 unread", appName: "Mail", pid: 0,
                     frame: CGRect(x: 0, y: 0, width: 1200, height: 800), icon: nil, thumbnail: nil),
        IslandWindow(id: 3, title: "Notch Island — Design", appName: "Safari", pid: 0,
                     frame: CGRect(x: 0, y: 0, width: 1280, height: 860), icon: nil, thumbnail: nil),
        IslandWindow(id: 4, title: "Downloads", appName: "Finder", pid: 0,
                     frame: CGRect(x: 0, y: 0, width: 900, height: 600), icon: nil, thumbnail: nil),
    ]
}

import AppKit
import SwiftUI

/// Every window on the Mac as a strip of live tiles: click one to bring it to the front, or
/// use the row of zones that appears on it to put it somewhere. Mission Control, in the notch.
struct WindowsSectionView: View {
    @ObservedObject private var monitor = WindowsMonitor.shared
    @State private var hovered: CGWindowID?

    private var windows: [IslandWindow] {
        RenderMode.isGallery ? WindowsSectionView.sampleWindows : monitor.windows
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
                } else if !windows.isEmpty {
                    Text(windows.count == 1 ? "1 open" : "\(windows.count) open")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerDisappeared() }
    }

    @ViewBuilder
    private var content: some View {
        if windows.isEmpty && !monitor.canCapture {
            SectionEmptyState(symbol: "macwindow.on.rectangle",
                              title: "Let the notch see your windows",
                              subtitle: "Screen Recording is what draws each window's picture.") {
                PillButton(title: "Allow", prominent: true) { monitor.requestCapture() }
            }
        } else if windows.isEmpty {
            SectionEmptyState(symbol: "macwindow", title: "No windows open",
                              subtitle: "Everything you open shows up here.")
        } else {
            IslandScrollStrip {
                HStack(spacing: Self.tileGap) {
                    ForEach(windows) { window in
                        tile(window)
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

    private func tile(_ window: IslandWindow) -> some View {
        let showsZones = hovered == window.id
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
                    .strokeBorder(Color.white.opacity(showsZones ? 0.35 : 0.12), lineWidth: 1)
                if showsZones { zones(window) }
            }
            .frame(width: Self.tileWidth, height: Self.tileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { monitor.focus(window) }
            .onHover { inside in
                hovered = inside ? window.id : (hovered == window.id ? nil : hovered)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.appName), \(window.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { monitor.focus(window) }
    }

    /// The zones, over the picture, while the pointer is on the tile — and the one other thing
    /// you do to a window from a distance: close it.
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
                    Button(action: { _ = monitor.snap(window, to: zone) }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.16))
                            Image(systemName: zone.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                    }
                    .buttonStyle(IslandButtonStyle())
                    .help(zone.title)
                    .accessibilityLabel("\(zone.title), \(window.label)")
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

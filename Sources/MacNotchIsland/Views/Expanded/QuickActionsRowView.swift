import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Actions row: favourite apps first, then favourited Shortcuts, as round buttons.
/// Clicking an app opens it and closes the panel; clicking a shortcut runs it where it is.
struct QuickActionsRowView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    @ObservedObject private var apps = FavoriteApps.shared

    /// Eight buttons is what the row holds; apps come first because they are what people
    /// reach for most.
    static let capacity = 8

    /// The way to fill this row: straight to the pane that does it, rather than to whichever
    /// pane Settings happened to be left on. The section's header offers the same thing when
    /// there is already something here to edit.
    static func openSettings() { SettingsWindow.open(.shortcuts) }

    var body: some View {
        Group {
            if runner.favorites.isEmpty && apps.apps.isEmpty {
                // One row, like the timer presets under it: a glyph, a line, the way in.
                HStack(spacing: 12) {
                    Image(systemName: "bolt")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 24, height: 40, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No quick actions yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Your apps and Shortcuts, one click away.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 8)
                    PillButton(title: "Choose Actions…") { Self.openSettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            } else {
                let favourites = apps.apps
                // Wide enough that two names at full width still cannot touch: each name is
                // centred on its own disc and overhangs it either side, see `AppButton`.
                HStack(alignment: .top, spacing: ActionTile.gap) {
                    ForEach(favourites, id: \.path) { app in
                        AppButton(path: app.path, name: app.name)
                    }
                    ForEach(runner.favorites.prefix(max(0, Self.capacity - favourites.count)), id: \.self) { name in
                        QuickActionButton(name: name)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The measurements every tile in the Actions row shares.
///
/// A name is wider than the disc it belongs to, and only one of the two can be the tile. Make
/// it the name and the first disc sits 13 pt inside the panel's content column, out of line
/// with the section title above it and the rail below. Make it the name *and* hang both from
/// the leading edge — which is what this row used to do — and no name is under the middle of
/// the thing it names: a short one hugs the left of its box and sits left of its disc, a long
/// one fills the box and sits right of it, so the row wanders as the names change.
///
/// So the tile is the disc, it hangs from the column like everything else in the panel, and
/// the name is centred on it and allowed to overhang. It is what the Home screen does with an
/// app's name, and the row's spacing is set so two names at full width still cannot meet.
enum ActionTile {
    static let diameter: CGFloat = 40
    static let label: CGFloat = 66
    static let gap: CGFloat = 30
}

/// One favourite app: its own icon, its name, and a click that opens it.
private struct AppButton: View {
    let path: String
    let name: String
    @ObservedObject private var apps = FavoriteApps.shared
    @State private var hovering = false

    var body: some View {
        Button(action: { apps.launch(path) }) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.12))
                    if let icon = apps.icon(for: path) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: ActionTile.diameter, height: ActionTile.diameter)
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    // Its own box, centred; then only the disc's width claimed of the row, so
                    // what it overhangs is space and not the next tile.
                    .frame(width: ActionTile.label)
                    .frame(width: ActionTile.diameter)
            }
        }
        .buttonStyle(IslandButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.hover, value: hovering)
        .help("Open \(name)")
        .accessibilityLabel("Open \(name)")
    }
}

private struct QuickActionButton: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var hovering = false
    /// A file being held over this tile. A shortcut that takes an input is a droplet, and
    /// this is the only place on the island where dropping a file means something other than
    /// "put it on the shelf".
    @State private var dropping = false

    var body: some View {
        Button(action: { runner.run(name) }) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(dropping ? 0.32 : (hovering ? 0.2 : 0.12)))
                    Image(systemName: runner.symbol(for: name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: ActionTile.diameter, height: ActionTile.diameter)
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    // Its own box, centred; then only the disc's width claimed of the row, so
                    // what it overhangs is space and not the next tile.
                    .frame(width: ActionTile.label)
                    .frame(width: ActionTile.diameter)
            }
        }
        .buttonStyle(IslandButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.hover, value: hovering)
        .animation(IslandMotion.hover, value: dropping)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            DroppedFiles.paths(from: providers) { paths in
                guard !paths.isEmpty else { return }
                runner.run(name, inputPaths: paths)
            }
            return true
        }
        .help("Run \(name), or drop files on it to run it with them.")
        .accessibilityLabel("Run shortcut \(name)")
    }
}

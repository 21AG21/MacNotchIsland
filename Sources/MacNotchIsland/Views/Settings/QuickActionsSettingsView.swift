import SwiftUI

/// The quick actions list: every installed Shortcut with a favourite switch, a Refresh button,
/// and a per-favourite SF Symbol override. No chrome of its own — the Shortcuts pane drops
/// these rows straight into a `Form` section.
struct QuickActionsSettingsView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    /// Watched because the favourites share the Actions row with the apps: every app kept is
    /// one favourite fewer the row can show.
    @ObservedObject private var apps = FavoriteApps.shared

    /// How many favourites the row has room for beside the apps it draws (`FavoriteApps.inRow`).
    private var room: Int { QuickActionsRowView.shortcutRoom(besideApps: apps.inRow) }

    /// What the pane says under "Favourites": the row's own count (`QuickActionsRowView.tally`)
    /// and, while apps kept are on a disk that is not plugged in, that they are away. The room
    /// is the room the row has now, and an app coming back takes a button of it: where the
    /// favourites chosen would not all fit then, the tally says how many would, rather than
    /// leave a favourite to drop out of the row unannounced when the disk is plugged in.
    static func tally(favourites: Int, appsInRow: Int, appsAway: Int) -> String {
        let now = QuickActionsRowView.tally(favourites: favourites, apps: appsInRow)
        guard appsAway > 0 else { return now }
        let one = appsAway == 1
        let whenBack = QuickActionsRowView.shortcutRoom(besideApps: appsInRow + appsAway)
        guard favourites > whenBack else {
            return now + (one ? ". 1 app is away on a disk that is not plugged in"
                              : ". \(appsAway) apps are away on disks that are not plugged in")
        }
        return now + (one ? ". \(whenBack) fit once the app on a disk that is not plugged in is back"
                          : ". \(whenBack) fit once the \(appsAway) apps on disks that are not plugged in are back")
    }

    var body: some View {
        Group {
            LabeledContent {
                Button("Refresh") { runner.refresh() }
                    .help("Ask the Shortcuts app for the current list.")
            } label: {
                Text("Favourites")
                Text(Self.tally(favourites: runner.favorites.count, appsInRow: apps.inRow, appsAway: apps.away.count))
            }

            if !runner.isAvailable {
                // Not "add some in the Shortcuts app": there is nothing here to ask them of.
                Text("This Mac has no shortcuts command, so none can be listed or run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if runner.available.isEmpty {
                Text("No shortcuts found. Add some in the Shortcuts app, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(runner.available, id: \.self) { name in
                    row(for: name)
                }
            }
        }
        .onAppear { runner.refresh() }
    }

    @ViewBuilder
    private func row(for name: String) -> some View {
        let isFavorite = runner.isFavorite(name)
        LabeledContent {
            HStack(spacing: 10) {
                if isFavorite {
                    SymbolField(name: name)
                }
                Toggle("", isOn: Binding(
                    get: { runner.isFavorite(name) },
                    set: { _ in runner.toggleFavorite(name, room: room) }
                ))
                .labelsHidden()
                .disabled(!isFavorite && runner.favorites.count >= room)
                .accessibilityLabel(Text(name))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: runner.symbol(for: name))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// The SF Symbol name for one favourite. Empty means the automatic symbol.
private struct SymbolField: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var text: String = ""

    init(name: String) {
        self.name = name
    }

    var body: some View {
        TextField("Symbol", text: $text)
            .frame(width: 130)
            .font(.callout)
            .help("An SF Symbol name, such as bolt.fill. Press Return to use it; a name that is not a symbol, or nothing at all, goes back to the automatic symbol.")
            .accessibilityLabel(Text("Symbol for \(name)"))
            // On Return only. Saved on every keystroke, a name was stored while it was still
            // being typed — "b", "bo", "bol" — and one left half-typed or misspelt drew nothing
            // on the tile at all. The field is put back to what was kept, so a name that was
            // refused does not sit there looking as if it had been taken.
            .onSubmit {
                runner.setSymbol(text, for: name)
                text = runner.symbolOverride(for: name) ?? ""
            }
            .onAppear { text = runner.symbolOverride(for: name) ?? "" }
    }
}

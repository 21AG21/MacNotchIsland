import SwiftUI

/// The quick actions list: every installed Shortcut with a favourite switch, a Refresh button,
/// and a per-favourite SF Symbol override. No chrome of its own — the Shortcuts pane drops
/// these rows straight into a `Form` section.
struct QuickActionsSettingsView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    /// Watched because the favourites share the Actions row with the apps: every app kept is
    /// one favourite fewer the row can show.
    @ObservedObject private var apps = FavoriteApps.shared

    /// How many favourites the row has room for beside the apps.
    private var room: Int { QuickActionsRowView.shortcutRoom(besideApps: apps.paths.count) }

    var body: some View {
        Group {
            LabeledContent {
                Button("Refresh") { runner.refresh() }
                    .help("Ask the Shortcuts app for the current list.")
            } label: {
                Text("Favourites")
                Text(QuickActionsRowView.tally(favourites: runner.favorites.count, apps: apps.paths.count))
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

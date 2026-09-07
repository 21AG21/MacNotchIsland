import SwiftUI

/// The quick actions list: every installed Shortcut with a favourite switch, a Refresh button,
/// and a per-favourite SF Symbol override. No chrome of its own — the Shortcuts pane drops
/// these rows straight into a `Form` section.
struct QuickActionsSettingsView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared

    var body: some View {
        Group {
            LabeledContent {
                Button("Refresh") { runner.refresh() }
                    .help("Ask the Shortcuts app for the current list.")
            } label: {
                Text("Favourites")
                Text("\(runner.favorites.count) of 8 chosen")
            }

            if runner.available.isEmpty {
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
                    set: { _ in runner.toggleFavorite(name) }
                ))
                .labelsHidden()
                .disabled(!isFavorite && runner.favorites.count >= 8)
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
            .help("An SF Symbol name, such as bolt.fill. Leave empty for the automatic symbol.")
            .accessibilityLabel(Text("Symbol for \(name)"))
            .onSubmit { runner.setSymbol(text, for: name) }
            .onChange(of: text) { _, newValue in runner.setSymbol(newValue, for: name) }
            .onAppear { text = runner.symbolOverride(for: name) ?? "" }
    }
}

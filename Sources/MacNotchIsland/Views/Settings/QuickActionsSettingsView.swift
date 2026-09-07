import SwiftUI

/// "Quick actions" settings section body: every installed Shortcut with a favourite toggle,
/// a Refresh button, and a per-favourite SF Symbol override with a live preview. No window
/// chrome of its own — SettingsView embeds this inside one of its `section(...)` blocks.
struct QuickActionsSettingsView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if runner.available.isEmpty {
                Text("No shortcuts found. Add some in the Shortcuts app, then refresh.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(runner.available, id: \.self) { name in
                    row(for: name)
                }
            }
        }
        .onAppear { runner.refresh() }
    }

    private var header: some View {
        HStack {
            Text("\(runner.favorites.count)/8 favourited")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") { runner.refresh() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func row(for name: String) -> some View {
        let isFavorite = runner.isFavorite(name)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: runner.symbol(for: name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 20)
                Text(name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isFavorite {
                    SymbolField(name: name)
                }
                Toggle("", isOn: Binding(
                    get: { runner.isFavorite(name) },
                    set: { _ in runner.toggleFavorite(name) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.primary)
                .disabled(!isFavorite && runner.favorites.count >= 8)
            }
            .padding(.vertical, 8)
            Divider().opacity(0.5)
        }
    }
}

/// Small SF Symbol name field with a live glyph preview, for overriding a favourite's icon.
private struct SymbolField: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: runner.symbol(for: name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("SF Symbol", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 130)
                .onSubmit { runner.setSymbol(text, for: name) }
                .onChange(of: text) { _, newValue in runner.setSymbol(newValue, for: name) }
        }
        .onAppear { text = runner.symbolOverride(for: name) ?? "" }
    }
}

import AppKit
import SwiftUI

/// "Media": where playback information comes from, and how other apps and scripts can push
/// their own Live Activities into the island.
struct MediaPane: View {
    @ObservedObject private var music = NowPlayingService.shared
    @ObservedObject private var prefs = Preferences.shared
    @AppStorage("settingsSection") private var selectedSection = SettingsSection.general.rawValue

    var body: some View {
        Form {
            // Not one word naming the winner, which had nothing to say when there was no
            // winner. A line for each source, so a blank card can be read from here: nothing
            // is playing, or a source has stopped — and which, and what to do about it.
            Section {
                LabeledContent("MediaRemote helper") {
                    HStack(spacing: 8) {
                        Text(Self.wording(music.health[.adapter]))
                            .foregroundStyle(.secondary)
                        Button("Restart Helper") { music.restartHelper() }
                            .disabled(!helperCanRestart)
                            .help("Quit the helper and start it again now, without waiting for it to be tried on its own.")
                    }
                }
                LabeledContent("MediaRemote", value: Self.wording(music.health[.mediaRemote]))
                LabeledContent("AppleScript (Music and Spotify)", value: Self.wording(music.health[.appleScript]))
                // The same helper as the first row, by the same name: whether this build carries
                // its file at all, which is the first thing to know when that row says nothing.
                LabeledContent("MediaRemote helper file",
                               value: AdapterBackend.dylibURL != nil ? "Bundled" : "Not found")
            } header: {
                Text("Now Playing")
            } footer: {
                HStack(spacing: 8) {
                    // The budget and the rest are read from the rule rather than written out
                    // here, so this cannot quietly become a promise the app has stopped keeping.
                    Text("Notch Island reads the system player, so Music, Spotify, Safari and most other apps work without setup. The source marked Live is the one the island is showing; the others stand by until it stops answering. A helper that stops answering is started again on its own, and after more than \(AdapterBackend.restartBudget) crashes in \(Int(AdapterBackend.restartWindow / 60)) minutes it rests for \(Int(AdapterBackend.restCooldown / 60)) minutes first. Restart Helper skips the wait.")
                    Button("Open Activities") {
                        selectedSection = SettingsSection.activities.rawValue
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                Picker("Leftmost", selection: transportSlot(0)) { slotChoices }
                Picker("Left of back", selection: transportSlot(1)) { slotChoices }
                Picker("Right of forward", selection: transportSlot(2)) { slotChoices }
                Picker("Rightmost", selection: transportSlot(3)) { slotChoices }
            } header: {
                Text("Buttons beside play")
            } footer: {
                Text("Up to two more buttons either side of back, play and forward, the same size as they are. Out of the box there are none and the row is Music's three. For podcasts and audiobooks, Back 15 s and Forward 15 s are the pair to choose; for albums, Shuffle and Repeat. A button the player in front does not offer is drawn dimmed. Where MediaRemote says nothing about shuffle, repeat or the favourite, Music and Spotify are asked with AppleScript, which macOS asks you to allow once for each.")
            }

            Section {
                Text(Self.startExample)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.endExample)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Let pushed cards run Shortcuts", isOn: $prefs.apiShortcutsEnabled)
                Text("A card pushed in can put a button on the island. That button may always open a web link. Only with this on may it also name one of your Shortcuts and run it.\n\nAnything on this Mac can push a card, and a Shortcut can run a shell script. A card is drawn in the island's own hand, so its button reads as the island asking — and \u{201C}Update available / Install\u{201D} is a sentence anybody would click. Leave this off unless you are pushing cards yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Automation")
            } footer: {
                Text("Push your own Live Activities from scripts, Shortcuts or a build system by opening these URLs. Scripts/notchctl in the repository wraps them in a command-line helper.")
            }
        }
        .formStyle(.grouped)
    }

    private static let startExample =
        "open \"notchisland://activity?id=build&title=Building&symbol=hammer.fill&tint=blue&progress=0.4\""
    private static let endExample = "open \"notchisland://activity/end?id=build\""

    /// The six things a place beside play can hold.
    @ViewBuilder
    private var slotChoices: some View {
        ForEach(TransportSlot.allCases) { slot in
            Text(slot.title).tag(slot)
        }
    }

    /// One place beside play. Choosing a button that is already in another place moves it
    /// here, see `TransportSlot.placing`.
    private func transportSlot(_ index: Int) -> Binding<TransportSlot> {
        Binding(
            get: { TransportSlot.resolved(stored: prefs.transportSlots)[index] },
            set: { slot in
                let current = TransportSlot.resolved(stored: prefs.transportSlots)
                prefs.transportSlots = TransportSlot.placing(slot, at: index, in: current).map(\.rawValue)
            }
        )
    }

    /// A helper this Mac cannot run has nothing to restart, and one that has not been started
    /// — Now Playing switched off — must not be started from here behind the switch's back.
    private var helperCanRestart: Bool {
        guard let health = music.health[.adapter] else { return false }
        return health != .unavailable
    }

    /// The words for a backend's state. Nil is a backend that has not been asked, because Now
    /// Playing is switched off. "No track" rather than "nothing playing": on macOS 15.4 and
    /// later MediaRemote answers with no track while a song is plainly playing, and a row that
    /// said "nothing playing" next to a helper marked Live would read as a contradiction.
    private static func wording(_ health: NowPlayingService.Health?) -> String {
        guard let health else { return "Off" }
        switch health {
        case .live: return "Live"
        case .idle: return "Answering, no track"
        case .standingBy: return "Standing by"
        case .givenUp: return "Not answering"
        case .unavailable: return "Not available on this Mac"
        }
    }
}

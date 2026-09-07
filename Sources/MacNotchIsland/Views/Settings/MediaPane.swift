import AppKit
import SwiftUI

/// "Media": where playback information comes from, and how other apps and scripts can push
/// their own Live Activities into the island.
struct MediaPane: View {
    @ObservedObject private var music = NowPlayingService.shared
    @AppStorage("settingsSection") private var selectedSection = SettingsSection.general.rawValue

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: sourceDescription)
                LabeledContent("Media helper",
                               value: AdapterBackend.dylibURL != nil ? "Bundled" : "Not found")
            } header: {
                Text("Now Playing")
            } footer: {
                HStack(spacing: 8) {
                    Text("Notch Island reads the system player, so Music, Spotify, Safari and most other apps work without setup.")
                    Button("Open Activities") {
                        selectedSection = SettingsSection.activities.rawValue
                    }
                    .buttonStyle(.link)
                }
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

    private var sourceDescription: String {
        switch music.activeBackend {
        case .adapter: return "MediaRemote helper"
        case .mediaRemote: return "MediaRemote"
        case .appleScript: return "AppleScript (Music and Spotify)"
        case .inactive: return "Nothing playing"
        }
    }
}

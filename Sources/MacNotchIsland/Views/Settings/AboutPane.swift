import AppKit
import SwiftUI

/// "About": what this build is, and the three things people come here to do — take the tour,
/// check for a newer version, and find the source.
struct AboutPane: View {
    @ObservedObject private var updates = UpdateChecker.shared

    private static let repositoryURL = URL(string: "https://github.com/21AG21/MacNotchIsland")

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let icon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notch Island")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Version \(Self.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("A Dynamic Island for the MacBook notch.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent {
                    Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
                } label: {
                    Text("Updates")
                    Text(updateDetail)
                }
                LabeledContent {
                    Button("Show Welcome Tour") { WelcomeWindowController.shared.show() }
                } label: {
                    Text("Welcome tour")
                    Text("The four things worth knowing, in one window.")
                }
                LabeledContent {
                    Button("View on GitHub") { openRepository() }
                } label: {
                    Text("Source code")
                    Text("github.com/21AG21/MacNotchIsland")
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Updates are never installed automatically. Checking opens the release page so you can download it yourself.")
            }

            Section {
                Text("The island pauses its animations while your Mac sleeps, slows them down on battery, and stops them in Low Power Mode.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Energy")
            } footer: {
                Text("Notch Island also lives in the menu bar, where you will find timers, a demo of every alert, and Quit.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Details

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private var updateDetail: String {
        if updates.updateAvailable, let latest = updates.latestVersion {
            return "Version \(latest) is available."
        }
        if updates.latestVersion != nil {
            return "Notch Island is up to date."
        }
        return "Checked once a day when automatic checks are on."
    }

    private func openRepository() {
        guard let url = Self.repositoryURL else { return }
        NSWorkspace.shared.open(url)
    }
}

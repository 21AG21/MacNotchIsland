import AVFoundation
import SwiftUI

struct CallExpandedView: View {
    let state: CallState
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel
    @ObservedObject private var mic = MicrophoneControl.shared

    private var icon: NSImage? { CallAppIcon.icon(for: state.bundleID) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                // One stable container for both branches, so the matched group keeps its member
                // whether or not the app icon resolves.
                ZStack {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Circle().fill(Color.named("green").opacity(0.18))
                        Image(systemName: "phone.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.named("green"))
                    }
                }
                .frame(width: 44, height: 44)
                .islandMatched(IslandMatchedID.callGlyph)
                .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.appName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Call in progress")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(ctx.date.timeIntervalSince(state.startedAt).mmss)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: false))
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .islandMatched(IslandMatchedID.callTime)
                    }
                    // Name, status and the ticking digits read as one sentence; the button
                    // beside them keeps its own label.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: ctx.date))
                }
                // The microphone itself, for every app at once — the call app's own mute, the
                // browser tab that also has it, and the dictation nobody meant to leave on. A
                // quiet disc while it is live, filled red while it is not, as on the phone.
                CircleActionButton(symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill",
                                   tint: mic.isMuted ? Color.named("red") : .white,
                                   filled: mic.isMuted, glyph: .white,
                                   label: mic.isMuted ? "Unmute microphone" : "Mute microphone") {
                    mic.toggle()
                }
                .disabled(!mic.isAvailable)
                .opacity(mic.isAvailable ? 1 : 0.4)
                .help(mic.isMuted ? "Unmute the microphone for every app" : "Mute the microphone for every app")
                // Nothing public can hang up another app's call, so this jumps to the app that
                // owns it: the call's own green, rather than a hang-up red that would lie —
                // and the arrow the rest of the app uses for a button that leaves, because a
                // filled green disc with a handset in it is the one control on a phone that
                // means answer, and this does not answer anything.
                CircleActionButton(symbol: "arrow.up.forward", tint: Color.named("green"),
                                   filled: true, glyph: .white,
                                   label: "Go to call in \(state.appName)") {
                    goToCall()
                }
            }
            .islandContentColumn()
            // The two Control Centre panels a call reaches for, under the name they belong
            // to. The menu bar only offers them while an app has the camera or the
            // microphone, and nobody on a call is looking at the menu bar.
            HStack(spacing: 8) {
                PillButton(title: "Effects", symbol: "camera.filters") {
                    Self.showSystemPanel(.videoEffects)
                }
                .accessibilityLabel("Video effects")
                .help("Portrait, Studio Light and Reactions for the camera, in Control Centre.")
                PillButton(title: "Mic Mode", symbol: "waveform") {
                    Self.showSystemPanel(.microphoneModes)
                }
                .accessibilityLabel("Microphone mode")
                .help("Standard, Voice Isolation or Wide Spectrum for the microphone, in Control Centre.")
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.discWidth + Self.rowSpacing)
            .padding(.top, 8)
            .islandContentColumn()
            .padding(.bottom, insidePanel ? 0 : 16)
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// The app's disc, and the gap after it, which the row of controls is indented by so that
    /// it starts under the name.
    private static let discWidth: CGFloat = 44
    private static let rowSpacing: CGFloat = 14

    /// Control Centre's own panel for the camera's effects or the microphone's mode. The
    /// island closes first: the panel drops from the menu bar's corner, and a card left open
    /// in the middle of the screen would only be in the way of the eye going there.
    private static func showSystemPanel(_ panel: AVCaptureDevice.SystemUserInterface) {
        ActivityCenter.shared.collapse(reason: "call controls")
        AVCaptureDevice.showSystemUserInterface(panel)
    }

    private func goToCall() {
        if let open = activity.openAction {
            open.perform()
        } else {
            OpenAction.app(bundleID: state.bundleID).perform()
        }
    }

    /// "FaceTime call, 4 minutes 12 seconds".
    private func spokenLabel(at date: Date) -> String {
        "\(state.appName) call, \(IslandAccessibility.spokenDuration(date.timeIntervalSince(state.startedAt)))"
    }
}

/// The icon of the app a call is in, looked up once per app.
///
/// The card asked LaunchServices where the app is and the file system for its icon on every
/// pass of its body: on the first frame of the spring that brings the card up, and again at
/// every change of the microphone's mute, each time a new image that SwiftUI had to take in
/// afresh. An app's icon does not change during a call. An app LaunchServices cannot find is
/// asked about again next time, so one installed or moved since is found once it can be.
/// Read and written on the main thread only, as the card is drawn.
enum CallAppIcon {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let known = icons[bundleID] { return known }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

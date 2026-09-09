import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A capture's card: the picture you just took, and the three things anybody wants to do with
/// it — put it on the pasteboard, put its words on the pasteboard, or open it.
///
/// The picture is draggable, the way the corner thumbnail macOS shows is: pick it up here and
/// drop it into a message without it ever touching the Desktop.
struct CaptureExpandedView: View {
    let state: CaptureState
    let activity: IslandActivity
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    /// What Vision found, once it has looked. Held here rather than on the activity so the
    /// reading starts when the card is on screen and costs nothing when it never is.
    @State private var reading: CaptureText.Reading?
    @State private var copied: String?

    /// Seeded from the activity rather than left to `onAppear`, which never runs when the
    /// view is being drawn into an image rather than onto a screen.
    init(state: CaptureState, activity: IslandActivity, geometry: NotchGeometry) {
        self.state = state
        self.activity = activity
        self.geometry = geometry
        if state.text != nil || state.link != nil {
            _reading = State(initialValue: CaptureText.Reading(text: state.text ?? "", link: state.link))
        }
    }

    private var tint: Color { Color.named("blue") }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    // Where the QR code goes, when there is one: a button that opens a
                    // stranger's link without saying where it goes is a button nobody should
                    // press, so the host takes the line the file name was on.
                    Text(copied ?? linkLine ?? state.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                controls
            }
            .islandContentColumn()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(state.title), \(state.name)")
        }
        .padding(.bottom, insidePanel ? 0 : 16)
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
        .animation(IslandMotion.content, value: reading == nil)
        .animation(IslandMotion.fade, value: copied)
        .onAppear(perform: read)
    }

    /// The picture itself, at the size every other card gives its glyph. A recording has no
    /// still to show, so it keeps the glyph.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.18))
            if let image = state.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 44, height: 44)
        .modifier(CaptureDrag(url: state.url))
        .help("Drag it anywhere")
        .accessibilityHidden(true)
    }

    /// "notch-island.app" — the host of the link a QR code in the picture points at.
    private var linkLine: String? {
        guard let host = reading?.link?.host() else { return nil }
        return host
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            // A QR code in a screenshot is the one thing everybody photographs a screen for.
            if let link = reading?.link {
                CircleActionButton(symbol: "qrcode", tint: .white, label: "Open \(link.host() ?? "the link")") {
                    NSWorkspace.shared.open(link)
                    ActivityCenter.shared.collapse(reason: "opened a link from a capture")
                }
                .help(link.absoluteString)
            }
            // Only where there is something to read: a card that offers to copy words from a
            // picture with none in it has made a promise it cannot keep.
            if let text = reading?.text, !text.isEmpty {
                CircleActionButton(symbol: "text.viewfinder", tint: .white, label: "Copy the text") {
                    copy(text, saying: "Text copied")
                }
            }
            if !state.isRecording {
                CircleActionButton(symbol: "doc.on.doc", tint: .white, label: "Copy the picture") {
                    copyImage()
                }
            }
            CircleActionButton(symbol: "arrow.up.forward", tint: tint, label: "Open \(state.name)") {
                activity.openAction?.perform()
            }
        }
    }

    // MARK: - Doing things with it

    /// Looks for words, once, and only for a still.
    private func read() {
        guard !RenderMode.isGallery, !state.isRecording, reading == nil else { return }
        CaptureText.recognize(state.url) { found in
            reading = found ?? CaptureText.Reading()
        }
    }

    private func copy(_ string: String, saying message: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(string, forType: .string)
        say(message)
    }

    private func copyImage() {
        guard let image = NSImage(contentsOf: state.url) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        // The file as well as the picture: pasted into Finder it is the file, into a document
        // it is the image, which is what both of those places expect.
        board.writeObjects([state.url as NSURL, image])
        say("Picture copied")
    }

    /// Says what just happened where the file name is, and puts the name back after a moment.
    private func say(_ message: String) {
        copied = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copied == message { copied = nil }
        }
    }
}

/// `onDrag`, except in the gallery, where `ImageRenderer` cannot draw one.
private struct CaptureDrag: ViewModifier {
    let url: URL

    @ViewBuilder
    func body(content: Content) -> some View {
        if RenderMode.isGallery {
            content
        } else {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        }
    }
}

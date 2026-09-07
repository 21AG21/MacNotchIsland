import SwiftUI

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var radius: CGFloat = 8
    /// Let the artwork shrink below `size` when something proposes a smaller box.
    ///
    /// A plain `.frame(width:height:)` swallows the proposal, which would make
    /// `matchedGeometryEffect` able to *move* the artwork but never to resize it — the compact
    /// thumbnail would jump to the expanded slot at its old size instead of growing into it.
    /// With `flexible` the view keeps `size` as its ceiling but follows a smaller imposed frame,
    /// so the morph between the 22 pt pill thumbnail and the 60 pt expanded cover is continuous.
    /// Every other caller leaves this off and gets the old, exactly-`size` behaviour.
    var flexible: Bool = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        // min == ideal == max == size when not flexible, i.e. identical to .frame(width:height:).
        .frame(minWidth: flexible ? 0 : size, idealWidth: size, maxWidth: size,
               minHeight: flexible ? 0 : size, idealHeight: size, maxHeight: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

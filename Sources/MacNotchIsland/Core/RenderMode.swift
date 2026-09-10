import SwiftUI
import UniformTypeIdentifiers

/// How the island is being drawn. The gallery (a review tool, see `GalleryTests`) renders the
/// views offscreen with `ImageRenderer`, which cannot draw AppKit-backed pieces: a drop target
/// or a scroll view comes out as a yellow block. Those pieces switch to plain equivalents while
/// this is set, and to nothing else.
enum RenderMode {
    nonisolated(unsafe) static var isGallery = false
}

extension View {
    /// `onDrop`, except in the gallery.
    @ViewBuilder
    func islandDrop(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if RenderMode.isGallery {
            self
        } else {
            onDrop(of: ShelfStore.acceptedTypes, isTargeted: isTargeted, perform: perform)
        }
    }
}

extension View {
    /// `onDrop` for a chosen set of types, except in the gallery. Every drop target is backed
    /// by AppKit, and `ImageRenderer` draws one as a yellow block with a red line through it —
    /// which is what the window tiles had become in every picture the gallery took of them.
    @ViewBuilder
    func islandDrop(of types: [UTType], isTargeted: Binding<Bool>,
                    perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if RenderMode.isGallery {
            self
        } else {
            onDrop(of: types, isTargeted: isTargeted, perform: perform)
        }
    }
}

/// A scroll view, except in the gallery, where the content is laid out in place and clipped.
struct IslandScrollStrip<Content: View>: View {
    var axis: Axis.Set = .horizontal
    /// Shown, because a column holding four of the twenty networks in range and saying nothing
    /// about the other sixteen is a list of four networks as far as anybody can tell: content
    /// nobody can see is content nobody knows to look for. The Mac's own scrollers are overlay
    /// ones — they arrive under the hand and fade when it stops — so a strip with nothing
    /// hidden is no different for having them, and one with something hidden finally says so.
    ///
    /// The gallery is untouched by this either way: it builds no scroll view at all, which is
    /// the whole reason this type exists.
    var showsIndicators = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        if RenderMode.isGallery {
            // A scroll view puts its content against the leading edge; laid out in place it
            // would centre instead, and the gallery would show a strip nobody will ever see.
            content()
                .frame(maxWidth: axis == .horizontal ? .infinity : nil,
                       maxHeight: axis == .vertical ? .infinity : nil,
                       alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axis, showsIndicators: showsIndicators) { content() }
        }
    }
}

import SwiftUI

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

/// A scroll view, except in the gallery, where the content is laid out in place and clipped.
struct IslandScrollStrip<Content: View>: View {
    var axis: Axis.Set = .horizontal
    var showsIndicators = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if RenderMode.isGallery {
            content().clipped()
        } else {
            ScrollView(axis, showsIndicators: showsIndicators) { content() }
        }
    }
}

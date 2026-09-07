import SwiftUI
import UniformTypeIdentifiers

/// The black island itself: shape, content, hover / click / drop handling.
struct IslandBodyView: View {
    let geometry: NotchGeometry
    let presentation: IslandPresentation
    let layout: IslandLayout

    @EnvironmentObject private var center: ActivityCenter
    @EnvironmentObject private var prefs: Preferences
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                .fill(Color.black)

            content
                .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
                .clipped()
                .padding(.horizontal, layout.topRadius)
        }
        .frame(width: layout.frameWidth, height: layout.bodyHeight)
        .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius))
        .onHover { hovering in center.setHovering(hovering) }
        .onTapGesture { center.tap() }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard prefs.shelfEnabled else { return false }
            return ShelfStore.shared.acceptDrop(providers)
        }
        .onChange(of: dropTargeted) { _, targeted in
            center.setDragTargeted(targeted && prefs.shelfEnabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch presentation {
            case .idle:
                IdleContentView(layout: layout)
            case .compact(let activity, _):
                CompactContentView(activity: activity, layout: layout, geometry: geometry)
            case .expanded(let activity):
                ExpandedContentView(activity: activity, layout: layout, geometry: geometry)
            case .home:
                HomeExpandedView(geometry: geometry, layout: layout)
            case .shelf:
                ShelfExpandedView(geometry: geometry, layout: layout, isDropTarget: true)
            }
        }
        .id(presentation.contentID)
        .transition(.blurReplace)
    }
}

struct IdleContentView: View {
    let layout: IslandLayout
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if center.privacyIndicatorsVisible {
                PrivacyDots()
                    .frame(width: layout.privacyWidth + 4, height: layout.bodyHeight)
                    .padding(.trailing, 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
        .animation(IslandMotion.quick, value: center.privacyIndicatorsVisible)
    }
}

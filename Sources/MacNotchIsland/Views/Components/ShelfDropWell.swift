import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag over the shelf's well is doing. A reference, so the drop delegate — a value
/// SwiftUI builds again with every body — has somewhere to write that outlives it.
final class ShelfWellDrag: ObservableObject {
    /// Whether the drag carries files, and so whether the well is split three ways.
    @Published var carriesFiles = false
    /// The target under the pointer; nil while the pointer is somewhere else on the island.
    @Published private(set) var hovered: ShelfDropTarget?
    /// Whether the drag is over the well itself rather than elsewhere on the island.
    private(set) var inside = false
    /// The well's width, for telling which column a point is in. Not published: nothing is
    /// drawn from it.
    var width: CGFloat = 0

    var lit: ShelfDropTarget { ShelfDropTarget.lit(hovered) }

    func enter() { inside = true }

    /// The pointer is at `x` across the well. A tap under the finger when that lights a
    /// different target — and only on a split well, where there is more than one to light.
    func point(at x: CGFloat) {
        let next = ShelfDropTarget.at(x: x, width: width)
        guard next != hovered else { return }
        let tap = carriesFiles && ShelfDropTarget.changesLight(from: hovered, to: next)
        hovered = next
        if tap { Haptics.tap() }
    }

    /// The pointer has left the well for the rest of the island, or the drop has landed.
    func leave() {
        inside = false
        if hovered != nil { hovered = nil }
    }

    /// The drag is over.
    func reset() {
        leave()
        if carriesFiles { carriesFiles = false }
    }
}

/// The well as a drop target of its own, inside the island's.
///
/// An inner drop target takes the drag off the island's for as long as the pointer is over
/// it, and the island is told the drag has left — the switcher's slots have the same problem,
/// and `holdDrag` exists for it. The well goes further and claims the drag for the island
/// outright, on arrival and on every move: it is part of the island, and a drag that reaches
/// the Shelf section without crossing anything else first is on the island all the same.
struct ShelfWellDropDelegate: DropDelegate {
    let well: ShelfWellDrag
    let panelID: String
    let anchor: ShelfShareAnchor

    /// How long after arriving the well claims the drag a second time. The island hears that
    /// the drag has left its own target on its next update, which is after the well has heard
    /// it arrive — and the exit it starts then would take the well away under the hand.
    static let reclaimDelay: TimeInterval = 0.1

    func validateDrop(info: DropInfo) -> Bool {
        Preferences.shared.shelfEnabled && info.hasItemsConforming(to: ShelfStore.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        well.enter()
        well.carriesFiles = info.hasItemsConforming(to: [.fileURL])
        ShelfWellDrop.claim(panelID)
        let drag = well, island = panelID
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reclaimDelay) {
            guard drag.inside else { return }
            ShelfWellDrop.claim(island)
        }
        well.point(at: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        ShelfWellDrop.claim(panelID)
        well.point(at: info.location.x)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        well.leave()
        ActivityCenter.shared.holdDrag(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Where it was let go, not where it was last lit: the two differ by at most the last
        // few points of movement, and the place the hand opened is the one it meant.
        let target = well.carriesFiles ? ShelfDropTarget.at(x: info.location.x, width: well.width) : .shelf
        let providers = info.itemProviders(for: ShelfStore.acceptedTypes)
        well.leave()
        return ShelfWellDrop.receive(providers, on: target, panel: panelID, anchor: anchor)
    }
}

/// What a drop on the split well does with what it carried.
enum ShelfWellDrop {
    /// The drag is on this island. The same call the island's own drop target makes; a
    /// repeat of it only cancels a pending exit.
    static func claim(_ panel: String) {
        guard Preferences.shared.shelfEnabled else { return }
        ActivityCenter.shared.setDragTargeted(true, panel: panel)
    }

    /// Returns whether the drop was taken, as `onDrop` wants.
    static func receive(_ providers: [NSItemProvider], on target: ShelfDropTarget, panel: String,
                        anchor: ShelfShareAnchor) -> Bool {
        guard Preferences.shared.shelfEnabled else { return false }
        let isFile: (NSItemProvider) -> Bool = { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let files = providers.filter(isFile)
        // The shelf, or a drag with no files in it: exactly what a drop on the well always did.
        guard target != .shelf, !files.isEmpty else { return ShelfStore.shared.acceptDrop(providers) }
        // Anything in the same drag that is not a file — a picture, a link — has only the shelf
        // to go to, and goes there the way it always has.
        let rest = providers.filter { !isFile($0) }
        if !rest.isEmpty { _ = ShelfStore.shared.acceptDrop(rest) }
        if target == .share {
            // The picker hangs off the well, so the panel has to stay on the shelf for as long
            // as it is up: pinned there, rather than held only by a drag that is about to end.
            // Not an invitation to the keyboard: the hand is on its way to the picker.
            ActivityCenter.shared.open(.home(tab: HomeSection.shelf.rawValue), panel: panel, invitesKeyboard: false)
            ActivityCenter.shared.holdOpen(for: 30)
        }
        let destinations = ShelfDropDestinations(anchor: anchor, column: target)
        DroppedFiles.paths(from: files) { paths in
            let outcome = target.deliver(paths.map { URL(fileURLWithPath: $0) }, to: destinations)
            IslandLog.island.notice("drop on the well's \(target.rawValue, privacy: .public): \(String(describing: outcome), privacy: .public)")
            ActivityCenter.shared.setDragTargeted(false)
        }
        return true
    }
}

/// The island's own three destinations for a drop on the split well.
struct ShelfDropDestinations: ShelfDropSending {
    /// The view the share picker hangs off: the strip the well is drawn in.
    let anchor: ShelfShareAnchor
    /// The column the file was let go over, which the picker points at.
    var column: ShelfDropTarget = .share

    func keep(_ urls: [URL]) {
        ShelfStore.shared.add(urls)
    }

    func airDrop(_ urls: [URL]) -> Bool {
        ShelfStore.shared.sendByAirDrop(urls)
    }

    /// Only with a view that is on screen: `ShelfStore.share` falls back to AirDrop without
    /// one, and a drop on Share is not a drop on AirDrop.
    func share(_ urls: [URL]) -> Bool {
        guard let view = anchor.view, view.window != nil else { return false }
        ShelfStore.shared.share(urls, from: view, rect: column.column(in: view.bounds))
        return true
    }
}

/// The well while files are held over it: Shelf, AirDrop and Share side by side, the one
/// under the pointer lit. Drawn in the same accent the undivided well is, so the three read as
/// that well split, not as something new that arrived with the drag.
struct ShelfDropSplitView: View {
    let lit: ShelfDropTarget

    static let gap: CGFloat = 8
    static let cornerRadius: CGFloat = 14

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(ShelfDropTarget.allCases) { target in
                cell(target, isLit: target == lit)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop targets")
    }

    private func cell(_ target: ShelfDropTarget, isLit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return VStack(spacing: 6) {
            Image(systemName: target.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(isLit ? 0.95 : 0.35))
            Text(target.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isLit ? 0.9 : 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { shape.fill(Color.accentColor.opacity(isLit ? 0.22 : 0.06)) }
        .overlay { shape.strokeBorder(Color.accentColor.opacity(isLit ? 0.9 : 0.25), lineWidth: 2) }
        .scaleEffect(isLit ? 1 : 0.97)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.title)
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }
}

extension View {
    /// `onDrop` with a delegate, except in the gallery, for the reason `islandDrop(of:isTargeted:perform:)`
    /// gives: `ImageRenderer` draws every drop target as a yellow block with a red line through it.
    @ViewBuilder
    func islandDrop<Delegate: DropDelegate>(of types: [UTType], delegate: Delegate) -> some View {
        if RenderMode.isGallery {
            self
        } else {
            onDrop(of: types, delegate: delegate)
        }
    }
}

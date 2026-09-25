import AppKit
import Foundation

/// Where a file dropped on the shelf's well goes.
///
/// While files are held over the island the well splits into three targets side by side —
/// Shelf, AirDrop, Share — so sending something somewhere is one trip instead of two: it used
/// to have to land on the shelf first and be sent from there. The split is only for a drag
/// that carries files. A picture, a link or a piece of text has only the shelf to go to, and
/// the well stays the one target it always was.
///
/// Everything here is pure, so where a point lands and what a drop there does can be read
/// back without a drag, a trackpad or a share sheet.
enum ShelfDropTarget: String, CaseIterable, Identifiable {
    case shelf
    case airDrop
    case share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "Shelf"
        case .airDrop: return "AirDrop"
        case .share: return "Share"
        }
    }

    /// The glyphs the rest of the island already uses for the same three things.
    var symbol: String {
        switch self {
        case .shelf: return "tray.and.arrow.down.fill"
        case .airDrop: return "dot.radiowaves.right"
        case .share: return "square.and.arrow.up"
        }
    }

    /// What letting go here will do, for the header over the well.
    var prompt: String {
        switch self {
        case .shelf: return "Drop to add"
        case .airDrop: return "Drop to send by AirDrop"
        case .share: return "Drop to share"
        }
    }

    // MARK: - Where a point lands

    /// The target under a point `x` points across a well `width` wide: three equal columns,
    /// left to right in `allCases` order. A point past either edge belongs to the column at
    /// that edge, and a well that has no width yet is all shelf — which is what the well was
    /// before it split, and where a drop goes when there is any doubt.
    static func at(x: CGFloat, width: CGFloat) -> ShelfDropTarget {
        let all = allCases
        guard width > 0, width.isFinite, x.isFinite else { return .shelf }
        // Held inside the well before it becomes an index, so no figure can land outside it.
        let fraction = min(max(x / width, 0), 1)
        let index = min(all.count - 1, Int(fraction * CGFloat(all.count)))
        return all[index]
    }

    /// The column this target takes up in a well with these bounds, for hanging the share
    /// picker off the part of the well the file was dropped on.
    func column(in bounds: CGRect) -> CGRect {
        let all = Self.allCases
        let width = bounds.width / CGFloat(all.count)
        let index = all.firstIndex(of: self) ?? 0
        return CGRect(x: bounds.minX + width * CGFloat(index), y: bounds.minY, width: width, height: bounds.height)
    }

    // MARK: - What is lit

    /// What the well lights: the target under the pointer, or the shelf while the pointer is
    /// somewhere else on the island — which is where a drop there goes, so the well says so.
    static func lit(_ hovered: ShelfDropTarget?) -> ShelfDropTarget {
        hovered ?? .shelf
    }

    /// Whether the pointer moving from one place to another is worth a tap under the finger:
    /// only when what is lit changes. Arriving on the island already taps, so coming onto the
    /// shelf's own column from the rest of the island is not a second one.
    static func changesLight(from old: ShelfDropTarget?, to new: ShelfDropTarget?) -> Bool {
        lit(old) != lit(new)
    }

    // MARK: - Whether the well splits

    /// Whether a drag carries files, read off the drag pasteboard, so the well can split the
    /// moment a drag reaches the island rather than only once it is over the well itself.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // MARK: - What a drop does

    /// Delivers the files a drop carried to this target.
    ///
    /// The shelf keeps them. AirDrop and Share send them without putting them on the shelf —
    /// unless the send cannot happen (AirDrop switched off, nothing on screen to hang the
    /// picker from), and then they are kept after all: something that was dropped on the
    /// island is never simply gone.
    @discardableResult
    func deliver(_ urls: [URL], to sender: ShelfDropSending) -> ShelfDropOutcome {
        guard !urls.isEmpty else { return .nothing }
        switch self {
        case .shelf:
            sender.keep(urls)
            return .kept
        case .airDrop:
            if sender.airDrop(urls) { return .sent }
        case .share:
            if sender.share(urls) { return .sent }
        }
        sender.keep(urls)
        return .keptInstead
    }
}

/// What became of a drop on the split well.
enum ShelfDropOutcome: Equatable {
    /// It carried no files.
    case nothing
    /// On the shelf, where it was dropped.
    case kept
    /// Sent by AirDrop, or handed to the share picker.
    case sent
    /// Dropped on AirDrop or Share, which could not take it, so it went on the shelf.
    case keptInstead
}

/// The three places a drop on the well can send files. The island's own is
/// `ShelfDropDestinations`; the tests bring one that only writes down what it was asked.
protocol ShelfDropSending {
    /// Puts files on the shelf.
    func keep(_ urls: [URL])
    /// Sends files by AirDrop. False when AirDrop cannot take them right now.
    func airDrop(_ urls: [URL]) -> Bool
    /// Opens the share picker for files. False when there is nothing on screen to show it from.
    func share(_ urls: [URL]) -> Bool
}

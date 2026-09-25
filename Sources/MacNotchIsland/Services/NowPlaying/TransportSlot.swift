import Foundation

/// One of the four places beside play that the user fills in Settings > Media: two to the
/// left of the back button and two to the right of the forward one. Out of the box all four
/// are empty and the row is the three buttons Music has — what somebody wants there depends
/// on what they listen to. A podcast wants fifteen seconds back and on; an album wants shuffle
/// and repeat.
enum TransportSlot: String, CaseIterable, Identifiable {
    case empty = "none"
    case shuffle
    case cycleRepeat = "repeat"
    case favourite
    case back15
    case forward15

    var id: String { rawValue }

    /// Two either side of play.
    static let count = 4

    /// Stored as `Preferences.transportSlots`: none, none, none, none.
    static let defaults: [TransportSlot] = Array(repeating: .empty, count: TransportSlot.count)

    /// The words in the Settings menu.
    var title: String {
        switch self {
        case .empty: return "None"
        case .shuffle: return "Shuffle"
        case .cycleRepeat: return "Repeat"
        case .favourite: return "Favourite"
        case .back15: return "Back 15 s"
        case .forward15: return "Forward 15 s"
        }
    }

    /// The player command behind the button; nil for an empty place.
    var command: NowPlayingInfo.Command? {
        switch self {
        case .empty: return nil
        case .shuffle: return .shuffle
        case .cycleRepeat: return .cycleRepeat
        case .favourite: return .like
        case .back15: return .back15
        case .forward15: return .forward15
        }
    }

    /// What is stored, made into exactly four places. Pure, so it is tested.
    ///
    /// A name this build does not know — written by a newer one, or by hand — is an empty
    /// place rather than a reason to throw the row away; a list that is short is filled out
    /// with empty places and one that is long is cut at four. The same button twice is one
    /// button: the first place keeps it and the later one is emptied, since two shuffle buttons
    /// in one row is a row that has stopped meaning anything.
    static func resolved(stored: [String]) -> [TransportSlot] {
        var seen: Set<TransportSlot> = []
        var result: [TransportSlot] = []
        for raw in stored.prefix(Self.count) {
            let slot = TransportSlot(rawValue: raw) ?? .empty
            if slot != .empty, seen.contains(slot) {
                result.append(.empty)
            } else {
                seen.insert(slot)
                result.append(slot)
            }
        }
        while result.count < Self.count { result.append(.empty) }
        return result
    }

    /// The four places with `slot` put at `index`, and taken from wherever else it was. What a
    /// menu in Settings writes, so choosing a button that is already in the row moves it.
    static func placing(_ slot: TransportSlot, at index: Int, in slots: [TransportSlot]) -> [TransportSlot] {
        var result = resolved(stored: slots.map(\.rawValue))
        guard result.indices.contains(index) else { return result }
        if slot != .empty {
            for i in result.indices where result[i] == slot { result[i] = .empty }
        }
        result[index] = slot
        return result
    }

    /// The row as it is drawn: the left pair and the right pair with their empty places taken
    /// out, then the shorter side made up with blank places on its outer edge, so play stays
    /// in the middle of the row whatever is chosen. Nothing chosen is nothing either side —
    /// exactly the three buttons the row has always had. Pure, so it is tested.
    static func sides(_ slots: [TransportSlot]) -> (left: [TransportSlot], right: [TransportSlot]) {
        let all = resolved(stored: slots.map(\.rawValue))
        var left: [TransportSlot] = Array(all[0..<2]).filter { $0 != .empty }
        var right: [TransportSlot] = Array(all[2..<4]).filter { $0 != .empty }
        let width = max(left.count, right.count)
        while left.count < width { left.insert(.empty, at: 0) }
        while right.count < width { right.append(.empty) }
        return (left, right)
    }

    /// Whether the player in front honours this button. An empty place honours nothing.
    func isSupported(by info: NowPlayingInfo) -> Bool {
        guard let command else { return false }
        return info.supports.contains(command)
    }

    /// Whether the button is lit: shuffle on, a repeat that is not off, a track favourited.
    func isOn(in info: NowPlayingInfo, liked: Bool) -> Bool {
        switch self {
        case .shuffle: return info.shuffle == true
        case .cycleRepeat: return (info.repeatMode ?? .off) != .off
        case .favourite: return liked
        default: return false
        }
    }

    /// The glyph, as the players draw it: repeat with a 1 on it for one track, a heart that
    /// fills once pressed.
    func symbol(in info: NowPlayingInfo, liked: Bool) -> String {
        switch self {
        case .empty: return ""
        case .shuffle: return "shuffle"
        case .cycleRepeat: return info.repeatMode == .one ? "repeat.1" : "repeat"
        case .favourite: return liked ? "heart.fill" : "heart"
        case .back15: return "gobackward.15"
        case .forward15: return "goforward.15"
        }
    }

    /// What VoiceOver says the button is.
    var spokenName: String {
        switch self {
        case .empty: return ""
        case .shuffle: return "Shuffle"
        case .cycleRepeat: return "Repeat"
        case .favourite: return "Favourite"
        case .back15: return "Back 15 seconds"
        case .forward15: return "Forward 15 seconds"
        }
    }

    /// And what state it is in, where it has one.
    func spokenValue(in info: NowPlayingInfo, liked: Bool) -> String? {
        switch self {
        case .shuffle: return info.shuffle == true ? "On" : "Off"
        case .cycleRepeat:
            switch info.repeatMode ?? .off {
            case .off: return "Off"
            case .one: return "One track"
            case .all: return "All"
            }
        case .favourite: return liked ? "Favourited" : nil
        default: return nil
        }
    }
}

import Foundation

/// What Control Centre's Sound module puts under the slider: where the sound goes, then where
/// it comes from, each list headed and the live one ticked.
///
/// The rules are here, away from the view, because they are the part worth being sure of: a
/// heading with nothing under it, or an empty column that still draws two headings, is the
/// kind of thing only a test notices.
enum SoundList {
    enum Entry: Identifiable, Equatable {
        case heading(String)
        case device(AudioOutputs.Device, isCurrent: Bool, isInput: Bool)

        var id: String {
            switch self {
            case .heading(let title): return "head-\(title)"
            case .device(let device, _, let isInput): return "\(isInput ? "in" : "out")-\(device.id)"
            }
        }
    }

    static let output = "Output"
    static let input = "Input"

    /// The two lists, headed only when they have something under them.
    static func entries(outputs: [AudioOutputs.Device], current: AudioOutputs.Device?,
                        inputs: [AudioOutputs.Device], currentInput: AudioOutputs.Device?) -> [Entry] {
        var entries: [Entry] = []
        if !outputs.isEmpty {
            entries.append(.heading(output))
            entries += outputs.map { .device($0, isCurrent: $0.id == current?.id, isInput: false) }
        }
        if !inputs.isEmpty {
            entries.append(.heading(input))
            entries += inputs.map { .device($0, isCurrent: $0.id == currentInput?.id, isInput: true) }
        }
        return entries
    }
}

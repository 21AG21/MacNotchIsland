import Foundation

/// What Control Centre's Sound module puts under the slider: where the sound goes — the outputs,
/// then the AirPlay receivers — then where it comes from, each list headed and the live one
/// ticked.
///
/// The rules are here, away from the view, because they are the part worth being sure of: a
/// heading with nothing under it, or an empty column that still draws two headings, is the
/// kind of thing only a test notices.
enum SoundList {
    enum Entry: Identifiable, Equatable {
        case heading(String)
        case device(AudioOutputs.Device, isCurrent: Bool, isInput: Bool)
        case airPlay(AudioOutputs.AirPlayTarget, isCurrent: Bool)

        var id: String {
            switch self {
            case .heading(let title): return "head-\(title)"
            case .device(let device, _, let isInput): return "\(isInput ? "in" : "out")-\(device.id)"
            case .airPlay(let target, _): return "airplay-\(target.id)"
            }
        }
    }

    static let output = "Output"
    static let airPlay = AirPlayList.heading
    static let input = "Input"

    /// The lists, headed only when they have something under them. While the AirPlay group has
    /// receivers, the AirPlay device's own row leaves the outputs; see `AirPlayList.outputs`.
    static func entries(outputs: [AudioOutputs.Device], current: AudioOutputs.Device?,
                        inputs: [AudioOutputs.Device], currentInput: AudioOutputs.Device?,
                        airPlay targets: [AudioOutputs.AirPlayTarget] = [],
                        airPlayCurrent: Set<UInt32> = []) -> [Entry] {
        var entries: [Entry] = []
        let outputs = AirPlayList.outputs(outputs, airPlay: targets)
        if !outputs.isEmpty {
            entries.append(.heading(output))
            entries += outputs.map { .device($0, isCurrent: $0.id == current?.id, isInput: false) }
        }
        if !targets.isEmpty {
            entries.append(.heading(airPlay))
            entries += targets.map { .airPlay($0, isCurrent: airPlayCurrent.contains($0.source)) }
        }
        if !inputs.isEmpty {
            entries.append(.heading(input))
            entries += inputs.map { .device($0, isCurrent: $0.id == currentInput?.id, isInput: true) }
        }
        return entries
    }
}

import SwiftUI

/// The iPhone's animated audio bars, tinted from the album artwork.
///
/// Two sources drive the bars. When `AudioLevelTap` has a live system-audio tap the measured
/// level dominates and the bars really follow the music; otherwise they fall back to the
/// synthetic sine pattern, which is what every Mac before 14.2 (and everyone who leaves the
/// reactive visualizer off) sees.
struct VisualizerBars: View {
    @ObservedObject private var energy = EnergyPolicy.shared
    @ObservedObject private var tap = AudioLevelTap.shared

    var isPlaying: Bool
    var color: Color
    var barCount: Int = 4
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 14
    var minHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: energy.animationInterval, paused: !isPlaying || energy.animationsPaused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.8) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(index: index, time: t))
                }
            }
            .animation(IslandMotion.fade, value: isPlaying)
        }
        .frame(height: maxHeight)
    }

    private func height(index: Int, time t: Double) -> CGFloat {
        // Still, but still a waveform. Both of the states where nothing is driving the bars
        // used to give every one of them the same height, and four marks of one height are
        // not bars at all — they are dots, which is what a paused track and a Mac on battery
        // were both showing in the pill.
        guard isPlaying else { return bar(Self.resting(index) * Self.quietScale) }
        // Playing, but the policy has stopped continuous animation (asleep, Low Power, or on
        // battery by the user's setting): the wave holds its shape at full size, so the pill
        // still reads as "something is playing" without moving.
        guard !energy.animationsPaused else { return bar(Self.resting(index)) }
        return bar(tap.isRunning ? reactiveFraction(index: index, time: t)
                                 : syntheticFraction(index: index, time: t))
    }

    /// The shape the bars hold when nothing is driving them. Uneven on purpose: a wave at
    /// rest is still a wave.
    private static func resting(_ index: Int) -> Double {
        let pattern = [0.34, 0.78, 0.52, 0.92]
        return pattern[abs(index) % pattern.count]
    }

    /// How far that shape is flattened when the music is not playing at all.
    private static let quietScale = 0.45

    private func bar(_ fraction: Double) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(max(0, min(1, fraction)))
    }

    /// 0…1 driven by the measured system level. The middle bars are weighted slightly
    /// higher (as on the iPhone) and a small phase-shifted wobble — itself scaled by the
    /// level, so silence is still — keeps neighbouring bars from moving in lockstep.
    private func reactiveFraction(index: Int, time t: Double) -> Double {
        let level = max(0, min(1, tap.level))
        guard level > 0 else { return 0 }
        let wobble = 0.12 * sin(t * (5.0 + Double(index) * 0.9) + Double(index) * 1.7)
        return level * weight(index: index) + wobble * level
    }

    /// 1.1 for the middle bar(s) down to 0.75 at the edges.
    private func weight(index: Int) -> Double {
        guard barCount > 1 else { return 1.1 }
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 1.1 - 0.35 * distance
    }

    /// The original pattern: two detuned sines per bar, used whenever there is no tap.
    private func syntheticFraction(index: Int, time t: Double) -> Double {
        let f1 = 2.1 + Double(index) * 0.37
        let f2 = 3.3 + Double(index) * 0.53
        let phase = Double(index) * 1.7
        return 0.55 + 0.45 * (0.6 * sin(t * f1 + phase) + 0.4 * sin(t * f2 * 1.3 + phase * 2.1))
    }
}

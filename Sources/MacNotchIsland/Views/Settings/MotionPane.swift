import SwiftUI

/// "Motion": the two numbers every spring in the island is built from, and an island that
/// opens and closes on them while you turn them.
///
/// No other notch app has this. A survey of them found one speed setting between the lot and
/// none that lets you watch the curve you are setting — which is also why the preview is
/// here rather than only the sliders. The opening animation was reported as wrong by somebody
/// who could run the app, to people who could not, and an island looping in the Settings
/// window with its numbers written under it is the first thing either side has been able to
/// point at.
struct MotionPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    /// The picker's fourth state: the sliders are somewhere no preset is.
    private static let custom = "custom"

    var body: some View {
        Form {
            Section {
                MotionPreview(running: !reduceMotion && activeState != .inactive)
                LabeledContent("Opening", value: describe(.open))
                LabeledContent("Closing", value: describe(.close))
            } header: {
                Text("Preview")
            } footer: {
                if reduceMotion {
                    Text("Reduce Motion is on in System Settings, so the island fades between its sizes instead of springing, and nothing below has any effect until it is off.")
                } else {
                    Text("The island opens and closes here on the very curves it uses on the notch, so a change below shows on the next cycle. The figures are what each spring is given: how long it takes, and how far it overshoots.")
                }
            }

            Section {
                Picker("Preset", selection: chosenPreset) {
                    ForEach(IslandMotion.Preset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                    if isCustom {
                        Text("Custom").tag(Self.custom)
                    }
                }
                .pickerStyle(.segmented)
                .help("Faithful is the phone's own timing. Calm keeps it and never overshoots. Instant is half the time and no overshoot.")
                SettingsSlider("Duration", value: duration, range: Self.percent(IslandMotion.Tuning.durationRange), unit: "%")
                    .help("How long every spring takes to settle, as a share of the phone's own timing.")
                SettingsSlider("Bounce", value: bounce, range: Self.percent(IslandMotion.Tuning.bounceRange), unit: "%")
                    .help("How far every spring overshoots on the way, as a share of the phone's own.")
                Button("Reset to Faithful") { apply(.faithful) }
                    .disabled(tuning == IslandMotion.Preset.faithful.tuning)
            } header: {
                Text("Springs")
            } footer: {
                Text("Duration is how long a spring takes to settle and bounce is how far it overshoots on the way; both turn every spring in the island together, and Faithful is the phone's own timing.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Numbers

    private var tuning: IslandMotion.Tuning {
        IslandMotion.Tuning(duration: prefs.motionDuration, bounce: prefs.motionBounce)
    }

    private var isCustom: Bool { IslandMotion.Preset.matching(tuning) == nil }

    /// The numbers the island will actually give a spring, said plainly, so a report that it
    /// looks wrong can carry the figures it looked wrong at.
    private func describe(_ spring: IslandMotion.Spring) -> String {
        let given = IslandMotion.scaled(duration: spring.base.duration, bounce: spring.base.bounce, by: tuning.clamped)
        return String(format: "%.2f s, bounce %.2f", given.duration, given.bounce)
    }

    // MARK: Bindings

    /// Which preset the sliders are on, worked out from the numbers rather than remembered, so
    /// the picker can never claim a preset the island is not using.
    private var chosenPreset: Binding<String> {
        Binding(
            get: { IslandMotion.Preset.matching(tuning)?.rawValue ?? Self.custom },
            set: { name in
                if let preset = IslandMotion.Preset(rawValue: name) { apply(preset) }
            }
        )
    }

    /// The sliders speak in whole percentages, so a hand can land back on 100 exactly and the
    /// picker can see that it did.
    private var duration: Binding<Double> {
        Binding(
            get: { prefs.motionDuration * 100 },
            set: { percent in prefs.motionDuration = percent.rounded() / 100 }
        )
    }

    private var bounce: Binding<Double> {
        Binding(
            get: { prefs.motionBounce * 100 },
            set: { percent in prefs.motionBounce = percent.rounded() / 100 }
        )
    }

    /// A preset is only its two numbers; picking one writes both.
    private func apply(_ preset: IslandMotion.Preset) {
        prefs.motionDuration = preset.tuning.duration
        prefs.motionBounce = preset.tuning.bounce
    }

    private static func percent(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        (range.lowerBound * 100).rounded()...(range.upperBound * 100).rounded()
    }
}

/// A stand-in for the island: the same outline in the same black over a pale mock menu bar,
/// opening and closing on a loop on the real `open` and `close` springs.
///
/// The real island cannot be borrowed for this — its root view wants the whole activity centre
/// and a screen to sit on — but the outline and the curves are the whole of what is being
/// looked at, and both are the island's own. The curves are read afresh at each turn of the
/// loop, so a slider is seen on the next cycle rather than after a relaunch.
struct MotionPreview: View {
    /// Whether to loop at all. Under Reduce Motion the island holds still, since the springs
    /// do not apply and a loop that faded would demonstrate nothing about them. And only while
    /// the window is up and in front: closing the Settings window puts it away rather than
    /// tearing it down, so nothing else here would ever hear that the pane had gone.
    let running: Bool

    @State private var expanded = false
    @State private var loop: Timer?

    /// The two sizes, in the island's own points — the pill the notch shows and a panel —
    /// before scaling to whatever width the pane has. Both are scaled by the same amount: a
    /// spring's overshoot is a share of its travel, so a preview that shrank one size and not
    /// the other would bounce differently from the island it stands for.
    private static let compactSize = CGSize(width: 200, height: 33)
    private static let expandedSize = CGSize(width: 560, height: 180)
    /// The menu bar the island sits in, in the same points.
    private static let menuBarHeight: CGFloat = 37
    /// How long each size is held before the next spring: past the longest settle the sliders
    /// allow, so the outline is never caught mid-flight by the next turn.
    private static let hold: TimeInterval = 1.4
    private static let stageHeight: CGFloat = 164
    private static let margin: CGFloat = 20
    private static let ink = Color(white: 0.72)

    var body: some View {
        GeometryReader { proxy in
            let fit = Self.fit(in: proxy.size)
            let size = expanded ? Self.expandedSize : Self.compactSize
            let top = (expanded ? IslandLayout.expandedTopRadius : IslandLayout.compactTopRadius) * fit
            let bottom = (expanded ? IslandLayout.expandedBottomRadius : Self.compactSize.height / 2) * fit
            ZStack(alignment: .top) {
                // A picture of a screen, not a control of this window, so it keeps its own
                // light colours in either appearance: the notch's black only reads against
                // something pale.
                Color(white: 0.965)
                menuBar(height: Self.menuBarHeight * fit)
                NotchShape(topRadius: top, bottomRadius: bottom, floating: false)
                    .fill(Color.black)
                    .frame(width: size.width * fit + top * 2, height: size.height * fit)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: Self.stageHeight)
        .accessibilityLabel(Text("The island opening and closing"))
        .onAppear { if running { start() } }
        .onDisappear { stop() }
        .onChange(of: running) { _, now in
            if now { start() } else { stop() }
        }
    }

    /// How far the island's points are scaled to sit in the stage: to its width or to its
    /// height, whichever is the tighter fit.
    private static func fit(in stage: CGSize) -> CGFloat {
        max(0.2, min((stage.width - margin) / expandedSize.width, (stage.height - margin) / expandedSize.height))
    }

    /// A menu bar with nothing on it but the suggestion of one — a few grey titles on the
    /// left, a few status items on the right — so the black reads as the notch rather than as
    /// a black rectangle.
    private func menuBar(height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Capsule().fill(Self.ink).frame(width: 12, height: 6)
            ForEach(0..<3) { _ in
                Capsule().fill(Self.ink).frame(width: 30, height: 6)
            }
            Spacer(minLength: 0)
            ForEach(0..<3) { _ in
                Capsule().fill(Self.ink).frame(width: 10, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(Color(white: 0.9))
    }

    // MARK: The loop

    private func start() {
        guard loop == nil else { return }
        let timer = Timer(timeInterval: Self.hold, repeats: true) { _ in self.turn() }
        // The common modes, so the loop keeps turning while a slider above it is being
        // dragged — which is the one moment anybody is watching it.
        RunLoop.main.add(timer, forMode: .common)
        loop = timer
    }

    private func stop() {
        loop?.invalidate()
        loop = nil
        expanded = false
    }

    /// One turn of the loop: out on the open spring, back on the close, each read live.
    private func turn() {
        withAnimation(expanded ? IslandMotion.close : IslandMotion.open) {
            expanded.toggle()
        }
    }
}

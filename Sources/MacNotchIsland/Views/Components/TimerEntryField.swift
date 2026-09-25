import AppKit
import SwiftUI

/// The field typing opens on Actions: a number for a timer, a time for an alarm.
///
/// The find's twin. It is the panel's find — `ActivityCenter.findQuery`, opened by the first
/// key the same way a letter opens a find on a list, and left with Escape the same way — so
/// the keyboard is handed over and handed back by the rule that already does it for the find,
/// and the digits it opened with are claimed from the switcher only while Actions is showing.
/// What it adds is Return meaning *start*, and a line on the trailing edge saying what Return
/// would start, so "7:30" never becomes a seven-and-a-half-hour timer by surprise.
struct TimerEntryField: View {
    @ObservedObject private var center = ActivityCenter.shared
    // Qualified: the island has a `FocusState` of its own, the payload of a Focus activity.
    @SwiftUI.FocusState private var focused: Bool

    /// As tall as the pills it stands in for, and wide enough for "7:30pm" and what it means.
    static let width: CGFloat = 260
    static let height: CGFloat = 28
    static let clearGlyph: CGFloat = 12

    private var text: String { center.findQuery ?? "" }

    var body: some View {
        let now = Date()
        let typed = TimerEntry.parse(text, now: now, calendar: .current)
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            field
            if let hint = Self.hint(for: typed, text: text, now: now) {
                Text(hint)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(typed == nil ? 0.3 : 0.55))
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(action: { ActivityCenter.shared.endFind() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: Self.clearGlyph, height: Self.clearGlyph)
                    .hitOutset(drawn: Self.clearGlyph)
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Stop typing a timer")
        }
        .padding(.horizontal, 10)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .help(Self.tooltip(for: typed))
        .transition(IslandMotion.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }

    /// What Return would do, in a few words: "5 min timer", "Alarm 7:30 AM tomorrow" — or,
    /// for something that is neither, what would be. Nothing while the field is empty.
    static func hint(for typed: TimerEntry.Typed?, text: String, now: Date) -> String? {
        switch typed {
        case .minutes(let minutes)?: return "\(minutes) min timer"
        case .alarm(let date)?: return "Alarm " + IslandAlarm.describe(date, now: now)
        case nil: return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Minutes, or a time"
        }
    }

    private static func tooltip(for typed: TimerEntry.Typed?) -> String {
        if case .alarm? = typed { return IslandAlarm.awakeNote }
        return "Type minutes for a timer, or a time such as 7:30 or 7:30pm for an alarm. Return starts it, Escape leaves."
    }

    /// Return: the timer or the alarm, and the field closes. Something that is neither leaves
    /// the field as it is, with the Mac's own no, so it can be put right.
    static func submit(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch TimerEntry.parse(text, now: now, calendar: calendar) {
        case .minutes(let minutes)?:
            IslandTimer.shared.start(seconds: TimeInterval(minutes * 60), label: "Timer")
            return true
        case .alarm(let date)?:
            return IslandTimer.shared.setAlarm(at: date, now: now) != nil
        case nil:
            return false
        }
    }

    /// Puts the caret after the digit that opened the field, as the find does: focus lands with
    /// the text selected, and the next key typed would replace it.
    private static func moveCaretToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    @ViewBuilder
    private var field: some View {
        if RenderMode.isGallery {
            Text(text.isEmpty ? "Minutes or a time" : text)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.35 : 1))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Minutes or a time", text: Binding(
                get: { ActivityCenter.shared.findQuery ?? "" },
                set: { ActivityCenter.shared.updateFind($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit {
                if Self.submit(ActivityCenter.shared.findQuery ?? "") {
                    ActivityCenter.shared.endFind()
                } else {
                    NSSound.beep()
                }
            }
            .onAppear { focused = true }
            .onChange(of: center.findQuery == nil) { _, gone in if !gone { focused = true } }
            .onChange(of: focused) { _, now in if now { Self.moveCaretToEnd() } }
            .accessibilityLabel("Timer minutes or alarm time")
        }
    }
}

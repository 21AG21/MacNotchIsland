import Foundation

extension TimeInterval {
    /// 3:07 / 1:02:09 — floors to the second (playback position, call duration).
    var mmss: String {
        let t = Int(self.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Countdown formatting that rounds up so a 5:00 timer starts at 5:00, not 4:59.
    var timerString: String {
        let t = Int(self.rounded(.up))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

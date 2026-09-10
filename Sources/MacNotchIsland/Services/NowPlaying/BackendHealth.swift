import Foundation

/// The small rules that decide whether a Now Playing backend is still worth listening to.
///
/// They live here, apart from the backends, because each one is the answer to a question that
/// has already cost this app a blank island, and because a rule that can be asked on its own is
/// a rule that stays answered. Media detection quietly breaking on a macOS point release is the
/// most-repeated bug in this whole category of app; none of it can be exercised on a build
/// machine with nothing playing unless the rules can be put a question directly.
enum BackendHealth {
    /// Whether a backend last heard from at `lastHeardAt` still counts as working.
    ///
    /// Health has to be able to lapse. A backend that answered once and then went silent — which
    /// is exactly how this breaks in the wild — used to keep the credit for that first answer
    /// until the app was relaunched, and held every fallback shut behind it with nothing said to
    /// the user. Recency is the only honest measure of a thing that has stopped talking.
    ///
    /// A timestamp in the future is read as fresh rather than as a death: a clock nudged
    /// backwards by a second of time sync must not be able to kill a working backend.
    static func isFresh(_ lastHeardAt: Date?, now: Date, within window: TimeInterval) -> Bool {
        guard let lastHeardAt else { return false }
        return now.timeIntervalSince(lastHeardAt) <= window
    }

    /// The failures that still count against a restart budget: those inside the window ending now.
    static func recentFailures(_ failures: [Date], endingAt now: Date, window: TimeInterval) -> [Date] {
        failures.filter { now.timeIntervalSince($0) <= window }
    }

    /// Whether a helper has died too often to be worth restarting straight away.
    ///
    /// A lifetime count is the wrong shape for this. A helper that dies once a day exhausts a
    /// budget of five after five days of uptime, and the app then spends the rest of its life
    /// with the island dark and no way back. A rate — this many deaths inside this window —
    /// forgives the slow drip and still catches the crash loop it was written for.
    static func hasBlownBudget(_ failures: [Date], endingAt now: Date, window: TimeInterval, budget: Int) -> Bool {
        recentFailures(failures, endingAt: now, window: window).count > budget
    }
}

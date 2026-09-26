import Foundation

/// The one serial queue the island's AppleScripts run on, and the way they are run there.
///
/// `NSAppleScript` is not safe to use from several threads at once — Apple's reference asks for
/// the main thread — and Now Playing ran it on four queues of its own: the poll's, the presses',
/// the heart's, and whatever `unfavourite` was given. Any two of them could be compiling or
/// executing a script at the same moment. One serial queue keeps them to one at a time, and it
/// is off the main thread because a player can take seconds to answer.
///
/// Every script sent through here carries a `with timeout` (`timed`), so a player that has stopped
/// answering holds the queue for seconds rather than the two minutes an Apple event waits by
/// default. Small and free of Now Playing on purpose: the appearance switch in `SystemToggles`
/// runs here too, and any other script the app comes to send can as it is.
enum ScriptQueue {
    static let queue = DispatchQueue(label: "com.macnotchisland.applescript", qos: .userInitiated)

    /// Runs `work` on the queue, after whatever is already there.
    static func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// errAETimeout: an Apple event inside `with timeout` that was not answered in time.
    static let timedOutStatus = -1712

    /// `source` inside `with timeout of … seconds`, so no Apple event it sends waits longer than
    /// that for an answer. Pure, so it is tested.
    static func timed(_ source: String, seconds: Int) -> String {
        "with timeout of \(max(1, seconds)) seconds\n\(source)\nend timeout"
    }

    /// What running a script came to: whether it ran without an error, what it returned, and the
    /// error's number where it did not (0 for a script that did not compile).
    struct Outcome {
        var succeeded: Bool
        var descriptor: NSAppleEventDescriptor?
        var errorNumber: Int
        var error: NSDictionary?

        var text: String? { succeeded ? descriptor?.stringValue : nil }
    }

    /// Compiles and runs `source` where it is called from, which is to be `queue`: the one place
    /// a script may be running.
    static func execute(_ source: String) -> Outcome {
        guard let script = NSAppleScript(source: source) else {
            return Outcome(succeeded: false, descriptor: nil, errorNumber: 0, error: nil)
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard let error else { return Outcome(succeeded: true, descriptor: descriptor, errorNumber: 0, error: nil) }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        return Outcome(succeeded: false, descriptor: nil, errorNumber: number, error: error)
    }
}

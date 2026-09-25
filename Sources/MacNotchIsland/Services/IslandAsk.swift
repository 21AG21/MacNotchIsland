import AppKit
import Combine
import Foundation

/// A yes-or-no question a script put to the person at the Mac, through `notchctl ask` or
/// `notchisland://ask`: what to ask, what the two answers are called, how long to wait, and the
/// file the answer goes in.
///
///   notchisland://ask?title=Deploy%20to%20production%3F&detail=main%20at%204f2c1&yes=Deploy&no=Wait&timeout=120&reply=/tmp/notchctl-ask.Xy12/answer
struct AskRequest: Equatable {
    var title: String
    var detail: String?
    var yes: String
    var no: String
    var timeout: TimeInterval
    /// The reply file as the script gave it. `replyPath(isSafe:)` says whether it is one the
    /// island will write.
    var reply: String?

    static let defaultTimeout: TimeInterval = 60
    /// Five seconds is about the least in which somebody can notice a card and read it; ten
    /// minutes is as long as a card may hold the island against every other alert.
    static let timeoutRange: ClosedRange<TimeInterval> = 5...600
    /// A button a card has room for two of beside its question.
    static let maxLabel = 20

    /// The question in a URL's query, or nil when there is no question in it: a card with two
    /// buttons and nothing to say is not a question anybody can answer.
    ///
    /// Pure, so the rules can be tested without a card or a file.
    static func parse(_ q: [String: String]) -> AskRequest? {
        guard let title = LiveActivityAPI.text(q["title"]) else { return nil }
        return AskRequest(title: title,
                          detail: LiveActivityAPI.text(q["detail"]),
                          yes: label(q["yes"], fallback: "Yes"),
                          no: label(q["no"], fallback: "No"),
                          timeout: timeout(q["timeout"]),
                          reply: q["reply"])
    }

    /// How long the question waits, in seconds. Anything that is not a finite number is the
    /// minute it waits by default; a number is held to `timeoutRange`, since "0" would answer
    /// itself on arrival and "86400" would keep a card over the island all day.
    static func timeout(_ raw: String?) -> TimeInterval {
        guard let value = raw.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), value.isFinite else {
            return defaultTimeout
        }
        return min(timeoutRange.upperBound, max(timeoutRange.lowerBound, value))
    }

    /// A button's name: one line, and no longer than a card has room for, or the default when
    /// there is nothing in it.
    static func label(_ raw: String?, fallback: String) -> String {
        let flat = (raw ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return fallback }
        guard flat.count > maxLabel else { return flat }
        return String(flat.prefix(maxLabel - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The line under the question that says it can be answered from the keyboard — only when
    /// the two keys are the island's, since a hint for keys another app has taken is a lie.
    /// Spelled out rather than "⌃Y", which VoiceOver reads as a caret.
    func keyHint(keysHeld: Bool) -> String? {
        keysHeld ? "Control-Y for \(yes), Control-N for \(no)" : nil
    }

    /// The reply file, when it is one the island may create; nil otherwise, and then the
    /// question is not put up at all, since an answer with nowhere to go is not an answer.
    func replyPath(isSafe: (String) -> Bool = AskRequest.isSafeOnDisk) -> String? {
        Self.replyPath(reply, isSafe: isSafe)
    }

    /// The part of the rule that needs no disk: an absolute path, to a file rather than a
    /// folder, with no "." or ".." in it to climb out of wherever it seems to be. What is left —
    /// where it really is, and whether something is there already — is `isSafe`'s.
    static func replyPath(_ raw: String?, isSafe: (String) -> Bool) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.hasSuffix("/"), !raw.contains("\0") else { return nil }
        let parts = raw.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return isSafe(raw) ? raw : nil
    }

    /// Whether the island may create this file: its folder, once every link in it is followed,
    /// is the user's home or /tmp or inside one of them, and nothing — not even a link — is at
    /// the path yet.
    ///
    /// Anything on this Mac can open a `notchisland://` URL, so the reply path is somebody
    /// else's say-so. The folders keep the answer to the places a script of the user's own
    /// would put it; following the links keeps a link in /tmp from pointing the write at
    /// somewhere else entirely; and never replacing a file keeps "reply=~/.zshrc" from being a
    /// way to wipe one, a minute later, with the word "timeout".
    ///
    /// `resolve` follows the links in a folder, and gives nil for one that is not there.
    /// `exists` must not follow a link: a link to nowhere is still something at the path.
    static func isSafeReplyPath(_ path: String, home: String, resolve: (String) -> String?,
                                exists: (String) -> Bool) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        guard let real = resolve(folder) else { return false }
        let roots = [home, "/tmp"].compactMap(resolve).filter { $0 != "/" }
        let inside = roots.contains { real == $0 || real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        return inside && !exists(path)
    }

    /// `isSafeReplyPath` against the disk. Every folder is spelled the one way once its links
    /// are followed: Foundation sometimes leaves /tmp's /private on the front and sometimes takes
    /// it off, and a rule that compared the two spellings would turn away /tmp itself.
    static func isSafeOnDisk(_ path: String) -> Bool {
        isSafeReplyPath(path, home: FileManager.default.homeDirectoryForCurrentUser.path,
                        resolve: { folder in
                            var isFolder: ObjCBool = false
                            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
                                  isFolder.boolValue else { return nil }
                            let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
                            return real.hasPrefix("/private/") ? String(real.dropFirst("/private".count)) : real
                        },
                        // Read without following a link, unlike `fileExists`.
                        exists: { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil })
    }
}

/// How a question ended. The word is what the reply file holds.
enum AskAnswer: String, CaseIterable {
    case yes, no, timeout

    /// What `notchctl ask` exits with, so a script can write `if notchctl ask "Deploy?"; then`
    /// and have it mean what it says: only a yes is success, and a question nobody answered is
    /// never taken for one. The script keeps the same table; `AskTests` holds the two together.
    var exitStatus: Int32 {
        switch self {
        case .yes: return 0
        case .no: return 1
        case .timeout: return 2
        }
    }
}

/// Puts an answer in the reply file: all at once, readable by its owner alone, and never over
/// anything that is already there.
enum AskReply {
    /// Written to a hidden file beside the reply and then hard-linked into place, so the script
    /// polling for the reply never finds half of one; and a link, unlike a rename, refuses when
    /// the name is taken — by a file, or a symbolic link somebody left there to be followed.
    static func put(_ answer: AskAnswer, at path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let scratch = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\(name).\(UUID().uuidString)")
        let fd = open(scratch, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { unlink(scratch) }
        let bytes = Array((answer.rawValue + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count else { return false }
        return link(scratch, path) == 0
    }
}

/// The question on the island: at most one, as a card that holds until it is answered — a
/// click on one of its two buttons, or Control-Y or Control-N from anywhere — or until its time
/// is up, when the answer is "timeout".
///
/// The card is a live activity forced open for the whole of the wait, the way a ringing timer's
/// is: every alert but a battery about to run out waits behind it (`alertTakesIsland`), and the
/// pointer resting on the island does not turn it into the peek. A second question while one is
/// up answers the first "timeout" and takes its place, since the script that asked it is still
/// waiting and deserves an answer rather than silence.
///
/// The card's buttons are links back to the app carrying a token made for this one question, so
/// the only things that can answer it are its own buttons and the keys: a web page that opens
/// `notchisland://ask/answer?answer=yes` answers nothing.
final class IslandAsk {
    static let shared = IslandAsk()
    static let activityID = "ask"
    /// Ranked with the screen recording's card, under a call's.
    static let priority = 90
    /// Past its own timeout, the activity also expires on its own. The timeout ends it first;
    /// this is for a timer that somehow never fired, which would otherwise leave a card up.
    static let expiryGrace: TimeInterval = 5
    /// How often, and how many times, a question whose keys were not the island's when it went
    /// up asks again: four seconds in all, which covers an older copy's two to quit and the
    /// services starting after it on a cold launch.
    static let keyRecheckInterval: TimeInterval = 0.25
    static let keyRechecks = 16

    private struct Pending {
        let request: AskRequest
        let reply: String
        let token: String
    }

    private var pending: Pending?
    private var timeoutWork: DispatchWorkItem?
    private var cardWatch: AnyCancellable?
    private var quitObserver: NSObjectProtocol?

    private init() {
        // A question still up when the app quits is answered, so the script is not left
        // waiting out the rest of its time for an island that has gone.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.settle(.timeout, endCard: false)
        }
    }

    /// Whether a question is up.
    var isAsking: Bool { pending != nil }

    /// `notchisland://ask?…`, read and checked. A question with a reply file the island will not
    /// write is refused; one with nothing to ask is answered "timeout" at once, where its reply
    /// file is one it will write, so the script finds out now rather than in a minute.
    func handle(query q: [String: String]) {
        guard let request = AskRequest.parse(q) else {
            IslandLog.island.error("ask: no question in it")
            if let reply = AskRequest.replyPath(q["reply"], isSafe: AskRequest.isSafeOnDisk) {
                _ = AskReply.put(.timeout, at: reply)
            }
            return
        }
        guard let reply = request.replyPath() else {
            IslandLog.island.error("ask: the reply file is not one the island will create")
            return
        }
        ask(request, reply: reply)
    }

    func ask(_ request: AskRequest, reply: String) {
        // One at a time: the one on screen is answered and replaced, its card kept for this one.
        if pending != nil { settle(.timeout, endCard: false) }
        let token = UUID().uuidString
        pending = Pending(request: request, reply: reply, token: token)
        let keysHeld = HotKeyService.shared.setAskKeysArmed(true)

        let center = ActivityCenter.shared
        var activity = IslandActivity(id: Self.activityID, kind: .custom,
                                      content: .custom(Self.card(for: request, token: token, keysHeld: keysHeld)),
                                      priority: Self.priority, presentation: .expanded)
        activity.expiresAt = Date().addingTimeInterval(request.timeout + Self.expiryGrace)
        center.upsert(activity)
        center.forceExpanded(id: Self.activityID, for: request.timeout)
        watchCard()
        if !keysHeld { recheckKeys(token: token, left: Self.keyRechecks) }

        let work = DispatchWorkItem { [weak self] in self?.answer(.timeout, token: token) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: work)
        IslandLog.island.notice("ask: up for \(request.timeout, privacy: .public)s")
    }

    /// An answer. From the card's buttons it carries the question's token, and one that does
    /// not match — a stale card, or a URL made up elsewhere — is ignored; from the keys it
    /// carries none, and answers whatever question is up.
    func answer(_ answer: AskAnswer, token: String? = nil) {
        guard let pending else { return }
        if let token, token != pending.token {
            IslandLog.island.notice("ask: an answer for a question that is not up")
            return
        }
        settle(answer, endCard: true)
    }

    /// A cold launch by `open -g "notchisland://ask?…"` hands the app the question before it has
    /// finished starting, and the hot keys are installed with the rest of its services a moment
    /// later — so the keys were armed and worked, but the card had already been drawn without
    /// the line that says so. Asking again is `setAskKeysArmed(true)` once more: the keys are
    /// armed already, so it claims nothing new and only says whether they are the island's now.
    /// It stops as soon as they are, when the question is answered or replaced, or when it has
    /// asked `keyRechecks` times: keys another app holds are not worth waiting out, and the
    /// card without the line is still the truth then.
    private func recheckKeys(token: String, left: Int) {
        guard left > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyRecheckInterval) { [weak self] in
            guard let self, self.pending?.token == token else { return }
            if HotKeyService.shared.setAskKeysArmed(true) {
                self.showKeyHint()
            } else {
                self.recheckKeys(token: token, left: left - 1)
            }
        }
    }

    /// Redraws the question's card with the line that names its keys, once they are the
    /// island's: the same activity with one more line — the same buttons and token, the same
    /// expiry and hold — rather than a new question. Nothing when no question is up, or its
    /// card has already gone: a hint is no reason to put a card back.
    func showKeyHint() {
        guard let pending, var activity = ActivityCenter.shared.activity(id: Self.activityID) else { return }
        activity.content = .custom(Self.card(for: pending.request, token: pending.token, keysHeld: true))
        ActivityCenter.shared.upsert(activity)
    }

    /// The card, from the question: the question, the detail under it, the keys that answer it,
    /// and the two buttons, yes first — the filled one, as a card's first button is.
    static func card(for request: AskRequest, token: String, keysHeld: Bool) -> CustomActivity {
        var card = CustomActivity(title: request.title, subtitle: request.detail,
                                  symbol: "questionmark.circle.fill", tint: "blue")
        card.body = request.keyHint(keysHeld: keysHeld)
        card.actions = [CustomAction(title: request.yes, command: .answerAsk(token: token, answer: .yes)),
                        CustomAction(title: request.no, command: .answerAsk(token: token, answer: .no))]
        return card
    }

    /// Where a button goes: back to the app, with the answer and the question's token.
    static func answerURL(_ answer: AskAnswer, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "notchisland"
        components.host = "ask"
        components.path = "/answer"
        components.queryItems = [URLQueryItem(name: "answer", value: answer.rawValue),
                                 URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// Answers the question and lets everything it held go: the reply is written, the timer and
    /// the keys are given back, and — unless the card is already gone, or about to be reused —
    /// the card ends. `pending` is cleared first, so the card ending is not taken for the card
    /// being taken away.
    private func settle(_ answer: AskAnswer, endCard: Bool) {
        guard let pending else { return }
        self.pending = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        cardWatch = nil
        HotKeyService.shared.setAskKeysArmed(false)
        IslandLog.island.notice("ask: answered \(answer.rawValue, privacy: .public)")
        if !AskReply.put(answer, at: pending.reply) {
            IslandLog.island.error("ask: could not write the reply file")
        }
        if endCard { ActivityCenter.shared.end(id: Self.activityID) }
    }

    /// The card can go without an answer — its activity ended by something else, or expired —
    /// and a question whose card has gone cannot be answered with a click, nor should it keep
    /// Control-Y and Control-N from everybody else. So it is answered "timeout" there and then.
    private func watchCard() {
        cardWatch = ActivityCenter.shared.$activities.sink { [weak self] activities in
            guard let self, self.pending != nil, !activities.contains(where: { $0.id == Self.activityID }) else { return }
            self.settle(.timeout, endCard: false)
        }
    }

    /// Forgets the question without answering it. Used by the test suite.
    func resetForTesting() {
        timeoutWork?.cancel()
        timeoutWork = nil
        cardWatch = nil
        pending = nil
        HotKeyService.shared.setAskKeysArmed(false)
    }
}

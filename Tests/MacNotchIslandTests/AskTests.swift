import XCTest
@testable import MacNotchIsland

/// `notchctl ask`: reading the question, where its answer may be written and how, the keys that
/// answer it, and the card — which holds the island the way a ringing timer's does.
final class AskTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }
    private var folders: [String] = []

    override func setUp() {
        super.setUp()
        IslandAsk.shared.resetForTesting()
        center.resetForTesting()
    }

    override func tearDown() {
        IslandAsk.shared.resetForTesting()
        center.resetForTesting()
        for folder in folders { try? FileManager.default.removeItem(atPath: folder) }
        folders = []
        super.tearDown()
    }

    /// A folder of the test's own in /tmp, where `notchctl` makes its own, and the reply path in it.
    private func replyPath() throws -> String {
        let folder = "/tmp/notchctl-ask-test.\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        folders.append(folder)
        return folder + "/answer"
    }

    private func contents(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func handle(_ s: String) {
        LiveActivityAPI.shared.handle(URL(string: s)!)
    }

    private func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    // MARK: - Reading the question

    func testAQuestionWithDefaults() {
        let request = AskRequest.parse(["title": "Deploy?", "reply": "/tmp/x/answer"])
        XCTAssertEqual(request, AskRequest(title: "Deploy?", detail: nil, yes: "Yes", no: "No", timeout: 60,
                                           reply: "/tmp/x/answer"))
    }

    func testEverythingAScriptCanSay() {
        let request = AskRequest.parse(["title": "Deploy?", "detail": "main at 4f2c1", "yes": "Deploy",
                                        "no": "Not now", "timeout": "120"])
        XCTAssertEqual(request?.detail, "main at 4f2c1")
        XCTAssertEqual(request?.yes, "Deploy")
        XCTAssertEqual(request?.no, "Not now")
        XCTAssertEqual(request?.timeout, 120)
        XCTAssertNil(request?.reply)
    }

    func testNoQuestionIsNoQuestion() {
        XCTAssertNil(AskRequest.parse([:]))
        XCTAssertNil(AskRequest.parse(["title": "   \n"]), "two buttons and nothing to say")
        XCTAssertNil(AskRequest.parse(["title": "Q?", "detail": "  "])?.detail, "a blank detail is no detail")
    }

    func testTheTimeoutIsHeldToFiveSecondsToTenMinutes() {
        XCTAssertEqual(AskRequest.timeout(nil), 60)
        XCTAssertEqual(AskRequest.timeout("30"), 30)
        XCTAssertEqual(AskRequest.timeout(" 7.5 "), 7.5)
        XCTAssertEqual(AskRequest.timeout("0"), 5, "would answer itself on arrival")
        XCTAssertEqual(AskRequest.timeout("-3"), 5)
        XCTAssertEqual(AskRequest.timeout("86400"), 600, "would hold the island all day")
        XCTAssertEqual(AskRequest.timeout("inf"), 60)
        XCTAssertEqual(AskRequest.timeout("nan"), 60)
        XCTAssertEqual(AskRequest.timeout("soon"), 60)
    }

    func testALabelIsOneShortLine() {
        XCTAssertEqual(AskRequest.label(nil, fallback: "Yes"), "Yes")
        XCTAssertEqual(AskRequest.label("  ", fallback: "No"), "No")
        XCTAssertEqual(AskRequest.label(" Ship it ", fallback: "Yes"), "Ship it")
        XCTAssertEqual(AskRequest.label("Ship\nit", fallback: "Yes"), "Ship it")
        let long = AskRequest.label("Deploy every service to production now", fallback: "Yes")
        XCTAssertEqual(long.count, AskRequest.maxLabel)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }

    func testTheKeysAreNamedOnlyWhenTheyAreTheIslands() {
        let request = AskRequest(title: "Q?", detail: nil, yes: "Deploy", no: "Wait", timeout: 60, reply: nil)
        XCTAssertEqual(request.keyHint(keysHeld: true), "Control-Y for Deploy, Control-N for Wait")
        XCTAssertNil(request.keyHint(keysHeld: false), "a hint for keys another app has taken is a lie")
    }

    // MARK: - Where the answer may go

    func testOnlyAPlainAbsolutePathToAFileIsConsidered() {
        var asked: [String] = []
        let yes: (String) -> Bool = { asked.append($0); return true }
        XCTAssertEqual(AskRequest.replyPath("/tmp/a/answer", isSafe: yes), "/tmp/a/answer")
        XCTAssertNil(AskRequest.replyPath(nil, isSafe: yes))
        XCTAssertNil(AskRequest.replyPath("", isSafe: yes))
        XCTAssertNil(AskRequest.replyPath("answer", isSafe: yes), "relative")
        XCTAssertNil(AskRequest.replyPath("~/answer", isSafe: yes), "a tilde is not expanded")
        XCTAssertNil(AskRequest.replyPath("/tmp/a/", isSafe: yes), "a folder")
        XCTAssertNil(AskRequest.replyPath("/", isSafe: yes))
        XCTAssertNil(AskRequest.replyPath("/tmp/../etc/answer", isSafe: yes), "climbs out")
        XCTAssertNil(AskRequest.replyPath("/tmp/./answer", isSafe: yes))
        XCTAssertNil(AskRequest.replyPath("/tmp/a\0b", isSafe: yes))
        XCTAssertEqual(asked, ["/tmp/a/answer"], "the disk is asked only about a path worth asking about")
        XCTAssertNil(AskRequest.replyPath("/tmp/a/answer", isSafe: { _ in false }))
        let request = AskRequest(title: "Q?", detail: nil, yes: "Yes", no: "No", timeout: 60, reply: "/tmp/b/answer")
        XCTAssertEqual(request.replyPath(isSafe: { _ in true }), "/tmp/b/answer")
    }

    /// A Mac whose /tmp is a link to /private/tmp, as every Mac's is, with a link in /tmp that
    /// points somewhere else entirely.
    private func safe(_ path: String, existing: Set<String> = []) -> Bool {
        let folders = ["/Users/me": "/Users/me", "/Users/me/Projects": "/Users/me/Projects",
                       "/Users/meow": "/Users/meow", "/tmp": "/private/tmp", "/private/tmp": "/private/tmp",
                       "/tmp/notchctl-ask.X": "/private/tmp/notchctl-ask.X", "/tmp/escape": "/etc",
                       "/Users/me/link": "/Library", "/var/folders/T": "/private/var/folders/T"]
        return AskRequest.isSafeReplyPath(path, home: "/Users/me", resolve: { folders[$0] },
                                          exists: { existing.contains($0) })
    }

    func testTheAnswerGoesInTheHomeFolderOrTmp() {
        XCTAssertTrue(safe("/tmp/notchctl-ask.X/answer"))
        XCTAssertTrue(safe("/tmp/answer"))
        XCTAssertTrue(safe("/private/tmp/answer"))
        XCTAssertTrue(safe("/Users/me/Projects/answer"))
        XCTAssertTrue(safe("/Users/me/answer"))
        XCTAssertFalse(safe("/Users/meow/answer"), "a neighbour whose name starts the same way")
        XCTAssertFalse(safe("/var/folders/T/answer"), "somewhere else")
        XCTAssertFalse(safe("/tmp/missing/answer"), "a folder that is not there")
    }

    func testALinkDoesNotCarryTheAnswerOut() {
        XCTAssertFalse(safe("/tmp/escape/answer"))
        XCTAssertFalse(safe("/Users/me/link/answer"))
    }

    func testTheAnswerNeverReplacesAFile() {
        XCTAssertFalse(safe("/Users/me/answer", existing: ["/Users/me/answer"]),
                       "reply=~/.zshrc must not be a way to wipe one")
    }

    func testTheRuleAgainstTheDisk() throws {
        let path = try replyPath()
        XCTAssertTrue(AskRequest.isSafeOnDisk(path))
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertFalse(AskRequest.isSafeOnDisk(path), "something is there")
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp/nowhere-\(UUID().uuidString)")
        XCTAssertFalse(AskRequest.isSafeOnDisk(path), "a link to nowhere is still something at the path")

        let link = "/tmp/notchctl-ask-link.\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr")
        folders.append(link)
        XCTAssertFalse(AskRequest.isSafeOnDisk(link + "/answer"), "a link in /tmp to a folder outside it")
    }

    // MARK: - Writing it

    func testTheReplyIsWrittenWholeAndForItsOwnerAlone() throws {
        let path = try replyPath()
        XCTAssertTrue(AskReply.put(.yes, at: path))
        XCTAssertEqual(contents(path), "yes\n")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let folder = (path as NSString).deletingLastPathComponent
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["answer"], "nothing left beside it")
    }

    func testTheReplyNeverGoesOverWhatIsThere() throws {
        let path = try replyPath()
        FileManager.default.createFile(atPath: path, contents: Data("mine".utf8))
        XCTAssertFalse(AskReply.put(.no, at: path))
        XCTAssertEqual(contents(path), "mine")

        let other = try replyPath()
        let target = (other as NSString).deletingLastPathComponent + "/target"
        try FileManager.default.createSymbolicLink(atPath: other, withDestinationPath: target)
        XCTAssertFalse(AskReply.put(.no, at: other), "a link is not followed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    // MARK: - What notchctl exits with

    func testOnlyAYesIsSuccess() {
        XCTAssertEqual(AskAnswer.yes.exitStatus, 0)
        XCTAssertEqual(AskAnswer.no.exitStatus, 1)
        XCTAssertEqual(AskAnswer.timeout.exitStatus, 2)
        XCTAssertEqual(AskAnswer(rawValue: "yes"), .yes)
        XCTAssertNil(AskAnswer(rawValue: "YES"), "the file holds the word the island wrote")
    }

    func testTheScriptKeepsTheSameTable() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/notchctl")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("yes) echo yes; exit \(AskAnswer.yes.exitStatus) ;;"))
        XCTAssertTrue(text.contains("no) echo no; exit \(AskAnswer.no.exitStatus) ;;"))
        XCTAssertTrue(text.contains("*) echo timeout; exit \(AskAnswer.timeout.exitStatus) ;;"))
    }

    // MARK: - The keys

    func testTheKeysAreFoundByTheLettersTheyType() {
        let letters = HotKeyService.letterKeyCodes
        // American: each key types its own legend.
        let american: (Int) -> String? = { code in
            letters.firstIndex(of: code).map { String(Character(UnicodeScalar(UInt8(97 + $0)))) }
        }
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "y", among: letters, character: american), 16)
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "n", among: letters, character: american), 45)
        // German: Y and Z change places.
        let german: (Int) -> String? = { code in
            switch code {
            case 16: return "z"
            case 6: return "y"
            default: return american(code)
            }
        }
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "y", among: letters, character: german), 6)
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "n", among: letters, character: german), 45)
        // A layout whose keys type no Latin letters: the American places.
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "y", among: letters, character: { _ in "ж" }), 16)
        XCTAssertEqual(HotKeyService.askKeyCode(typing: "n", among: letters, character: { _ in nil }), 45)
    }

    // MARK: - The card

    private func ask(_ path: String, extra: String = "") {
        handle("notchisland://ask?title=Deploy%3F&yes=Deploy&no=Wait&timeout=30&reply=\(encoded(path))\(extra)")
    }

    private var card: CustomActivity? {
        guard case .custom(let c)? = center.activity(id: IslandAsk.activityID)?.content else { return nil }
        return c
    }

    func testAQuestionIsACardThatHoldsTheIsland() throws {
        let path = try replyPath()
        ask(path, extra: "&detail=main")
        XCTAssertTrue(IslandAsk.shared.isAsking)
        XCTAssertEqual(card?.title, "Deploy?")
        XCTAssertEqual(card?.subtitle, "main")
        XCTAssertEqual(card?.actions.map(\.title), ["Deploy", "Wait"])
        XCTAssertEqual(center.forcedExpandedID, IslandAsk.activityID)
        guard case .card(let shown) = center.presentation else { return XCTFail("the question is not up as a card") }
        XCTAssertEqual(shown.id, IslandAsk.activityID)
        XCTAssertNotNil(center.activity(id: IslandAsk.activityID)?.expiresAt, "a card that cannot outlive its question")
        XCTAssertNil(contents(path), "not answered yet")
    }

    func testTheCardsButtonAnswersIt() throws {
        let path = try replyPath()
        ask(path)
        // The buttons are commands, not links: a link went out through Launch Services and
        // came back, and the card flashed to a pill on the way.
        guard let command = card?.actions.first?.command else { return XCTFail("no button") }
        command.perform()
        XCTAssertEqual(contents(path), "yes\n")
        XCTAssertFalse(IslandAsk.shared.isAsking)
        XCTAssertNil(center.activity(id: IslandAsk.activityID))
        XCTAssertNil(center.forcedExpandedID)
    }

    func testTheSecondButtonIsNo() throws {
        let path = try replyPath()
        ask(path)
        guard let command = card?.actions.last?.command else { return XCTFail("no button") }
        command.perform()
        XCTAssertEqual(contents(path), "no\n")
    }

    func testTheKeysAnswerWhateverIsUp() throws {
        let path = try replyPath()
        ask(path)
        IslandAsk.shared.answer(.no)
        XCTAssertEqual(contents(path), "no\n")
        XCTAssertNil(center.activity(id: IslandAsk.activityID))
        IslandAsk.shared.answer(.yes)
        XCTAssertEqual(contents(path), "no\n", "answered once")
    }

    func testAnAnswerFromAnywhereElseAnswersNothing() throws {
        let path = try replyPath()
        ask(path)
        handle("notchisland://ask/answer?answer=yes")
        handle("notchisland://ask/answer?answer=yes&token=guess")
        XCTAssertTrue(IslandAsk.shared.isAsking)
        XCTAssertNil(contents(path))
    }

    func testASecondQuestionAnswersTheFirstTimeoutAndTakesItsPlace() throws {
        let first = try replyPath(), second = try replyPath()
        ask(first)
        guard let stale = card?.actions.first?.command else { return XCTFail("no button") }
        handle("notchisland://ask?title=Restart%3F&reply=\(encoded(second))")
        XCTAssertEqual(contents(first), "timeout\n")
        XCTAssertEqual(card?.title, "Restart?")
        XCTAssertEqual(center.activities.filter { $0.id == IslandAsk.activityID }.count, 1)
        XCTAssertEqual(center.forcedExpandedID, IslandAsk.activityID)
        stale.perform()
        XCTAssertTrue(IslandAsk.shared.isAsking, "the first card's button does not answer the second")
        IslandAsk.shared.answer(.yes)
        XCTAssertEqual(contents(second), "yes\n")
    }

    func testACardThatGoesWithoutAnAnswerIsATimeout() throws {
        let path = try replyPath()
        ask(path)
        center.end(id: IslandAsk.activityID)
        XCTAssertEqual(contents(path), "timeout\n")
        XCTAssertFalse(IslandAsk.shared.isAsking)
    }

    func testOtherAlertsWaitBehindTheQuestionButAFlatBatteryDoesNot() throws {
        let path = try replyPath()
        ask(path)
        let download = DownloadState(name: "report.zip", bytes: 10, total: 10, app: "Safari", isComplete: true)
        center.showAlert(IslandActivity(id: "download-done", kind: .download, content: .download(download),
                                        priority: 85, presentation: .expanded), duration: 4)
        guard case .card(let shown) = center.presentation else { return XCTFail("the question lost the island") }
        XCTAssertEqual(shown.id, IslandAsk.activityID)

        let battery = BatteryState(percent: 4, isCharging: false, isPluggedIn: false, event: .critical)
        center.showAlert(IslandActivity(id: "battery", kind: .battery, content: .battery(battery), priority: 95))
        if case .card(let shown) = center.presentation, shown.id == IslandAsk.activityID {
            XCTFail("a battery about to run out takes the island from anything")
        }
        XCTAssertTrue(IslandAsk.shared.isAsking, "and the question is still waiting under it")
    }

    /// A cold launch by `open -g`: the question arrives before the hot keys are installed, so
    /// the card goes up without the line that names them, and the keys are the island's a
    /// moment later. The suite never installs them, which is that moment held still.
    func testTheHintArrivesWhenTheKeysDo() throws {
        let path = try replyPath()
        ask(path)
        if card?.body != nil { throw XCTSkip("the keys were already the island's in this run") }
        IslandAsk.shared.showKeyHint()
        XCTAssertEqual(card?.body, "Control-Y for Deploy, Control-N for Wait")
        XCTAssertEqual(card?.title, "Deploy?", "the same card otherwise")
        XCTAssertEqual(card?.actions.map(\.title), ["Deploy", "Wait"])
        XCTAssertEqual(center.forcedExpandedID, IslandAsk.activityID, "and still holding the island")
        guard let command = card?.actions.first?.command else { return XCTFail("no button") }
        command.perform()
        XCTAssertEqual(contents(path), "yes\n", "its buttons still answer it")
    }

    func testAHintIsNoReasonToPutACardBack() throws {
        let path = try replyPath()
        ask(path)
        IslandAsk.shared.answer(.no)
        IslandAsk.shared.showKeyHint()
        XCTAssertNil(center.activity(id: IslandAsk.activityID))
        XCTAssertEqual(contents(path), "no\n")
    }

    func testAReplyFileTheIslandWillNotWriteMeansNoQuestion() {
        handle("notchisland://ask?title=Deploy%3F&reply=%2Fetc%2Fanswer")
        handle("notchisland://ask?title=Deploy%3F&reply=relative")
        handle("notchisland://ask?title=Deploy%3F")
        XCTAssertFalse(IslandAsk.shared.isAsking)
        XCTAssertNil(center.activity(id: IslandAsk.activityID))
    }

    func testNothingToAskIsAnsweredAtOnce() throws {
        let path = try replyPath()
        handle("notchisland://ask?title=%20&reply=\(encoded(path))")
        XCTAssertEqual(contents(path), "timeout\n", "the script hears now rather than in a minute")
        XCTAssertNil(center.activity(id: IslandAsk.activityID))
    }
}

import CoreLocation
import EventKit
import XCTest
@testable import MacNotchIsland

/// What asks macOS for something, and when. A question the app puts on screen has to come from
/// something somebody chose to do — never from the pointer crossing the notch or a section
/// being arrived on — and a refusal has to be said somewhere.
final class FirstLaunchPromptsTests: XCTestCase {
    // MARK: - Reminders, from a peek

    /// The Home peek opens under a pointer resting on the bare notch, and its Today tile was
    /// the agenda's first viewer — which is what asks for Reminders.
    func testAPeekDoesNotAskForTheAgenda() {
        XCTAssertFalse(HomeGridView.holdsAgenda(wantsCalendar: true, pinnedOpen: false, wouldAsk: true),
                       "a pointer passing over is not somebody asking")
        XCTAssertTrue(HomeGridView.holdsAgenda(wantsCalendar: true, pinnedOpen: true, wouldAsk: true),
                      "a panel somebody opened may ask")
        XCTAssertTrue(HomeGridView.holdsAgenda(wantsCalendar: true, pinnedOpen: false, wouldAsk: false),
                      "once both are answered, a peek keeps its tile fresh too")
        XCTAssertFalse(HomeGridView.holdsAgenda(wantsCalendar: false, pinnedOpen: true, wouldAsk: false),
                       "never ahead of the tour, nor with Today switched off")
    }

    func testTheAgendaAsksOnceAndOnlyForWhatIsUnanswered() {
        XCTAssertTrue(AgendaStore.wouldAsk(requested: false, events: .fullAccess, reminders: .notDetermined),
                      "the calendar answered by the monitor, reminders still to ask")
        XCTAssertFalse(AgendaStore.wouldAsk(requested: false, events: .fullAccess, reminders: .denied))
        XCTAssertFalse(AgendaStore.wouldAsk(requested: true, events: .notDetermined, reminders: .notDetermined),
                       "asked once this session already")
    }

    // MARK: - Location, from arriving on Controls

    func testTheWiFiColumnOffersToAskRatherThanAsking() {
        XCTAssertTrue(WiFiScanner.namesUnasked(.notDetermined), "never asked: the pill offers it")
        XCTAssertFalse(WiFiScanner.namesUnasked(.denied), "refused: the pill goes to System Settings instead")
        XCTAssertFalse(WiFiScanner.namesUnasked(.authorizedAlways))
        // The two never both hold, so the column shows one offer or the other.
        for status: CLAuthorizationStatus in [.notDetermined, .denied, .restricted, .authorizedAlways] {
            XCTAssertFalse(WiFiScanner.namesUnasked(status) && WiFiScanner.namesWithheld(status), "\(status.rawValue)")
        }
    }

    // MARK: - Automation, refused in silence

    func testAnAutomationAnswerIsReadWithoutAsking() {
        XCTAssertEqual(AutomationConsent.from(status: 0), .allowed)
        XCTAssertEqual(AutomationConsent.from(status: -1743), .refused)
        XCTAssertEqual(AutomationConsent.from(status: -1744), .notAsked)
        XCTAssertEqual(AutomationConsent.from(status: -600), .notRunning)
        XCTAssertEqual(AutomationConsent.from(status: -50), .unknown)
    }

    func testARefusalSeenThisSessionFillsInForAClosedPlayer() {
        XCTAssertEqual(AutomationConsent.merged(.notRunning, refusedThisSession: true), .refused)
        XCTAssertEqual(AutomationConsent.merged(.notRunning, refusedThisSession: false), .notRunning)
        XCTAssertEqual(AutomationConsent.merged(.allowed, refusedThisSession: true), .allowed,
                       "macOS's own answer is the later word: allowed since")
    }

    func testThePrivacyRowNamesThePlayerThatRefused() {
        XCTAssertEqual(AutomationConsent.summary([("Music", .refused), ("Spotify", .allowed)]), "Refused for Music")
        XCTAssertEqual(AutomationConsent.summary([("Music", .refused), ("Spotify", .refused)]),
                       "Refused for Music and Spotify")
        XCTAssertEqual(AutomationConsent.summary([("Music", .allowed)]), "Granted")
        XCTAssertEqual(AutomationConsent.summary([("Music", .allowed), ("Spotify", .notAsked)]), "Granted for Music")
        XCTAssertEqual(AutomationConsent.summary([("Music", .notRunning)]), "Asked when needed")
        XCTAssertEqual(AutomationConsent.summary([]), "Asked when needed")
    }

    /// The backend's health said answering whenever it was asked, refused or not.
    func testTheScriptedBackendIsRefusedOnlyWhenEveryOpenPlayerSaidNo() {
        let music = AppleScriptBackend.musicID
        let spotify = AppleScriptBackend.spotifyID
        XCTAssertTrue(AppleScriptBackend.refusesEverything(running: [music], refused: [music]))
        XCTAssertFalse(AppleScriptBackend.refusesEverything(running: [music, spotify], refused: [music]),
                       "Spotify can still answer")
        XCTAssertFalse(AppleScriptBackend.refusesEverything(running: [], refused: [music]),
                       "nothing open is nothing asked, not a refusal")
        XCTAssertTrue(AppleScriptBackend.refusesEverything(running: [music, "com.apple.Safari"], refused: [music]),
                      "only the players count")
    }
}

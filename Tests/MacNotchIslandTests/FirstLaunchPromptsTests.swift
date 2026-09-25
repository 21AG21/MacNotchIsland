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
        XCTAssertEqual(HomeGridView.agendaHold(wantsCalendar: true, pinnedOpen: false), .reading,
                       "a pointer passing over is not somebody asking")
        XCTAssertEqual(HomeGridView.agendaHold(wantsCalendar: true, pinnedOpen: true), .asking,
                       "a panel somebody opened may ask")
        XCTAssertEqual(HomeGridView.agendaHold(wantsCalendar: false, pinnedOpen: true), .off,
                       "never ahead of the tour, nor with Today switched off")
        XCTAssertEqual(HomeGridView.agendaHold(wantsCalendar: false, pinnedOpen: false), .off)
    }

    /// After the tour Calendars is answered and Reminders is not, since only the agenda's own
    /// viewer asks for it. A peek that stayed off the agenda until then said "Nothing today"
    /// over a day of meetings, on every new Mac, until a panel had been pinned open once. It
    /// reads what has been granted now, and only a panel somebody opened asks.
    func testAPeekReadsTheDayWithoutAsking() {
        typealias Hold = AgendaStore.Hold
        XCTAssertEqual(AgendaStore.change(from: .off, to: .reading), .appear(mayAsk: false),
                       "a peek is a viewer that asks for nothing")
        XCTAssertEqual(AgendaStore.change(from: .off, to: .asking), .appear(mayAsk: true))
        XCTAssertEqual(AgendaStore.change(from: .reading, to: .asking), .ask,
                       "the peek pinned open: now it may ask, and it stays the viewer it was")
        XCTAssertEqual(AgendaStore.change(from: .asking, to: .reading), .nothing,
                       "unpinned: a question already put is not taken back, and the day is still read")
        XCTAssertEqual(AgendaStore.change(from: .reading, to: .off), .disappear)
        XCTAssertEqual(AgendaStore.change(from: .asking, to: .off), .disappear)
        for hold: Hold in [.off, .reading, .asking] {
            XCTAssertEqual(AgendaStore.change(from: hold, to: hold), .nothing, "\(hold)")
        }
    }

    func testTheAgendaAsksOnceAndOnlyForWhatIsUnanswered() {
        XCTAssertTrue(AgendaStore.wouldAsk(requested: false, events: .fullAccess, reminders: .notDetermined),
                      "the calendar answered by the monitor, reminders still to ask")
        XCTAssertFalse(AgendaStore.wouldAsk(requested: false, events: .fullAccess, reminders: .denied))
        XCTAssertFalse(AgendaStore.wouldAsk(requested: true, events: .notDetermined, reminders: .notDetermined),
                       "asked once this session already")
    }

    // MARK: - Location, from a peek at Today

    /// Any Today on screen started the weather, and its first refresh asked for Location: a
    /// pointer resting on the notch, a peek landing on Today, put the sheet up.
    func testAPeekAtTodayDoesNotAskForLocation() {
        XCTAssertEqual(TodaySectionView.weatherHold(weatherOn: true, pinnedOpen: false), .reading,
                       "a pointer passing over is not somebody asking")
        XCTAssertEqual(TodaySectionView.weatherHold(weatherOn: true, pinnedOpen: true), .asking,
                       "a panel somebody opened may ask")
        XCTAssertEqual(TodaySectionView.weatherHold(weatherOn: false, pinnedOpen: true), .off,
                       "and nothing at all with the weather switched off")
        XCTAssertEqual(TodaySectionView.weatherHold(weatherOn: false, pinnedOpen: false), .off)
    }

    func testTheWeatherReadsWhatIsGrantedAndAsksOnlyWhereItMay() {
        XCTAssertEqual(WeatherService.locationStep(.notDetermined, mayAsk: false), .wait, "a peek never asks")
        XCTAssertEqual(WeatherService.locationStep(.notDetermined, mayAsk: true), .ask)
        // Everything already answered reads the same, asking or not.
        for mayAsk in [false, true] {
            XCTAssertEqual(WeatherService.locationStep(.authorizedAlways, mayAsk: mayAsk), .locate, "\(mayAsk)")
            XCTAssertEqual(WeatherService.locationStep(.denied, mayAsk: mayAsk), .refuse, "\(mayAsk)")
            XCTAssertEqual(WeatherService.locationStep(.restricted, mayAsk: mayAsk), .refuse, "\(mayAsk)")
        }
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

    /// With the helper and MediaRemote silent and Music or Spotify open, the AppleScript
    /// fallback's first poll put the Automation question up ahead of the tour.
    func testThePlayersAreNotScriptedBeforeTheTour() {
        let prefs = Preferences.shared
        let saved = prefs.hasSeenWelcome
        defer { prefs.hasSeenWelcome = saved }

        prefs.hasSeenWelcome = false
        XCTAssertFalse(NowPlayingService.scriptsPlayers(prefs), "not before the tour")
        prefs.hasSeenWelcome = true
        XCTAssertTrue(NowPlayingService.scriptsPlayers(prefs), "and after it")
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

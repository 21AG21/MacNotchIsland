import ServiceManagement
import XCTest
@testable import MacNotchIsland

/// Settings that ride on another switch, and sentences in Settings that are read from the rule
/// they describe rather than written out beside it.
final class SettingsRulesTests: XCTestCase {
    // MARK: - A switch for nothing

    /// "Tell me at" is read by the battery monitor and by nothing else. It sat under Downloads,
    /// a section away from "Battery and charging", and stayed live with that off.
    func testTheChargeMarkRidesOnTheBatterySwitch() {
        let prefs = Preferences.shared
        let saved = prefs.batteryEnabled
        defer { prefs.batteryEnabled = saved }

        // The battery is handed in: the build machine may be a Mac with none.
        prefs.batteryEnabled = true
        XCTAssertTrue(ServiceHub.wantsBattery(prefs, hasBattery: true), "on, the monitor runs and reads the mark")
        prefs.batteryEnabled = false
        XCTAssertFalse(ServiceHub.wantsBattery(prefs, hasBattery: true), "off, nothing reads it, and the menu is greyed out by this")
    }

    /// On a Mac mini the switch and the menu stayed live for a charge nobody has.
    func testAMacWithNoBatteryWatchesNoCharge() {
        let prefs = Preferences.shared
        let saved = prefs.batteryEnabled
        defer { prefs.batteryEnabled = saved }

        prefs.batteryEnabled = true
        XCTAssertFalse(ServiceHub.wantsBattery(prefs, hasBattery: false), "switched on, and still nothing to watch")
        let footer = ActivitiesPane.systemFooter(watchingBattery: false, hasBattery: false)
        XCTAssertTrue(footer.contains("no battery"), "the footer says why both are greyed out")
        XCTAssertFalse(footer.contains("lithium"), "and does not explain a mark there is nothing to set against")
    }

    func testTheSystemFooterSaysWhyTheChargeMarkIsGreyedOut() {
        let on = ActivitiesPane.systemFooter(watchingBattery: true)
        let off = ActivitiesPane.systemFooter(watchingBattery: false)
        XCTAssertTrue(on.contains("Tell me at"), "the footer explains the menu it sits under")
        XCTAssertFalse(on.contains("Battery and charging"), "and has no reason to give while it works")
        XCTAssertTrue(off.hasPrefix(on), "the same explanation, and then the reason")
        XCTAssertTrue(off.contains("Battery and charging"), "greyed out, it names the switch that brings it back")
    }

    // MARK: - What a new Mac is asked, and when

    /// The Bluetooth monitor ships on, and starting it is what asks macOS for Bluetooth: the
    /// sheet came up ahead of the tour, the calendar's mistake again (`wantsCalendar`).
    func testBluetoothWaitsForTheTour() {
        let prefs = Preferences.shared
        let saved = (prefs.hasSeenWelcome, prefs.bluetoothEnabled)
        defer { (prefs.hasSeenWelcome, prefs.bluetoothEnabled) = saved }

        prefs.bluetoothEnabled = true
        prefs.hasSeenWelcome = false
        XCTAssertFalse(ServiceHub.wantsBluetooth(prefs), "not before the tour")
        XCTAssertFalse(ServiceHub.warmsToggles(prefs), "nor the rail's switches, which read the same radio")
        prefs.hasSeenWelcome = true
        XCTAssertTrue(ServiceHub.wantsBluetooth(prefs), "and after it, if it is switched on")
        XCTAssertTrue(ServiceHub.warmsToggles(prefs))
        prefs.bluetoothEnabled = false
        XCTAssertFalse(ServiceHub.wantsBluetooth(prefs), "never when it is switched off")
    }

    // MARK: - A tick that is not the whole story

    /// A `register()` that threw left the tick in place with nothing registered, and an item
    /// waiting on approval read as unticked with nothing to say what it was waiting for.
    func testOpenAtLoginShowsWhatMacOSHasRegistered() {
        XCTAssertEqual(LoginItemRule.shown(status: .enabled).checked, true)
        XCTAssertNil(LoginItemRule.shown(status: .enabled).note)
        XCTAssertEqual(LoginItemRule.shown(status: .notRegistered).checked, false,
                       "a refused register comes back to this, not to the tick it was asked for")
        XCTAssertNil(LoginItemRule.shown(status: .notRegistered).note)

        let waiting = LoginItemRule.shown(status: .requiresApproval)
        XCTAssertTrue(waiting.checked, "registered, so unticking is how to take it back")
        XCTAssertTrue(waiting.note?.contains("Login Items") == true, "and the note says where the rest is done")
        XCTAssertTrue(LoginItemRule.offersLoginItems(waiting.note), "with a way there")

        let lost = LoginItemRule.shown(status: .notFound)
        XCTAssertFalse(lost.checked)
        XCTAssertNotNil(lost.note)
        XCTAssertFalse(LoginItemRule.offersLoginItems(lost.note), "Login Items cannot fix a copy macOS cannot find")
        XCTAssertFalse(LoginItemRule.offersLoginItems(nil))
    }

    // MARK: - A switch that does nothing without a permission

    /// Focus alerts and holding alerts back during a Focus both ship on, and both read a file
    /// macOS may keep from the app. Activities showed them live with nothing said.
    func testTheFocusSwitchSaysWhenTheDatabaseIsKeptFromIt() {
        XCTAssertNil(FocusNote.text(enabled: true, readable: true), "it works, so nothing to say")
        XCTAssertNil(FocusNote.text(enabled: false, readable: false), "switched off, the switch is the explanation")
        let note = FocusNote.text(enabled: true, readable: false)
        XCTAssertTrue(note?.contains("Full Disk Access") == true, "it names what to allow")
        XCTAssertTrue(note?.contains("holding alerts back") == true, "and the second switch it costs")
    }

    /// A folder whose watcher is not running is not listed, since a listing is the question.
    func testAFolderIsOnlyJudgedWhileItsWatcherRuns() {
        XCTAssertEqual(FolderAccess.status(watching: false, readable: false), "Not in use")
        XCTAssertEqual(FolderAccess.status(watching: false, readable: true), "Not in use",
                       "a folder nobody watches is not probed, so nothing is claimed about it")
        XCTAssertEqual(FolderAccess.status(watching: true, readable: true), "Granted")
        XCTAssertEqual(FolderAccess.status(watching: true, readable: false), "Not granted")
    }

    /// The shelf's two switches are read by the watchers that see a file arrive, and each
    /// watcher is switched in Activities, a pane away from them.
    func testTheShelfNamesTheWatcherItsSwitchesNeed() {
        XCTAssertNil(HomePanelPane.shelfNote(downloads: true, screenshots: true), "both work, so nothing to say")

        let noDownloads = HomePanelPane.shelfNote(downloads: false, screenshots: true)
        XCTAssertTrue(noDownloads?.contains("Downloads") == true)
        XCTAssertFalse(noDownloads?.contains("Screenshots") == true, "the switch that is on is not blamed")

        let noScreenshots = HomePanelPane.shelfNote(downloads: true, screenshots: false)
        XCTAssertTrue(noScreenshots?.contains("Screenshots") == true)
        XCTAssertFalse(noScreenshots?.contains("Downloads") == true)

        let neither = HomePanelPane.shelfNote(downloads: false, screenshots: false)
        XCTAssertTrue(neither?.contains("Downloads") == true && neither?.contains("Screenshots") == true,
                      "with both off, both are named")
        for note in [noDownloads, noScreenshots, neither] {
            XCTAssertTrue(note?.contains("Activities") == true, "and says where the switch is")
        }
    }

    // MARK: - A sentence read from its rule

    /// The Island pane named the sections that take the letters by hand, and missed
    /// Notifications. It is read from `PanelFind.sections` now.
    func testTheLettersAreNamedForEverySectionThatTakesThem() {
        let named = IslandPane.findSections
        for section in PanelFind.sections {
            XCTAssertTrue(named.contains(section.title), "\(section.title) takes the letters and is not named")
        }
        XCTAssertTrue(named.contains("Notifications"))
        for section in HomeSection.allCases where !PanelFind.sections.contains(section) {
            XCTAssertFalse(named.contains(section.title), "\(section.title) takes no letters and is named")
        }
        XCTAssertTrue(named.contains(" and "), "a list of names reads as one")
        XCTAssertFalse(named.contains(", and"), "without the serial comma the panes use elsewhere")
    }
}

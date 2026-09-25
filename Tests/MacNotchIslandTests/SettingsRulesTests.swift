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

    // MARK: - What a switch starts at where the island floats

    /// Shipped off everywhere, so on a Mac without a notch the full-screen watch never ran and
    /// the pill stayed over every full-screen film.
    func testFullScreenHidingFollowsTheIslandUntilItIsSet() {
        XCTAssertTrue(FloatingDefaults.hidesInFullScreen(stored: nil, floating: true),
                      "never set, a floating island hides in full screen")
        XCTAssertFalse(FloatingDefaults.hidesInFullScreen(stored: nil, floating: false),
                       "never set, a notch's island stays beside the camera, as it always has")
        for floating in [true, false] {
            XCTAssertTrue(FloatingDefaults.hidesInFullScreen(stored: true, floating: floating),
                          "switched on, it is on, floating \(floating)")
            XCTAssertFalse(FloatingDefaults.hidesInFullScreen(stored: false, floating: floating),
                           "switched off, it is off, floating \(floating)")
        }
    }

    /// Under a notch the strip the island sits in is dead space; on a plain display it is the
    /// tab bar, and a quarter of a second's rest there opened Home.
    func testIdleHoverFollowsTheIslandUntilItIsSet() {
        XCTAssertFalse(FloatingDefaults.idleHoverOpens(stored: nil, floating: true),
                       "never set, the bare floating pill does not open under a resting pointer")
        XCTAssertTrue(FloatingDefaults.idleHoverOpens(stored: nil, floating: false),
                      "never set, the empty notch opens as it always has")
        for floating in [true, false] {
            XCTAssertTrue(FloatingDefaults.idleHoverOpens(stored: true, floating: floating),
                          "switched on, it is on, floating \(floating)")
            XCTAssertFalse(FloatingDefaults.idleHoverOpens(stored: false, floating: floating),
                           "switched off, it is off, floating \(floating)")
        }
        // The switch is only about the bare island: something live opens under the pointer
        // whatever it starts at.
        XCTAssertTrue(ActivityCenter.peeksWhenIdle(
            hasLiveActivity: true, idleHover: FloatingDefaults.idleHoverOpens(stored: nil, floating: true)))
    }

    /// The island floats, for the two switches, only where no display has a notch for it to
    /// sit in. A monitor beside a MacBook, with or without "Show on all displays", leaves the
    /// notch's defaults alone: they flipped every time it was plugged in or out.
    func testTheIslandFloatsWhereItHasNoNotchToSitIn() {
        XCTAssertEqual(FloatingDefaults.floats(notched: [false]), true, "a Mac without a notch")
        XCTAssertEqual(FloatingDefaults.floats(notched: [true]), false, "a MacBook on its own")
        XCTAssertEqual(FloatingDefaults.floats(notched: [true, false]), false,
                       "a MacBook and a monitor, whether or not the monitor carries a floating island too")
        XCTAssertEqual(FloatingDefaults.floats(notched: [false, false]), true, "two plain displays")
        XCTAssertNil(FloatingDefaults.floats(notched: []), "no displays says nothing about the island")
    }

    /// The panels say whether each of them floats each time they are built, and a switch nobody
    /// has set moves with it, without being written down; one somebody has set stays put.
    func testASwitchNobodySetMovesWithTheIslandAndOneSomebodySetStays() {
        let d = UserDefaults.standard
        let prefs = Preferences.shared
        let keys = ["hideInFullscreen", "expandOnIdleHover"]
        let savedObjects = keys.map { d.object(forKey: $0) }
        let savedValues = (prefs.hideInFullscreen, prefs.expandOnIdleHover)
        defer {
            (prefs.hideInFullscreen, prefs.expandOnIdleHover) = savedValues
            for (key, object) in zip(keys, savedObjects) {
                if let object { d.set(object, forKey: key) } else { d.removeObject(forKey: key) }
            }
        }
        keys.forEach { d.removeObject(forKey: $0) }

        prefs.followFloatingDefaults(panelsFloating: [true])
        XCTAssertTrue(prefs.hideInFullscreen, "a floating island hides in full screen out of the box")
        XCTAssertTrue(ServiceHub.wantsFullscreen(prefs), "so the watch runs, by the switch as ever")
        XCTAssertFalse(prefs.expandOnIdleHover, "and the bare pill waits for a click")
        for key in keys {
            XCTAssertNil(d.object(forKey: key), "followed, not written down: \(key)")
        }

        prefs.followFloatingDefaults(panelsFloating: [false])
        XCTAssertFalse(prefs.hideInFullscreen, "the lid opened on a notch: the notch's defaults again")
        XCTAssertFalse(ServiceHub.wantsFullscreen(prefs))
        XCTAssertTrue(prefs.expandOnIdleHover)

        prefs.followFloatingDefaults(panelsFloating: [false, true])
        XCTAssertFalse(prefs.hideInFullscreen,
                       "a monitor's floating island beside the notch's: the notch keeps its defaults")
        XCTAssertTrue(prefs.expandOnIdleHover)

        prefs.followFloatingDefaults(panelsFloating: [true, true])
        XCTAssertTrue(prefs.hideInFullscreen, "every island floating: the floating defaults")
        XCTAssertFalse(prefs.expandOnIdleHover)

        prefs.followFloatingDefaults(panelsFloating: [])
        XCTAssertTrue(prefs.hideInFullscreen, "no panels says nothing, and moves nothing")

        prefs.hideInFullscreen = false
        prefs.expandOnIdleHover = true
        for key in keys {
            XCTAssertNotNil(d.object(forKey: key), "set by hand, it is written down: \(key)")
        }
        prefs.followFloatingDefaults(panelsFloating: [true])
        XCTAssertFalse(prefs.hideInFullscreen, "and stays as it was set, floating or not")
        XCTAssertTrue(prefs.expandOnIdleHover)
    }

    // MARK: - A sentence read from its rule

    /// Both switches start somewhere different on a Mac without a notch, and a switch found
    /// one way on one Mac and the other way on the next reads as a setting that was lost
    /// unless something says so.
    func testSettingsSayTheDefaultsAreNotTheSameWithoutANotch() {
        let footers = [GeneralPane.hidingFooter(needsAccessibility: false),
                       GeneralPane.hidingFooter(needsAccessibility: true),
                       IslandPane.pointerFooter]
        for footer in footers {
            XCTAssertTrue(footer.contains("without a notch"), footer)
            XCTAssertTrue(footer.localizedCaseInsensitiveContains("until you set it"), footer)
        }
    }

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

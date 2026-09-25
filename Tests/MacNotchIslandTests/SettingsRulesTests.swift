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

        prefs.batteryEnabled = true
        XCTAssertTrue(ServiceHub.wantsBattery(prefs), "on, the monitor runs and reads the mark")
        prefs.batteryEnabled = false
        XCTAssertFalse(ServiceHub.wantsBattery(prefs), "off, nothing reads it, and the menu is greyed out by this")
    }

    func testTheSystemFooterSaysWhyTheChargeMarkIsGreyedOut() {
        let on = ActivitiesPane.systemFooter(watchingBattery: true)
        let off = ActivitiesPane.systemFooter(watchingBattery: false)
        XCTAssertTrue(on.contains("Tell me at"), "the footer explains the menu it sits under")
        XCTAssertFalse(on.contains("Battery and charging"), "and has no reason to give while it works")
        XCTAssertTrue(off.hasPrefix(on), "the same explanation, and then the reason")
        XCTAssertTrue(off.contains("Battery and charging"), "greyed out, it names the switch that brings it back")
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

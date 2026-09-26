import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacNotchIsland

/// The display settings the island draws by — Increase Contrast, Differentiate Without Color and
/// Reduce Motion — and the rules each one decides. Every setting is handed in: nothing here reads
/// the Mac the tests run on, or changes the answer the rest of the app reads.
final class AccessibilityDisplayTests: XCTestCase {

    // MARK: - Heard, and passed on

    /// A reading is published setting by setting, and only where it changed: the notification
    /// comes for every display option, and each publish redraws everything that follows.
    func testAReadingPublishesOnlyWhatChanged() {
        let display = AccessibilityDisplay(options: .init())
        var sends = 0
        let watching = display.objectWillChange.sink { _ in sends += 1 }
        defer { watching.cancel() }

        display.apply(.init())
        XCTAssertEqual(sends, 0, "nothing changed, nothing is said")

        display.apply(.init(reduceMotion: true))
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(display.reduceMotion)
        XCTAssertFalse(display.increaseContrast)
        XCTAssertFalse(display.differentiateWithoutColor)

        display.apply(.init(increaseContrast: true, differentiateWithoutColor: true, reduceMotion: true))
        XCTAssertEqual(sends, 3, "the two that changed, and not the one that did not")
        XCTAssertTrue(display.increaseContrast)
        XCTAssertTrue(display.differentiateWithoutColor)

        display.apply(.init(increaseContrast: true, differentiateWithoutColor: true, reduceMotion: true))
        XCTAssertEqual(sends, 3)
    }

    /// Reduce Motion is passed on to what follows the energy policy wherever it changes whether
    /// animation is paused, and not where something else already holds everything still.
    func testTheEnergyPolicyPassesReduceMotionOnOnlyWhereItMatters() {
        XCTAssertTrue(EnergyPolicy.reduceMotionSwitchMatters(asleep: false, lowPower: false, onBattery: false,
                                                             pauseOnBattery: false),
                      "a Mac at its desk: the marquee and the bars stop or start with it")
        XCTAssertTrue(EnergyPolicy.reduceMotionSwitchMatters(asleep: false, lowPower: false, onBattery: true,
                                                             pauseOnBattery: false))
        XCTAssertFalse(EnergyPolicy.reduceMotionSwitchMatters(asleep: true, lowPower: false, onBattery: false,
                                                              pauseOnBattery: false))
        XCTAssertFalse(EnergyPolicy.reduceMotionSwitchMatters(asleep: false, lowPower: true, onBattery: false,
                                                              pauseOnBattery: false))
        XCTAssertFalse(EnergyPolicy.reduceMotionSwitchMatters(asleep: false, lowPower: false, onBattery: true,
                                                              pauseOnBattery: true))
        XCTAssertFalse(EnergyPolicy.reduceMotionSwitchMatters(asleep: false, lowPower: false, onBattery: false,
                                                              pauseOnBattery: false, unattended: true))
        // And what it passes on is the answer the policy gives.
        XCTAssertTrue(EnergyPolicy.animationsPaused(asleep: false, lowPower: false, onBattery: false,
                                                    pauseOnBattery: false, reduceMotion: true))
    }

    // MARK: - Increase Contrast

    /// Quiet text is raised to the floor while contrast is increased, and left exactly as it
    /// was otherwise; nothing already stronger is touched.
    func testIncreaseContrastRaisesOnlyWhatIsFainterThanTheFloor() {
        XCTAssertEqual(IslandContrast.alpha(0.4, increased: false), 0.4)
        XCTAssertEqual(IslandContrast.alpha(0.45, increased: false), 0.45)
        XCTAssertEqual(IslandContrast.alpha(0.4, increased: true), IslandContrast.floor)
        XCTAssertEqual(IslandContrast.alpha(0.55, increased: true), IslandContrast.floor)
        XCTAssertEqual(IslandContrast.alpha(0.85, increased: true), 0.85)
        XCTAssertEqual(IslandContrast.alpha(1, increased: true), 1)
        XCTAssertEqual(IslandContrast.floor, 0.6)
    }

    /// The Bluetooth list's battery figure is a colour rather than a line drawn with
    /// `quietWhite`, so it is raised by hand; its grey rises, and the red that warns does not.
    func testTheBluetoothListsBatteryFigureRisesUnderIncreaseContrast() {
        XCTAssertEqual(ControlsSectionView.batteryTint(80, increased: false), Color.white.opacity(0.45),
                       "exactly as it was with the setting off")
        XCTAssertEqual(ControlsSectionView.batteryTint(80, increased: true), Color.white.opacity(IslandContrast.floor))
        XCTAssertEqual(ControlsSectionView.batteryTint(15, increased: true), ControlsSectionView.batteryTint(15, increased: false),
                       "the red is not a grey, and is left alone")
    }

    // MARK: - Differentiate Without Color

    /// A stopped stopwatch carries a pause glyph, and a low battery a warning, only for the
    /// user who asked not to be told by colour alone.
    func testMarksStandBesideAColourOnlyWhenAskedFor() {
        XCTAssertTrue(IslandMarks.pause(running: false, differentiate: true))
        XCTAssertFalse(IslandMarks.pause(running: true, differentiate: true))
        XCTAssertFalse(IslandMarks.pause(running: false, differentiate: false), "everybody else sees it as it was")
        XCTAssertTrue(IslandMarks.warning(low: true, differentiate: true))
        XCTAssertFalse(IslandMarks.warning(low: false, differentiate: true))
        XCTAssertFalse(IslandMarks.warning(low: true, differentiate: false))
    }

    /// Low is whatever the pill draws in red: a warning, or a fifth or less with nothing
    /// plugged in.
    func testABatteryIsLowWhereItIsDrawnInRed() {
        XCTAssertTrue(BatteryState(percent: 15, isCharging: false, isPluggedIn: false, event: .unplugged).isLow)
        XCTAssertTrue(BatteryState(percent: 30, isCharging: false, isPluggedIn: false, event: .low).isLow)
        XCTAssertTrue(BatteryState(percent: 5, isCharging: false, isPluggedIn: false, event: .critical).isLow)
        XCTAssertFalse(BatteryState(percent: 15, isCharging: true, isPluggedIn: true, event: .pluggedIn).isLow)
        XCTAssertFalse(BatteryState(percent: 80, isCharging: false, isPluggedIn: false, event: .unplugged).isLow)
    }

    /// The privacy dots become a microphone and a camera, in their own colours, only under the
    /// setting.
    func testPrivacyDotsBecomeGlyphsOnlyWhenAskedFor() {
        XCTAssertNil(PrivacyDots.symbol(for: .microphone, differentiate: false))
        XCTAssertNil(PrivacyDots.symbol(for: .camera, differentiate: false))
        XCTAssertEqual(PrivacyDots.symbol(for: .microphone, differentiate: true), "mic.fill")
        XCTAssertEqual(PrivacyDots.symbol(for: .camera, differentiate: true), "video.fill")
    }

    // MARK: - Said out loud

    func testAnAnnouncementIsUrgentUnlessAskedNotToBe() {
        XCTAssertEqual(IslandAccessibility.announcementPriority(high: true), .high)
        XCTAssertEqual(IslandAccessibility.announcementPriority(high: false), .medium)
    }
}

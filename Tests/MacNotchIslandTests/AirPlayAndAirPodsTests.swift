import AppKit
import CoreAudio
import XCTest
@testable import MacNotchIsland

/// What the output picker makes of the AirPlay device's data sources, and what the AirPods pills
/// make of AVFoundation's listening modes. Both sit on behaviour nobody has written down — public
/// CoreAudio used where Apple never said what it does, and private AVFoundation — so the rules
/// that decide what is shown are held here, where they can be checked without a HomePod, a pair
/// of AirPods or a Mac.
final class AirPlayAndAirPodsTests: XCTestCase {

    // MARK: - AirPlay: which receivers get a row

    private let airPlayID: AudioDeviceID = 40

    private func source(_ id: UInt32, _ name: String?) -> AirPlayList.Source {
        AirPlayList.Source(id: id, name: name)
    }

    private func device(_ id: UInt32, _ name: String,
                        _ transport: UInt32 = kAudioDeviceTransportTypeBuiltIn) -> AudioOutputs.Device {
        AudioOutputs.Device(id: AudioDeviceID(id), name: name, transport: transport)
    }

    func testEveryNamedReceiverIsARowInNameOrder() {
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [
            source(3, "Living Room"),
            source(1, "Bedroom HomePod"),
            source(2, "Kitchen"),
        ])
        XCTAssertEqual(targets.map(\.name), ["Bedroom HomePod", "Kitchen", "Living Room"])
        XCTAssertEqual(targets.map(\.source), [1, 2, 3], "each keeps the id it is selected by")
        XCTAssertTrue(targets.allSatisfy { $0.device == airPlayID })
    }

    func testAReceiverWithNoNameIsNotSomewhereAnybodyCanChoose() {
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [
            source(1, nil), source(2, ""), source(3, "   "), source(4, "Kitchen"),
        ])
        XCTAssertEqual(targets.map(\.source), [4])
        XCTAssertEqual(targets.first?.name, "Kitchen")
    }

    func testTheDeviceStandingInForItsOwnListIsNotAReceiver() {
        // One source named after the device is the device answering for itself, not a speaker
        // on the network; a list of only that is an empty list.
        let alone = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [source(1, "airplay")])
        XCTAssertTrue(alone.isEmpty)
        let mixed = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay",
                                        sources: [source(1, "AirPlay"), source(2, "Apple TV")])
        XCTAssertEqual(mixed.map(\.name), ["Apple TV"])
    }

    func testAReceiverListedTwiceIsOneRow() {
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay",
                                          sources: [source(5, "Den"), source(5, "Den (again)"), source(6, "Den")])
        XCTAssertEqual(targets.map(\.source), [5, 6], "the id is what makes a receiver; the first name it gave wins")
        XCTAssertEqual(targets.first?.name, "Den")
        XCTAssertEqual(Set(targets.map(\.id)).count, targets.count, "rows need ids of their own")
    }

    func testOnlyTheReceiversBeingPlayedToAreTicked() {
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay",
                                          sources: [source(1, "Den"), source(2, "Kitchen")])
        XCTAssertEqual(AirPlayList.ticked(selected: [2], targets: targets, isDefaultOutput: true), [2])
        XCTAssertEqual(AirPlayList.ticked(selected: [1, 2], targets: targets, isDefaultOutput: true), [1, 2],
                       "AirPlay plays to several at once, and every one of them is ticked")
        XCTAssertEqual(AirPlayList.ticked(selected: [9], targets: targets, isDefaultOutput: true), [],
                       "a selection that is not on the list ticks nothing")
    }

    func testAChoiceNobodyIsHearingIsNotTicked() {
        // The AirPlay device remembers its last receiver after the sound has gone back to the
        // speakers; ticking it would say the sound is in two places.
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [source(1, "Den")])
        XCTAssertEqual(AirPlayList.ticked(selected: [1], targets: targets, isDefaultOutput: false), [])
    }

    // MARK: - AirPlay: beside the outputs

    func testTheAirPlayDevicesOwnRowGoesWhileItsReceiversAreListed() {
        let speakers = device(1, "MacBook Air Speakers")
        let airPlay = device(airPlayID, "AirPlay", kAudioDeviceTransportTypeAirPlay)
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [source(1, "Den")])
        XCTAssertEqual(AirPlayList.outputs([speakers, airPlay], airPlay: targets), [speakers])
        XCTAssertEqual(AirPlayList.outputs([speakers, airPlay], airPlay: []), [speakers, airPlay],
                       "with no receivers to stand for it, the device keeps the row it always had")
    }

    func testTheAirPlayGroupSitsBetweenTheOutputsAndTheInputs() {
        let speakers = device(1, "MacBook Air Speakers")
        let airPlay = device(airPlayID, "AirPlay", kAudioDeviceTransportTypeAirPlay)
        let mic = device(3, "MacBook Air Microphone")
        let targets = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay",
                                          sources: [source(1, "Den"), source(2, "Kitchen")])
        let entries = SoundList.entries(outputs: [speakers, airPlay], current: airPlay,
                                        inputs: [mic], currentInput: mic,
                                        airPlay: targets, airPlayCurrent: [2])
        XCTAssertEqual(entries, [
            .heading(SoundList.output),
            .device(speakers, isCurrent: false, isInput: false),
            .heading(SoundList.airPlay),
            .airPlay(targets[0], isCurrent: false),
            .airPlay(targets[1], isCurrent: true),
            .heading(SoundList.input),
            .device(mic, isCurrent: true, isInput: true),
        ])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }

    func testNoReceiversMeansNoAirPlayHeading() {
        let speakers = device(1, "MacBook Air Speakers")
        let entries = SoundList.entries(outputs: [speakers], current: speakers, inputs: [], currentInput: nil)
        XCTAssertFalse(entries.contains(.heading(SoundList.airPlay)))
    }

    func testOneReceiverIsAlreadyAChoice() {
        let speakers = device(1, "MacBook Air Speakers")
        let airPlay = device(airPlayID, "AirPlay", kAudioDeviceTransportTypeAirPlay)
        let den = AirPlayList.targets(device: airPlayID, deviceName: "AirPlay", sources: [source(1, "Den")])
        XCTAssertTrue(AirPlayList.hasChoice(outputs: [speakers, airPlay], airPlay: den),
                      "the speakers or the HomePod in the den")
        XCTAssertFalse(AirPlayList.hasChoice(outputs: [speakers], airPlay: []), "one output is a label, not a picker")
        XCTAssertTrue(AirPlayList.hasChoice(outputs: [speakers, airPlay], airPlay: []),
                      "as before: two outputs are a choice")
    }

    func testTheAirPlayGroupCostsTheRailNothing() {
        // It lives in the menu behind the picker's one disc, so a network full of HomePods takes
        // no more of the rail than a pair of headphones does.
        let with = RailMetrics.leading(hasPicker: true, hasBrightness: true)
        let without = RailMetrics.leading(hasPicker: false, hasBrightness: true)
        XCTAssertEqual(with - without, RailMetrics.gap + RailMetrics.button)
    }

    // MARK: - AirPods: reading AVFoundation's names

    func testTheNamesAVFoundationUsesAreRead() {
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeNormal"), .off)
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeAudioTransparency"), .transparency)
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation"), .noiseCancellation)
    }

    func testTheShorterSpellingAndAdaptiveAreReadToo() {
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceListeningModeNoiseCancellation"), .noiseCancellation)
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceListeningModeAdaptive"), .adaptive)
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeAutomatic"), .adaptive)
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceListeningModeOff"), .off)
    }

    func testAdaptiveTransparencyIsAKindOfTransparency() {
        // The pro models' Adaptive Transparency is a Transparency setting, not the Adaptive mode.
        XCTAssertEqual(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeAdaptiveTransparency"), .transparency)
    }

    func testANameNobodyKnowsIsNoMode() {
        XCTAssertNil(AirPodsControl.mode(named: "AVOutputDeviceBluetoothListeningModeSomethingNew"))
        XCTAssertNil(AirPodsControl.mode(named: ""))
    }

    func testTheModesAreCalledWhatControlCentreCallsThem() {
        XCTAssertEqual(AirPodsControl.Mode.allCases.map(\.title), ["Off", "Transparency", "Adaptive", "Noise Cancellation"])
    }

    // MARK: - AirPods: which device, which modes

    private let normal = "AVOutputDeviceBluetoothListeningModeNormal"
    private let anc = "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation"
    private let transparency = "AVOutputDeviceBluetoothListeningModeAudioTransparency"
    private let adaptive = "AVOutputDeviceBluetoothListeningModeAdaptive"

    private func reading(_ name: String, _ available: [String], current: String? = nil,
                         identifier: String = "") -> AirPodsControl.Reading {
        AirPodsControl.Reading(name: name, identifier: identifier, available: available, current: current)
    }

    func testTheFirstDeviceWithAChoiceIsTheOne() {
        let choice = AirPodsControl.choose([
            reading("MacBook Air Speakers", []),
            reading("AirPods Pro", [anc, transparency, normal], current: anc),
        ])
        XCTAssertEqual(choice?.index, 1)
        XCTAssertEqual(choice?.name, "AirPods Pro")
        XCTAssertEqual(choice?.modes, [.off, .transparency, .noiseCancellation], "in Control Centre's order, not the device's")
        XCTAssertEqual(choice?.current, .noiseCancellation)
        XCTAssertEqual(choice?.names[.noiseCancellation], anc, "what is written back is exactly what the device gave")
    }

    func testAdaptiveTakesItsPlaceWhereThePairHasIt() {
        let choice = AirPodsControl.choose([reading("AirPods Pro", [normal, transparency, adaptive, anc], current: adaptive)])
        XCTAssertEqual(choice?.modes, AirPodsControl.Mode.allCases)
        XCTAssertEqual(choice?.current, .adaptive)
    }

    func testOneModeIsNotAChoice() {
        XCTAssertNil(AirPodsControl.choose([reading("AirPods", [normal], current: normal)]),
                     "a pair with no noise control gets no pills")
        XCTAssertNil(AirPodsControl.choose([reading("AirPods", [normal, "SomethingNew"])]),
                     "and a mode the island cannot name does not make it two")
        XCTAssertNil(AirPodsControl.choose([]))
    }

    func testAModeListedTwiceIsOnePill() {
        let choice = AirPodsControl.choose([reading("Beats", [anc, "AVOutputDeviceListeningModeNoiseCancellation", normal])])
        XCTAssertEqual(choice?.modes, [.off, .noiseCancellation])
        XCTAssertEqual(choice?.names[.noiseCancellation], anc, "under the first name it was given")
    }

    func testAModeThePairDidNotOfferLightsNoPill() {
        let choice = AirPodsControl.choose([reading("AirPods Pro", [normal, anc], current: transparency)])
        XCTAssertNotNil(choice)
        XCTAssertNil(choice?.current, "no pill is lit rather than the wrong one")
    }

    // MARK: - AirPods: which row, which card

    func testTheAddressSettlesWhichRowItIs() {
        XCTAssertTrue(AirPodsControl.isSameDevice(name: "Somebody's AirPods", address: "ac:1d:df:11:22:33",
                                                  deviceName: "AirPods Pro", deviceIdentifier: "AC-1D-DF-11-22-33:output"),
                      "the radio's separators and AVFoundation's are one address")
        XCTAssertFalse(AirPodsControl.isSameDevice(name: "Other", address: "ac:1d:df:11:22:44",
                                                   deviceName: "AirPods Pro", deviceIdentifier: "AC-1D-DF-11-22-33:output"))
    }

    func testWithoutAnAddressTheNameDoes() {
        XCTAssertTrue(AirPodsControl.isSameDevice(name: "AirPods Pro ", address: "",
                                                  deviceName: "airpods pro", deviceIdentifier: "0F3C"))
        XCTAssertFalse(AirPodsControl.isSameDevice(name: "", address: "", deviceName: "", deviceIdentifier: nil),
                       "two blank names are not one device")
        XCTAssertFalse(AirPodsControl.isSameDevice(name: "AirPods Pro", address: "", deviceName: nil, deviceIdentifier: nil))
    }

    func testAModeTheIslandSetIsNotUndoneByTheReadingBeforeIt() {
        let pending: (mode: AirPodsControl.Mode, until: TimeInterval) = (.noiseCancellation, 100)
        XCTAssertFalse(AirPodsControl.accepts(.off, pending: pending, now: 99), "the buds have not switched yet")
        XCTAssertTrue(AirPodsControl.accepts(.noiseCancellation, pending: pending, now: 99), "they agree: settled")
        XCTAssertTrue(AirPodsControl.accepts(.off, pending: pending, now: 100), "past the wait, the pair is believed")
        XCTAssertTrue(AirPodsControl.accepts(.off, pending: nil, now: 0))
    }

    // MARK: - AirPods: the glyphs

    func testAGlyphThisMacCannotDrawFallsBackToOneItCan() {
        XCTAssertEqual(AirPodsControl.glyph(from: ["new", "old"]) { $0 == "old" }, "old")
        XCTAssertEqual(AirPodsControl.glyph(from: ["new", "old"]) { _ in true }, "new")
        XCTAssertEqual(AirPodsControl.glyph(from: ["new", "old"]) { _ in false }, "old", "the last is the safe one")
    }

    func testEveryPillHasAGlyphOnThisMac() {
        for mode in AirPodsControl.Mode.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil), "\(mode)")
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbolCandidates.last ?? "", accessibilityDescription: nil),
                            "\(mode)'s fallback must be a symbol every supported macOS has")
        }
        XCTAssertEqual(Set(AirPodsControl.Mode.allCases.map(\.symbol)).count, AirPodsControl.Mode.allCases.count,
                       "four pills, four different glyphs")
    }

    // MARK: - AirPods: the card

    func testTheCardIsTallEnoughForThePillsOnlyWhenItHasThem() {
        XCTAssertEqual(ActivityContent.cardListeningModes, 8 + ListeningModeMetrics.height,
                       "8 pt of air and the row of pills")
        var state = BluetoothState(name: "AirPods Pro", address: "a", symbol: "airpodspro")
        XCTAssertEqual(ActivityContent.bluetooth(state).cardHeight, ActivityContent.cardRow)
        state.offersListeningModes = true
        XCTAssertEqual(ActivityContent.bluetooth(state).cardHeight,
                       ActivityContent.cardRow + ActivityContent.cardListeningModes)
    }

    func testTheCardsPillsAndTheirNameFitUnderTheName() {
        let indent = BluetoothExpandedView.discWidth + BluetoothExpandedView.rowSpacing
        let pills = ListeningModeMetrics.rowWidth(count: AirPodsControl.Mode.allCases.count, pill: ListeningModeMetrics.cardPill)
        // "Noise Cancellation" at 12.5 pt is about 115 pt; 120 leaves it a little air.
        let used = indent + pills + BluetoothExpandedView.rowSpacing + 120
        XCTAssertLessThanOrEqual(used, IslandLayout.cardWidth - 2 * IslandInsets.horizontal)
        XCTAssertGreaterThanOrEqual(ListeningModeMetrics.cardPill, IslandHit.minimum)
        XCTAssertEqual(ListeningModeMetrics.height, IslandHit.minimum, "a 24 pt target, and no taller")
    }

    func testEqualPillsShareTheirRowAndNeverOverrunIt() {
        for count in 2...4 {
            for width in stride(from: CGFloat(100), through: 400, by: 37) {
                let pill = ListeningModeMetrics.pillWidth(count: count, in: width)
                XCTAssertLessThanOrEqual(ListeningModeMetrics.rowWidth(count: count, pill: pill), width, "\(count) in \(width)")
                XCTAssertEqual(pill, pill.rounded(.down), "whole points")
            }
        }
        XCTAssertEqual(ListeningModeMetrics.pillWidth(count: 0, in: 100), 0)
    }
}

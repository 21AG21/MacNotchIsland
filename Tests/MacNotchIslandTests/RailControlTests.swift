import AVFoundation
import Combine
import XCTest
@testable import MacNotchIsland

/// The control rail's catalog: the order it is in, which controls are switched on, and which this
/// Mac has. The same soundness the panel's sections have, because it is the same kind of list —
/// something a user arranges once and an update must not scramble.
final class RailControlTests: XCTestCase {

    // MARK: - Order

    func testTheRailShipsInTheOrderItIsWrittenIn() {
        XCTAssertEqual(RailControl.order(stored: []), RailControl.allCases)
        XCTAssertEqual(RailControl.defaultOrder, RailControl.allCases)
        XCTAssertEqual(RailControl.defaultOrder.last, .settings)
    }

    func testAStoredRailOrderIsFollowed() {
        let order = RailControl.order(stored: [RailControl.record.rawValue, RailControl.wifi.rawValue])
        XCTAssertEqual(Array(order.prefix(2)), [.record, .wifi])
        XCTAssertEqual(Set(order), Set(RailControl.allCases), "and nothing is lost")
        XCTAssertEqual(order.count, RailControl.allCases.count)
    }

    func testAControlTheStoredOrderNeverMentionedKeepsItsPlaceAtTheEnd() {
        // What an older build wrote will not name a control a later one added; it has to appear
        // rather than vanish.
        let order = RailControl.order(stored: [RailControl.lock.rawValue])
        XCTAssertEqual(order.first, .lock)
        XCTAssertEqual(order.count, RailControl.allCases.count)
        XCTAssertEqual(Array(order.dropFirst().dropLast()),
                       RailControl.defaultOrder.filter { $0 != .lock && $0 != .settings },
                       "the rest in the order they ship")
    }

    func testARailOrderWithRubbishInItIsStillAnOrder() {
        let order = RailControl.order(stored: ["lock", "lock", "chocolate", ""])
        XCTAssertEqual(order.first, .lock)
        XCTAssertEqual(order.count, RailControl.allCases.count, "no duplicates, no ghosts")
    }

    func testSettingsIsLastWhateverTheStoredOrderSays() {
        let order = RailControl.order(stored: ["settings", "wifi", "settings"])
        XCTAssertEqual(order.first, .wifi)
        XCTAssertEqual(order.last, .settings)
        XCTAssertEqual(order.filter { $0 == .settings }.count, 1)
    }

    func testTheUsersOrderIsTheOneTheRailReads() {
        let prefs = Preferences.shared
        let saved = prefs.railOrder
        defer { prefs.railOrder = saved }
        prefs.railOrder = [RailControl.keepAwake.rawValue, RailControl.display.rawValue]
        XCTAssertEqual(Array(RailControl.ordered(prefs).prefix(2)), [.keepAwake, .display])
    }

    // MARK: - Switches

    func testTheButtonsTheRailAlwaysHadShipOnAndTheNewActionsWaitToBeAskedFor() {
        for control in [RailControl.wifi, .bluetooth, .display, .keepAwake, .mirror, .airDrop, .keyboardLight, .settings] {
            XCTAssertTrue(RailControl.isSwitchedOn(control, switches: [:]), "\(control) ships on")
        }
        for control in [RailControl.focus, .microphone, .lock, .sleepDisplay, .screenshot, .record] {
            XCTAssertFalse(RailControl.isSwitchedOn(control, switches: [:]), "\(control) ships off")
        }
    }

    func testASwitchTheUserThrewIsKeptEitherWay() {
        XCTAssertTrue(RailControl.isSwitchedOn(.lock, switches: ["lock": true]))
        XCTAssertFalse(RailControl.isSwitchedOn(.wifi, switches: ["wifi": false]))
        XCTAssertTrue(RailControl.isSwitchedOn(.settings, switches: ["settings": false]), "Settings has no switch")
    }

    func testTheMirrorsSwitchIsTheMirrorFeaturesOwn() {
        let prefs = Preferences.shared
        let saved = (prefs.mirrorEnabled, prefs.railSwitches)
        defer { (prefs.mirrorEnabled, prefs.railSwitches) = saved }
        RailControl.mirror.setEnabled(false, in: prefs)
        XCTAssertFalse(prefs.mirrorEnabled, "one switch for the mirror, not two that can disagree")
        XCTAssertNil(prefs.railSwitches[RailControl.mirror.rawValue])
        XCTAssertFalse(RailControl.mirror.isEnabled(prefs))
        RailControl.lock.setEnabled(true, in: prefs)
        XCTAssertTrue(RailControl.lock.isEnabled(prefs))
        XCTAssertEqual(prefs.railSwitches[RailControl.lock.rawValue], true)
    }

    // MARK: - What this Mac has

    func testAControlThisMacHasNothingForIsNotOffered() {
        let bare = RailControl.Presence(hasWiFi: false, hasBluetooth: false, hasKeyboardLight: false, shelfHasFiles: false)
        let shown = RailControl.available(order: RailControl.defaultOrder, isEnabled: { _ in true }, presence: bare)
        XCTAssertFalse(shown.contains(.wifi))
        XCTAssertFalse(shown.contains(.bluetooth))
        XCTAssertFalse(shown.contains(.keyboardLight), "no backlight, no disc for one")
        XCTAssertFalse(shown.contains(.airDrop), "nothing on the shelf, nothing to send")
        XCTAssertEqual(shown.last, .settings)
        XCTAssertTrue(shown.contains(.display), "every Mac has a display and a Dark Mode")

        let full = RailControl.Presence()
        XCTAssertEqual(RailControl.available(order: RailControl.defaultOrder, isEnabled: { _ in true }, presence: full),
                       RailControl.defaultOrder)
    }

    /// The mirror ships on, and on a Mac with no camera it was a disc that asked for the camera
    /// and then said there was none.
    func testTheMirrorNeedsACamera() {
        let noCamera = RailControl.Presence(hasCamera: false)
        let shown = RailControl.available(order: RailControl.defaultOrder, isEnabled: { _ in true }, presence: noCamera)
        XCTAssertFalse(shown.contains(.mirror))
        XCTAssertTrue(shown.contains(.wifi), "nothing else goes with it")
        XCTAssertTrue(RailControl.available(order: RailControl.defaultOrder, isEnabled: { _ in true },
                                            presence: RailControl.Presence()).contains(.mirror),
                      "a camera, built in or plugged in, brings it back")
    }

    /// Looking for a camera comes before asking for one, see `CameraPreview.firstStep`.
    func testTheMirrorLooksForACameraBeforeAskingForIt() {
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: false, access: .notDetermined), .unavailable,
                       "nothing to look through is said without a question")
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: false, access: .authorized), .unavailable)
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: true, access: .notDetermined), .ask)
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: true, access: .authorized), .start)
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: true, access: .denied), .denied)
        XCTAssertEqual(CameraPreview.firstStep(hasCamera: true, access: .restricted), .denied)
    }

    func testOnlyTheControlsSwitchedOnAreOfferedInTheUsersOrder() {
        let order = RailControl.order(stored: ["lock", "wifi"])
        let switches = ["lock": true, "bluetooth": false]
        let shown = RailControl.available(order: order,
                                          isEnabled: { RailControl.isSwitchedOn($0, switches: switches) },
                                          presence: RailControl.Presence())
        XCTAssertEqual(Array(shown.prefix(2)), [.lock, .wifi])
        XCTAssertFalse(shown.contains(.bluetooth))
        XCTAssertFalse(shown.contains(.record), "an action nobody asked for stays off the rail")
    }

    func testEveryControlCanBeNamedAndDrawn() {
        for control in RailControl.allCases {
            XCTAssertFalse(control.label.isEmpty)
            XCTAssertFalse(control.symbol.isEmpty)
        }
        XCTAssertEqual(Set(RailControl.allCases.map(\.label)).count, RailControl.allCases.count, "no two share a name")
    }

    func testEveryControlIsADiscTheKeyboardsLightIncluded() {
        // The keyboard's slider was 104 pt of the rail, and the first thing a file on the shelf
        // pushed off it. It is a disc like the rest, and its slider is in the popover it opens.
        XCTAssertEqual(RailMetrics.width(of: .keyboardLight), RailMetrics.button)
        XCTAssertEqual(RailMetrics.cost(of: .keyboardLight), RailMetrics.cost(of: .display))
        for control in RailControl.allCases {
            XCTAssertEqual(RailMetrics.width(of: control), RailMetrics.button, "\(control)")
            XCTAssertEqual(RailMetrics.cost(of: control), RailMetrics.gap + RailMetrics.button, "\(control)")
        }
        XCTAssertEqual(RailMetrics.cost(of: .keyboardLight), 42)
        XCTAssertGreaterThanOrEqual(RailMetrics.button, IslandHit.minimum, "and every disc takes its click in 24 pt or more")
    }

    // MARK: - The Shelf section's AirDrop

    /// Every control that ships on, on a Mac that has them all, with one file on the shelf.
    private var shippedWithAirDrop: [RailControl] {
        RailControl.available(order: RailControl.defaultOrder,
                              isEnabled: { RailControl.isSwitchedOn($0, switches: [:]) },
                              presence: RailControl.Presence(shelfHasFiles: true))
    }

    func testTheShelfSectionTakesItsOwnAirDropOffTheRailAndNothingElseMoves() {
        // AirDrop stands down on the Shelf section, which has its own. The room it leaves is not
        // handed to whatever did not fit: the strip keeps its shape whatever the panel shows.
        XCTAssertTrue(shippedWithAirDrop.contains(.airDrop))
        for picker in [false, true] {
            for brightness in [false, true] {
                let room = RailMetrics.room(hasPicker: picker, hasBrightness: brightness)
                let elsewhere = RailPlan.plan(shippedWithAirDrop, room: room, showingShelf: false, showingMirror: false)
                let onShelf = RailPlan.plan(shippedWithAirDrop, room: room, showingShelf: true, showingMirror: false)
                XCTAssertEqual(onShelf.rail, elsewhere.rail.filter { $0 != .airDrop }, "picker \(picker), brightness \(brightness)")
                XCTAssertEqual(onShelf.spill, elsewhere.spill.filter { $0 != .airDrop }, "picker \(picker), brightness \(brightness)")
                XCTAssertFalse(onShelf.rail.contains(.airDrop))
            }
        }
    }

    func testThePlanIsTheFitEverywhereButTheShelf() {
        let room = RailMetrics.room(hasPicker: true, hasBrightness: true)
        XCTAssertEqual(RailPlan.plan(shippedWithAirDrop, room: room, showingShelf: false, showingMirror: false),
                       RailControl.fit(shippedWithAirDrop, room: room))
        XCTAssertEqual(RailPlan.plan(shippedWithAirDrop, room: room, showingShelf: false, showingMirror: true),
                       RailControl.fit(shippedWithAirDrop, room: room, pinned: [.settings, .mirror]))
    }

    // MARK: - The volume, muted

    /// Muted, the bar is drawn empty, and VoiceOver read the level it was muted at — "50
    /// percent" over nothing.
    func testAMutedVolumeIsReadAsWhatTheBarShows() {
        XCTAssertEqual(ControlRail.volumeValue(volume: 0.5, muted: true), "Muted")
        XCTAssertEqual(ControlRail.volumeValue(volume: 0.5, muted: false), "50 percent")
        XCTAssertEqual(ControlRail.volumeValue(volume: 0.254, muted: false), "25 percent")
        XCTAssertEqual(ControlRail.volumeValue(volume: nil, muted: false), "0 percent", "no reading yet, as before")
    }

    /// A press of VoiceOver's increment on a muted Mac starts where the bar is drawn, at
    /// nothing, and writes one notch — which unmutes it. A decrement there has nowhere to go:
    /// it writes nothing, rather than unmuting the Mac at a level of nothing and losing the
    /// one it was muted at.
    func testAStepFromAMutedVolumeStartsFromTheEmptyBar() {
        let up = IslandSlider.stepped(from: 0, up: true)
        XCTAssertEqual(ControlRail.volumeWrite(up, muted: true) ?? -1, GestureRouter.keyStep, accuracy: 0.0001,
                       "one notch up from the empty bar, and heard")
        XCTAssertNil(ControlRail.volumeWrite(IslandSlider.stepped(from: 0, up: false), muted: true),
                     "a step down from the empty bar leaves a muted Mac as it was")
        XCTAssertNil(ControlRail.volumeWrite(0, muted: true), "nor does a drag to the bottom")
        XCTAssertEqual(ControlRail.volumeWrite(0, muted: false), 0, "unmuted, the bottom is a level like any other")
        XCTAssertEqual(ControlRail.volumeWrite(0.3, muted: true), 0.3, "and anything above it is written")
    }

    // MARK: - The volume's glyph

    /// An output with no mute of its own took the click, said "Mute", and did nothing.
    func testTheMuteButtonIsOnlyOfferedWhereTheOutputHasAMute() {
        let speakers = ControlRail.muteButton(volume: 0.5, muted: false, hasMute: true)
        XCTAssertTrue(speakers.isEnabled)
        XCTAssertEqual(speakers.label, "Mute")
        XCTAssertEqual(speakers.symbol, "speaker.wave.2.fill")
        XCTAssertEqual(ControlRail.muteButton(volume: 0.5, muted: true, hasMute: true).label, "Unmute")

        let dac = ControlRail.muteButton(volume: 0.5, muted: false, hasMute: false)
        XCTAssertFalse(dac.isEnabled, "a level and no mute: the button is dimmed and takes no click")
        XCTAssertEqual(dac.symbol, "speaker.wave.2.fill", "the glyph still says what the level is")
        XCTAssertNotEqual(dac.help, dac.label, "and the tooltip says why")
    }

    /// With no level to read — HDMI, some AirPlay — the glyph was the struck-out speaker over
    /// music that was playing.
    func testNoLevelIsAPlainSpeakerNotAMutedOne() {
        XCTAssertEqual(ControlRail.muteButton(volume: nil, muted: false, hasMute: false).symbol, "speaker.fill")
        XCTAssertEqual(ControlRail.muteButton(volume: nil, muted: false, hasMute: true).symbol, "speaker.fill")
        XCTAssertEqual(ControlRail.muteButton(volume: nil, muted: true, hasMute: true).symbol, "speaker.slash.fill",
                       "muted is still muted")
        XCTAssertEqual(ControlRail.muteButton(volume: 0, muted: false, hasMute: true).symbol, "speaker.slash.fill",
                       "a level of nothing is drawn as it always was")
    }

    // MARK: - What the rail watches

    /// The rail, the Controls section and the island's menu watch one thing each of the shelf
    /// and the sound devices, and are drawn again only when that thing changes: not for a
    /// thumbnail made for a file on the shelf, nor for a write of a drag of the volume slider.
    func testANarrowReadingStartsFromItsSourceAndPublishesOnlyAChange() {
        let source = CurrentValueSubject<Int, Never>(3)
        let reading = NarrowReading(source, initial: 0)
        XCTAssertEqual(reading.value, 3, "the source's own value, as it is subscribed to")
        var published = 0
        let watching = reading.objectWillChange.sink { _ in published += 1 }
        source.send(3)
        XCTAssertEqual(published, 0, "the same again is not news, and draws nothing")
        source.send(4)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(reading.value, 4)
        watching.cancel()
    }

    /// The rail's output picker is drawn from the route alone, and says what the service would:
    /// whether there is a choice, and where the sound is going.
    func testTheRouteThePickerIsDrawnFromSaysWhatTheServiceWould() {
        let speakers = AudioOutputs.Device(id: 1, name: "MacBook Air Speakers", transport: 0)
        let pods = AudioOutputs.Device(id: 2, name: "AirPods Pro", transport: 0)
        let kitchen = AudioOutputs.AirPlayTarget(device: 9, source: 7, name: "Kitchen")
        let alone = AudioOutputs.Route(devices: [speakers], current: speakers)
        XCTAssertFalse(alone.hasChoice, "one output is a label, not a picker")
        XCTAssertEqual(alone.destinationName, "MacBook Air Speakers")
        let two = AudioOutputs.Route(devices: [speakers, pods], current: pods)
        XCTAssertTrue(two.hasChoice)
        XCTAssertEqual(two.hasChoice, AirPlayList.hasChoice(outputs: two.devices, airPlay: two.airPlay))
        XCTAssertEqual(two.shownOutputs, [speakers, pods])
        let receiving = AudioOutputs.Route(devices: [speakers], current: speakers, airPlay: [kitchen], airPlayCurrent: [7])
        XCTAssertTrue(receiving.hasChoice, "a receiver is somewhere else to go")
        XCTAssertEqual(receiving.destinationName, "Kitchen", "the receiver the sound is on, not the output")
        XCTAssertNil(AudioOutputs.destinationName(current: nil, airPlay: [kitchen], airPlayCurrent: []),
                     "nothing known, nothing named")
    }
}

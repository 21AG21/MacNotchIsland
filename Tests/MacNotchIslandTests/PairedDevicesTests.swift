import XCTest
@testable import MacNotchIsland

/// What the island's right-click menu makes of the paired list and the radio's switch read
/// beside it (`PairedDevices.radioOn`). The radio itself is not here to be asked on a build
/// machine; the rule the menu goes by is.
final class PairedDevicesTests: XCTestCase {
    private let airPods = BluetoothMonitor.Paired(name: "AirPods Pro", address: "00-11-22-33-44-55",
                                                  symbol: "airpodspro", isConnected: true, battery: 68)
    private let keyboard = BluetoothMonitor.Paired(name: "Magic Keyboard", address: "00-11-22-33-44-56",
                                                   symbol: "keyboard.fill", isConnected: false)

    /// With the radio off the menu listed every device as one click from connecting, a tick
    /// still on the one that had been connected, and a click did nothing and said nothing.
    func testWithTheRadioOffTheMenuSaysSoInPlaceOfTheList() {
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: false, devices: [airPods, keyboard]), .off,
                       "the tick left on the AirPods is from before the radio went off")
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: false, devices: [keyboard]), .off)
    }

    func testWithTheRadioOnTheMenuListsTheDevicesAsTheyWereRead() {
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: true, devices: [airPods, keyboard]),
                       .devices([airPods, keyboard]), "in the order read: connected first, then by name")
    }

    /// The first opening, before any read has landed, lists what the menu read for itself; the
    /// gallery, which has no radio, is handed nil too.
    func testARadioNotReadYetListsTheDevicesAsTheMenuAlwaysDid() {
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: nil, devices: [airPods, keyboard]),
                       .devices([airPods, keyboard]), "a guess of off would hide them from a radio that is on")
    }

    func testNothingPairedIsNoItemWhateverTheRadioSays() {
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: true, devices: []), .hidden)
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: false, devices: []), .hidden,
                       "off, with nothing to reconnect, is not worth a line in the menu")
        XCTAssertEqual(IslandMenu.bluetoothMenu(radioOn: nil, devices: []), .hidden,
                       "before the tour the list is empty, and the menu has no Bluetooth item")
    }
}

import XCTest
@testable import MacNotchIsland

/// Covers the one decision the mirror makes that doesn't need a camera: which device to
/// point at. Nothing here touches AVCaptureDevice — `DeviceInfo` is the plain value the
/// real code maps its devices into.
final class CameraPreviewTests: XCTestCase {
    private func device(_ name: String, builtIn: Bool = false) -> CameraPreview.DeviceInfo {
        CameraPreview.DeviceInfo(uniqueID: "id-\(name)", isBuiltIn: builtIn, name: name)
    }

    func testNoDevicesPicksNothing() {
        XCTAssertNil(CameraPreview.pickDevice(from: []))
    }

    func testPrefersBuiltInOverExternal() {
        let external = device("Logitech BRIO")
        let builtIn = device("FaceTime HD Camera", builtIn: true)
        XCTAssertEqual(CameraPreview.pickDevice(from: [external, builtIn]), builtIn)
        XCTAssertEqual(CameraPreview.pickDevice(from: [builtIn, external]), builtIn)
    }

    func testFallsBackToFirstDeviceWhenNoneAreBuiltIn() {
        let first = device("Continuity Camera")
        let second = device("OBS Virtual Camera")
        XCTAssertEqual(CameraPreview.pickDevice(from: [first, second]), first)
    }

    func testKeepsSystemOrderAmongBuiltInCameras() {
        let first = device("Built-in A", builtIn: true)
        let second = device("Built-in B", builtIn: true)
        XCTAssertEqual(CameraPreview.pickDevice(from: [first, second]), first)
    }

    func testSingleDeviceIsAlwaysTheChoice() {
        let only = device("Desk View Camera")
        XCTAssertEqual(CameraPreview.pickDevice(from: [only]), only)
    }

    /// With a MacBook's lid shut its camera is still listed, and opens, and shows black.
    func testASuspendedCameraIsNeverTheChoice() {
        let lidShut = CameraPreview.DeviceInfo(uniqueID: "id-builtin", isBuiltIn: true, name: "FaceTime HD Camera",
                                               isSuspended: true)
        let webcam = device("Logitech BRIO")
        XCTAssertEqual(CameraPreview.pickDevice(from: [lidShut, webcam]), webcam,
                       "the webcam that works, over the built-in camera that cannot see")
        XCTAssertNil(CameraPreview.pickDevice(from: [lidShut]), "and nothing, rather than a black picture")
        XCTAssertFalse(device("Anything").isSuspended, "a device is awake unless the system says otherwise")
    }
}

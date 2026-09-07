import AVFoundation
import Combine
import Foundation

/// Drives the live camera feed behind the Home panel's "Mirror" tab: one shared capture
/// session, started only while a mirror view is on screen and torn down the moment the
/// last one goes away, so the green camera indicator never outlives the picture.
///
/// Everything that mutates `clients` / `asleep` / `state` happens on the main thread;
/// the session itself is configured and started on `queue`, because
/// `AVCaptureSession.startRunning()` blocks for a beat while the camera warms up.
final class CameraPreview: ObservableObject {
    static let shared = CameraPreview()

    enum State: Equatable {
        /// Nothing on screen wants the camera.
        case idle
        /// Permission prompt and/or session warm-up in flight.
        case starting
        /// Frames are flowing into `previewLayer`.
        case running
        /// The user said no (or a profile forbids it).
        case denied
        /// No camera attached, or the session refused to take it.
        case unavailable
    }

    @Published private(set) var state: State = .idle

    /// The layer `MirrorView` drops into an AppKit view. Created once and reused, so
    /// swapping tabs back and forth doesn't rebuild the render tree.
    let previewLayer: AVCaptureVideoPreviewLayer

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.macnotchisland.camera-preview")

    /// How many views currently want a picture. Main thread only.
    private var clients = 0
    /// Mirrors `EnergyPolicy.shared.isAsleep`; the camera stays off while it is true.
    private var asleep = false
    /// Session queue only: whether an input has been wired up.
    private var configured = false
    private var energyCancellable: AnyCancellable?

    private init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        asleep = EnergyPolicy.shared.isAsleep
        // EnergyPolicy publishes *will*-change, so let the value settle before reading it
        // — same debounce CameraMonitor uses.
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.energyChanged() }
    }

    // MARK: - Reference-counted lifetime

    /// Claim the camera. Balanced by `stop()`; the second claimant just joins the session
    /// that is already running instead of fighting over it.
    func start() {
        onMain { [weak self] in
            guard let self else { return }
            self.clients += 1
            guard self.clients == 1 else { return }
            guard !self.asleep else { return }
            self.beginSession()
        }
    }

    /// Release a claim. When the last one goes the session is stopped *and* torn down, so
    /// macOS drops the camera-in-use indicator immediately.
    func stop() {
        onMain { [weak self] in
            guard let self else { return }
            guard self.clients > 0 else { return }
            self.clients -= 1
            guard self.clients == 0 else { return }
            self.endSession()
        }
    }

    private func energyChanged() {
        let sleeping = EnergyPolicy.shared.isAsleep
        guard sleeping != asleep else { return }
        asleep = sleeping
        if sleeping {
            // Never hold the camera across sleep, even if a panel is still mounted.
            if clients > 0 { endSession() }
        } else if clients > 0 {
            beginSession()
        }
    }

    // MARK: - Session

    private func beginSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = .starting
            configureAndStart()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.clients > 0, !self.asleep else { return }
                    if granted { self.configureAndStart() } else { self.state = .denied }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    private func endSession() {
        state = .idle
        teardown()
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard self.configureSession() else {
                    DispatchQueue.main.async { self.state = .unavailable }
                    return
                }
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                guard self.clients > 0, !self.asleep else {
                    // The view left (or the Mac dozed off) while the camera was warming up.
                    self.state = .idle
                    self.teardown()
                    return
                }
                self.applyMirroring()
                self.state = .running
            }
        }
    }

    /// Session queue. Returns false when there is nothing usable to look at.
    private func configureSession() -> Bool {
        let devices = Self.discoveredDevices()
        guard let choice = Self.pickDevice(from: devices.map(Self.info(for:))),
              let device = devices.first(where: { $0.uniqueID == choice.uniqueID }),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
        session.commitConfiguration()
        return true
    }

    /// Session queue. Stops the camera and unhooks the input; `configured` goes false so the
    /// next start rebuilds from scratch.
    private func teardown() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            guard self.configured else { return }
            self.session.beginConfiguration()
            for existing in self.session.inputs { self.session.removeInput(existing) }
            self.session.commitConfiguration()
            self.configured = false
        }
    }

    /// Main thread: a mirror should show you what a mirror shows you, not what the camera
    /// sees. The connection only exists once an input has been added.
    private func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    // MARK: - Device choice

    /// The bits of an `AVCaptureDevice` the picker cares about, as a plain value so the
    /// preference order can be tested without a camera.
    struct DeviceInfo: Equatable {
        let uniqueID: String
        let isBuiltIn: Bool
        let name: String
    }

    /// Prefer the built-in camera (the one above the notch, which is what you want when
    /// checking your face before a call); otherwise take the first thing offered — an
    /// external webcam, a Continuity Camera — in the order the system listed it.
    static func pickDevice(from devices: [DeviceInfo]) -> DeviceInfo? {
        devices.first(where: { $0.isBuiltIn }) ?? devices.first
    }

    static func info(for device: AVCaptureDevice) -> DeviceInfo {
        DeviceInfo(uniqueID: device.uniqueID,
                   isBuiltIn: device.deviceType == .builtInWideAngleCamera,
                   name: device.localizedName)
    }

    private static func discoveredDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                         mediaType: .video,
                                                         position: .unspecified)
        let devices = discovery.devices
        if devices.isEmpty, let fallback = AVCaptureDevice.default(for: .video) { return [fallback] }
        return devices
    }

    // MARK: - Helpers

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

import AppKit
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
        switch Self.firstStep(hasCamera: Self.anyCamera(), access: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .unavailable:
            state = .unavailable
        case .start:
            state = .starting
            configureAndStart()
        case .ask:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.clients > 0, !self.asleep else { return }
                    if granted { self.configureAndStart() } else { self.state = .denied }
                }
            }
        case .denied:
            state = .denied
        }
    }

    /// What opening the mirror does first.
    enum FirstStep: Equatable { case unavailable, start, ask, denied }

    /// Looks for a camera before asking for one. The question came first, and the device was
    /// looked for only once it was answered — so a Mac mini with nothing plugged in asked for
    /// the camera, and then said there was none. Nothing to look through is said without
    /// asking anybody anything. Pure, so the order can be held.
    static func firstStep(hasCamera: Bool, access: AVAuthorizationStatus) -> FirstStep {
        guard hasCamera else { return .unavailable }
        switch access {
        case .authorized: return .start
        case .notDetermined: return .ask
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Whether there is any camera to look through. Listing them asks nothing of anybody; only
    /// opening one does. A suspended camera is not one: see `DeviceInfo.isSuspended`.
    static func anyCamera() -> Bool {
        discoveredDevices().contains { !$0.isSuspended }
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
            // Switching tabs away and straight back queues stop then start; if a client has
            // re-claimed the camera by the time this runs, leave the session alone.
            var reclaimed = false
            DispatchQueue.main.sync { reclaimed = self.clients > 0 }
            if reclaimed { return }
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
        /// The system has the camera switched off where it sits — a MacBook's, with the lid
        /// shut. It is still listed, and still opens, and shows nothing but black.
        var isSuspended = false
    }

    /// Prefer the built-in camera (the one above the notch, which is what you want when
    /// checking your face before a call); otherwise take the first thing offered — an
    /// external webcam, a Continuity Camera — in the order the system listed it. Never a
    /// suspended one: with the lid shut on a MacBook the built-in camera was still first, and
    /// the mirror a black picture beside a webcam that would have worked.
    static func pickDevice(from devices: [DeviceInfo]) -> DeviceInfo? {
        let awake = devices.filter { !$0.isSuspended }
        return awake.first(where: { $0.isBuiltIn }) ?? awake.first
    }

    static func info(for device: AVCaptureDevice) -> DeviceInfo {
        DeviceInfo(uniqueID: device.uniqueID,
                   isBuiltIn: device.deviceType == .builtInWideAngleCamera,
                   name: device.localizedName,
                   isSuspended: device.isSuspended)
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

/// Whether this Mac has a camera at all, for the rail's mirror disc (`RailControl.Presence`).
///
/// The mirror was on the rail by default on every Mac, cameras or none, and a click on it
/// asked for the camera before looking for one. Read once, then kept current by the system's
/// own notices of cameras coming and going — a Continuity Camera or a webcam plugged in brings
/// the disc back. Listing devices needs no permission. Published on the main thread.
///
/// The list is taken on a queue of its own. The first look was made on the main thread by the
/// rail's body, the first time a panel opened — a discovery session inside the opening spring —
/// and every later one on the notice that brought it. Until the first answer lands the disc is
/// left off; it arrives inside the rail's assembly window (`RailAssembly`), without a slide.
/// A MacBook's camera goes to sleep with its lid, and the screens changing is when that is
/// looked at again.
final class CameraPresence: ObservableObject {
    static let shared = CameraPresence()

    @Published private(set) var hasCamera = false
    private var observers: [NSObjectProtocol] = []
    /// Serial, so the last notice's answer is the last one shown.
    private let queue = DispatchQueue(label: "com.macnotchisland.camera-presence", qos: .utility)

    private init() {
        let names: [Notification.Name] = [AVCaptureDevice.wasConnectedNotification,
                                          AVCaptureDevice.wasDisconnectedNotification,
                                          NSApplication.didChangeScreenParametersNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reread()
            })
        }
        reread()
    }

    /// Lists the cameras on `queue`; the answer is shown on the main thread.
    private func reread() {
        queue.async { [weak self] in
            let has = CameraPreview.anyCamera()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.hasCamera != has { self.hasCamera = has }
            }
        }
    }
}

import AppKit

/// Brightness HUD. There is no public change notification, so the built-in display's
/// brightness is sampled a few times a second through DisplayServices (cheap call).
final class BrightnessMonitor {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightnessFn?
    private var timer: Timer?
    private var last: Float = -1

    func start() {
        guard timer == nil else { return }
        if handle == nil {
            handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
            if let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(sym, to: GetBrightnessFn.self)
            }
        }
        guard getBrightness != nil else { return }
        last = read() ?? -1
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.05
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var builtInDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        _ = CGGetOnlineDisplayList(8, &ids, &count)
        for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 { return ids[i] }
        return CGMainDisplayID()
    }

    private func read() -> Float? {
        guard let fn = getBrightness else { return nil }
        var value: Float = 0
        return fn(builtInDisplay, &value) == 0 ? value : nil
    }

    private func tick() {
        guard let v = read() else { return }
        if last < 0 { last = v; return }
        guard abs(v - last) > 0.002 else { return }
        last = v
        let hud = LevelHUD(kind: .brightness, level: Double(v))
        ActivityCenter.shared.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(hud), priority: 85), duration: 1.5)
    }
}

import AppKit
import ApplicationServices

/// Opt-in replacement of the system volume / brightness bezel. (Stub: an implementation
/// agent fills this in with a CGEventTap on media keys; requires Accessibility trust.)
final class MediaKeyInterceptor {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {}
    func stop() {}
}

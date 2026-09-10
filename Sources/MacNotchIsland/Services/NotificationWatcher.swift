import AppKit
import ApplicationServices

/// Reads the banners macOS puts on screen, so that `NotificationInbox` can remember them.
///
/// **This file is expected to stop working, and is built for it.** There is no supported way
/// to be told what an app has just notified you about: the only thing on offer is the
/// Notification Centre process's own accessibility tree, read with the same permission the
/// media keys already ask for. That tree is a private piece of system UI. Apple owes nobody a
/// stable shape for it, and it has changed shape before. So the degraded path is not a fallback
/// here, it is the design:
///
/// * **Nothing is ever dropped for want of text.** If the tree cannot be walked, or yields
///   nothing legible, what is known — that a banner appeared, and when — is recorded anyway,
///   as a thin entry. "Something from Messages at twenty past" answers most of the questions
///   this feature exists to answer, and an empty list answers none of them.
/// * **A reading that fails costs nothing.** Every accessibility call is allowed to fail;
///   there is no path here in which a missing attribute is an error. The walk is bounded in
///   depth, in children and in how much text it will take, so a tree that has grown a
///   thousand-node subtree, or a cycle, cannot hold the thread.
/// * **The sweep, not the observer, is the floor.** The `AXObserver` is only the fast path:
///   it tells us within a moment that something appeared. When its notification names stop
///   meaning what they mean today — or the observer cannot be created at all — the timed
///   sweep still finds banners on screen, and the feature degrades to "a second or two late"
///   rather than to nothing.
/// * **It cannot spin.** The run loop is always given something to wait on, the sweep is
///   coalesced so a burst of accessibility callbacks is answered once, and an observer that
///   will not be created is asked for a few times and then left alone until Notification
///   Centre restarts.
///
/// Everything that touches accessibility runs on this watcher's own thread and run loop:
/// reading another process's tree can block for as long as its messaging timeout, and the one
/// thread that must never block is the one drawing the island. Everything that reaches
/// `NotificationInbox`, or AppKit, is handed to the main queue first.
///
/// Nothing that a notification actually says is ever logged above `.debug`, and what is
/// logged is marked private. Notices are written to disk on the user's Mac, and somebody's
/// messages must not end up in a log file because their notch app was curious.
final class NotificationWatcher {

    /// One banner as it was read off the screen: the strings found in it, in the order they
    /// appear, and where the window sits.
    ///
    /// The position is here for the sake of banners with no legible text at all — it is the
    /// only thing left that tells two of those apart, and without it a second unreadable
    /// banner would look like the first one still being on screen.
    struct Banner: Equatable {
        var texts: [String] = []
        var position: CGPoint? = nil

        /// What tells one banner on screen from another between one sweep and the next. A
        /// banner that is still up is the same banner, not a second notification, which is
        /// the whole reason the sweep may run every couple of seconds without filling the
        /// history with copies.
        var digest: String {
            guard texts.isEmpty else { return texts.joined(separator: "\u{1}") }
            // Checked and clamped before it is made a whole number: a position read out of
            // somebody else's tree is not this app's to trust, and converting an infinite or
            // enormous one traps.
            guard let position, position.x.isFinite, position.y.isFinite else { return "unreadable" }
            let x = Int(min(max(position.x, -100_000), 100_000))
            let y = Int(min(max(position.y, -100_000), 100_000))
            return "unreadable@\(x),\(y)"
        }
    }

    /// The process that draws banners. It is not the app that sent one — that is worked out,
    /// where it can be, from the name the banner shows.
    static let notificationCentreBundleID = "com.apple.notificationcenterui"

    /// What the observer is asked for. Both, because neither is promised: a banner is a
    /// window on today's macOS, and `AXCreated` is the broader net for the day it is not.
    static let observedNotifications = [kAXWindowCreatedNotification, kAXCreatedNotification]

    /// How often the screen is looked at when nothing has told us to look. Two seconds is
    /// nothing on an idle Mac — with no banner up it is a single accessibility call that
    /// comes back empty — and it is the interval at which this feature keeps working after
    /// the observer stops being told anything.
    static let sweepInterval: TimeInterval = 2

    /// A burst of accessibility callbacks — one banner can be a dozen created elements — is
    /// answered once, this long after the first of them.
    static let coalescingInterval: TimeInterval = 0.2

    /// How long an accessibility call may take before it is given up on. Notification Centre
    /// is a system process and is not always answering; the default timeout is far longer
    /// than anything this thread should wait for.
    static let messagingTimeout: Float = 2

    /// The bounds on the walk. A banner is a shallow thing — an icon, a name, a line or two —
    /// so anything deeper or wider than this is not a banner, and reading it is not worth the
    /// time of a process that must never be noticed.
    static let maxDepth = 6
    static let maxChildren = 32
    static let maxTexts = 6
    static let maxBanners = 8

    /// How big a window may be and still be a banner.
    ///
    /// Notification Centre draws its own panel — the tall column of everything you have not
    /// dealt with, with the widgets beneath it — out of this same process, and it is a window
    /// like any other. Reading that as a notification would file the whole column every time
    /// somebody opened it. A window that cannot be measured is read anyway; only one that
    /// measures too big to be a banner is passed over.
    static let maxBannerSize = CGSize(width: 900, height: 320)

    /// How many times an observer that will not be created is asked for again. Without a cap
    /// this would ask every couple of seconds for the life of the process.
    static let maxObserverAttempts = 5

    // Main thread only.
    private(set) var running = false
    private var thread: Thread?

    // Shared with the watcher thread.
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var stopRequested = false

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        lock.lock()
        stopRequested = false
        lock.unlock()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.notchisland.notifications"
        // Reading a system UI is background work by any measure; it must never take a beat
        // away from the island being drawn.
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    func stop() {
        guard running else { return }
        running = false
        lock.lock()
        stopRequested = true
        let loop = self.loop
        lock.unlock()
        // The thread lets go of the observer itself, on the way out of its own run loop:
        // accessibility observers belong to the loop they were added to.
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// The watcher's thread, from the moment it starts to the moment it lets go of everything
    /// it holds.
    private func run() {
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        self.loop = loop
        lock.unlock()

        let session = Session(watcher: self)
        // A run loop with no source in it returns the instant it is asked to run, so the
        // sweep timer is what keeps this thread waiting rather than spinning. The timeout on
        // `CFRunLoopRunInMode` and the sleep below are the belt to that brace.
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak session] _ in
            session?.sweep()
        }
        RunLoop.current.add(timer, forMode: .default)
        session.sweep()

        while !isStopping {
            if CFRunLoopRunInMode(CFRunLoopMode.defaultMode, Self.sweepInterval, false) == .finished {
                Thread.sleep(forTimeInterval: Self.sweepInterval)
            }
        }

        timer.invalidate()
        session.detach()

        lock.lock()
        if self.loop === loop { self.loop = nil }
        lock.unlock()
    }

    // MARK: - Filing what was read (main queue)

    /// Turns banners into entries and files them. On the main queue, because AppKit is asked
    /// which apps are running and because the inbox is what the panel draws itself from.
    private func record(_ banners: [Banner]) {
        let apps = Self.runningAppNames()
        let now = Date()
        for banner in banners {
            let entry = Self.entry(from: banner, at: now, apps: apps)
            // Debug only, and the words themselves private: an `IslandLog` notice is kept on
            // disk, and a notification is somebody's post, not the island's business.
            IslandLog.island.debug("notification from \(entry.bundleID, privacy: .public): \(entry.title, privacy: .private)")
            NotificationInbox.shared.record(entry)
        }
    }

    /// The names macOS shows for what is running, against the bundle identifiers behind them.
    /// A banner shows the app's name and nothing else, so this is the only bridge from what
    /// was read to which app sent it.
    static func runningAppNames() -> [String: String] {
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, let bundle = app.bundleIdentifier else { continue }
            if names[name] == nil { names[name] = bundle }
        }
        return names
    }

    /// What one banner's strings mean.
    ///
    /// A banner reads as its app's name, then its title, then whatever else it had room for,
    /// so the first string is taken as the app when it names something that is running, and
    /// the rest fill in from the top. When it names nothing that is running — which is what
    /// happens the day the tree changes shape — the entry is still made, and the app is
    /// simply unknown. Pure, and the whole of the interpretation: nothing else in this file
    /// decides what a banner said.
    static func entry(from banner: Banner, at date: Date,
                      apps: [String: String]) -> NotificationInbox.Entry {
        var texts = banner.texts
        var appName = ""
        var bundleID = NotificationInbox.Entry.unknownBundleID
        if let first = texts.first, let bundle = apps[first] {
            appName = first
            bundleID = bundle
            texts.removeFirst()
        }
        var subtitle: String?
        var body: String?
        if texts.count > 2 {
            subtitle = texts[1]
            body = texts[2...].joined(separator: "\n")
        } else if texts.count == 2 {
            body = texts[1]
        }
        return NotificationInbox.Entry(bundleID: bundleID,
                                       appName: appName,
                                       title: texts.first ?? "",
                                       subtitle: subtitle,
                                       body: body,
                                       date: date)
    }

    // MARK: - Reading the tree (watcher thread)

    /// Every banner Notification Centre has on screen. An attribute that is not there, or is
    /// not what it was, ends the read for that element and no more than that.
    static func banners(in app: AXUIElement) -> [Banner] {
        guard let windows = value(of: app, attribute: kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var result: [Banner] = []
        for window in windows.prefix(maxBanners) {
            guard isBannerSized(window) else { continue }
            var texts: [String] = []
            collectText(from: window, into: &texts, depth: 0)
            result.append(Banner(texts: texts, position: position(of: window)))
        }
        return result
    }

    /// Whether a window is small enough to be a banner rather than the Notification Centre
    /// panel. A window that will not say how big it is gets the benefit of the doubt.
    private static func isBannerSized(_ window: AXUIElement) -> Bool {
        guard let measured = size(of: window) else { return true }
        return measured.width <= maxBannerSize.width && measured.height <= maxBannerSize.height
    }

    /// Every string in a banner, in the order it is drawn, bounded so that a tree which is
    /// not what we think it is cannot cost more than a moment.
    private static func collectText(from element: AXUIElement, into texts: inout [String], depth: Int) {
        guard depth < maxDepth, texts.count < maxTexts else { return }
        if let text = string(of: element), !texts.contains(text) { texts.append(text) }
        guard let children = value(of: element, attribute: kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children.prefix(maxChildren) {
            collectText(from: child, into: &texts, depth: depth + 1)
        }
    }

    /// Whatever an element has to say for itself. A label, a title and a description are all
    /// the same thing to a reader; which of them a banner uses has changed between releases.
    private static func string(of element: AXUIElement) -> String? {
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let raw = value(of: element, attribute: attribute), let text = raw as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let raw = value(of: element, attribute: kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }   // type checked just above
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let raw = value(of: element, attribute: kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var measured = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &measured) else { return nil }   // type checked just above
        return measured
    }

    private static func value(of element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// What the accessibility observer calls. It carries the session that registered it
    /// rather than the watcher, so a callback can only ever reach the thread it belongs to —
    /// a watcher that has been stopped and started again has a session of its own.
    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let raw = refcon as UnsafeMutableRawPointer? else { return }
        Unmanaged<Session>.fromOpaque(raw).takeUnretainedValue().somethingAppeared()
    }

    /// One run of the watcher thread, and everything it holds while it runs.
    ///
    /// All of this belongs to that thread and is touched from nowhere else, which is what
    /// makes the accessibility observer safe to hand a raw pointer to: the observer is created
    /// here, added to this thread's run loop, and let go of on the way out.
    private final class Session {
        private weak var watcher: NotificationWatcher?
        private var observer: AXObserver?
        private var element: AXUIElement?
        private var observed: pid_t = 0
        private var failures = 0
        /// The banners that were on screen at the last sweep, so one that is still up is not
        /// recorded again.
        private var onScreen: Set<String> = []
        private var lastSweep = Date.distantPast
        private var coalesced: Timer?

        init(watcher: NotificationWatcher) {
            self.watcher = watcher
        }

        /// The observer's fast path. A dozen of these can arrive for one banner, so they are
        /// gathered up into a single reading a moment later.
        func somethingAppeared() {
            let since = Date().timeIntervalSince(lastSweep)
            guard since < NotificationWatcher.coalescingInterval else {
                sweep()
                return
            }
            guard coalesced == nil else { return }
            let timer = Timer(timeInterval: NotificationWatcher.coalescingInterval - since,
                              repeats: false) { [weak self] _ in
                self?.coalesced = nil
                self?.sweep()
            }
            RunLoop.current.add(timer, forMode: .default)
            coalesced = timer
        }

        /// Look at what is on screen, and file whatever was not there last time.
        func sweep() {
            guard let watcher, !watcher.isStopping else { return }
            lastSweep = Date()
            attach()
            guard let element else {
                // Nothing to read from: no permission, or Notification Centre is not running.
                // Whatever was on screen is not ours to remember any more.
                onScreen.removeAll()
                return
            }
            var seen: Set<String> = []
            var fresh: [Banner] = []
            for banner in NotificationWatcher.banners(in: element) {
                let digest = banner.digest
                guard seen.insert(digest).inserted else { continue }
                if !onScreen.contains(digest) { fresh.append(banner) }
            }
            onScreen = seen
            guard !fresh.isEmpty else { return }
            DispatchQueue.main.async { [weak watcher] in watcher?.record(fresh) }
        }

        /// Makes sure we are pointed at the Notification Centre that is running now.
        ///
        /// It restarts on its own account, and the permission can be given or taken away
        /// while the app is up, so this is asked on every sweep rather than once at the start.
        private func attach() {
            guard AXIsProcessTrusted() else {
                detach()
                return
            }
            // `NSRunningApplication` is thread safe; `NSWorkspace` is not asked anything here.
            let centre = NSRunningApplication.runningApplications(
                withBundleIdentifier: NotificationWatcher.notificationCentreBundleID).first
            guard let centre else {
                detach()
                return
            }
            let pid = centre.processIdentifier
            // A different process id means the one we were reading has gone, and everything
            // held for it points at nothing.
            if pid != observed { detach() }
            if element == nil {
                let app = AXUIElementCreateApplication(pid)
                _ = AXUIElementSetMessagingTimeout(app, NotificationWatcher.messagingTimeout)
                element = app
                observed = pid
            }
            guard let element else { return }
            addObserver(to: element, pid: pid)
        }

        /// The fast path, if it can be had. Every failure here is survivable: the sweep goes
        /// on without it, a second or two behind.
        private func addObserver(to element: AXUIElement, pid: pid_t) {
            guard observer == nil, failures < NotificationWatcher.maxObserverAttempts else { return }
            var created: AXObserver?
            guard AXObserverCreate(pid, NotificationWatcher.axCallback, &created) == .success,
                  let created else {
                failures += 1
                IslandLog.island.debug("no notification observer, sweeping instead; attempt \(self.failures, privacy: .public)")
                return
            }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var added = 0
            for name in NotificationWatcher.observedNotifications {
                if AXObserverAddNotification(created, element, name as CFString, refcon) == .success {
                    added += 1
                }
            }
            guard added > 0 else {
                // The observer exists but is being told nothing, which is worse than no
                // observer at all: it would sit in the run loop for ever, silent.
                failures += 1
                IslandLog.island.debug("notification observer accepted nothing to watch for; sweeping instead")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
            failures = 0
        }

        /// Lets go of everything, and is safe to call when there is nothing to let go of.
        func detach() {
            coalesced?.invalidate()
            coalesced = nil
            if let observer {
                if let element {
                    for name in NotificationWatcher.observedNotifications {
                        _ = AXObserverRemoveNotification(observer, element, name as CFString)
                    }
                }
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            element = nil
            observed = 0
            failures = 0
            onScreen.removeAll()
        }
    }
}

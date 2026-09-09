import AppKit
import SwiftUI
import XCTest
@testable import MacNotchIsland

/// Renders every state the island can be in, at Retina scale, over a mock menu bar and
/// desktop, into `GALLERY_DIR`. Skipped unless that variable is set: this is a review tool
/// for the design, not a test of behaviour.
///
///     GALLERY_DIR=$PWD/build/gallery swift test --filter GalleryTests
@MainActor
final class GalleryTests: XCTestCase {
    private static let notch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                             notchWidth: 185, notchHeight: 33.5, hasPhysicalNotch: true)
    private static let plain = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                             notchWidth: 190, notchHeight: 30, hasPhysicalNotch: false)

    private struct Scene {
        var name: String
        var floating = false
        /// Rendered over a dark wallpaper, where macOS draws the menu bar almost black.
        ///
        /// Every other scene sits on a pale bar, which is where the island's own black is its
        /// own edge — and is why nobody noticed that on a dark one the shape dissolves into
        /// the bar entirely and what is in it reads as marks floating in a void.
        var dark = false
        var setup: (ActivityCenter) -> Void
    }

    func testRenderGallery() throws {
        guard let dir = ProcessInfo.processInfo.environment["GALLERY_DIR"], !dir.isEmpty else {
            throw XCTSkip("GALLERY_DIR is not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Drawing these scenes fills in the notes and the clipboard history, and both of those
        // write themselves to the app's own folder. Somebody rendering the gallery to look at
        // a change on their own Mac should not find their scratchpad replaced by "Call the
        // landlord about the heating."
        IslandFiles.overrideFolder = URL(fileURLWithPath: dir).appendingPathComponent("support", isDirectory: true)
        defer { IslandFiles.overrideFolder = nil }
        // Other tests leave preferences behind in the same defaults domain; every tab and
        // feature the gallery shows is switched on explicitly.
        let prefs = Preferences.shared
        prefs.hapticsEnabled = false
        prefs.weatherEnabled = true
        prefs.statsEnabled = true
        prefs.mirrorEnabled = true
        prefs.quickActionsEnabled = true
        prefs.shelfEnabled = true
        prefs.clipboardEnabled = true
        prefs.lyricsEnabled = true
        prefs.nowPlayingEnabled = true
        prefs.notesEnabled = true
        prefs.calendarEnabled = true
        prefs.windowsEnabled = true
        prefs.hoverToExpand = true
        prefs.hoverDelay = 0.05
        RenderMode.isGallery = true
        defer { RenderMode.isGallery = false }
        let center = ActivityCenter.shared
        let files = Self.sampleFiles(in: dir)

        var rendered: [String] = []
        for scene in Self.scenes(files: files) {
            center.resetForTesting()
            center.setHovering(false)
            ShelfStore.shared.clear()
            // Every store the panel reads starts empty for each scene; the scene fills in
            // whatever it means to show. Without this the sections that read the calendar,
            // the pasteboard and the user's apps could only ever be reviewed empty.
            AgendaStore.shared.seedForGallery(events: [], reminders: [])
            ClipboardStore.shared.seedForGallery([])
            FavoriteApps.shared.seedForGallery([])
            NotesStore.shared.text = "Call the landlord about the heating.\nPick up the print from the shop before 6."
            scene.setup(center)
            let geometry = scene.floating ? Self.plain : Self.notch
            let shot = render(geometry: geometry, dark: scene.dark)
            try write(shot, name: scene.name, dir: dir)
            rendered.append(scene.name)
        }
        center.resetForTesting()
        ShelfStore.shared.clear()
        print("GALLERY rendered \(rendered.count) scenes: \(rendered.joined(separator: " "))")
        XCTAssertGreaterThan(rendered.count, 40)
    }

    // MARK: - Rendering

    /// Two copies of one scene: the archival Retina one, and the smaller one the review
    /// actually reads.
    ///
    /// The review copy is read back out of the CI job log, which the API truncates at a couple
    /// of megabytes — from the *front*, so the scenes early in the alphabet are the ones that
    /// vanish. Every card and every alert had fallen off it. Rendered at `reviewScale` rather
    /// than compressed harder, because the thing most in need of looking at is a hairline of
    /// ten-percent white along the island's edge, and a JPEG squeezed until the whole gallery
    /// fits is a JPEG that has thrown that away.
    private static let reviewScale: CGFloat = 1.4

    private func render(geometry: NotchGeometry, dark: Bool = false) -> (full: CGImage?, review: CGImage?) {
        let layout = IslandLayout.make(presentation: ActivityCenter.shared.presentation(for: "main"), geometry: geometry,
                                       center: .shared, clearance: .unlimited)
        let height = max(96, layout.bodyHeight + layout.topInset + 48)
        let content = GalleryBackdrop(geometry: geometry, dark: dark) {
            IslandRootView(geometry: geometry, panelID: "main")
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
                .environment(\.colorScheme, .dark)
        }
        .frame(width: 880, height: height)
        let retina = ImageRenderer(content: content)
        retina.scale = 2
        let review = ImageRenderer(content: content)
        review.scale = Self.reviewScale
        return (retina.cgImage, review.cgImage)
    }

    private func write(_ shot: (full: CGImage?, review: CGImage?), name: String, dir: String) throws {
        guard let image = shot.full else {
            XCTFail("nothing rendered for \(name)")
            return
        }
        let folder = URL(fileURLWithPath: dir)
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        let reviewRep = NSBitmapImageRep(cgImage: shot.review ?? image)
        if let jpeg = reviewRep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
            try jpeg.write(to: folder.appendingPathComponent(name + ".jpg"))
        }
    }

    /// A couple of real files for the shelf scenes.
    private static func sampleFiles(in dir: String) -> [URL] {
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = folder.appendingPathComponent("Notes for Monday.txt")
        try? "Agenda\n- island review\n- ship".write(to: text, atomically: true, encoding: .utf8)
        let picture = folder.appendingPathComponent("Screenshot 2026-09-08.png")
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 30)
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: picture)
        }
        return [text, picture]
    }

    // MARK: - Fixtures

    private static let track = NowPlayingService.fakeTrack()

    private static func nowPlaying(playing: Bool = true) -> IslandActivity {
        var info = track
        info.isPlaying = playing
        var a = IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(info), priority: 50)
        a.openAction = .app(bundleID: "com.apple.Music")
        return a
    }

    private static func timer() -> IslandActivity {
        IslandActivity(id: "timer", kind: .timer,
                       content: .timer(TimerState(label: "Tea", total: 300, endDate: Date().addingTimeInterval(187))), priority: 60)
    }

    private static func stopwatch() -> IslandActivity {
        IslandActivity(id: "stopwatch", kind: .stopwatch,
                       content: .stopwatch(StopwatchState(startedAt: Date().addingTimeInterval(-125), laps: [31.2, 64.8])), priority: 55)
    }

    private static func call() -> IslandActivity {
        IslandActivity(id: "call", kind: .call,
                       content: .call(CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: Date().addingTimeInterval(-63))),
                       priority: 100, presentation: .expanded, openAction: .app(bundleID: "com.apple.FaceTime"))
    }

    private static func download() -> IslandActivity {
        IslandActivity(id: "download", kind: .download,
                       content: .download(DownloadState(name: "Xcode_26.6.xip", bytes: 2_100_000_000, total: 3_300_000_000, app: "Safari")),
                       priority: 45)
    }

    private static func drive(_ event: DriveState.Event = .connected) -> IslandActivity {
        IslandActivity(id: "drive", kind: .drive,
                       content: .drive(DriveState(name: "Backup", path: "/Volumes/Backup",
                                                  total: 1_000_000_000_000, free: 238_000_000_000, event: event)),
                       priority: 80, presentation: .expanded,
                       openAction: .url(URL(fileURLWithPath: "/Volumes/Backup")))
    }

    private static func capture(_ recording: Bool = false) -> IslandActivity {
        let name = recording ? "Screen Recording 2026-09-09 at 21.14.02.mov"
                             : "Screenshot 2026-09-09 at 21.14.02.png"
        let state = CaptureState(path: "/Users/you/Desktop/" + name, isRecording: recording,
                                 thumbnail: nil, onShelf: true, text: recording ? nil : "Notch Island")
        return IslandActivity(id: "capture", kind: .capture, content: .capture(state),
                              priority: 85, presentation: .expanded,
                              openAction: .url(URL(fileURLWithPath: "/Users/you/Desktop/" + name)))
    }

    private static func calendar() -> IslandActivity {
        IslandActivity(id: "calendar", kind: .calendar,
                       content: .calendar(CalendarState(title: "Design review", start: Date().addingTimeInterval(7 * 60),
                                                        end: Date().addingTimeInterval(67 * 60), location: "Caffè Macs",
                                                        joinURL: URL(string: "https://zoom.us/j/123"), tint: "blue")),
                       priority: 65)
    }

    private static func custom() -> IslandActivity {
        IslandActivity(id: "delivery", kind: .custom,
                       content: .custom(CustomActivity(title: "Order on the way", subtitle: "Arriving in 12 min", symbol: "bicycle",
                                                       tint: "green", progress: 0.65, trailingText: "12 min",
                                                       body: "Your courier is 1.4 km away.", showsRing: true)),
                       priority: 70)
    }

    private static func charging() -> IslandActivity {
        IslandActivity(id: "battery", kind: .battery,
                       content: .battery(BatteryState(percent: 82, isCharging: true, isPluggedIn: true, event: .pluggedIn,
                                                      timeRemainingMinutes: 48, wattage: 61.2, cycleCount: 112, healthPercent: 97)),
                       priority: 85)
    }

    private static func lowBattery() -> IslandActivity {
        IslandActivity(id: "battery", kind: .battery,
                       content: .battery(BatteryState(percent: 10, isCharging: false, isPluggedIn: false, event: .low,
                                                      timeRemainingMinutes: 22, wattage: -7.4, cycleCount: 112, healthPercent: 97)),
                       priority: 85, presentation: .expanded)
    }

    private static func airPods() -> IslandActivity {
        IslandActivity(id: "bluetooth", kind: .bluetooth,
                       content: .bluetooth(BluetoothState(name: "AirPods Pro", address: "demo", symbol: "airpodspro",
                                                          batteryLeft: 92, batteryRight: 88, batteryCase: 64)),
                       priority: 85, presentation: .expanded)
    }

    private static func focus() -> IslandActivity {
        IslandActivity(id: "focus", kind: .focus,
                       content: .focus(FocusState(name: "Do Not Disturb", symbol: "moon.fill", isOn: true, tint: "indigo")), priority: 85)
    }

    private static func hud(_ kind: LevelHUD.Kind, _ level: Double, device: String? = nil, symbol: String? = nil) -> IslandActivity {
        IslandActivity(id: "hud", kind: .hud,
                       content: .hud(LevelHUD(kind: kind, level: level, device: device, deviceSymbol: symbol)),
                       priority: 85)
    }

    private static func shelf(count: Int) -> IslandActivity {
        IslandActivity(id: "shelf", kind: .shelf, content: .shelf(ShelfState(count: count, latestName: "Screenshot 2026-09-08.png", latestIsImage: true)),
                       priority: 30)
    }

    // MARK: - What the sections show

    /// Two events and two reminders: the shape of an afternoon that is still ahead.
    private static func today() {
        let now = Date()
        AgendaStore.shared.seedForGallery(
            events: [
                AgendaStore.Event(id: "e1", title: "Design review", start: now.addingTimeInterval(7 * 60),
                                  end: now.addingTimeInterval(67 * 60), isAllDay: false, location: "Caffè Macs",
                                  joinURL: URL(string: "https://zoom.us/j/123"), tint: "blue"),
                AgendaStore.Event(id: "e2", title: "1:1 with Sam", start: now.addingTimeInterval(95 * 60),
                                  end: now.addingTimeInterval(125 * 60), isAllDay: false, location: nil,
                                  joinURL: nil, tint: "purple"),
            ],
            reminders: [
                AgendaStore.Reminder(id: "r1", title: "Send the notes round", due: now.addingTimeInterval(3 * 3600),
                                     isCompleted: false, priority: 1, tint: "orange"),
                AgendaStore.Reminder(id: "r2", title: "Book the flight", due: nil, isCompleted: false,
                                     priority: 0, tint: "green"),
            ])
    }

    /// A history with one of each kind in it.
    private static func clipboard() {
        let now = Date()
        ClipboardStore.shared.seedForGallery([
            ClipboardItem(kind: .url, text: "https://developer.apple.com/design/human-interface-guidelines",
                          date: now.addingTimeInterval(-60), pinned: true),
            ClipboardItem(kind: .text, text: "let panelWidth: CGFloat = 720", date: now.addingTimeInterval(-8 * 60)),
            ClipboardItem(kind: .text, text: "Flat 4, 18 Rosebery Avenue, London EC1R 4TD",
                          date: now.addingTimeInterval(-42 * 60)),
        ])
    }

    /// Apps every Mac has, so the row draws real icons.
    private static func favouriteApps() {
        FavoriteApps.shared.seedForGallery([
            "/System/Applications/Music.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
        ].filter { FileManager.default.fileExists(atPath: $0) })
    }

    // MARK: - Scenes

    /// Lets the hover delay elapse so the panel opens under the (simulated) pointer.
    private static func peek(_ c: ActivityCenter) {
        c.setHovering(true)
        RunLoop.main.run(until: Date().addingTimeInterval(Preferences.shared.hoverDelay + 0.15))
    }

    private static func scenes(files: [URL]) -> [Scene] {
        func panel(_ tab: String, _ extra: @escaping (ActivityCenter) -> Void = { _ in }) -> (ActivityCenter) -> Void {
            { c in extra(c); c.open(.home(tab: tab)) }
        }
        func card(_ activity: @escaping () -> IslandActivity) -> (ActivityCenter) -> Void {
            { c in
                let a = activity()
                c.upsert(a)
                c.open(.activity(id: a.id))
            }
        }
        return [
            Scene(name: "notch-idle") { _ in },
            Scene(name: "floating-idle", floating: true) { _ in },

            Scene(name: "compact-nowplaying") { c in c.upsert(nowPlaying()) },
            Scene(name: "compact-nowplaying-paused") { c in c.upsert(nowPlaying(playing: false)) },
            // The same states over a dark wallpaper, where the island has no contrast of its
            // own to fall back on.
            Scene(name: "dark-notch-idle", dark: true) { _ in },
            Scene(name: "dark-compact-nowplaying", dark: true) { c in c.upsert(nowPlaying()) },
            Scene(name: "dark-panel-music", dark: true, setup: panel("music") { c in c.upsert(nowPlaying()) }),
            // The floating pill on a dark desktop: the one geometry whose outline is a closed
            // loop, with a real top edge of its own, and the only place the rim can be seen
            // all the way round.
            Scene(name: "dark-floating-idle", floating: true, dark: true) { _ in },
            Scene(name: "dark-floating-compact-nowplaying", floating: true, dark: true) { c in c.upsert(nowPlaying()) },
            Scene(name: "compact-timer") { c in c.upsert(timer()) },
            Scene(name: "compact-timer-bubble-nowplaying") { c in c.upsert(nowPlaying()); c.upsert(timer()) },
            Scene(name: "compact-stopwatch") { c in c.upsert(stopwatch()) },
            Scene(name: "compact-call") { c in c.upsert(call()) },
            Scene(name: "compact-download") { c in c.upsert(download()) },
            Scene(name: "compact-drive") { c in c.upsert(drive()) },
            Scene(name: "compact-capture") { c in c.upsert(capture()) },
            Scene(name: "compact-calendar") { c in c.upsert(calendar()) },
            Scene(name: "compact-custom-delivery") { c in c.upsert(custom()) },
            Scene(name: "compact-shelf") { c in ShelfStore.shared.add(files); c.upsert(shelf(count: files.count)) },

            Scene(name: "alert-battery-charging") { c in c.showAlert(charging(), duration: 60) },
            Scene(name: "alert-focus") { c in c.showAlert(focus(), duration: 60) },
            Scene(name: "alert-volume") { c in c.showAlert(hud(.volume, 0.6), duration: 60) },
            Scene(name: "alert-brightness") { c in c.showAlert(hud(.brightness, 0.4), duration: 60) },
            // The volume display when the sound is somewhere worth naming.
            Scene(name: "alert-volume-airpods") { c in
                c.showAlert(hud(.volume, 0.35, device: "AirPods Pro", symbol: "airpodspro"), duration: 60)
            },
            // And when the thing it is going to sets its own level.
            Scene(name: "alert-volume-unavailable") { c in
                var state = LevelHUD.unavailableVolume(output: nil)
                state.device = "Studio Display"
                state.deviceSymbol = "display"
                c.showAlert(IslandActivity(id: "hud", kind: .hud, content: .hud(state), priority: 85), duration: 60)
            },
            Scene(name: "alert-silent") { c in
                c.showAlert(IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: true)), priority: 85), duration: 60)
            },
            Scene(name: "alert-unlock") { c in
                c.showAlert(IslandActivity(id: "unlock", kind: .unlock, content: .unlock, priority: 85), duration: 60)
            },
            Scene(name: "alert-volume-over-nowplaying") { c in
                c.upsert(nowPlaying())
                c.showAlert(hud(.volume, 0.6), duration: 60)
            },

            // System cards: an alert with a large view, or a timer that rang.
            Scene(name: "card-battery-low") { c in c.showAlert(lowBattery(), duration: 60) },
            Scene(name: "card-airpods") { c in c.showAlert(airPods(), duration: 60) },
            Scene(name: "card-timer-rang") { c in
                var t = timer()
                if case .timer(var state) = t.content { state.isFinished = true; t.content = .timer(state) }
                c.upsert(t)
                c.forceExpanded(id: t.id, for: 60)
            },
            Scene(name: "card-call") { c in c.upsert(call()); c.forceExpanded(id: "call", for: 60) },

            // The panel, pinned, on each view it can show.
            Scene(name: "panel-music", setup: panel("music") { c in c.upsert(nowPlaying()) }),
            Scene(name: "panel-music-empty", setup: panel("music")),
            Scene(name: "panel-today", setup: panel("today") { _ in today() }),
            Scene(name: "panel-today-empty", setup: panel("today")),
            Scene(name: "panel-windows", setup: panel("windows")),
            // Type-to-find, narrowing a list of four to the one window that answers.
            Scene(name: "panel-windows-find") { c in
                c.open(.home(tab: "windows"))
                c.beginFind(with: "m")
                c.updateFind("ma")
            },
            Scene(name: "panel-shelf", setup: panel("shelf") { _ in ShelfStore.shared.add(files) }),
            Scene(name: "panel-shelf-empty", setup: panel("shelf")),
            Scene(name: "panel-clipboard", setup: panel("clipboard") { _ in clipboard() }),
            Scene(name: "panel-clipboard-empty", setup: panel("clipboard")),
            Scene(name: "panel-clipboard-find") { c in
                clipboard()
                c.open(.home(tab: "clipboard"))
                c.beginFind(with: "a")
                c.updateFind("app")
            },
            Scene(name: "panel-actions", setup: panel("actions") { _ in favouriteApps() }),
            Scene(name: "panel-actions-empty", setup: panel("actions")),
            Scene(name: "panel-notes", setup: panel("notes")),
            Scene(name: "panel-stats", setup: panel("stats") { _ in SystemStats.shared.seedForGallery() }),
            Scene(name: "panel-timer", setup: card(timer)),
            Scene(name: "panel-stopwatch", setup: card(stopwatch)),
            Scene(name: "panel-call", setup: card(call)),
            Scene(name: "panel-download", setup: card(download)),
            Scene(name: "panel-drive", setup: card({ drive() })),
            Scene(name: "card-capture") { c in
                let a = capture()
                c.upsert(a)
                c.forceExpanded(id: a.id, for: 60)
            },
            Scene(name: "card-drive") { c in
                let a = drive()
                c.upsert(a)
                c.forceExpanded(id: a.id, for: 60)
            },
            Scene(name: "card-drive-ejected") { c in
                let a = drive(.ejected)
                c.upsert(a)
                c.forceExpanded(id: a.id, for: 60)
            },
            Scene(name: "panel-calendar", setup: card(calendar)),
            Scene(name: "panel-custom-delivery", setup: card(custom)),
            Scene(name: "panel-battery", setup: card(charging)),
            Scene(name: "panel-bluetooth", setup: card(airPods)),
            Scene(name: "panel-busy") { c in
                c.upsert(nowPlaying()); c.upsert(timer()); c.upsert(download()); c.upsert(calendar())
                ShelfStore.shared.add(files)
                c.open(.home(tab: "music"))
            },
            Scene(name: "panel-banner-volume") { c in
                c.upsert(nowPlaying())
                c.open(.home(tab: "music"))
                c.showAlert(hud(.volume, 0.6, device: "AirPods Pro", symbol: "airpodspro"), duration: 60)
            },
            Scene(name: "panel-banner-airpods") { c in
                c.upsert(nowPlaying())
                c.open(.home(tab: "music"))
                c.showAlert(airPods(), duration: 60)
            },
            Scene(name: "panel-banner-battery-low") { c in
                c.upsert(nowPlaying())
                c.open(.home(tab: "music"))
                c.showAlert(lowBattery(), duration: 60)
            },
            // Under the pointer, not pinned: no close button.
            Scene(name: "peek-music") { c in c.upsert(nowPlaying()); peek(c) },
            Scene(name: "peek-timer") { c in c.upsert(timer()); peek(c) },
            Scene(name: "drag-shelf") { c in c.upsert(nowPlaying()); c.setDragTargeted(true) },

            Scene(name: "floating-compact-nowplaying", floating: true) { c in c.upsert(nowPlaying()) },
            Scene(name: "floating-panel-music", floating: true, setup: panel("music") { c in c.upsert(nowPlaying()) }),
            Scene(name: "floating-card-battery-low", floating: true) { c in c.showAlert(lowBattery(), duration: 60) },
        ]
    }
}

/// A slice of a Mac desktop: the menu bar (with the physical cutout on a notched screen)
/// and a plain desktop below it, so the island is judged against what it actually sits on.
private struct GalleryBackdrop<Island: View>: View {
    let geometry: NotchGeometry
    var dark = false
    @ViewBuilder let island: () -> Island

    private var menuBarHeight: CGFloat { geometry.hasPhysicalNotch ? geometry.notchHeight : 24 }

    var body: some View {
        ZStack(alignment: .top) {
            dark ? Color(white: 0.08) : Color(red: 0.19, green: 0.36, blue: 0.62)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Color(white: dark ? 0.07 : 0.94)
                    HStack(spacing: 18) {
                        Image(systemName: "apple.logo")
                        Text("Finder").bold()
                        Text("File"); Text("Edit"); Text("View"); Text("Go"); Text("Window"); Text("Help")
                        Spacer()
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                        Text("Tue 8 Sep  4:32 PM")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: dark ? 0.88 : 0.12))
                    .padding(.horizontal, 16)
                    .frame(height: menuBarHeight)
                    if geometry.hasPhysicalNotch {
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: geometry.notchWidth, height: geometry.notchHeight)
                    }
                }
                .frame(height: menuBarHeight)
                Spacer(minLength: 0)
            }
            island()
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

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
        var setup: (ActivityCenter) -> Void
    }

    func testRenderGallery() throws {
        guard let dir = ProcessInfo.processInfo.environment["GALLERY_DIR"], !dir.isEmpty else {
            throw XCTSkip("GALLERY_DIR is not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let prefs = Preferences.shared
        prefs.hapticsEnabled = false
        prefs.weatherEnabled = true
        let center = ActivityCenter.shared
        let files = Self.sampleFiles(in: dir)

        var rendered: [String] = []
        for scene in Self.scenes(files: files) {
            center.resetForTesting()
            ShelfStore.shared.clear()
            scene.setup(center)
            let geometry = scene.floating ? Self.plain : Self.notch
            try write(render(geometry: geometry), name: scene.name, dir: dir)
            rendered.append(scene.name)
        }
        center.resetForTesting()
        ShelfStore.shared.clear()
        print("GALLERY rendered \(rendered.count) scenes: \(rendered.joined(separator: " "))")
        XCTAssertGreaterThan(rendered.count, 30)
    }

    // MARK: - Rendering

    private func render(geometry: NotchGeometry) -> CGImage? {
        let layout = IslandLayout.make(presentation: ActivityCenter.shared.presentation(for: "main"), geometry: geometry,
                                       center: .shared, clearance: .unlimited)
        let height = max(96, layout.bodyHeight + layout.topInset + 48)
        let content = GalleryBackdrop(geometry: geometry) {
            IslandRootView(geometry: geometry, panelID: "main")
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
                .environment(\.colorScheme, .dark)
        }
        .frame(width: 760, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.cgImage
    }

    private func write(_ image: CGImage?, name: String, dir: String) throws {
        guard let image else {
            XCTFail("nothing rendered for \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let folder = URL(fileURLWithPath: dir)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
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

    private static func nowPlaying() -> IslandActivity {
        var a = IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(track), priority: 50)
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

    private static func hud(_ kind: LevelHUD.Kind, _ level: Double) -> IslandActivity {
        IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: kind, level: level)), priority: 85)
    }

    private static func shelf(count: Int) -> IslandActivity {
        IslandActivity(id: "shelf", kind: .shelf, content: .shelf(ShelfState(count: count, latestName: "Screenshot 2026-09-08.png", latestIsImage: true)),
                       priority: 30)
    }

    // MARK: - Scenes

    private static func scenes(files: [URL]) -> [Scene] {
        func home(_ tab: String, _ extra: @escaping (ActivityCenter) -> Void = { _ in }) -> (ActivityCenter) -> Void {
            { c in extra(c); c.open(.home(tab: tab)) }
        }
        func expanded(_ activity: @escaping () -> IslandActivity) -> (ActivityCenter) -> Void {
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
            Scene(name: "compact-timer") { c in c.upsert(timer()) },
            Scene(name: "compact-timer-bubble-nowplaying") { c in c.upsert(nowPlaying()); c.upsert(timer()) },
            Scene(name: "compact-stopwatch") { c in c.upsert(stopwatch()) },
            Scene(name: "compact-call") { c in c.upsert(call()) },
            Scene(name: "compact-download") { c in c.upsert(download()) },
            Scene(name: "compact-calendar") { c in c.upsert(calendar()) },
            Scene(name: "compact-custom-delivery") { c in c.upsert(custom()) },
            Scene(name: "compact-shelf") { c in ShelfStore.shared.add(files); c.upsert(shelf(count: files.count)) },

            Scene(name: "alert-battery-charging") { c in c.showAlert(charging(), duration: 60) },
            Scene(name: "alert-battery-low") { c in c.showAlert(lowBattery(), duration: 60) },
            Scene(name: "alert-airpods") { c in c.showAlert(airPods(), duration: 60) },
            Scene(name: "alert-focus") { c in c.showAlert(focus(), duration: 60) },
            Scene(name: "alert-volume") { c in c.showAlert(hud(.volume, 0.6), duration: 60) },
            Scene(name: "alert-brightness") { c in c.showAlert(hud(.brightness, 0.4), duration: 60) },
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

            Scene(name: "expanded-nowplaying", setup: expanded(nowPlaying)),
            Scene(name: "expanded-timer", setup: expanded(timer)),
            Scene(name: "expanded-stopwatch", setup: expanded(stopwatch)),
            Scene(name: "expanded-call", setup: expanded(call)),
            Scene(name: "expanded-download", setup: expanded(download)),
            Scene(name: "expanded-calendar", setup: expanded(calendar)),
            Scene(name: "expanded-custom-delivery", setup: expanded(custom)),
            Scene(name: "expanded-battery", setup: expanded(charging)),
            Scene(name: "expanded-bluetooth", setup: expanded(airPods)),
            Scene(name: "expanded-focus", setup: expanded(focus)),
            Scene(name: "expanded-shelf") { c in
                ShelfStore.shared.add(files)
                c.upsert(shelf(count: files.count))
                c.open(.activity(id: "shelf"))
            },
            Scene(name: "strip-volume-over-expanded-nowplaying") { c in
                c.upsert(nowPlaying())
                c.open(.activity(id: "nowplaying"))
                c.showAlert(hud(.volume, 0.6), duration: 60)
            },

            Scene(name: "home-music", setup: home("music") { c in c.upsert(nowPlaying()) }),
            Scene(name: "home-music-empty", setup: home("music")),
            Scene(name: "home-shelf", setup: home("shelf") { _ in ShelfStore.shared.add(files) }),
            Scene(name: "home-clipboard", setup: home("clipboard")),
            Scene(name: "home-actions", setup: home("actions")),
            Scene(name: "home-stats", setup: home("stats")),
            Scene(name: "home-weather", setup: home("weather")),

            Scene(name: "floating-compact-nowplaying", floating: true) { c in c.upsert(nowPlaying()) },
            Scene(name: "floating-expanded-nowplaying", floating: true, setup: expanded(nowPlaying)),
            Scene(name: "floating-home-music", floating: true, setup: home("music") { c in c.upsert(nowPlaying()) }),
        ]
    }
}

/// A slice of a Mac desktop: the menu bar (with the physical cutout on a notched screen)
/// and a plain desktop below it, so the island is judged against what it actually sits on.
private struct GalleryBackdrop<Island: View>: View {
    let geometry: NotchGeometry
    @ViewBuilder let island: () -> Island

    private var menuBarHeight: CGFloat { geometry.hasPhysicalNotch ? geometry.notchHeight : 24 }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.19, green: 0.36, blue: 0.62)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Color(white: 0.94)
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
                    .foregroundStyle(Color(white: 0.12))
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
        .environment(\.colorScheme, .light)
    }
}

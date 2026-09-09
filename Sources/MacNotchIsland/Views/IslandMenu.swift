import AppKit
import SwiftUI

/// What a right-click on the island offers: the handful of things from the menu bar that are
/// worth having where the pointer already is.
///
/// Deliberately shorter than the status item's menu. That one is a whole menu bar's worth of
/// app — timers, the demo, diagnostics, About. This one is what somebody wants *of the island
/// they are looking at*: keep the Mac awake, clear the shelf, get it out of the way, open
/// Settings, quit.
struct IslandMenu: View {
    /// What the island is showing at this moment, if it is showing one thing. Its own
    /// commands come first: a right-click on a playing pill that cannot skip a track is a
    /// context menu with no context in it.
    var activity: IslandActivity?

    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var volumes = VolumeMonitor.shared

    var body: some View {
        if let activity, Self.hasCommands(activity.content) {
            commands(activity)
            Divider()
        }
        Button(keepAwake.isOn ? "Let the Mac Sleep" : "Keep Awake") { keepAwake.toggle() }
        if !shelf.items.isEmpty {
            Button("Clear Shelf") { ShelfStore.shared.clear() }
        }
        // Getting a drive out safely, at any moment rather than only while its card happens
        // to be up. One disk is a command; several are a list, because a submenu holding one
        // thing is a click somebody had to make for nothing.
        ejectable
        // And the other thing that is otherwise a trip to System Settings: putting a pair of
        // headphones back on. Built when the menu opens, since nothing else needs the list.
        bluetoothDevices
        Divider()
        // The same pair of states the menu bar shows, said the same way.
        if Self.isPaused(until: prefs.pausedUntil) {
            Button("Show the Island") { ActivityCenter.shared.pause(for: 0) }
        } else {
            Button("Hide the Island for an Hour") { ActivityCenter.shared.pause(for: 3600) }
        }
        Button("Settings…") { SettingsWindow.open() }
        Divider()
        Button("Quit Notch Island") { NSApp.terminate(nil) }
    }

    /// Whether this activity has anything of its own to offer. Kept beside `commands` so the
    /// separator above them is never drawn over nothing.
    static func hasCommands(_ content: ActivityContent) -> Bool {
        switch content {
        case .nowPlaying, .timer, .stopwatch, .shelf, .call, .drive: return true
        default: return false
        }
    }

    /// What this activity can be told to do, without opening the panel to say it.
    @ViewBuilder
    private func commands(_ activity: IslandActivity) -> some View {
        switch activity.content {
        case .nowPlaying(let info):
            Button(info.isPlaying ? "Pause" : "Play") { NowPlayingService.shared.togglePlayPause() }
            Button("Next Track") { NowPlayingService.shared.next() }
            Button("Previous Track") { NowPlayingService.shared.previous() }
        case .timer(let state):
            if state.isFinished {
                Button("Repeat") { IslandTimer.shared.repeatLast() }
            } else {
                Button(state.isPaused ? "Resume Timer" : "Pause Timer") {
                    state.isPaused ? IslandTimer.shared.resume(id: activity.id)
                                   : IslandTimer.shared.pause(id: activity.id)
                }
                Button("Add a Minute") { IslandTimer.shared.add(seconds: IslandTimer.addStep, id: activity.id) }
            }
            Button("Cancel Timer") { IslandTimer.shared.cancel(id: activity.id) }
        case .stopwatch(let state):
            if state.isRunning {
                Button("Lap") { IslandStopwatch.shared.lap() }
                Button("Stop") { IslandStopwatch.shared.stop() }
            } else {
                Button("Start") { IslandStopwatch.shared.start() }
            }
            Button("Reset Stopwatch") { IslandStopwatch.shared.reset() }
        case .shelf:
            Button("AirDrop the Shelf") { ShelfStore.shared.airDrop(ShelfStore.shared.urls) }
        case .call(let call):
            Button("Open \(call.appName)") { activity.openAction?.perform() }
        case .drive(let drive):
            Button("Open \(drive.name)") { activity.openAction?.perform() }
            // Only while there is still a disk to eject: after it has gone the card is a
            // receipt, not a control.
            if drive.isEjectable, drive.event != .ejected {
                Button("Eject \(drive.name)") { VolumeMonitor.shared.eject(drive) }
            }
        default:
            EmptyView()
        }
    }

    /// Everything this Mac is paired with, connected first. A click connects what is not and
    /// disconnects what is — the one thing the menu bar's own Bluetooth item takes three
    /// clicks and a submenu to do.
    @ViewBuilder
    private var bluetoothDevices: some View {
        let devices = BluetoothMonitor.paired()
        if !devices.isEmpty {
            Menu("Bluetooth") {
                ForEach(devices) { device in
                    Button(action: { BluetoothMonitor.setConnected(!device.isConnected, address: device.address) }) {
                        // A tick beside what is connected, the way every list of things on the
                        // Mac marks the ones that are on.
                        if device.isConnected {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        }
    }

    /// Eject, for whatever is attached. Nothing at all when nothing is.
    @ViewBuilder
    private var ejectable: some View {
        let disks = volumes.volumes.filter(\.isEjectable)
        if disks.count == 1, let disk = disks.first {
            Button("Eject \(disk.name)") { VolumeMonitor.shared.eject(disk) }
        } else if disks.count > 1 {
            Menu("Eject") {
                ForEach(disks, id: \.path) { disk in
                    Button(disk.name) { VolumeMonitor.shared.eject(disk) }
                }
                Divider()
                Button("Eject All") { disks.forEach { VolumeMonitor.shared.eject($0) } }
            }
        }
    }

    /// Whether the island is hidden by the clock rather than by an app in front. Pure, so the
    /// menu and the menu bar cannot disagree about which of the two words to show.
    static func isPaused(until: Double, now: Date = Date()) -> Bool {
        until > 0 && now.timeIntervalSince1970 < until
    }
}

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
    /// Whether the shelf has anything on it, which is all the menu asks of the shelf: the whole
    /// shelf publishes a thumbnail at a time as they are made, and each drew the menu again.
    @ObservedObject private var shelfHasFiles = NarrowReadings.shelfHasFiles
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var volumes = VolumeMonitor.shared
    @ObservedObject private var timers = IslandTimer.shared
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        if let activity, Self.hasCommands(activity.content) {
            commands(activity)
            Divider()
        }
        Button(keepAwake.isOn ? "Let the Mac Sleep" : "Keep Awake") { keepAwake.toggle() }
        // Beside Keep Awake, since an alarm rings only on a Mac that is awake.
        pendingAlarms
        if shelfHasFiles.value {
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
        // The microphone, which is otherwise a different button in every call app; a picture
        // or a movie of the screen; and the two ways to step away from the Mac — each a
        // keystroke macOS has always had and hardly anybody remembers.
        MicrophoneMenuItem()
        Button("Screenshot") { SystemActions.openScreenshotToolbar() }
        // While the movie is being finished the recording is still running and Stop has
        // already been pressed; a second Stop would do nothing, so the menu says what is
        // happening instead of offering it.
        if recorder.isSaving {
            Button("Saving Recording…") {}
                .disabled(true)
        } else {
            Button(recorder.isRecording ? "Stop Recording" : "Record Screen") { ScreenRecorder.shared.toggle() }
        }
        Button("Lock Screen") { SystemActions.lockScreen() }
        Button("Sleep Display") { SystemActions.sleepDisplay() }
        Divider()
        // The same pair of states the menu bar shows, in the menu bar's words. This menu used
        // to say "Hide the Island for an Hour" for the command the menu bar calls "Hide Island
        // for 1 Hour", while claiming to say it the same way. See `hideTitle`.
        if Self.isPaused(until: prefs.pausedUntil) {
            Button(Self.showTitle) { ActivityCenter.shared.pause(for: 0) }
        } else {
            Button(Self.hideTitle) { ActivityCenter.shared.pause(for: 3600) }
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
            sleepMenu
        case .timer(let state):
            if state.isAlarm {
                Button("Snooze") { IslandTimer.shared.snooze(id: activity.id) }
                Button("Stop Alarm") { IslandTimer.shared.cancel(id: activity.id) }
            } else {
                if state.isFinished {
                    // The timer that rang, not the last one started, see `repeatTimer(id:)`.
                    Button("Repeat") { IslandTimer.shared.repeatTimer(id: activity.id) }
                } else {
                    Button(state.isPaused ? "Resume Timer" : "Pause Timer") {
                        state.isPaused ? IslandTimer.shared.resume(id: activity.id)
                                       : IslandTimer.shared.pause(id: activity.id)
                    }
                    Button("Add a Minute") { IslandTimer.shared.add(seconds: IslandTimer.addStep, id: activity.id) }
                }
                Button("Cancel Timer") { IslandTimer.shared.cancel(id: activity.id) }
            }
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

    /// The alarms waiting to ring, each one a way to take it back. Nothing at all when there
    /// are none; one alarm is a command of its own rather than a submenu holding one thing.
    @ViewBuilder
    private var pendingAlarms: some View {
        let alarms = timers.alarms
        if alarms.count == 1, let alarm = alarms.first {
            Button("Cancel Alarm, \(alarm.menuTitle())") { IslandTimer.shared.cancelAlarm(id: alarm.id) }
        } else if alarms.count > 1 {
            Menu("Alarms") {
                ForEach(alarms) { alarm in
                    Button("Cancel \(alarm.menuTitle())") { IslandTimer.shared.cancelAlarm(id: alarm.id) }
                }
                Divider()
                Button("Cancel All Alarms") { IslandTimer.shared.cancelAllAlarms() }
            }
        }
    }

    /// The thing everybody sets a timer on a phone for at night, on the Mac at last: a
    /// countdown whose whole point is the silence at the end of it.
    @ViewBuilder
    private var sleepMenu: some View {
        if let sleeping = timers.sleepTimer {
            Button("Cancel Sleep Timer") { IslandTimer.shared.cancelSleep() }
                .help(sleeping.label)
        } else {
            Menu("Stop Playing In") {
                ForEach(Self.sleepChoices, id: \.self) { minutes in
                    Button(Self.sleepTitle(minutes)) {
                        IslandTimer.shared.startSleep(seconds: TimeInterval(minutes) * 60)
                    }
                }
            }
        }
    }

    /// The choices, in minutes. The ones a bedside timer offers.
    static let sleepChoices = [15, 30, 45, 60, 90]

    /// "15 Minutes", "1 Hour", "1 Hour 30 Minutes": menu items, so title case, the way the
    /// menu bar's timer presets are written (`StatusItemController.presetTitle`).
    static func sleepTitle(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) Minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = hours == 1 ? "1 Hour" : "\(hours) Hours"
        return rest == 0 ? hourText : "\(hourText) \(rest) Minutes"
    }

    /// Everything this Mac is paired with, connected first. A click connects what is not and
    /// disconnects what is — the one thing the menu bar's own Bluetooth item takes three
    /// clicks and a submenu to do.
    ///
    /// Read only once the tour is done, as Controls reads it (`ControlsSectionView`): reading
    /// the list is a Bluetooth question, and a right-click on a new Mac put macOS's Bluetooth
    /// sheet up ahead of the welcome tour. Before it the menu has no Bluetooth item at all.
    @ViewBuilder
    private var bluetoothDevices: some View {
        let devices: [BluetoothMonitor.Paired] = prefs.hasSeenWelcome ? BluetoothMonitor.paired() : []
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

    /// The two ways to put the island away and bring it back, in the words the status item's
    /// menu has always used for them. Kept here so the menu bar can say them from the same
    /// place (`StatusItemController.refreshDynamicItems` still spells them out).
    static let hideTitle = "Hide Island for 1 Hour"
    static let showTitle = "Show Island"

    /// Whether the island is hidden by the clock rather than by an app in front. Pure, so the
    /// menu and the menu bar cannot disagree about which of the two words to show.
    static func isPaused(until: Double, now: Date = Date()) -> Bool {
        until > 0 && now.timeIntervalSince1970 < until
    }
}

/// Mute or unmute the microphone, for every app at once. A view of its own so the microphone
/// is first asked about when the menu's items are built rather than whenever the island is
/// drawn: `MicrophoneControl` starts listening the first time anything asks.
private struct MicrophoneMenuItem: View {
    @ObservedObject private var mic = MicrophoneControl.shared

    var body: some View {
        Button(mic.isMuted ? "Unmute Microphone" : "Mute Microphone") { mic.toggle() }
            .disabled(!mic.isAvailable)
    }
}

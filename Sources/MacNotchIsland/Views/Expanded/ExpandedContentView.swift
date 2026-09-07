import SwiftUI

/// Routes an activity to its expanded (large) view.
struct ExpandedContentView: View {
    let activity: IslandActivity
    let layout: IslandLayout
    let geometry: NotchGeometry

    var body: some View {
        Group {
            switch activity.content {
            case .nowPlaying(let info):
                NowPlayingExpandedView(info: info, geometry: geometry)
            case .timer(let t):
                TimerExpandedView(state: t, geometry: geometry)
            case .call(let c):
                CallExpandedView(state: c, activity: activity, geometry: geometry)
            case .battery(let b):
                BatteryExpandedView(state: b, geometry: geometry)
            case .bluetooth(let d):
                BluetoothExpandedView(state: d, geometry: geometry)
            case .focus(let f):
                FocusExpandedView(state: f, geometry: geometry)
            case .hud(let h):
                HUDExpandedView(state: h, geometry: geometry)
            case .calendar(let c):
                CalendarExpandedView(state: c, geometry: geometry)
            case .custom(let c):
                CustomExpandedView(state: c, activity: activity, geometry: geometry)
            case .unlock, .silent:
                EmptyView()
            }
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
    }
}

/// Shared header spacing: content starts below the physical notch.
struct NotchClearance: View {
    let geometry: NotchGeometry
    var extra: CGFloat = 8
    var body: some View { Color.clear.frame(height: geometry.notchHeight + extra) }
}

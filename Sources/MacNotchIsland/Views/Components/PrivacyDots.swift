import SwiftUI

/// The orange (microphone) and green (camera) privacy indicators the iPhone shows inside the island.
struct PrivacyDots: View {
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        HStack(spacing: 4) {
            if center.micInUse {
                Circle().fill(Color(red: 1, green: 0.58, blue: 0)).frame(width: 7, height: 7)
            }
            if center.cameraInUse {
                Circle().fill(Color(red: 0.2, green: 0.84, blue: 0.29)).frame(width: 7, height: 7)
            }
        }
        .animation(IslandMotion.quick, value: center.micInUse)
        .animation(IslandMotion.quick, value: center.cameraInUse)
    }
}

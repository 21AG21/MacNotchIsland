import SwiftUI

/// One line of time-synced lyrics for the black island.
///
/// Renders nothing at all (zero height) when there is no line for the current moment, so a
/// track without lyrics, an instrumental break, or a paused-before-the-first-line state never
/// leaves an empty row behind. Callers that need a stable layout give it a fixed frame.
struct LyricsView: View {
    @ObservedObject private var lyrics = LyricsService.shared

    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white
    var lineHeight: CGFloat = 18

    private var line: String? {
        guard let line = lyrics.currentLine else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let line = line {
                Text(line)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .frame(height: lineHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(line)
                    .transition(.asymmetric(
                        insertion: .offset(y: 6).combined(with: .opacity),
                        removal: .offset(y: -6).combined(with: .opacity)
                    ))
            }
        }
        .clipped()
        .animation(IslandMotion.fade, value: line)
    }
}

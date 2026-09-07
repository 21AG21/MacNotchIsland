import SwiftUI

/// iOS-style battery outline with fill level and charging bolt.
struct BatteryGlyph: View {
    let percent: Int
    var charging: Bool = false
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let capW = w * 0.08
            let bodyW = w - capW - 1
            let inset: CGFloat = 2
            let fillW = max(0, (bodyW - inset * 2) * CGFloat(min(100, max(0, percent))) / 100)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.28, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 1.5)
                    .frame(width: bodyW, height: h)
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .fill(tint)
                    .frame(width: fillW, height: h - inset * 2)
                    .padding(.leading, inset)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint.opacity(0.5))
                    .frame(width: capW, height: h * 0.4)
                    .offset(x: bodyW + 1)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.85, weight: .black))
                        .foregroundStyle(Color.black)
                        .frame(width: bodyW, height: h)
                        .overlay(
                            Image(systemName: "bolt.fill")
                                .font(.system(size: h * 0.6, weight: .black))
                                .foregroundStyle(Color.white)
                        )
                }
            }
        }
    }
}

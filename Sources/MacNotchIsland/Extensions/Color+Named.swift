import SwiftUI

extension Color {
    /// The system colours by name (the same NSColor.system* values iOS and macOS use, so they
    /// track the panel's dark appearance and Increase Contrast), or a hex string ("#34C759").
    static func named(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return Color(nsColor: .systemRed)
        case "orange": return Color(nsColor: .systemOrange)
        case "yellow": return Color(nsColor: .systemYellow)
        case "green": return Color(nsColor: .systemGreen)
        case "mint": return Color(nsColor: .systemMint)
        case "teal": return Color(nsColor: .systemTeal)
        case "cyan": return Color(nsColor: .systemCyan)
        case "blue": return Color(nsColor: .systemBlue)
        case "indigo": return Color(nsColor: .systemIndigo)
        case "purple": return Color(nsColor: .systemPurple)
        case "pink": return Color(nsColor: .systemPink)
        case "brown": return Color(nsColor: .systemBrown)
        case "gray", "grey": return Color(nsColor: .systemGray)
        case "white", "": return .white
        default:
            if let c = Color(hex: name) { return c }
            return .white
        }
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "white" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

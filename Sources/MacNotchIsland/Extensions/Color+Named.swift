import SwiftUI

extension Color {
    /// iOS system colours by name, or a hex string ("#34C759" / "34C759").
    static func named(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return Color(red: 1, green: 0.27, blue: 0.23)
        case "orange": return .orange
        case "yellow": return Color(red: 1, green: 0.8, blue: 0)
        case "green": return Color(red: 0.2, green: 0.84, blue: 0.29)
        case "mint": return Color(red: 0, green: 0.78, blue: 0.75)
        case "teal": return Color(red: 0.19, green: 0.69, blue: 0.78)
        case "cyan": return Color(red: 0.2, green: 0.68, blue: 0.9)
        case "blue": return Color(red: 0.04, green: 0.52, blue: 1)
        case "indigo": return Color(red: 0.35, green: 0.34, blue: 0.84)
        case "purple": return Color(red: 0.69, green: 0.32, blue: 0.87)
        case "pink": return Color(red: 1, green: 0.22, blue: 0.37)
        case "brown": return Color(red: 0.64, green: 0.52, blue: 0.37)
        case "gray", "grey": return Color(white: 0.6)
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

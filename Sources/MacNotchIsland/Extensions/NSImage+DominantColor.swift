import AppKit

extension NSImage {
    /// A vivid colour representative of the artwork, brightened so it reads on black.
    /// Used to tint the audio visualizer like the iPhone does.
    func dominantColor() -> NSColor {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let w = 12, h = 12
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return .white }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var bestScore = -1.0
        var best = (r: 1.0, g: 1.0, b: 1.0)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        let n = Double(w * h)
        for i in 0..<(w * h) {
            let r = Double(p[i * 4]) / 255, g = Double(p[i * 4 + 1]) / 255, b = Double(p[i * 4 + 2]) / 255
            sum.r += r; sum.g += g; sum.b += b
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let score = sat * (1 - abs(lum - 0.55))
            if score > bestScore { bestScore = score; best = (r, g, b) }
        }
        let chosen = bestScore > 0.18
            ? NSColor(red: best.r, green: best.g, blue: best.b, alpha: 1)
            : NSColor(red: sum.r / n, green: sum.g / n, blue: sum.b / n, alpha: 1)

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        (chosen.usingColorSpace(.deviceRGB) ?? chosen).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        if sat < 0.12 { return NSColor(white: 0.95, alpha: 1) }
        return NSColor(hue: hue, saturation: min(sat, 0.8), brightness: max(bri, 0.8), alpha: 1)
    }
}

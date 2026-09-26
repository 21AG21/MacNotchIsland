import AppKit
import ImageIO

extension NSImage {
    /// A vivid colour representative of the artwork, brightened so it reads on black.
    /// Used to tint the audio visualizer like the iPhone does.
    ///
    /// Asking an image read from a file or from bytes for its `CGImage` decodes all of it, so
    /// this costs a full decode on such an image; a cover is decoded small with `cover(from:)`,
    /// which works its accent out from the small copy instead.
    func dominantColor() -> NSColor {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        return NSImage.dominantColor(of: cg)
    }

    /// The accent of a bitmap already in hand: it is drawn into twelve by twelve pixels and
    /// the most vivid of them is taken, or their average where none of them is vivid.
    static func dominantColor(of cg: CGImage) -> NSColor {
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

    /// The most pixels a cover is kept at along its short side.
    ///
    /// The largest cover the island draws is the Music section's, 60 pt, which is 120 pixels on
    /// a Retina display; the pill's and the Home tile's are smaller. Twice that is a clean
    /// halving at the largest and sharper than the screen can show anywhere. A player hands
    /// over its cover at whatever size it has — many hundreds of pixels, often more, and the
    /// search's are 600 — and the whole of it used to be decoded on the main thread, kept, and
    /// scaled down again on every frame it was drawn. The short side, because every cover is
    /// drawn filling a square: a wide one is cropped to its height, so its height is what has
    /// to be sharp, and capping its width at this left a 2:1 cover with 120 pixels of height
    /// for 120 pixels of box.
    static let coverPixels = 240

    /// The most pixels a cover of `width` by `height` is decoded to along its long side, so that
    /// its short side keeps `maxPixels` where the picture has them. Never more than four times
    /// that: a banner gives up a little of its height rather than be kept as a strip thousands
    /// of pixels long. Pure.
    static func coverLongSide(width: Int, height: Int, maxPixels: Int) -> Int {
        guard width > 0, height > 0 else { return maxPixels }
        let ratio = Double(max(width, height)) / Double(min(width, height))
        return min(maxPixels * 4, Int((Double(maxPixels) * ratio).rounded(.up)))
    }

    /// A player's cover from its encoded bytes, decoded no larger than `maxPixels` on its short
    /// side (`coverLongSide`), with its accent worked out from that copy (`dominantColor(of:)`).
    /// Nil when the bytes are not a picture.
    ///
    /// For a queue other than the main one: this is the whole decode, done at once
    /// (`kCGImageSourceShouldCacheImmediately`) so that nothing is left for the first frame
    /// that draws it. Bytes ImageIO cannot read are handed to `NSImage` as they always were.
    static func cover(from data: Data, maxPixels: Int = NSImage.coverPixels) -> (image: NSImage, accent: NSColor)? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            var longSide = maxPixels
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                longSide = coverLongSide(width: width, height: height, maxPixels: maxPixels)
            }
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: longSide,
            ] as CFDictionary) {
                return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), dominantColor(of: cg))
            }
        }
        guard let image = NSImage(data: data) else { return nil }
        return (image, image.dominantColor())
    }
}

import AppKit

// Measures how far the island's black starts below the top of a screenshot, in pixels, at the
// column given (default: the middle of the image, which is the notch). The island is fused to
// the top edge of the screen, so anything but 0 is a seam the user can see.
//
// usage: topgap <screenshot.png> [column fraction 0–1]

let args = CommandLine.arguments
guard args.count > 1, let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("topgap: cannot read \(args.count > 1 ? args[1] : "")\n".utf8))
    exit(2)
}
let fraction = args.count > 2 ? (Double(args[2]) ?? 0.5) : 0.5
let x = min(rep.pixelsWide - 1, max(0, Int(Double(rep.pixelsWide) * fraction)))

func isIslandBlack(_ y: Int) -> Bool {
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    // The island is pure black; the menu bar and every wallpaper the runner uses are lighter.
    return color.redComponent < 0.12 && color.greenComponent < 0.12 && color.blueComponent < 0.12
}

var gap = 0
while gap < rep.pixelsHigh, !isIslandBlack(gap) { gap += 1 }
// Nothing black at all in this column: report it as such rather than as a giant gap.
print(gap >= rep.pixelsHigh ? -1 : gap)

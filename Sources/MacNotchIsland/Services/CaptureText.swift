import AppKit
import Vision

/// The words in a picture.
///
/// macOS has read text out of images since Live Text arrived, and a screenshot is the one
/// image where that is nearly always what you wanted: a code somebody sent you, an error from
/// a machine you cannot copy from, a paragraph in a video call. The card offers it only when
/// there is something to offer, which means looking first — quietly, off the main thread, and
/// only for the capture that is on screen.
enum CaptureText {
    /// How much of a picture is read: enough for a full-screen grab, and bounded so a huge
    /// capture cannot tie up a core.
    static let maxPixel: CGFloat = 2400

    /// Reads `url` and calls back on the main queue with what was found, or nil where nothing
    /// could be read at all. An empty string means "looked, and there were no words".
    static func recognize(_ url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = recognizeSync(url)
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// The work itself. Separated so it can be called from a queue of somebody else's choosing.
    static func recognizeSync(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            IslandLog.island.error("could not read the capture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return joined(lines)
    }

    /// The lines as one piece of text, the way a person would paste it: in reading order, one
    /// line each, with nothing but whitespace dropped. Pure, so the shape can be tested.
    static func joined(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

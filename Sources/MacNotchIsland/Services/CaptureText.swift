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
    /// Everything one look at a picture found: the words in it, and the one thing a QR code in
    /// it points at.
    struct Reading: Equatable {
        var text = ""
        var link: URL?
    }

    /// How much of a picture is read: enough for a full-screen grab, and bounded so a huge
    /// capture cannot tie up a core.
    static let maxPixel: CGFloat = 2400

    /// Reads `url` and calls back on the main queue with what was found, or nil where nothing
    /// could be read at all. An empty reading means "looked, and there was nothing in it".
    static func recognize(_ url: URL, completion: @escaping (Reading?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = recognizeSync(url)
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// The work itself. Separated so it can be called from a queue of somebody else's choosing.
    /// Both questions are asked of the same decoded picture in one pass, because decoding it
    /// twice to ask them separately is the expensive half.
    static func recognizeSync(_ url: URL) -> Reading? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let words = VNRecognizeTextRequest()
        words.recognitionLevel = .accurate
        words.usesLanguageCorrection = true
        let codes = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([words, codes])
        } catch {
            IslandLog.island.error("could not read the capture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let lines = (words.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let payloads = (codes.results ?? []).compactMap { $0.payloadStringValue }
        return Reading(text: joined(lines), link: link(in: payloads))
    }

    /// The web address a QR code in the picture points at, if it points at one.
    ///
    /// Only `http` and `https`: a code in a screenshot is a stranger's, and the one thing the
    /// island will offer to do with it is the one thing a browser would do anyway. A `tel:`,
    /// a `mailto:` or a configuration profile is not something to hand a click to.
    ///
    /// Pure, so the rule can be tested.
    static func link(in payloads: [String]) -> URL? {
        for payload in payloads {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false else { continue }
            return url
        }
        return nil
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

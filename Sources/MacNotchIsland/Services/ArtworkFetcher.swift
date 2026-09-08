import AppKit

/// Cover art for tracks whose player will not hand any over.
///
/// The iPhone always has the artwork because the phone owns the music. On a Mac it depends
/// entirely on where the sound comes from: Music gives its own, Spotify gives a URL, and a
/// browser playing a set gives nothing at all — which is why the island so often showed a grey
/// music note where a cover belongs. When that happens the track is looked up by name in
/// Apple's public search API and the cover comes back from there, the same picture the phone
/// would show.
///
/// One lookup per track, cached; a track that has no match is remembered as a miss so it is
/// never asked about twice. Nothing but the title, artist and album is ever sent, and only when
/// the player itself supplied no artwork.
final class ArtworkFetcher {
    static let shared = ArtworkFetcher()

    struct Key: Hashable {
        var title: String
        var artist: String
        var album: String

        init(_ info: NowPlayingInfo) {
            title = info.title.lowercased()
            artist = info.artist.lowercased()
            album = info.album.lowercased()
        }

        /// What to search for: the artist and the title, or the album when there is no title.
        var terms: String {
            [artist, title.isEmpty ? album : title]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Covers held in memory. Small: a cover is a few hundred kilobytes and the list is capped.
    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []
    private var misses: Set<Key> = []
    private var inFlight: Set<Key> = []
    private let session: URLSession

    static let cacheLimit = 40
    /// Covers come back at this many points square: enough for the 60 pt panel cover on a
    /// Retina display, and for the blurred backdrop behind it.
    static let size = 600

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Cover art for a track, if one can be found. The completion runs on the main queue, and
    /// only when there is something to show.
    func artwork(for info: NowPlayingInfo, completion: @escaping (NSImage) -> Void) {
        let key = Key(info)
        guard !key.terms.isEmpty else { return }
        if let image = cache[key] { return completion(image) }
        guard !misses.contains(key), !inFlight.contains(key), let url = Self.searchURL(for: key) else { return }
        inFlight.insert(key)
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let artworkURL = Self.artworkURL(fromSearch: data) else {
                self.finish(key, image: nil, completion: completion)
                return
            }
            self.session.dataTask(with: artworkURL) { [weak self] data, _, _ in
                self?.finish(key, image: data.flatMap { NSImage(data: $0) }, completion: completion)
            }.resume()
        }.resume()
    }

    private func finish(_ key: Key, image: NSImage?, completion: @escaping (NSImage) -> Void) {
        DispatchQueue.main.async {
            self.inFlight.remove(key)
            guard let image, image.size.width > 1 else {
                self.misses.insert(key)
                return
            }
            self.cache[key] = image
            self.order.append(key)
            while self.order.count > Self.cacheLimit, let oldest = self.order.first {
                self.order.removeFirst()
                self.cache.removeValue(forKey: oldest)
            }
            completion(image)
        }
    }

    /// The search that would find this track. Nil when there is nothing worth searching for.
    static func searchURL(for key: Key) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: key.terms),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components?.url
    }

    /// The cover's address inside a search response, asked for at `size` points rather than the
    /// thumbnail the API returns by default.
    static func artworkURL(fromSearch data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first,
              let raw = first["artworkUrl100"] as? String else { return nil }
        let sized = raw.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")
        return URL(string: sized)
    }
}

import AppKit
import Combine
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files dropped on the notch. Persists paths across launches and caches thumbnails.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [URL] = []
    @Published private var thumbnails: [URL: NSImage] = [:]

    private let key = "shelfItems"
    private let maxItems = 24

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        items.forEach(generateThumbnail)
    }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls where url.isFileURL {
            if let i = items.firstIndex(of: url) { items.remove(at: i) }
            items.insert(url, at: 0)
            generateThumbnail(url)
            changed = true
        }
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        if changed {
            persist()
            Haptics.tap()
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        thumbnails[url] = nil
        persist()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        persist()
    }

    func thumbnail(for url: URL) -> NSImage? { thumbnails[url] }

    /// SwiftUI `.onDrop` handler.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                else if let s = item as? String { url = URL(string: s) }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(urls)
            ActivityCenter.shared.setDragTargeted(false)
        }
        return true
    }

    private func persist() {
        UserDefaults.standard.set(items.map { $0.path }, forKey: key)
    }

    private func generateThumbnail(_ url: URL) {
        guard thumbnails[url] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async { self?.thumbnails[url] = rep.nsImage }
        }
    }
}

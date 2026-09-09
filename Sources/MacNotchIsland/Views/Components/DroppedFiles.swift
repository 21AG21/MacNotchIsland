import Foundation
import UniformTypeIdentifiers

/// The files a drop carried, in the order they were dragged.
///
/// Shared by the two places on the island where a drop means something other than "put it on
/// the shelf": a quick action runs its shortcut with them, and a window tile opens them with
/// that window's app. A provider that answers with nothing is left out rather than dropping a
/// hole into the middle of the list.
enum DroppedFiles {
    static func paths(from providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        var found = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = ShelfStore.fileURL(from: item)
                lock.lock(); found[index] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(found.compactMap { $0?.path }) }
    }
}

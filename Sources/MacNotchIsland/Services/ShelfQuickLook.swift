import AppKit
import QuickLookUI

/// Quick Look for shelf items: the system's own preview window, with the shelf's selection
/// as its pages, so a file can be checked without opening the app that made it.
///
/// The panel is driven directly rather than through the responder chain: the island is a
/// background panel that is deliberately never the key window, so there is no responder for
/// Quick Look to ask. Taking the panel over ourselves is what makes it work from here.
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()

    private var urls: [URL] = []

    private override init() { super.init() }

    /// Shows `urls`, starting at `index`. Does nothing when there is nothing to preview.
    func show(_ urls: [URL], startingAt index: Int = 0) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = files
        // Quick Look opens a window of its own; the app has to come forward for it, and the
        // island must not close behind it.
        ActivityCenter.shared.holdOpen(for: 30)
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), files.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

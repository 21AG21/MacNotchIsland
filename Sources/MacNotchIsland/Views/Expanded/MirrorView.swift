import AppKit
import AVFoundation
import SwiftUI

/// The Home panel's "Mirror" tab: a live, mirrored view of the built-in camera so you can
/// check your hair before the call starts. The camera only runs while this is on screen.
struct MirrorView: View {
    @ObservedObject private var camera = CameraPreview.shared

    var body: some View {
        ZStack {
            CameraPreviewLayerView(previewLayer: camera.previewLayer)
                .opacity(camera.state == .running ? 1 : 0)
                .animation(IslandMotion.quick, value: camera.state)
            overlay
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch camera.state {
        case .idle, .running:
            EmptyView()
        case .starting:
            Text("Starting camera…")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        case .denied:
            VStack(spacing: 8) {
                Text("Camera access is off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                PillButton(title: "Open Settings", symbol: "gearshape.fill") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .unavailable:
            VStack(spacing: 6) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                Text("No camera")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Hosts the shared `AVCaptureVideoPreviewLayer` in a layer-backed AppKit view, because
/// SwiftUI has no way to show a CALayer on its own.
private struct CameraPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.attach(previewLayer)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewHostView, context: Context) {
        nsView.attach(previewLayer)
    }
}

/// Rounded, clipped container that keeps the preview layer pinned to its bounds.
final class CameraPreviewHostView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func attach(_ preview: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== preview else { return }
        previewLayer?.removeFromSuperlayer()
        // The layer is shared, so it may still be sitting in a view that is on its way out.
        preview.removeFromSuperlayer()
        previewLayer = preview
        layer?.addSublayer(preview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let preview = previewLayer else { return }
        // Resizing a preview layer through an implicit animation looks like a rubber band.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        if let scale = window?.backingScaleFactor { preview.contentsScale = scale }
        CATransaction.commit()
    }
}

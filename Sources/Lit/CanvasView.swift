import SwiftUI
import UniformTypeIdentifiers
import LitCore

/// The photo, fitted to the available space (or zoomed), with the tool overlays on top.
/// Zoom: pinch, Z, ⌘+ / ⌘− / ⌘0 / ⌘1, or double-click in the Edit tool.
/// Pan when zoomed: drag (Edit tool), space-drag (any tool), or scroll.
struct CanvasView: View {
    @Bindable var model: EditorModel
    @State private var isDropTargeted = false
    @State private var pinchStart: CGFloat?
    @State private var panLast: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                model.background.color
                if let cg = model.preview, let rect = model.imageRect(in: geo.size) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(model.zoom > 1.01 ? .medium : .high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    detailLayer(rect)
                    if model.tool == .crop {
                        if model.previewRegion == CGRect(x: 0, y: 0, width: 1, height: 1) {
                            CropOverlay(model: model, rect: rect)
                        }
                    } else if model.tool == .dust {
                        if !model.showOriginal { DustOverlay(model: model, rect: rect) }
                    } else if !model.showOriginal {
                        GradientOverlay(model: model, rect: rect)
                    }
                    if model.tool == .edit || (model.spaceHeld && model.zoom > 1.01) { panLayer }
                } else if let ph = model.placeholder {
                    let rect = fit(CGSize(width: ph.width, height: ph.height), in: geo.size)
                    Image(decorative: ph, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else if model.source != nil || model.loadingURL != nil {
                    ProgressView().controlSize(.small)
                } else {
                    EmptyStateView(model: model)
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(12)
                }
            }
            .clipped()
            .onAppear { report(geo) }
            .onChange(of: geo.size) { _, _ in report(geo) }
            .onContinuousHover { phase in
                if case .active(let p) = phase { model.mouseInCanvas = p } else { model.mouseInCanvas = nil }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        if pinchStart == nil { pinchStart = model.zoom }
                        model.setZoom((pinchStart ?? 1) * g.magnification, anchor: g.startLocation)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadURLs(providers) { model.handle(urls: $0) }
            return true
        }
    }

    private func fit(_ image: CGSize, in view: CGSize) -> CGRect {
        let pad: CGFloat = 28
        let s = min((view.width - pad * 2) / image.width, (view.height - pad * 2) / image.height)
        let size = CGSize(width: image.width * s, height: image.height * s)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func report(_ geo: GeometryProxy) {
        model.canvasSize = geo.size
        model.canvasFrameInWindow = geo.frame(in: .global)
    }

    /// The sharp render of the visible area, when zoomed past the preview's resolution.
    @ViewBuilder private func detailLayer(_ rect: CGRect) -> some View {
        if let d = model.detail, model.zoom > 1.01, d.adjustments == model.displayedAdjustments {
            let r = model.previewRegion
            let x = rect.minX + (d.region.minX - r.minX) / r.width * rect.width
            let y = rect.minY + (d.region.minY - r.minY) / r.height * rect.height
            let w = d.region.width / r.width * rect.width
            let h = d.region.height / r.height * rect.height
            Image(decorative: d.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: w, height: h)
                .position(x: x + w / 2, y: y + h / 2)
                .allowsHitTesting(false)
        }
    }

    /// Drag to pan; in the Edit tool, double-click toggles fit / 100%.
    private var panLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let last = panLast ?? .zero
                        model.pan(by: CGSize(width: g.translation.width - last.width,
                                             height: g.translation.height - last.height))
                        panLast = g.translation
                        NSCursor.closedHand.set()
                    }
                    .onEnded { _ in panLast = nil; NSCursor.openHand.set() }
            )
            .onTapGesture(count: 2) { p in
                if model.tool == .edit { model.mouseInCanvas = p; model.toggleZoom() }
            }
            .onHover { h in (h && model.zoom > 1.01 ? NSCursor.openHand : NSCursor.arrow).set() }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

struct EmptyStateView: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 14) {
            Brand.wordmark(height: 64)
            Text(Brand.tagline).font(.system(size: 14)).foregroundStyle(Theme.text.opacity(0.85))
                .padding(.top, 6)
            Text("Drop a photo here, or several to build a panorama.\nSony ARW and other RAW files, JPEG, HEIC, TIFF.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .padding(.top, 10)
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LitCore

enum Tool { case edit, gradient, crop, dust }

/// What's behind the photo: jet black (default) or pure white.
enum CanvasBackground: String {
    case black, white

    var color: Color { self == .black ? .black : .white }
    var next: CanvasBackground { self == .black ? .white : .black }
}

@MainActor
@Observable
final class EditorModel {
    static let shared = EditorModel()

    // Photo + edits
    private(set) var source: PhotoSource?
    var adjustments = Adjustments() {
        didSet { if adjustments != oldValue { adjustmentsDidChange() } }
    }

    // Display
    private(set) var preview: CGImage?
    /// Shown instantly while a photo loads: the camera's embedded preview, or a quick decode.
    private(set) var placeholder: CGImage?
    /// The file being opened (nil once it's shown).
    private(set) var loadingURL: URL?
    /// The part of the image `preview` shows, normalized (top-left origin).
    private(set) var previewRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var histogram: [[UInt]] = []
    /// Gentle notes about exposure, from the histogram (experimental).
    private(set) var insights: [Insight] = []
    var showOriginal = false { didSet { scheduleRender() } }
    var showMaskOverlay = false
    /// Clipping warning: paint pure-white areas red / pure-black areas blue.
    var clipHighlights = false { didSet { scheduleRender() } }
    var clipShadows = false { didSet { scheduleRender() } }
    /// Whether the current preview has any clipped highlights / shadows (lights the histogram triangles).
    private(set) var hasClippedHighlights = false
    private(set) var hasClippedShadows = false
    var background = CanvasBackground(rawValue: UserDefaults.standard.string(forKey: "canvasBackground") ?? "") ?? .black {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: "canvasBackground") }
    }

    // Zoom: 1 = whole photo fits the canvas. `zoomCenter` is the point (normalized within
    // the shown region) at the centre of the canvas.
    private(set) var zoom: CGFloat = 1
    private(set) var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// A sharper render of the visible area when zoomed in past the preview's resolution.
    private(set) var detail: (image: CGImage, region: CGRect, adjustments: Adjustments)?
    /// Canvas size and its frame in window coordinates (top-left origin); set by CanvasView.
    var canvasSize: CGSize = .zero { didSet { if canvasSize != oldValue { scheduleDetail() } } }
    @ObservationIgnored var canvasFrameInWindow: CGRect = .zero
    @ObservationIgnored var mouseInCanvas: CGPoint?
    /// Space bar held: drag pans in any tool.
    var spaceHeld = false

    // Tools
    var tool: Tool = .edit {
        didSet {
            if tool != .gradient { selectedMaskID = nil }
            if tool != .dust { selectedSpotID = nil; if showDustView { showDustView = false } }
            // The crop tool shows the whole frame; everything else shows the crop.
            if (tool == .crop) != (oldValue == .crop) { zoomToFit(); scheduleRender() }
        }
    }
    var selectedMaskID: UUID?

    // Dust Speck tool
    var selectedSpotID: UUID?
    /// Brush radius for new specks, as a fraction of the image width.
    var dustBrush = 0.003
    /// High-contrast "find dust" view.
    var showDustView = false { didSet { scheduleRender() } }
    var dustSensitivity = 0.5 { didSet { if showDustView { scheduleRender() } } }

    // Sheets / status
    var showExportSheet = false
    var exportOptions = ExportOptions()
    var panoramaURLs: [URL] = []
    var showPanoramaSheet = false
    /// Shown in the panorama sheet when RAW originals will be used instead of the chosen files.
    private(set) var panoramaInputNote: String?
    /// Live preview in the panorama sheet.
    private(set) var panoramaPreview: CGImage?
    private(set) var panoramaPreviewSize: CGSize?
    private(set) var panoramaPreviewError: String?
    private(set) var panoramaPreviewBusy = false
    private(set) var busyMessage: String?
    private(set) var busyProgress: Double?
    var errorMessage: String?
    private(set) var toast: String?

    @ObservationIgnored private let renderer = Renderer()
    @ObservationIgnored private let renderQueue = DispatchQueue(label: "lit.preview", qos: .userInteractive)
    @ObservationIgnored private var isRendering = false
    @ObservationIgnored private var needsRender = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Adjustments of the last export of an in-memory panorama (nil = never exported).
    @ObservationIgnored private var exportedPanorama: Adjustments?
    @ObservationIgnored private var detailWork: DispatchWorkItem?
    @ObservationIgnored private var openGeneration = 0
    /// Alignment reused between previews and the merge, keyed by files + rows + projection family.
    @ObservationIgnored private var panoramaPlan: (key: String, plan: PanoramaStitcher.PanoramaPlan, sources: [PhotoSource])?
    @ObservationIgnored private var panoramaPreviewGeneration = 0
    @ObservationIgnored private lazy var stitcher = PanoramaStitcher(renderer: renderer)
    @ObservationIgnored private let panoramaQueue = DispatchQueue(label: "lit.panorama", qos: .userInitiated)
    /// The crop rectangle when a straighten drag began (the angle shrinks a copy of it).
    @ObservationIgnored private var straightenBase: CGRect?
    @ObservationIgnored private let loadQueue = DispatchQueue(label: "lit.load", qos: .userInitiated)
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var undoStack: [Adjustments] = []
    @ObservationIgnored private var redoStack: [Adjustments] = []
    /// New gradients start with the last-used local settings, like Camera Raw.
    @ObservationIgnored private var lastLocal: LocalAdjustments = {
        var l = LocalAdjustments(); l.exposure = -0.5; return l
    }()

    nonisolated static let previewLongEdge: CGFloat = 2560

    // MARK: Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .jpeg, .tiff, .heic, .png]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Opens a photo without blocking: a quick placeholder appears at once, the photo is
    /// decoded in the background, then the real preview replaces the placeholder.
    func open(_ url: URL) {
        guard confirmLeavingPanorama() else { return }
        flushSave()
        openGeneration += 1
        let gen = openGeneration
        loadingURL = url
        placeholder = nil
        loadQueue.async {
            let quick = Self.quickPreview(url)
            DispatchQueue.main.async {
                if gen == self.openGeneration, self.loadingURL == url { self.placeholder = quick }
            }
            let result = Result { try PhotoSource(url: url) }
            let saved = Sidecar.load(for: url)
            DispatchQueue.main.async {
                guard gen == self.openGeneration else { return }
                switch result {
                case .success(let src):
                    self.present(src, adjustments: saved ?? src.defaultAdjustments)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                case .failure(let e):
                    self.loadingURL = nil
                    self.placeholder = nil
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    /// The camera's embedded JPEG (RAW) or a fast small decode — typically 20–40 ms.
    nonisolated static func quickPreview(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Compiles GPU kernels in the background at launch.
    func warmUp() {
        let renderer = renderer
        renderQueue.async { renderer.warmUp() }
    }

    private func present(_ src: PhotoSource, adjustments adj: Adjustments) {
        openGeneration += 1
        loadingURL = nil
        source = src
        preview = nil
        histogram = []
        undoStack.removeAll()
        redoStack.removeAll()
        selectedMaskID = nil
        tool = .edit
        showOriginal = false
        exportedPanorama = nil
        zoom = 1
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        detail = nil
        insights = []
        adjustments = adj
        scheduleRender()
    }

    /// Dropped / opened-with files: one opens, several go to the panorama sheet.
    func handle(urls: [URL]) {
        let supported = urls.filter { PhotoSource.supportedExtensions.contains($0.pathExtension.lowercased()) }
        if supported.count == 1 { open(supported[0]) }
        else if supported.count > 1 { startPanorama(with: supported) }
    }

    /// A merged panorama lives only in memory until it's exported.
    var panoramaNeedsExport: Bool {
        source?.isInMemory == true && exportedPanorama != adjustments
    }

    /// Asks before discarding an unexported panorama. Returns true if it's OK to continue.
    func confirmLeavingPanorama() -> Bool {
        guard panoramaNeedsExport else { return true }
        let alert = NSAlert()
        alert.messageText = "Export the panorama first?"
        alert.informativeText = exportedPanorama == nil
            ? "This panorama hasn't been saved yet. It only exists in LIT until you export it."
            : "Your latest changes to this panorama haven't been exported."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.buttons[2].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: showExportSheet = true; return false
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    var fileName: String { loadingURL?.lastPathComponent ?? source?.fileName ?? "" }

    // MARK: Rendering

    func scheduleRender() {
        needsRender = true
        if !isRendering { renderNext() }
    }

    private func renderNext() {
        guard needsRender, let src = source else { return }
        needsRender = false
        isRendering = true
        let adj = displayedAdjustments
        let renderer = renderer, cropped = tool != .crop, clip = (clipHighlights, clipShadows)
        let dust = showDustView ? dustSensitivity : nil
        renderQueue.async { [weak self] in
            let result = renderer.preview(src, adj, longEdge: EditorModel.previewLongEdge, cropped: cropped,
                                          clipping: clip, dustView: dust)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRendering = false
                if let result, src === self.source {
                    if self.preview == nil {
                        // First real preview: drop the placeholder and decode the full image
                        // in the background so zoom and export are ready when needed.
                        self.placeholder = nil
                        DispatchQueue.global(qos: .utility).async { src.prefetchFullResolution() }
                    }
                    self.preview = result.image
                    let pixels = result.image.width * result.image.height
                    self.insights = Insight.from(histogram: result.histogram, pixels: pixels)
                    let h = result.histogram
                    if h.count == 3 {
                        let limit = UInt(max(1, pixels / 5000))   // 0.02 % of the photo
                        self.hasClippedHighlights = h.contains { $0[255] > limit }
                        self.hasClippedShadows = (0..<3).map { h[$0][0] }.min()! > limit
                    }
                    self.previewRegion = cropped ? (adj.crop.flatMap { $0.isFullFrame ? nil : $0.rect }
                                                    ?? CGRect(x: 0, y: 0, width: 1, height: 1))
                                                 : CGRect(x: 0, y: 0, width: 1, height: 1)
                    self.histogram = result.histogram
                }
                self.scheduleDetail()
                self.renderNext()
            }
        }
    }

    /// What's on screen: the edits, or the original (keeping the crop) for before/after.
    var displayedAdjustments: Adjustments {
        guard showOriginal, let src = source else { return adjustments }
        var adj = src.defaultAdjustments
        adj.crop = adjustments.crop
        return adj
    }

    private func adjustmentsDidChange() {
        scheduleRender()
        guard let src = source, !src.isInMemory else { return }
        let url = src.url
        saveWork?.cancel()
        let adj = adjustments
        let work = DispatchWorkItem { Sidecar.save(adj, for: url) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushSave() {
        guard let work = saveWork, !work.isCancelled, let url = source?.url else { return }
        work.cancel()
        Sidecar.save(adjustments, for: url)
    }

    // MARK: Undo

    /// Call before a user change begins (slider grab, mask drag…).
    func checkpoint() {
        if undoStack.last != adjustments { undoStack.append(adjustments) }
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(adjustments)
        adjustments = prev
        validateSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(adjustments)
        adjustments = next
        validateSelection()
    }

    func resetAll() {
        guard let src = source else { return }
        checkpoint()
        adjustments = src.defaultAdjustments
        selectedMaskID = nil
    }

    // MARK: Bindings

    func binding(_ kp: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { self.adjustments[keyPath: kp] }, set: { self.adjustments[keyPath: kp] = $0 })
    }

    /// RAW: Kelvin with an As Shot default. Bitmaps: relative -100…100.
    var temperatureBinding: Binding<Double> {
        Binding(get: { self.adjustments.temperature ?? self.asShotTemperature },
                set: { self.adjustments.temperature = $0 })
    }
    func colorBinding(_ kp: WritableKeyPath<ColorMix, [Double]>, _ band: ColorBand) -> Binding<Double> {
        Binding(get: { self.adjustments.color[keyPath: kp][band.rawValue] },
                set: { self.adjustments.color[keyPath: kp][band.rawValue] = $0 })
    }

    var asShotTemperature: Double { source?.isRAW == true ? source!.asShotTemperature : 0 }
    var isRAW: Bool { source?.isRAW ?? false }

    // MARK: Masks

    var selectedMask: GradientMask? {
        adjustments.gradients.first { $0.id == selectedMaskID }
    }

    func addGradient(start: CGPoint, end: CGPoint) -> UUID {
        checkpoint()
        let mask = GradientMask(start: start, end: end, local: lastLocal)
        adjustments.gradients.append(mask)
        selectedMaskID = mask.id
        return mask.id
    }

    func updateMask(_ id: UUID, _ change: (inout GradientMask) -> Void) {
        guard let i = adjustments.gradients.firstIndex(where: { $0.id == id }) else { return }
        change(&adjustments.gradients[i])
        if id == selectedMaskID { lastLocal = adjustments.gradients[i].local }
    }

    func deleteMask(_ id: UUID) {
        checkpoint()
        adjustments.gradients.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil }
    }

    func localBinding(_ kp: WritableKeyPath<LocalAdjustments, Double>) -> Binding<Double> {
        Binding(
            get: { self.selectedMask?.local[keyPath: kp] ?? 0 },
            set: { v in
                guard let id = self.selectedMaskID else { return }
                self.updateMask(id) { $0.local[keyPath: kp] = v }
            })
    }

    private func validateSelection() {
        if let id = selectedMaskID, !adjustments.gradients.contains(where: { $0.id == id }) {
            selectedMaskID = nil
        }
    }

    // MARK: Export

    func export() {
        guard let src = source else { return }
        showExportSheet = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.directoryURL = src.url.deletingLastPathComponent()
        panel.nameFieldStringValue = src.url.deletingPathExtension().lastPathComponent + ".jpg"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let adj = adjustments, options = exportOptions, renderer = renderer
        setBusy("Exporting \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try renderer.exportJPEG(src, adj, to: url, options: options) }
            DispatchQueue.main.async {
                self.setBusy(nil)
                switch result {
                case .success:
                    if src === self.source, src.isInMemory { self.exportedPanorama = adj }
                    self.flash("Exported \(url.lastPathComponent)")
                case .failure(let e): self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    // MARK: Panorama

    func choosePanoramaFrames() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .jpeg, .tiff, .heic, .png]
        panel.allowsMultipleSelection = true
        panel.message = "Select 2–9 overlapping photos"
        if panel.runModal() == .OK { startPanorama(with: panel.urls) }
    }

    func startPanorama(with urls: [URL]) {
        guard urls.count >= 2 else { errorMessage = "Select at least 2 photos for a panorama."; return }
        guard urls.count <= 9 else { errorMessage = "Select at most 9 photos for a panorama."; return }
        panoramaURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let best = PanoramaStitcher.bestInputs(for: panoramaURLs)
        panoramaInputNote = best != panoramaURLs
            ? "Merging from the RAW originals (\(best[0].pathExtension.uppercased())) for the best quality."
            : nil
        showPanoramaSheet = true
    }

    /// Merges at full precision from the best available files and opens the result for
    /// editing. Nothing is written until the user exports.
    func mergePanorama(_ urls: [URL], options: PanoramaOptions) {
        showPanoramaSheet = false
        guard confirmLeavingPanorama() else { return }
        flushSave()
        setBusy("Preparing panorama…", progress: 0)
        panoramaPreviewGeneration += 1
        let key = Self.panoramaKey(urls, options)
        let cached = panoramaPlan?.key == key ? panoramaPlan : nil
        let stitcher = stitcher
        panoramaQueue.async {
            let result = Result { () throws -> PhotoSource in
                let sources: [PhotoSource]
                let pano: CIImage
                if let cached {
                    // Already aligned for the preview: go straight to the full-resolution blend.
                    sources = cached.sources
                    DispatchQueue.main.async { self.setBusy("Blending…", progress: 0.5) }
                    pano = try stitcher.compose(cached.plan, options: options, preview: false)
                } else {
                    sources = try PanoramaStitcher.bestInputs(for: urls).map { try PhotoSource(url: $0) }
                    pano = try stitcher.stitch(sources, options: options) { p, msg in
                        DispatchQueue.main.async { self.setBusy(msg + "…", progress: p) }
                    }
                }
                DispatchQueue.main.async { self.setBusy("Rendering full-resolution panorama…", progress: 0.6) }
                let merged = try stitcher.renderInMemory(pano)
                let first = urls[0]
                let name = first.deletingPathExtension().lastPathComponent + "-Pano.jpg"
                return PhotoSource(image: merged, url: first.deletingLastPathComponent().appendingPathComponent(name),
                                   metadata: sources[0].metadata)
            }
            DispatchQueue.main.async {
                self.setBusy(nil)
                switch result {
                case .success(let src):
                    self.panoramaPlan = nil
                    self.clearPanoramaPreview()
                    self.present(src, adjustments: src.defaultAdjustments)
                    self.flash("Panorama ready. Export (⌘E) to save it.")
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    static func panoramaKey(_ urls: [URL], _ o: PanoramaOptions) -> String {
        urls.map(\.path).joined(separator: "|") + "#\(o.rows)#\(o.projection == .flat)"
    }

    /// Updates the merge sheet's preview: aligns once (in the background), then composes a
    /// quick low-resolution panorama for the chosen projection and crop.
    func updatePanoramaPreview(_ urls: [URL], options: PanoramaOptions) {
        panoramaPreviewGeneration += 1
        let gen = panoramaPreviewGeneration
        let key = Self.panoramaKey(urls, options)
        let cached = panoramaPlan?.key == key ? panoramaPlan : nil
        panoramaPreviewBusy = true
        panoramaPreviewError = nil
        if cached == nil { panoramaPreview = nil }
        let stitcher = stitcher
        panoramaQueue.async {
            let result = Result { () throws -> (CGImage?, CGSize, (String, PanoramaStitcher.PanoramaPlan, [PhotoSource])) in
                let entry: (String, PanoramaStitcher.PanoramaPlan, [PhotoSource])
                if let cached {
                    entry = (cached.key, cached.plan, cached.sources)
                } else {
                    let sources = try PanoramaStitcher.bestInputs(for: urls).map { try PhotoSource(url: $0) }
                    entry = (key, try stitcher.plan(sources, options: options), sources)
                }
                let pano = try stitcher.compose(entry.1, options: options, preview: true)
                return (stitcher.previewImage(pano, maxWidth: 1400), entry.1.fullSize(ofPreview: pano.extent.size), entry)
            }
            DispatchQueue.main.async {
                guard gen == self.panoramaPreviewGeneration else { return }
                self.panoramaPreviewBusy = false
                switch result {
                case .success(let (image, size, entry)):
                    self.panoramaPlan = (entry.0, entry.1, entry.2)
                    self.panoramaPreview = image
                    self.panoramaPreviewSize = size
                case .failure(let e):
                    self.panoramaPreview = nil
                    self.panoramaPreviewSize = nil
                    self.panoramaPreviewError = e.localizedDescription
                }
            }
        }
    }

    /// Drops the cached alignment (sheet closed without merging).
    func clearPanoramaPreview() {
        panoramaPreviewGeneration += 1
        panoramaPreview = nil
        panoramaPreviewSize = nil
        panoramaPreviewError = nil
        panoramaPreviewBusy = false
    }

    // MARK: Zoom

    /// Where the photo sits in the canvas at the current zoom (may extend past the edges).
    func imageRect(in view: CGSize, zoom: CGFloat? = nil) -> CGRect? {
        let zoom = zoom ?? self.zoom
        guard let src = source, view.width > 0, view.height > 0 else { return nil }
        let full = src.fullSize, r = previewRegion
        let aspect = (full.width * r.width) / max(full.height * r.height, 1)
        let pad: CGFloat = 28
        let avail = CGSize(width: max(view.width - pad * 2, 10), height: max(view.height - pad * 2, 10))
        let fitW = min(avail.width, avail.height * aspect)
        let size = CGSize(width: (fitW * zoom).rounded(), height: (fitW / aspect * zoom).rounded())
        func place(_ len: CGFloat, _ viewLen: CGFloat, _ c: CGFloat) -> CGFloat {
            if len <= viewLen { return ((viewLen - len) / 2).rounded() }
            return min(0, max(viewLen - len, viewLen / 2 - c * len)).rounded()
        }
        return CGRect(x: place(size.width, view.width, zoomCenter.x),
                      y: place(size.height, view.height, zoomCenter.y),
                      width: size.width, height: size.height)
    }

    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// The zoom at which one image pixel is one screen pixel.
    var zoom100: CGFloat {
        guard let src = source, let fit = imageRect(in: canvasSize, zoom: 1) else { return 1 }
        return max(1, src.fullSize.width * previewRegion.width / backingScale / fit.width)
    }

    var zoomPercent: Int {
        guard let src = source, let rect = imageRect(in: canvasSize) else { return 100 }
        return Int((rect.width * backingScale / (src.fullSize.width * previewRegion.width) * 100).rounded())
    }

    /// Sets the zoom, keeping the image point under `anchor` (view coordinates) in place.
    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        let newZoom = min(max(z, 1), zoom100 * 4)
        guard let old = imageRect(in: canvasSize) else { return }
        let a = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let n = CGPoint(x: (a.x - old.minX) / old.width, y: (a.y - old.minY) / old.height)
        let k = newZoom / zoom
        let size = CGSize(width: old.width * k, height: old.height * k)
        let origin = CGPoint(x: a.x - n.x * size.width, y: a.y - n.y * size.height)
        zoom = newZoom
        zoomCenter = CGPoint(x: (canvasSize.width / 2 - origin.x) / size.width,
                             y: (canvasSize.height / 2 - origin.y) / size.height)
        clampCenter()
        scheduleDetail()
    }

    func zoomToFit() { zoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5); scheduleDetail() }
    func zoomToActualPixels(anchor: CGPoint? = nil) { setZoom(zoom100, anchor: anchor) }
    func zoomIn() { setZoom(zoom * 1.5) }
    func zoomOut() { setZoom(zoom / 1.5) }

    /// Fit ↔ 100%, centred on the pointer when it's over the photo.
    func toggleZoom() {
        if zoom > 1.01 { zoomToFit() } else { zoomToActualPixels(anchor: mouseInCanvas) }
    }

    /// Pans by a view-space delta.
    func pan(by d: CGSize) {
        guard zoom > 1, let rect = imageRect(in: canvasSize) else { return }
        zoomCenter.x -= d.width / rect.width
        zoomCenter.y -= d.height / rect.height
        clampCenter()
        scheduleDetail()
    }

    private func clampCenter() {
        guard let rect = imageRect(in: canvasSize) else { return }
        let hx = canvasSize.width / 2 / rect.width, hy = canvasSize.height / 2 / rect.height
        zoomCenter.x = hx >= 0.5 ? 0.5 : min(max(zoomCenter.x, hx), 1 - hx)
        zoomCenter.y = hy >= 0.5 ? 0.5 : min(max(zoomCenter.y, hy), 1 - hy)
    }

    /// When the preview is too coarse for the current zoom, renders the visible part sharper.
    func scheduleDetail() {
        detailWork?.cancel()
        detailGeneration += 1
        guard let src = source, let preview, zoom > 1.01, let rect = imageRect(in: canvasSize),
              rect.width * backingScale > CGFloat(preview.width) * 1.1 else {
            if detail != nil, zoom <= 1.01 { detail = nil }
            return
        }
        // Visible part, as a normalized region of the whole image.
        let vis = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard vis.width > 1, vis.height > 1 else { return }
        let r = previewRegion
        let region = CGRect(x: r.minX + (vis.minX - rect.minX) / rect.width * r.width,
                            y: r.minY + (vis.minY - rect.minY) / rect.height * r.height,
                            width: vis.width / rect.width * r.width,
                            height: vis.height / rect.height * r.height)
        // Render scale: enough for the screen, rounded up to a power of two (keeps caches small).
        let needed = rect.width * backingScale / (src.fullSize.width * r.width)
        let scale = min(1, pow(2, ceil(log2(Double(max(needed, 0.01))))))
        let adj = displayedAdjustments, gen = detailGeneration, renderer = renderer
        let clip = (clipHighlights, clipShadows), dust = showDustView ? dustSensitivity : nil
        let work = DispatchWorkItem { [weak self] in
            self?.renderQueue.async {
                let d = renderer.detail(src, adj, region: region, scale: scale, clipping: clip, dustView: dust)
                DispatchQueue.main.async {
                    guard let self, let d, gen == self.detailGeneration, src === self.source else { return }
                    self.detail = (d.image, d.region, adj)
                }
            }
        }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Crop

    var crop: Crop { adjustments.crop ?? Crop() }

    func setCrop(_ c: Crop) {
        adjustments.crop = c
    }

    /// Picks a shape and fits the largest crop of it around the current crop's centre.
    func setCropAspect(_ aspect: CropAspect) {
        guard let src = source else { return }
        checkpoint()
        var c = crop
        c.aspect = aspect
        if aspect == .original || aspect == .square || aspect == .free { c.rotated = false }
        if let r = c.ratio(imageSize: src.fullSize) {
            c.rect = Crop.fitted(ratio: r, imageSize: src.fullSize, center: CGPoint(x: c.rect.midX, y: c.rect.midY))
        }
        c.rect = fitToAngle(c.rect, angle: c.angle)
        setCrop(c)
    }

    // MARK: Straighten

    var straightenBinding: Binding<Double> {
        Binding(get: { self.adjustments.crop?.angle ?? 0 }, set: { self.setStraighten($0) })
    }

    /// Call when a straighten change begins: later angles shrink a copy of today's crop.
    func beginStraighten() {
        checkpoint()
        straightenBase = crop.rect
    }

    func setStraighten(_ angle: Double) {
        var c = crop
        c.angle = (angle * 10).rounded() / 10
        c.rect = fitToAngle(straightenBase ?? c.rect, angle: c.angle)
        adjustments.crop = (c.angle == 0 && c.isFullFrame && c.aspect == .free) ? nil : c
    }

    /// Shrinks a normalized crop (about its centre) until it fits inside the turned photo.
    func fitToAngle(_ rect: CGRect, angle: Double) -> CGRect {
        guard let s = source?.fullSize, angle != 0 else { return rect }
        let px = CGRect(x: rect.minX * s.width, y: rect.minY * s.height, width: rect.width * s.width, height: rect.height * s.height)
        let fit = Crop.shrunkToFit(px, in: CGRect(origin: .zero, size: s), angle: angle)
        return CGRect(x: fit.minX / s.width, y: fit.minY / s.height, width: fit.width / s.width, height: fit.height / s.height)
    }

    // MARK: Dust specks

    var selectedSpot: DustSpot? { adjustments.dust.first { $0.id == selectedSpotID } }

    /// The brush (or the selected speck's) size, as a fraction of the image width.
    var dustSizeBinding: Binding<Double> {
        Binding(get: { self.selectedSpot?.radius ?? self.dustBrush },
                set: { v in
                    let r = min(max(v, DustSpot.minRadius), DustSpot.maxRadius)
                    self.dustBrush = r
                    if let id = self.selectedSpotID { self.updateSpot(id) { $0.radius = r } }
                })
    }

    /// Heals a speck at `point` (normalized), copying from the best-matching spot nearby.
    @discardableResult
    func addDustSpot(at point: CGPoint) -> UUID {
        checkpoint()
        let source = bestDustSource(for: point, radius: dustBrush)
        let spot = DustSpot(center: point, source: source, radius: dustBrush)
        adjustments.dust.append(spot)
        selectedSpotID = spot.id
        return spot.id
    }

    func updateSpot(_ id: UUID, _ change: (inout DustSpot) -> Void) {
        guard let i = adjustments.dust.firstIndex(where: { $0.id == id }) else { return }
        change(&adjustments.dust[i])
    }

    func deleteSpot(_ id: UUID) {
        checkpoint()
        adjustments.dust.removeAll { $0.id == id }
        if selectedSpotID == id { selectedSpotID = nil }
    }

    func clearDust() {
        checkpoint()
        adjustments.dust = []
        selectedSpotID = nil
    }

    func nudgeDustBrush(_ factor: Double) {
        dustSizeBinding.wrappedValue = (selectedSpot?.radius ?? dustBrush) * factor
    }

    /// Picks the source whose surroundings best match the speck's surroundings, from candidates
    /// around it, using the preview's pixels (the speck itself is ignored).
    private func bestDustSource(for p: CGPoint, radius: Double) -> CGPoint {
        let fallback = CGPoint(x: min(p.x + radius * 2.6, 1 - radius), y: p.y)
        guard let cg = preview, let full = source?.fullSize,
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return fallback }
        let region = previewRegion, aspect = full.width / full.height
        let w = cg.width, h = cg.height, row = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        func lum(_ q: CGPoint) -> Double? {   // q normalized to the whole image
            let x = Int((q.x - region.minX) / region.width * CGFloat(w))
            let y = Int((q.y - region.minY) / region.height * CGFloat(h))
            guard x >= 0, y >= 0, x < w, y < h else { return nil }
            let o = y * row + x * bpp
            return 0.2126 * Double(bytes[o]) + 0.7152 * Double(bytes[o + 1]) + 0.0722 * Double(bytes[o + 2])
        }
        // Ring samples (radius is a fraction of width; y offsets scale by the aspect ratio).
        func ring(_ c: CGPoint, _ k: Double) -> [Double]? {
            var out: [Double] = []
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * .pi
                let q = CGPoint(x: c.x + radius * k * cos(a), y: c.y + radius * k * sin(a) * aspect)
                guard let v = lum(q) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let target = ring(p, 1.3), let targetOuter = ring(p, 1.6) else { return fallback }
        var best = fallback, bestScore = Double.infinity
        for dist in [2.4, 3.2, 4.2] {
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let c = CGPoint(x: p.x + radius * dist * cos(a), y: p.y + radius * dist * sin(a) * aspect)
                guard c.x - radius * 1.7 > 0, c.x + radius * 1.7 < 1,
                      c.y - radius * 1.7 * aspect > 0, c.y + radius * 1.7 * aspect < 1,
                      let r1 = ring(c, 1.3), let r2 = ring(c, 1.6), let inner = ring(c, 0.5) else { continue }
                // Same surroundings, and a source centre that looks like its own surroundings
                // (so we don't copy another speck or an edge), with a slight preference for near.
                var score = zip(target, r1).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
                score += zip(targetOuter, r2).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
                let ringMean = (r1 + r2).reduce(0, +) / 32
                score += inner.map { ($0 - ringMean) * ($0 - ringMean) }.reduce(0, +) * 0.5
                score *= 1 + 0.08 * dist
                if score < bestScore { bestScore = score; best = c }
            }
        }
        return best
    }

    // MARK: Lens

    var hasLensProfile: Bool { source?.lensProfile != nil }

    var lensProfileBinding: Binding<Bool> {
        Binding(get: { self.adjustments.lens.useProfile },
                set: { v in self.checkpoint(); self.adjustments.lens.useProfile = v })
    }

    func rotateCropShape() {
        guard let src = source else { return }
        var c = crop
        guard c.aspect != .free, c.aspect != .square else { return }
        checkpoint()
        c.rotated.toggle()
        if let r = c.ratio(imageSize: src.fullSize) {
            c.rect = Crop.fitted(ratio: r, imageSize: src.fullSize, center: CGPoint(x: c.rect.midX, y: c.rect.midY))
        }
        setCrop(c)
    }

    func resetCrop() {
        checkpoint()
        adjustments.crop = nil
    }

    // MARK: Status

    private func setBusy(_ message: String?, progress: Double? = nil) {
        busyMessage = message
        busyProgress = progress
    }

    private func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: Info

    /// "ISO 100 · 24 mm · f/8 · 1/250 s"
    var exifSummary: String {
        guard let exif = source?.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return "" }
        var parts: [String] = []
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double { parts.append(String(format: "%.0f mm", f)) }
        if let n = exif[kCGImagePropertyExifFNumber as String] as? Double { parts.append(String(format: "f/%g", n)) }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        return parts.joined(separator: " · ")
    }

    var pixelSizeText: String {
        guard let full = source?.fullSize else { return "" }
        let s = adjustments.outputSize(for: full)
        let mp = s.width * s.height / 1_000_000
        return String(format: "%.0f × %.0f · %.1f MP", s.width, s.height, mp)
    }
}

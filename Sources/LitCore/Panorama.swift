import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum PanoramaProjection: String, CaseIterable, Identifiable {
    /// Wraps the scene around a cylinder: works for any width, verticals stay straight,
    /// long horizontal lines bow a little.
    case cylindrical
    /// A flat "wide lens" view: all straight lines stay straight and more height survives the
    /// crop, but edges stretch, so it's limited to about 120° across.
    case rectilinear
    /// No projection, frames placed as-is (only for flat subjects / testing).
    case flat

    public var id: String { rawValue }
}

public struct PanoramaOptions {
    /// Number of rows; frames are ordered row by row, left → right, top row first.
    public var rows = 1
    public var autoCrop = true
    public var projection = PanoramaProjection.cylindrical
    public init() {}

    var cylindrical: Bool { projection != .flat }
}

/// Stitches 2–9 overlapping frames into one panorama.
///
/// 1. Develop each frame neutrally and project it onto a cylinder (focal length from EXIF).
/// 2. On low-res copies, register each frame to its left neighbour (and each row's first
///    frame to the one above) — after cylindrical projection a pan is a pure translation.
/// 3. Match exposure across overlaps, then feather-blend at full resolution.
public final class PanoramaStitcher {
    let renderer: Renderer
    /// 32-bit float working format: blend weights get tiny near frame edges and would
    /// underflow in the half-float format used for previews.
    let context: CIContext
    public init(renderer: Renderer) {
        self.renderer = renderer
        context = CIContext(options: [
            .workingColorSpace: Renderer.linearSpace,
            .workingFormat: CIFormat.RGBAf,
            .name: "LIT.Panorama",
        ])
    }

    struct Frame {
        let source: PhotoSource
        let row: Int
        let col: Int
    }

    /// Frames developed at low resolution and aligned; see `plan` / `compose`.
    public final class PanoramaPlan {
        let frames: [Frame]
        let low: [CIImage]
        let transforms: [CGAffineTransform]
        let gains: [Double]
        let regScale: Double
        let focal35: Double
        let fullLong: Double
        let cylindrical: Bool

        init(frames: [Frame], low: [CIImage], transforms: [CGAffineTransform], gains: [Double],
             regScale: Double, focal35: Double, fullLong: Double, cylindrical: Bool) {
            self.frames = frames; self.low = low; self.transforms = transforms; self.gains = gains
            self.regScale = regScale; self.focal35 = focal35; self.fullLong = fullLong; self.cylindrical = cylindrical
        }

        /// Full-resolution size of a composite of the given (preview) size.
        public func fullSize(ofPreview size: CGSize) -> CGSize {
            CGSize(width: (size.width / regScale).rounded(), height: (size.height / regScale).rounded())
        }
    }

    /// Aligns and merges in one go (full resolution).
    public func stitch(_ sources: [PhotoSource], options: PanoramaOptions,
                       progress: (Double, String) -> Void = { _, _ in }) throws -> CIImage {
        let p = try plan(sources, options: options, progress: progress)
        progress(0.5, "Blending")
        let pano = try compose(p, options: options, preview: false)
        progress(0.55, "Rendering")
        return pano
    }

    /// The slow part: develops low-res copies of the frames and aligns them. The result can be
    /// composed many times (previews with different projections, then the full merge).
    public func plan(_ sources: [PhotoSource], options: PanoramaOptions,
                     progress: (Double, String) -> Void = { _, _ in }) throws -> PanoramaPlan {
        let n = sources.count
        guard n >= 2 else { throw LitError.panorama("Select at least 2 photos.") }
        let rows = max(1, options.rows)
        guard n % rows == 0 else { throw LitError.panorama("\(n) photos can't be split into \(rows) equal rows.") }
        let cols = n / rows
        let frames = sources.enumerated().map { Frame(source: $0.element, row: $0.offset / cols, col: $0.offset % cols) }

        let fullLong = sources.map { max($0.fullSize.width, $0.fullSize.height) }.max() ?? 1
        let focal35 = sources[0].focalLength35mm ?? 35
        let regScale = Double(min(1, 2000 / fullLong))

        progress(0.02, "Preparing frames")
        var low: [CIImage] = []
        for (i, f) in frames.enumerated() {
            low.append(materialize(warped(f.source, scale: regScale, focal35: focal35, cylindrical: options.cylindrical)))
            progress(0.02 + 0.25 * Double(i + 1) / Double(n), "Preparing frames")
        }

        // transforms[i] maps frame i's (low-res) coordinates into the panorama.
        var transforms = [CGAffineTransform](repeating: .identity, count: n)
        var gains = [Double](repeating: 1, count: n)
        var done = 0
        for i in 0..<n {
            let f = frames[i]
            let ref: Int
            if f.col > 0 { ref = i - 1 } else if f.row > 0 { ref = i - cols } else { continue }
            let m = try PhaseCorrelation.transform(of: low[i], relativeTo: low[ref], horizontal: f.col > 0,
                                                   context: context)
            transforms[i] = m.concatenating(transforms[ref])
            gains[i] = gains[ref] * gainRatio(low[i], transforms[i], reference: low[ref], transforms[ref])
            done += 1
            progress(0.27 + 0.2 * Double(done) / Double(n - 1), "Aligning")
        }
        // Normalise gains so overall brightness matches the average frame.
        let meanLog = gains.map { log2($0) }.reduce(0, +) / Double(n)
        gains = gains.map { $0 / pow(2, meanLog) }
        return PanoramaPlan(frames: frames, low: low, transforms: transforms, gains: gains, regScale: regScale,
                            focal35: focal35, fullLong: Double(fullLong), cylindrical: options.cylindrical)
    }

    /// Blends the aligned frames: `preview` uses the low-res copies (fast, ~2000 px frames),
    /// otherwise full resolution. Projection and auto-crop come from `options`.
    public func compose(_ plan: PanoramaPlan, options: PanoramaOptions, preview: Bool) throws -> CIImage {
        guard plan.cylindrical == options.cylindrical else {
            throw LitError.panorama("The alignment was made for a different projection.")
        }
        let frames = plan.frames, n = frames.count
        let toLow = CGAffineTransform(scaleX: plan.regScale, y: plan.regScale)
        let toFull = CGAffineTransform(scaleX: 1 / plan.regScale, y: 1 / plan.regScale)
        let k = preview ? plan.regScale : 1   // pixel scale of this composite
        let focal = plan.focal35 / 36 * plan.fullLong * k
        var acc: CIImage?
        var edges: [[[CGPoint]]] = []   // per frame: bottom, right, top, left edge samples
        var centres: [CGPoint] = []
        for (i, f) in frames.enumerated() {
            var img = preview ? plan.low[i] : warped(f.source, scale: 1, focal35: plan.focal35, cylindrical: plan.cylindrical)
            if abs(plan.gains[i] - 1) > 0.005 {
                img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(plan.gains[i])])
            }
            let local = img.extent
            let T = preview ? plan.transforms[i] : toLow.concatenating(plan.transforms[i]).concatenating(toFull)
            // Weight in the frame's own coordinates, then place it.
            let weighted = Kernels.panoWeight.apply(extent: local, arguments: [img, CIVector(cgRect: local), Float(blendSharpness)])!
                .transformed(by: T)
            let size = CGSize(width: f.source.fullSize.width * k, height: f.source.fullSize.height * k)
            edges.append(frameEdges(size, warped: local, focalPx: plan.cylindrical ? focal : nil)
                .map { $0.map { $0.applying(T) } })
            centres.append(CGPoint(x: local.midX, y: local.midY).applying(T))
            if let a = acc {
                acc = Kernels.add.apply(extent: a.extent.union(weighted.extent), arguments: [a, weighted])
            } else {
                acc = weighted
            }
        }
        guard let accumulated = acc, var pano = Kernels.normalize.apply(extent: accumulated.extent, arguments: [accumulated]) else {
            throw LitError.renderFailed
        }

        if options.projection == .rectilinear {
            let xs = centres.map(\.x)
            let centre = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: centres.map(\.y).reduce(0, +) / CGFloat(n))
            let allX = edges.flatMap { $0.flatMap { $0.map(\.x) } }
            let halfAngle = max(Double(centre.x - allX.min()!), Double(allX.max()! - centre.x)) / focal
            guard halfAngle < 1.13 else {   // ~130° across
                throw LitError.panorama(String(format: "This panorama is about %.0f° wide, too wide for Rectilinear (max ~130°). Use Cylindrical instead.",
                                                halfAngle * 2 * 180 / .pi))
            }
            edges = edges.map { $0.map { $0.map { Self.cylinderToPlane($0, centre: centre, focal: focal) } } }
            pano = rectilinear(pano, centre: centre, focal: focal, extent: Self.bounds(edges.flatMap { $0.flatMap { $0 } }))
        }

        if options.autoCrop {
            let crop = autoCropRect(frames: frames, edges: edges)
            if crop.width > 16, crop.height > 16 { pano = pano.cropped(to: crop) }
        }
        let e = pano.extent.integral
        return pano.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// Renders a composed (preview) panorama to an sRGB bitmap no wider than `maxWidth`.
    public func previewImage(_ pano: CIImage, maxWidth: CGFloat) -> CGImage? {
        let s = min(1, maxWidth / max(pano.extent.width, 1))
        let img = pano.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: Renderer.sRGB)
    }

    /// Exponent on the horizontal feather. Higher = narrower transition between frames,
    /// which hides parallax (nearby rocks/trees) instead of ghosting it.
    var blendSharpness: Double = 6

    /// The best files to merge: when every frame has a RAW original with the same name in the
    /// same folder (RAW + JPEG shooting), the RAWs are used. Otherwise the files as given.
    public static func bestInputs(for urls: [URL]) -> [URL] {
        var raws: [URL] = []
        for url in urls {
            if PhotoSource.rawExtensions.contains(url.pathExtension.lowercased()) { raws.append(url); continue }
            let dir = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard let raw = siblings.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == stem
                    && PhotoSource.rawExtensions.contains($0.pathExtension.lowercased())
            }) else { return urls }
            raws.append(raw)
        }
        return raws
    }

    /// Renders the panorama once into memory at full precision (half-float, linear), so it can
    /// be edited with the same headroom as the source frames. Nothing is written to disk.
    public func renderInMemory(_ pano: CIImage) throws -> CIImage {
        let e = pano.extent.integral
        let w = Int(e.width), h = Int(e.height)
        let rowBytes = w * 8
        guard w > 0, h > 0, let buffer = malloc(rowBytes * h) else { throw LitError.renderFailed }
        context.render(pano, toBitmap: buffer, rowBytes: rowBytes, bounds: e, format: .RGBAh,
                       colorSpace: Renderer.linearSpace)
        let data = Data(bytesNoCopy: buffer, count: rowBytes * h, deallocator: .free)
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: w, height: h),
                       format: .RGBAh, colorSpace: Renderer.linearSpace)
    }

    // MARK: Steps

    /// Neutral develop + projection. Origin (0,0).
    func warped(_ source: PhotoSource, scale: Double, focal35: Double, cylindrical: Bool) -> CIImage {
        var neutral = Adjustments()
        neutral.sharpenAmount = 0
        let base = Pipeline.prepare(source.whiteBalanced(temperature: nil, scale: scale), neutral, profile: source.lensProfile)
        let img = Pipeline.develop(base, neutral, scale: scale)
        guard cylindrical else { return img }
        let w = img.extent.width, h = img.extent.height
        let f = focal35 / 36 * Double(max(w, h))
        let outW = (2 * f * atan(Double(w) / 2 / f)).rounded(.down)
        let out = CGRect(x: 0, y: 0, width: outW, height: Double(h))
        return Kernels.cylindrical.apply(
            extent: out, roiCallback: { _, _ in img.extent }, image: img,
            arguments: [Double(w) / 2, Double(h) / 2, f, outW / 2, Double(h) / 2]
        ) ?? img
    }

    func materialize(_ img: CIImage) -> CIImage {
        guard let cg = context.createCGImage(img, from: img.extent, format: .RGBAh,
                                                      colorSpace: Renderer.linearSpace) else { return img }
        return CIImage(cgImage: cg)
    }

    /// Brightness ratio reference/moving in their overlap.
    func gainRatio(_ moving: CIImage, _ mt: CGAffineTransform, reference: CIImage, _ rt: CGAffineTransform) -> Double {
        let a = moving.transformed(by: mt)
        let b = reference.transformed(by: rt)
        let overlap = a.extent.intersection(b.extent).insetBy(dx: 16, dy: 16)
        guard overlap.width > 16, overlap.height > 16 else { return 1 }
        func mean(_ img: CIImage) -> Double {
            let avg = img.cropped(to: overlap).applyingFilter("CIAreaAverage", parameters: [
                kCIInputExtentKey: CIVector(cgRect: overlap),
            ])
            var px = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: Renderer.linearSpace)
            let alpha = Double(max(px[3], 1e-4))
            return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / alpha
        }
        let m = mean(a), r = mean(b)
        guard m > 1e-4, r > 1e-4 else { return 1 }
        return min(max(r / m, 0.5), 2)
    }

    /// The outline of a frame after projection, as points along its bottom, right, top and left
    /// edges (in the warped frame's coordinates, slightly inset).
    func frameEdges(_ size: CGSize, warped r: CGRect, focalPx: Double?) -> [[CGPoint]] {
        let w = Double(size.width) - 4, h = Double(size.height) - 4
        func map(_ px: Double, _ py: Double) -> CGPoint {
            guard let f = focalPx else { return CGPoint(x: Double(r.midX) + px, y: Double(r.midY) + py) }
            return CGPoint(x: Double(r.midX) + f * atan(px / f), y: Double(r.midY) + f * py / (px * px + f * f).squareRoot())
        }
        let steps = 24
        let t = (0...steps).map { Double($0) / Double(steps) - 0.5 }
        return [t.map { map($0 * w, -h / 2) }, t.map { map(w / 2, $0 * h) },
                t.map { map($0 * w, h / 2) }, t.map { map(-w / 2, $0 * h) }]
    }

    /// Largest axis-aligned rectangle inside the frames' outlines (conservative).
    func autoCropRect(frames: [Frame], edges: [[[CGPoint]]]) -> CGRect {
        let byRow = Dictionary(grouping: frames.indices, by: { frames[$0].row })
        let rowIdx = byRow.keys.sorted()   // row 0 is the top row
        // edges: 0 bottom, 1 right, 2 top, 3 left (CI y grows upwards).
        let top = byRow[rowIdx.first!]!.flatMap { edges[$0][2].map(\.y) }.min()!
        let bottom = byRow[rowIdx.last!]!.flatMap { edges[$0][0].map(\.y) }.max()!
        var left = -CGFloat.infinity, right = CGFloat.infinity
        for r in rowIdx {
            let idx = byRow[r]!.sorted { frames[$0].col < frames[$1].col }
            left = max(left, edges[idx.first!][3].map(\.x).max()!)
            right = min(right, edges[idx.last!][1].map(\.x).min()!)
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom).integral
    }

    // MARK: Rectilinear

    /// Cylinder (panorama) coordinates → flat plane coordinates, both centred on `centre`.
    static func cylinderToPlane(_ p: CGPoint, centre c: CGPoint, focal f: Double) -> CGPoint {
        let th = Double(p.x - c.x) / f
        return CGPoint(x: Double(c.x) + f * tan(th), y: Double(c.y) + Double(p.y - c.y) / cos(th))
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).integral
    }

    /// Re-projects a cylindrical mosaic onto a flat plane facing `centre`.
    func rectilinear(_ pano: CIImage, centre c: CGPoint, focal f: Double, extent: CGRect) -> CIImage {
        let src = pano.extent
        let roi: CIKernelROICallback = { _, r in
            // Bounding box of the source points the rectangle's edges map to.
            var pts: [CGPoint] = []
            for k in 0...8 {
                let t = CGFloat(k) / 8
                for (x, y) in [(r.minX + t * r.width, r.minY), (r.minX + t * r.width, r.maxY),
                               (r.minX, r.minY + t * r.height), (r.maxX, r.minY + t * r.height)] {
                    let X = Double(x - c.x), Y = Double(y - c.y)
                    let th = atan(X / f)
                    pts.append(CGPoint(x: Double(c.x) + f * th, y: Double(c.y) + Y * cos(th)))
                }
            }
            if r.minX < c.x, r.maxX > c.x {   // the vertical stretch peaks at the centre column
                pts.append(CGPoint(x: c.x, y: r.minY)); pts.append(CGPoint(x: c.x, y: r.maxY))
            }
            return PanoramaStitcher.bounds(pts).insetBy(dx: -4, dy: -4).intersection(src)
        }
        return Kernels.rectilinear.apply(extent: extent, roiCallback: roi, image: pano,
                                         arguments: [Double(c.x), Double(c.y), f]) ?? pano
    }
}

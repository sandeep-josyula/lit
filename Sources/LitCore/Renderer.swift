import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Accelerate

public struct ExportOptions: Codable, Equatable {
    public var quality: Double = 1.0         // 0...1 (100: full quality by default)
    public var limitLongEdge = false
    public var longEdge: Int = 4096
    public init() {}
}

/// Renders previews and exports. One shared CIContext (GPU).
public final class Renderer {
    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public let context: CIContext

    private var baseCache: (key: String, image: CIImage)?
    private var guideCache: (key: String, image: CIImage)?
    private let cacheLock = NSLock()

    public init() {
        context = CIContext(options: [
            .workingColorSpace: Renderer.linearSpace,
            .workingFormat: CIFormat.RGBAh,
            .name: "LIT",
        ])
    }

    // MARK: Preview

    public struct Preview {
        public let image: CGImage
        /// 256-bin histograms for R, G, B (counts).
        public let histogram: [[UInt]]
    }

    /// Scale that makes the photo's long edge `longEdge` pixels (never upscales).
    public static func scale(for source: PhotoSource, longEdge: CGFloat) -> Double {
        Double(min(1, longEdge / max(source.fullSize.width, source.fullSize.height)))
    }

    /// Renders a preview. The white-balanced base is cached as a bitmap so that
    /// non-WB slider changes don't re-decode the RAW file.
    /// `cropped`: apply the crop (off while the crop tool shows the whole frame).
    public func preview(_ source: PhotoSource, _ adj: Adjustments, longEdge: CGFloat, cropped: Bool = true,
                        clipping: (highlights: Bool, shadows: Bool) = (false, false),
                        dustView: Double? = nil) -> Preview? {
        var scale = Self.scale(for: source, longEdge: longEdge)
        if cropped, let c = adj.cropPixels(in: source.fullSize) {
            // Keep the visible (cropped) part sharp, within reason.
            scale = min(1, Double(longEdge / max(c.width, c.height)), scale * 2)
        }
        let base = Pipeline.prepare(cachedBase(source, adj, scale: scale), adj, profile: source.lensProfile)
        var developed = Pipeline.develop(base, adj, scale: scale)
        if cropped { developed = Pipeline.crop(developed, adj) }
        guard let cg = context.createCGImage(developed, from: developed.extent, format: .RGBA8,
                                             colorSpace: Self.sRGB) else { return nil }
        let histogram = Self.histogram(cg)
        if let sensitivity = dustView, let v = dustViewImage(cg, sensitivity: sensitivity) {
            return Preview(image: v, histogram: histogram)
        }
        // The clipping warning is painted on the finished bitmap, so the histogram stays clean.
        if clipping.highlights || clipping.shadows {
            let marked = Pipeline.clippingWarning(CIImage(cgImage: cg), highlights: clipping.highlights,
                                                  shadows: clipping.shadows)
            if let m = context.createCGImage(marked, from: marked.extent, format: .RGBA8, colorSpace: Self.sRGB) {
                return Preview(image: m, histogram: histogram)
            }
        }
        return Preview(image: cg, histogram: histogram)
    }

    private func cachedBase(_ source: PhotoSource, _ adj: Adjustments, scale: Double) -> CIImage {
        let key = "\(ObjectIdentifier(source).hashValue)|\(adj.temperature ?? -1)|\(scale)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = baseCache, c.key == key { return c.image }
        let wb = source.whiteBalanced(temperature: adj.temperature, scale: scale)
        guard let cg = context.createCGImage(wb, from: wb.extent, format: .RGBAh, colorSpace: Self.linearSpace) else {
            return wb
        }
        let img = CIImage(cgImage: cg)
        baseCache = (key, img)
        return img
    }

    static func histogram(_ cg: CGImage) -> [[UInt]] {
        var result: [[UInt]] = [[UInt]](repeating: [UInt](repeating: 0, count: 256), count: 3)
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return result }
        var buffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: ptr),
                                   height: vImagePixelCount(cg.height),
                                   width: vImagePixelCount(cg.width),
                                   rowBytes: cg.bytesPerRow)
        var r = [vImagePixelCount](repeating: 0, count: 256)
        var g = r, b = r, a = r
        r.withUnsafeMutableBufferPointer { rp in
            g.withUnsafeMutableBufferPointer { gp in
                b.withUnsafeMutableBufferPointer { bp in
                    a.withUnsafeMutableBufferPointer { ap in
                        var hist: [UnsafeMutablePointer<vImagePixelCount>?] = [
                            rp.baseAddress, gp.baseAddress, bp.baseAddress, ap.baseAddress,
                        ]
                        _ = vImageHistogramCalculation_ARGB8888(&buffer, &hist, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
        }
        result[0] = r.map { UInt($0) }
        result[1] = g.map { UInt($0) }
        result[2] = b.map { UInt($0) }
        return result
    }

    /// Compiles every GPU kernel the editor uses by rendering a tiny image with all features
    /// switched on. Call once at launch, off the main thread: otherwise the first photo (and the
    /// first move of some sliders) pays for shader compilation.
    public func warmUp() {
        let tiny = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let src = PhotoSource(image: tiny, url: URL(fileURLWithPath: "/warmup"))
        var adj = Adjustments()
        adj.temperature = 10
        adj.exposure = 0.1; adj.contrast = 10; adj.highlights = -10; adj.shadows = 10
        adj.whites = 5; adj.blacks = -5; adj.vibrance = 10; adj.saturation = 5
        adj.color.hue[1] = 10; adj.color.saturation[3] = 10; adj.color.luminance[4] = 10
        var local = LocalAdjustments()
        local.exposure = -0.5; local.temperature = 10; local.shadows = 10; local.saturation = 10
        adj.gradients = [GradientMask(start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1), local: local)]
        adj.crop = Crop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        _ = preview(src, adj, longEdge: 64)
        _ = preview(src, adj, longEdge: 64, cropped: false)
        _ = detail(src, adj, region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), scale: 1)
        baseCache = nil
        guideCache = nil
    }

    // MARK: Detail (zoomed in)

    public struct Detail {
        public let image: CGImage
        /// The part of the whole image it shows, normalized (top-left origin).
        public let region: CGRect
    }

    /// Renders just `region` (normalized, top-left origin, of the whole uncropped image) at
    /// `scale` × full resolution — for zoomed-in views.
    public func detail(_ source: PhotoSource, _ adj: Adjustments, region: CGRect, scale: Double,
                       clipping: (highlights: Bool, shadows: Bool) = (false, false), dustView: Double? = nil) -> Detail? {
        let base = Pipeline.prepare(source.whiteBalanced(temperature: adj.temperature, scale: scale), adj,
                                    profile: source.lensProfile)
        let guide = Pipeline.prepare(guide(source, adj), adj, profile: source.lensProfile)
        let developed = Pipeline.clippingWarning(Pipeline.develop(base, adj, scale: scale, guide: guide),
                                                 highlights: clipping.highlights, shadows: clipping.shadows)
        let e = developed.extent
        let r = CGRect(x: e.minX + region.minX * e.width, y: e.maxY - region.maxY * e.height,
                       width: region.width * e.width, height: region.height * e.height).integral.intersection(e)
        guard r.width >= 1, r.height >= 1,
              let cg = context.createCGImage(developed, from: r, format: .RGBA8, colorSpace: Self.sRGB) else { return nil }
        if let sensitivity = dustView, let v = dustViewImage(cg, sensitivity: sensitivity) {
            return Detail(image: v, region: CGRect(x: (r.minX - e.minX) / e.width, y: (e.maxY - r.maxY) / e.height,
                                                   width: r.width / e.width, height: r.height / e.height))
        }
        let actual = CGRect(x: (r.minX - e.minX) / e.width, y: (e.maxY - r.maxY) / e.height,
                            width: r.width / e.width, height: r.height / e.height)
        return Detail(image: cg, region: actual)
    }

    /// The "find dust" view of a rendered bitmap.
    private func dustViewImage(_ cg: CGImage, sensitivity: Double) -> CGImage? {
        let v = Pipeline.dustView(CIImage(cgImage: cg), sensitivity: sensitivity)
        return context.createCGImage(v, from: v.extent, format: .RGBA8, colorSpace: Self.sRGB)
    }

    /// A small white-balanced copy used as `Pipeline.develop`'s guide.
    private func guide(_ source: PhotoSource, _ adj: Adjustments) -> CIImage {
        let scale = Self.scale(for: source, longEdge: 1024)
        let key = "\(ObjectIdentifier(source).hashValue)|\(adj.temperature ?? -1)|\(scale)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = guideCache, c.key == key { return c.image }
        let wb = source.whiteBalanced(temperature: adj.temperature, scale: scale)
        guard let cg = context.createCGImage(wb, from: wb.extent, format: .RGBAh, colorSpace: Self.linearSpace) else {
            return wb
        }
        let img = CIImage(cgImage: cg)
        guideCache = (key, img)
        return img
    }

    // MARK: Full resolution

    public func fullResolution(_ source: PhotoSource, _ adj: Adjustments) -> CIImage {
        let base = Pipeline.prepare(source.whiteBalanced(temperature: adj.temperature, scale: 1), adj,
                                    profile: source.lensProfile)
        return Pipeline.crop(Pipeline.develop(base, adj, scale: 1), adj)
    }

    public func exportJPEG(_ source: PhotoSource, _ adj: Adjustments, to url: URL, options: ExportOptions) throws {
        var img = fullResolution(source, adj)
        if options.limitLongEdge {
            let long = max(img.extent.width, img.extent.height)
            let s = Double(options.longEdge) / Double(long)
            if s < 1 {
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0,
                ])
                img = img.cropped(to: img.extent.integral)
            }
        }
        guard let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Self.sRGB) else {
            throw LitError.renderFailed
        }
        try Self.writeImage(cg, to: url, type: .jpeg, metadata: Self.exportMetadata(from: source.metadata),
                            extra: [kCGImageDestinationLossyCompressionQuality as String: options.quality])
    }

    /// Keeps EXIF/GPS/IPTC/TIFF info but drops orientation (pixels are already upright)
    /// and RAW-specific dictionaries.
    static func exportMetadata(from props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let v = props[key as String] { out[key as String] = v }
        }
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "LIT"
        out[kCGImagePropertyTIFFDictionary as String] = tiff
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    static func writeImage(_ cg: CGImage, to url: URL, type: UTType, metadata: [String: Any],
                           extra: [String: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw LitError.writeFailed(url)
        }
        let props = metadata.merging(extra) { $1 }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LitError.writeFailed(url) }
    }
}

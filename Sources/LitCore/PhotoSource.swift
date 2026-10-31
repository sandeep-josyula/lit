import Foundation
import CoreImage
import ImageIO
import Accelerate

public enum LitError: LocalizedError {
    case cannotOpen(URL)
    case renderFailed
    case writeFailed(URL)
    case panorama(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "Couldn't open \(url.lastPathComponent)."
        case .renderFailed: return "Rendering failed."
        case .writeFailed(let url): return "Couldn't write \(url.lastPathComponent)."
        case .panorama(let msg): return msg
        }
    }
}

/// An opened photo: either a camera RAW file (decoded by Apple's RAW engine)
/// or a bitmap (JPEG, TIFF, HEIC, PNG…).
public final class PhotoSource {
    public static let rawExtensions: Set<String> = [
        "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "dng", "raf",
        "orf", "rw2", "pef", "srw", "3fr", "iiq", "erf", "mrw", "x3f",
    ]
    public static let bitmapExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "heic", "heif", "png"]
    public static var supportedExtensions: Set<String> { rawExtensions.union(bitmapExtensions) }

    public let url: URL
    public let isRAW: Bool
    /// Oriented pixel size at full resolution.
    public let fullSize: CGSize
    public let asShotTemperature: Double
    public let asShotTint: Double
    /// ImageIO properties of the original (EXIF, GPS, TIFF…).
    public let metadata: [String: Any]
    /// Exists only in memory (a fresh panorama); `url` is where it would be exported.
    public let isInMemory: Bool
    /// The camera's lens correction data, when the RAW file carries it.
    public private(set) var lensProfile: LensProfile?

    private var rawFilters: [Float: CIRAWFilter] = [:]
    /// Full-resolution bitmap, decoded on first use (zoom, export) — see `fullBitmap`.
    private var bitmap: CIImage?
    /// A preview-sized decode (long edge `previewLongEdge`), made straight from the file so
    /// opening a JPEG doesn't wait for the full decode.
    private var previewBitmap: CIImage?
    public static let previewLongEdge: CGFloat = 2560
    /// Downscaled copies of `bitmap`, so previews don't resample the full image every time.
    private var scaledBitmaps: [Double: CIImage] = [:]
    private static let scaler = CIContext(options: [.workingColorSpace: Renderer.linearSpace,
                                                    .workingFormat: CIFormat.RGBAh])
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        self.isInMemory = false
        let ext = url.pathExtension.lowercased()

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            metadata = props
        } else {
            metadata = [:]
        }

        if Self.rawExtensions.contains(ext), let raw = CIRAWFilter(imageURL: url), let out = raw.outputImage {
            isRAW = true
            bitmap = nil
            fullSize = out.extent.size
            asShotTemperature = Double(raw.neutralTemperature)
            asShotTint = Double(raw.neutralTint)
            raw.sharpnessAmount = 0
            rawFilters[1] = raw
            lensProfile = LensProfile.read(from: url)
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let w = metadata[kCGImagePropertyPixelWidth as String] as? Int,
                  let h = metadata[kCGImagePropertyPixelHeight as String] as? Int, w > 0, h > 0 {
            isRAW = false
            let o = metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
            fullSize = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            asShotTemperature = 0
            asShotTint = 0
            if max(w, h) > Int(Self.previewLongEdge) {
                // ImageIO decodes straight to a small size (JPEG DCT scaling), much faster than
                // a full decode + resample.
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(Self.previewLongEdge),
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    throw LitError.cannotOpen(url)
                }
                previewBitmap = CIImage(cgImage: cg)
            } else {
                bitmap = try Self.decodeFull(url, orientation: o)
            }
        } else {
            throw LitError.cannotOpen(url)
        }
    }

    /// Decodes the whole file once into memory. (CIImage(contentsOf:) decodes lazily per tile,
    /// which is pathologically slow for big compressed files like panoramas.)
    static func decodeFull(_ url: URL, orientation o: UInt32) throws -> CIImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LitError.cannotOpen(url) }
        let img = ciImage(from: cg).oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    /// The full-resolution bitmap, decoding it now if needed.
    private var fullBitmap: CIImage? {
        lock.lock(); defer { lock.unlock() }
        if bitmap == nil, !isRAW {
            let o = metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
            bitmap = try? Self.decodeFull(url, orientation: o)
        }
        return bitmap
    }

    /// Decodes the full-resolution image ahead of time (call off the main thread), so zooming
    /// in or exporting doesn't wait for it later.
    public func prefetchFullResolution() {
        if !isRAW { _ = fullBitmap }
    }

    /// Wraps an already-rendered image (e.g. a freshly stitched panorama).
    public init(image: CIImage, url: URL, metadata: [String: Any] = [:]) {
        self.url = url
        self.isRAW = false
        self.isInMemory = true
        let origin = image.extent.origin
        self.bitmap = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        self.fullSize = image.extent.size
        self.asShotTemperature = 0
        self.asShotTint = 0
        self.metadata = metadata
    }

    public var fileName: String { url.lastPathComponent }

    /// 35mm-equivalent focal length from EXIF, if known.
    public var focalLength35mm: Double? {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let f = exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double, f > 0 { return f }
        if let f = exif?[kCGImagePropertyExifFocalLength as String] as? Double, f > 0 { return f }
        return nil
    }

    /// Default adjustments for this photo (As Shot white balance).
    public var defaultAdjustments: Adjustments { Adjustments() }

    /// The decoded image with white balance applied, at `scale` × full resolution.
    /// Origin is always (0, 0). Values are scene-linear (may exceed 1 for RAW).
    /// RAW tint always stays as shot.
    public func whiteBalanced(temperature: Double?, scale: Double) -> CIImage {
        let scale = min(max(scale, 0.01), 1)
        if isRAW {
            lock.lock(); defer { lock.unlock() }
            let key = Float((scale * 1000).rounded() / 1000)
            let raw: CIRAWFilter
            if let cached = rawFilters[key] {
                raw = cached
            } else {
                guard let r = CIRAWFilter(imageURL: url) else { return CIImage.empty() }
                r.sharpnessAmount = 0
                r.scaleFactor = key
                rawFilters[key] = r
                raw = r
            }
            raw.neutralTemperature = Float(temperature ?? asShotTemperature)
            raw.neutralTint = Float(asShotTint)
            guard let out = raw.outputImage else { return CIImage.empty() }
            // The RAW engine may round the scaled size; normalise origin.
            return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        } else {
            let img: CIImage
            let long = Double(max(fullSize.width, fullSize.height))
            if let p = previewBitmap, scale * long <= Double(max(p.extent.width, p.extent.height)) + 0.5 {
                // The preview decode is enough; resample it if a smaller size is wanted.
                let k = scale * long / Double(max(p.extent.width, p.extent.height))
                img = k > 0.999 ? p : scaledBitmap(p, scale: k)
            } else {
                guard let full = fullBitmap else { return CIImage.empty() }
                img = scale < 0.999 ? scaledBitmap(full, scale: scale) : full
            }
            return Pipeline.whiteBalanceShift(img, temperature: temperature ?? 0)
        }
    }

    /// 8-bit images go straight to Core Image. Deeper ones (16-bit TIFFs, our panoramas) are
    /// converted once to half-float with vImage — Core Image otherwise converts them on the
    /// CPU on every render, which takes minutes for a large panorama.
    static func ciImage(from cg: CGImage) -> CIImage {
        guard cg.bitsPerComponent > 8,
              let format = vImage_CGImageFormat(
                  bitsPerComponent: 16, bitsPerPixel: 64, colorSpace: Renderer.linearSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                           | CGBitmapInfo.floatComponents.rawValue
                                           | CGBitmapInfo.byteOrder16Little.rawValue)),
              let buffer = try? vImage_Buffer(cgImage: cg, format: format) else {
            return CIImage(cgImage: cg)
        }
        let data = Data(bytesNoCopy: buffer.data, count: buffer.rowBytes * Int(buffer.height), deallocator: .free)
        return CIImage(bitmapData: data, bytesPerRow: buffer.rowBytes,
                       size: CGSize(width: Int(buffer.width), height: Int(buffer.height)),
                       format: .RGBAh, colorSpace: Renderer.linearSpace)
    }

    private func scaledBitmap(_ full: CIImage, scale: Double) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        let key = scale + (full === previewBitmap ? 10 : 0)   // separate cache entries per source
        if let cached = scaledBitmaps[key] { return cached }
        let scaled = full.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
        ])
        let e = scaled.extent.integral
        guard let cg = Self.scaler.createCGImage(scaled, from: e, format: .RGBAh, colorSpace: Renderer.linearSpace) else {
            return scaled
        }
        let img = CIImage(cgImage: cg)
        scaledBitmaps[key] = img
        return img
    }
}

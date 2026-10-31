import Foundation
import CoreGraphics

/// Adjustments applied locally inside a mask (gradient). All zero = no effect.
public struct LocalAdjustments: Codable, Equatable {
    public var exposure: Double = 0      // stops, -4...4
    public var contrast: Double = 0      // -100...100
    public var highlights: Double = 0    // -100...100
    public var shadows: Double = 0       // -100...100
    public var whites: Double = 0        // -100...100
    public var blacks: Double = 0        // -100...100
    public var temperature: Double = 0   // -100...100 (relative)
    public var saturation: Double = 0    // -100...100

    public init() {}

    public var isNeutral: Bool { self == LocalAdjustments() }
}

/// A linear graduated filter. Points are normalized to the image (0...1, top-left origin).
/// Full effect on the `start` side, fading to none at `end`.
public struct GradientMask: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var start: CGPoint
    public var end: CGPoint
    public var isEnabled = true
    public var local = LocalAdjustments()

    public init(start: CGPoint, end: CGPoint, local: LocalAdjustments = LocalAdjustments()) {
        self.start = start
        self.end = end
        self.local = local
    }
}

/// Everything the user can change about a photo. Stored as a JSON sidecar.
public struct Adjustments: Codable, Equatable {
    /// RAW: Kelvin as understood by the RAW engine. nil = As Shot.
    /// Bitmap (JPEG/TIFF): relative shift -100...100, nil = 0.
    /// (There is deliberately no tint control: the camera's green–magenta balance is kept.)
    public var temperature: Double?

    public var exposure: Double = 0      // stops, -5...5
    public var contrast: Double = 0      // -100...100
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0

    /// Per-colour hue / saturation / luminance (a small, fixed set of colours).
    public var color = ColorMix()

    /// Lens corrections: the camera's own profile plus manual fine-tuning.
    public var lens = LensSettings()

    /// Soft light spreading from bright areas, 0...100 (a style, off by default).
    public var glow: Double = 0

    public var sharpenAmount: Double = 25   // 0...150
    public var sharpenRadius: Double = 1.0  // 0.5...3 (px at full resolution)

    public var gradients: [GradientMask] = []

    /// nil = uncropped.
    public var crop: Crop?

    /// Healed dust specks.
    public var dust: [DustSpot] = []

    public init() {}

    /// Lenient decoding: fields missing from older saved edits keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Adjustments()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        temperature = get(.temperature, d.temperature)
        exposure = get(.exposure, d.exposure)
        contrast = get(.contrast, d.contrast)
        highlights = get(.highlights, d.highlights)
        shadows = get(.shadows, d.shadows)
        whites = get(.whites, d.whites)
        blacks = get(.blacks, d.blacks)
        vibrance = get(.vibrance, d.vibrance)
        saturation = get(.saturation, d.saturation)
        color = get(.color, d.color)
        lens = get(.lens, d.lens)
        glow = get(.glow, d.glow)
        sharpenAmount = get(.sharpenAmount, d.sharpenAmount)
        sharpenRadius = get(.sharpenRadius, d.sharpenRadius)
        gradients = get(.gradients, d.gradients)
        crop = get(.crop, d.crop)
        dust = get(.dust, d.dust)
    }
}

/// Lens corrections. The profile is the correction data the camera writes into the RAW file
/// (Sony ARW: vignetting, distortion and colour fringing), the same data the camera uses for
/// its own JPEGs. The sliders fine-tune on top, and work for any photo.
public struct LensSettings: Codable, Equatable {
    public var useProfile = true
    public var distortion: Double = 0   // -100...100, + corrects barrel (bulging) distortion
    public var vignetting: Double = 0   // -100...100, + brightens the corners

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useProfile = (try? c.decodeIfPresent(Bool.self, forKey: .useProfile)) ?? nil ?? true
        distortion = (try? c.decodeIfPresent(Double.self, forKey: .distortion)) ?? nil ?? 0
        vignetting = (try? c.decodeIfPresent(Double.self, forKey: .vignetting)) ?? nil ?? 0
    }
}

/// A healed dust speck: the area at `center` is replaced by texture copied from `source`,
/// matched in brightness and colour. Points are normalized to the image (top-left origin);
/// the radius is a fraction of the image width, capped at dust size on purpose.
public struct DustSpot: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var center: CGPoint
    public var source: CGPoint
    public var radius: Double

    /// Dust only: about 1.6 % of the width across at most (~125 px on a 42 MP photo).
    public static let maxRadius = 0.008
    public static let minRadius = 0.001

    public init(center: CGPoint, source: CGPoint, radius: Double) {
        self.center = center
        self.source = source
        self.radius = min(max(radius, Self.minRadius), Self.maxRadius)
    }
}

/// The colours the Color section can adjust. Deliberately few.
public enum ColorBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple

    public var id: Int { rawValue }
    public var name: String { String(describing: self).capitalized }
    /// Centre hue in degrees.
    public var hue: Double { [0, 30, 60, 120, 220, 285][rawValue] }
}

/// Hue / saturation / luminance shifts per `ColorBand`, each -100...100.
public struct ColorMix: Codable, Equatable {
    public var hue = [Double](repeating: 0, count: ColorBand.allCases.count)
    public var saturation = [Double](repeating: 0, count: ColorBand.allCases.count)
    public var luminance = [Double](repeating: 0, count: ColorBand.allCases.count)

    public init() {}

    public var isNeutral: Bool { self == ColorMix() }

    public func isNeutral(_ band: ColorBand) -> Bool {
        hue[band.rawValue] == 0 && saturation[band.rawValue] == 0 && luminance[band.rawValue] == 0
    }
}

/// A few crop shapes, named rather than numbered.
public enum CropAspect: String, Codable, CaseIterable, Identifiable {
    case free, original, square, social, wide, imax, pano

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "Square"
        case .social: return "Social"
        case .wide: return "Wide"
        case .imax: return "IMAX"
        case .pano: return "Pano"
        }
    }

    public var detail: String {
        switch self {
        case .free: return ""
        case .original: return "as shot"
        case .square: return "1:1"
        case .social: return "4:5"
        case .wide: return "16:9"
        case .imax: return "1.43:1"
        case .pano: return "3:1"
        }
    }

    /// Width / height in the shape's natural orientation (nil = unconstrained).
    public func ratio(imageSize: CGSize) -> Double? {
        switch self {
        case .free: return nil
        case .original: return Double(imageSize.width / imageSize.height)
        case .square: return 1
        case .social: return 4.0 / 5
        case .wide: return 16.0 / 9
        case .imax: return 1.43
        case .pano: return 3
        }
    }
}

/// Crop rectangle normalized to the image (0...1, top-left origin).
public struct Crop: Codable, Equatable {
    public var rect: CGRect
    public var aspect: CropAspect
    /// Turns the shape 90° (e.g. Wide 16:9 → 9:16).
    public var rotated: Bool
    /// Straighten angle in degrees, -45...45; positive turns the photo clockwise.
    public var angle: Double

    public init(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), aspect: CropAspect = .free,
                rotated: Bool = false, angle: Double = 0) {
        self.rect = rect
        self.aspect = aspect
        self.rotated = rotated
        self.angle = angle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decode(CGRect.self, forKey: .rect)
        aspect = (try? c.decodeIfPresent(CropAspect.self, forKey: .aspect)) ?? nil ?? .free
        rotated = (try? c.decodeIfPresent(Bool.self, forKey: .rotated)) ?? nil ?? false
        angle = (try? c.decodeIfPresent(Double.self, forKey: .angle)) ?? nil ?? 0
    }

    /// Whether `r` lies inside the photo after it's turned by `angle` degrees within `box`
    /// (all in the same uniformly scaled, top-left-origin space: pixels or view points).
    public static func fits(_ r: CGRect, in box: CGRect, angle: Double) -> Bool {
        if angle == 0 { return box.insetBy(dx: -0.5, dy: -0.5).contains(r) }
        let a = -angle * .pi / 180, ca = cos(a), sa = sin(a)
        let hw = Double(box.width) / 2 + 0.5, hh = Double(box.height) / 2 + 0.5
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] {
            let x = Double(p.x - box.midX), y = Double(p.y - box.midY)
            let qx = x * ca - y * sa, qy = x * sa + y * ca
            if abs(qx) > hw || abs(qy) > hh { return false }
        }
        return true
    }

    /// Shrinks `r` about its centre (keeping its shape) until it fits the turned photo.
    public static func shrunkToFit(_ r: CGRect, in box: CGRect, angle: Double) -> CGRect {
        if fits(r, in: box, angle: angle) { return r }
        func scaled(_ k: Double) -> CGRect {
            CGRect(x: Double(r.midX) - Double(r.width) * k / 2, y: Double(r.midY) - Double(r.height) * k / 2,
                   width: Double(r.width) * k, height: Double(r.height) * k)
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if fits(scaled(mid), in: box, angle: angle) { lo = mid } else { hi = mid }
        }
        return scaled(lo)
    }

    /// Width / height in pixels, or nil when free.
    public func ratio(imageSize: CGSize) -> Double? {
        guard let r = aspect.ratio(imageSize: imageSize) else { return nil }
        return rotated ? 1 / r : r
    }

    public var isFullFrame: Bool {
        angle == 0 && rect.minX <= 0.0005 && rect.minY <= 0.0005 && rect.maxX >= 0.9995 && rect.maxY >= 0.9995
    }

    /// The largest rectangle of `ratio` that fits the image, centred on `center` (normalized).
    public static func fitted(ratio: Double, imageSize: CGSize, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGRect {
        let imageRatio = Double(imageSize.width / imageSize.height)
        var w = 1.0, h = 1.0
        if ratio > imageRatio { h = imageRatio / ratio } else { w = ratio / imageRatio }
        let x = min(max(Double(center.x) - w / 2, 0), 1 - w)
        let y = min(max(Double(center.y) - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension Adjustments {
    /// The crop in pixels for an image of `size`, or nil when uncropped.
    public func cropPixels(in size: CGSize) -> CGRect? {
        guard let c = crop, !c.isFullFrame else { return nil }
        return CGRect(x: c.rect.minX * size.width, y: c.rect.minY * size.height,
                      width: c.rect.width * size.width, height: c.rect.height * size.height).integral
    }

    /// Output size after cropping.
    public func outputSize(for size: CGSize) -> CGSize {
        cropPixels(in: size)?.size ?? size
    }
}

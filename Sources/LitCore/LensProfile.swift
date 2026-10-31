import Foundation
import CoreImage

/// The lens correction data a Sony camera writes into each ARW: vignetting, distortion and
/// lateral chromatic aberration as radial splines (the same data the camera uses for its own
/// JPEGs). Apple's RAW engine doesn't apply it, so LIT does.
///
/// Encoding follows darktable's implementation (src/iop/lens.cc, "embedded metadata" v2):
/// `nc` knots at radius (i + 0.5) / (nc − 1) of the half-diagonal;
/// distortion scale = d·2⁻¹⁴ + 1, red/blue CA scale = c·2⁻²¹ + 1,
/// vignetting gain = 2^(0.5 − 2^(v·2⁻¹³ − 1)) (pixels are divided by it).
public struct LensProfile: Equatable {
    let distortion: [Double]
    let caRed: [Double]
    let caBlue: [Double]
    let vignetting: [Double]

    var count: Int { distortion.count }

    /// Reads the profile from a Sony ARW (tags 0x7032 / 0x7035 / 0x7037 in the raw SubIFD).
    public static func read(from url: URL) -> LensProfile? {
        guard ["arw", "sr2", "srf"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 else { return nil }
        let tiff = TIFFReader(data: data)
        guard let ifd0 = tiff.firstIFD, let subs = tiff.values(ifd0[0x14a]) else { return nil }
        for sub in subs {
            let t = tiff.ifd(at: sub)
            guard let d = tiff.values(t[0x7037]), let c = tiff.values(t[0x7035]), let v = tiff.values(t[0x7032]),
                  let nc = d.first, nc >= 2, nc <= 16,
                  d.count == nc + 1, c.count == 2 * nc + 1, v.count == nc + 1 else { continue }
            return LensProfile(distortion: d[1...].map { Double($0) * pow(2, -14) + 1 },
                               caRed: c[1...nc].map { Double($0) * pow(2, -21) + 1 },
                               caBlue: c[(nc + 1)...].map { Double($0) * pow(2, -21) + 1 },
                               vignetting: v[1...].map { pow(2, 0.5 - pow(2, Double($0) * pow(2, -13) - 1)) })
        }
        return nil
    }

    // MARK: Applying

    /// Corrects `img` (origin at its extent's corner) for the lens: the camera profile when
    /// given and enabled, plus manual distortion / vignetting.
    static func correct(_ img: CIImage, profile: LensProfile?, settings: LensSettings) -> CIImage {
        let use = settings.useProfile ? profile : nil
        let md = settings.distortion / 100, mv = settings.vignetting / 100
        guard use != nil || md != 0 || mv != 0 else { return img }

        // Knot values: (green/distortion, red, blue, vignetting gain).
        let n = use?.count ?? 16
        var knots: [[Double]] = []
        for i in 0..<n {
            let r = min(1, (Double(i) + 0.5) / Double(n - 1))
            var d = use?.distortion[i] ?? 1
            d *= 1 - 0.08 * md * r * r
            let red = d * (use?.caRed[i] ?? 1), blue = d * (use?.caBlue[i] ?? 1)
            var vig = use?.vignetting[i] ?? 1
            vig *= pow(2, -1.2 * mv * r * r)
            knots.append([d, red, blue, vig])
        }
        // Zoom so the corners never sample outside the photo, and the ROI bound for tiles.
        func value(_ ch: Int, at r: Double) -> Double {
            let x = min(max(r * Double(n - 1) - 0.5, 0), Double(n - 1))
            let i = min(Int(x), n - 2), f = x - Double(i)
            return knots[i][ch] * (1 - f) + knots[i + 1][ch] * f
        }
        var maxScale = 1.0, minScale = 1.0
        for k in 0...200 {
            let r = Double(k) / 200
            for ch in 0..<3 { let v = value(ch, at: r); maxScale = max(maxScale, v); minScale = min(minScale, v) }
        }
        let minRatio = minScale / maxScale

        // Lookup image, alpha kept at 1 (Core Image treats alpha as premultiplication):
        // row 0 = distortion scales (green, red, blue), row 1 = vignetting gain.
        var floats: [Float] = knots.flatMap { k -> [Float] in [Float(k[0]), Float(k[1]), Float(k[2]), 1] }
            + knots.flatMap { k -> [Float] in [Float(k[3]), Float(k[3]), Float(k[3]), 1] }
        let lut = CIImage(bitmapData: Data(bytes: &floats, count: floats.count * 4), bytesPerRow: n * 16,
                          size: CGSize(width: n, height: 2), format: .RGBAf, colorSpace: nil)
        let e = img.extent
        let c = CGPoint(x: e.midX, y: e.midY)
        let halfDiag = hypot(Double(e.width), Double(e.height)) / 2
        let roi: CIKernelROICallback = { index, r in
            guard index == 0 else { return lut.extent }
            // Samples lie between the destination point and the centre, no closer than minRatio.
            let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            var b = r
            for p in pts {
                b = b.union(CGRect(x: c.x + (p.x - c.x) * minRatio, y: c.y + (p.y - c.y) * minRatio, width: 0, height: 0))
            }
            return b.insetBy(dx: -3, dy: -3)
        }
        let out = Kernels.lens.apply(extent: e, roiCallback: roi, arguments: [
            img.clampedToExtent(), lut,
            CIVector(x: c.x, y: c.y, z: 1 / halfDiag, w: 1 / maxScale), CIVector(x: CGFloat(n), y: 0),
        ])
        return out?.cropped(to: e) ?? img
    }
}

/// Just enough TIFF parsing to reach a few tags.
private struct TIFFReader {
    let data: Data
    let little: Bool

    init(data: Data) {
        self.data = data
        little = data.prefix(2) == Data([0x49, 0x49])
    }

    func u16(_ o: Int) -> Int {
        guard o + 2 <= data.count else { return 0 }
        let a = Int(data[data.startIndex + o]), b = Int(data[data.startIndex + o + 1])
        return little ? a | b << 8 : a << 8 | b
    }
    func u32(_ o: Int) -> Int {
        little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)
    }

    struct Entry { let type: Int; let count: Int; let valueOffset: Int }

    var firstIFD: [Int: Entry]? {
        let o = u32(4)
        return o > 0 ? ifd(at: o) : nil
    }

    func ifd(at o: Int) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        let n = u16(o)
        guard n < 1000 else { return out }
        for i in 0..<n {
            let e = o + 2 + 12 * i
            out[u16(e)] = Entry(type: u16(e + 2), count: u32(e + 4), valueOffset: e + 8)
        }
        return out
    }

    /// Integer values of SHORT / SSHORT / LONG / SLONG / IFD entries.
    func values(_ entry: Entry?) -> [Int]? {
        guard let e = entry, e.count > 0, e.count < 4096 else { return nil }
        let size: Int
        switch e.type {
        case 3, 8: size = 2
        case 4, 9, 13: size = 4
        default: return nil
        }
        let start = size * e.count > 4 ? u32(e.valueOffset) : e.valueOffset
        guard start + size * e.count <= data.count else { return nil }
        return (0..<e.count).map { i in
            let o = start + i * size
            switch e.type {
            case 3: return u16(o)
            case 8: return Int(Int16(truncatingIfNeeded: u16(o)))
            case 9: return Int(Int32(truncatingIfNeeded: u32(o)))
            default: return u32(o)
            }
        }
    }
}

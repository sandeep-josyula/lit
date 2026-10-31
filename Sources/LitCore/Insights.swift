import Foundation

/// A gentle, static observation about the photo's tones, read from the preview histogram.
/// Experimental: these are hints, not rules. A silhouette or a high-key shot is fine as it is.
public struct Insight: Equatable, Identifiable {
    public enum Kind { case highlights, shadows, color, dark, bright, flat, balanced }
    public let kind: Kind
    public let text: String
    public var id: String { text }

    /// - Parameters:
    ///   - histogram: 256-bin R, G, B counts of the displayed (sRGB, 8-bit) preview.
    ///   - pixels: number of pixels in the preview.
    public static func from(histogram: [[UInt]], pixels: Int) -> [Insight] {
        guard histogram.count == 3, histogram.allSatisfy({ $0.count == 256 }), pixels > 0 else { return [] }
        let n = Double(pixels)
        let names = ["reds", "greens", "blues"]

        func frac(_ ch: Int, _ bins: ClosedRange<Int>) -> Double {
            Double(bins.reduce(0) { $0 + histogram[ch][$1] }) / n
        }
        func pct(_ f: Double) -> String { f < 0.01 ? "under 1%" : "about \(Int((f * 100).rounded()))%" }

        let clipHi = (0..<3).map { frac($0, 254...255) }
        let clipLo = (0..<3).map { frac($0, 0...1) }
        // Luminance histogram approximated from the channels.
        let w = [0.2126, 0.7152, 0.0722]
        var mean = 0.0
        var lum = [Double](repeating: 0, count: 256)
        for c in 0..<3 {
            for i in 0..<256 {
                let v = Double(histogram[c][i]) / n * w[c]
                lum[i] += v
                mean += v * Double(i) / 255
            }
        }
        func percentile(_ p: Double) -> Double {
            var acc = 0.0
            for i in 0..<256 { acc += lum[i]; if acc >= p { return Double(i) / 255 } }
            return 1
        }
        let p2 = percentile(0.02), p98 = percentile(0.98)

        var out: [Insight] = []
        let allHi = clipHi.min()!, anyHi = clipHi.max()!
        if allHi > 0.004 {
            out.append(Insight(kind: .highlights, text:
                "Some highlights look blown out (\(pct(allHi)) of the photo is pure white). Lowering Highlights or Whites may bring back detail."))
        } else if anyHi > 0.01, let c = clipHi.firstIndex(of: anyHi) {
            out.append(Insight(kind: .color, text:
                "Bright \(names[c]) are clipping in places. Easing Saturation or Vibrance a little may keep their texture."))
        }
        let allLo = clipLo.min()!
        if allLo > 0.02 {
            out.append(Insight(kind: .shadows, text:
                "Deep shadows are crushed to pure black (\(pct(allLo))). Lifting Shadows or Blacks may reveal more detail, if you want it."))
        }
        if out.isEmpty {
            if mean < 0.2 {
                out.append(Insight(kind: .dark, text: "The photo reads quite dark overall. A touch more Exposure or Shadows could help, unless that's the mood."))
            } else if mean > 0.72 {
                out.append(Insight(kind: .bright, text: "The photo reads very bright overall. A little less Exposure could add depth, unless you're going for high-key."))
            } else if p98 - p2 < 0.5 {
                out.append(Insight(kind: .flat, text: "Tones look a bit flat: no deep blacks or bright whites. A little Contrast, Whites or Blacks would add punch."))
            }
        }
        if out.isEmpty {
            out.append(Insight(kind: .balanced, text: "Tones look well balanced: nothing clipped, good range."))
        }
        return Array(out.prefix(2))
    }
}

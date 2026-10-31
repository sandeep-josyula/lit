import Foundation
import CoreImage
import Accelerate

/// Aligns two overlapping images with FFT phase correlation.
enum PhaseCorrelation {
    struct Gray {
        let w: Int
        let h: Int
        var v: [Float]   // gamma luminance, row 0 = top
        var m: [Float]   // validity (alpha)
    }

    /// Rigid transform (rotation + translation) taking `moving`'s CI coordinates into
    /// `reference`'s CI coordinates (both images with origin at 0,0).
    ///
    /// 1. Coarse translation over whole frames at ~384 px.
    /// 2. Refine on one central overlap patch.
    /// 3. Measure local shifts on a grid of textured patches across the overlap and fit
    ///    rotation + translation robustly — absorbs handheld roll and ignores sky.
    static func transform(of moving: CIImage, relativeTo reference: CIImage, horizontal: Bool,
                          context: CIContext) throws -> CGAffineTransform {
        let cs = 384 / Double(max(reference.extent.width, reference.extent.height))
        let a = gray(reference, scale: cs, context: context)
        let b = gray(moving, scale: cs, context: context)
        let coarse = try correlate(a, b, horizontal: horizontal, maxResidual: nil)
        debug("coarse", coarse.x / cs, coarse.y / cs)

        let A = gray(reference, scale: 1, context: context)
        let B = gray(moving, scale: 1, context: context)
        var t = (x: coarse.x / cs, y: coarse.y / cs)
        for _ in 0..<3 {
            guard let ov = overlap(A, B, t) else { break }
            var p = 512
            while p > 64 && (p > ov.width || p > ov.height) { p /= 2 }
            guard ov.width >= p, ov.height >= p else { break }
            let ax = ov.minX + (ov.width - p) / 2, ay = ov.minY + (ov.height - p) / 2
            let bx = ax - Int(t.x.rounded()), by = ay - Int(t.y.rounded())
            guard bx >= 0, by >= 0, bx + p <= B.w, by + p <= B.h else { break }
            guard let r = try? correlate(crop(A, x: ax, y: ay, w: p, h: p), crop(B, x: bx, y: by, w: p, h: p),
                                         horizontal: horizontal, maxResidual: 32) else { break }
            t = (Double(Int(t.x.rounded())) + r.x, Double(Int(t.y.rounded())) + r.y)
            debug("refine", r.x, r.y, "->", t.x, t.y)
            if abs(r.x) < 0.75 && abs(r.y) < 0.75 { break }
        }

        // Initial estimate: translation (array → CI coords).
        var T = CGAffineTransform(translationX: t.x, y: Double(A.h) - Double(B.h) - t.y)

        // Iterate: resample `moving` into the reference frame with the current estimate,
        // measure the small residual shifts on a grid of textured patches, refit.
        let bounds = CGRect(x: 0, y: 0, width: A.w, height: A.h)
        let p = 192, step = 96
        for iter in 0..<4 {
            let W = gray(moving.transformed(by: T), bounds: bounds, context: context)
            var q: [CGPoint] = [], d: [CGPoint] = []
            let inv = T.inverted()
            for y in stride(from: 0, through: A.h - p, by: step) {
                for x in stride(from: 0, through: A.w - p, by: step) {
                    let pw = crop(W, x: x, y: y, w: p, h: p)
                    guard isUsable(pw) else { continue }
                    let pa = crop(A, x: x, y: y, w: p, h: p)
                    guard isUsable(pa),
                          let r = try? correlate(pa, pw, horizontal: horizontal, maxResidual: iter == 0 ? 24 : 8),
                          r.peak > (iter == 0 ? 0.03 : 0.06) else { continue }
                    let cx = Double(x) + Double(p) / 2, cy = Double(y) + Double(p) / 2
                    q.append(CGPoint(x: cx, y: Double(A.h) - cy).applying(inv))
                    d.append(CGPoint(x: cx + r.x, y: Double(A.h) - (cy + r.y)))
                }
            }
            guard q.count >= 4, let fit = fitRigid(q, d) else {
                debug("iteration", iter, "only", q.count, "matches — keeping estimate")
                break
            }
            let moved = [CGPoint(x: 0, y: 0), CGPoint(x: B.w, y: B.h)]
                .map { hypot($0.applying(fit).x - $0.applying(T).x, $0.applying(fit).y - $0.applying(T).y) }.max()!
            T = fit
            debug("iteration", iter, "matches", q.count, "corner change px", moved)
            if moved < 0.3 { break }
        }
        return T
    }

    /// Overlap of B (placed at t, array coords) with A, in A's array coordinates.
    private static func overlap(_ A: Gray, _ B: Gray, _ t: (x: Double, y: Double)) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
        let x0 = max(0, Int(t.x.rounded())), x1 = min(A.w, Int(t.x.rounded()) + B.w)
        let y0 = max(0, Int(t.y.rounded())), y1 = min(A.h, Int(t.y.rounded()) + B.h)
        guard x1 - x0 > 32, y1 - y0 > 32 else { return nil }
        return (x0, y0, x1, y1, x1 - x0, y1 - y0)
    }

    /// Enough valid pixels and texture to correlate reliably (rejects sky, black borders).
    private static func isUsable(_ g: Gray) -> Bool {
        var n: Float = 0, s: Float = 0, s2: Float = 0
        for i in 0..<(g.w * g.h) where g.m[i] > 0 { n += 1; s += g.v[i]; s2 += g.v[i] * g.v[i] }
        guard n > Float(g.w * g.h) * 0.9 else { return false }
        let mean = s / n
        return (s2 / n - mean * mean).squareRoot() > 0.035
    }

    /// Least-squares rotation + translation mapping q → d, with outlier rejection.
    static func fitRigid(_ q: [CGPoint], _ d: [CGPoint]) -> CGAffineTransform? {
        var keep = Array(q.indices)
        var result: CGAffineTransform?
        for pass in 0..<4 {
            guard keep.count >= 3 else { break }
            let n = Double(keep.count)
            let qx = keep.map { Double(q[$0].x) }.reduce(0, +) / n, qy = keep.map { Double(q[$0].y) }.reduce(0, +) / n
            let dx = keep.map { Double(d[$0].x) }.reduce(0, +) / n, dy = keep.map { Double(d[$0].y) }.reduce(0, +) / n
            var sc = 0.0, ss = 0.0
            for i in keep {
                let ax = Double(q[i].x) - qx, ay = Double(q[i].y) - qy
                let bx = Double(d[i].x) - dx, by = Double(d[i].y) - dy
                sc += ax * bx + ay * by
                ss += ax * by - ay * bx
            }
            let theta = atan2(ss, sc)
            let c = cos(theta), s = sin(theta)
            let T = CGAffineTransform(a: c, b: s, c: -s, d: c, tx: dx - (c * qx - s * qy), ty: dy - (s * qx + c * qy))
            result = T
            let res = q.indices.map { i -> Double in
                let m = q[i].applying(T)
                return hypot(Double(m.x - d[i].x), Double(m.y - d[i].y))
            }
            let sorted = keep.map { res[$0] }.sorted()
            let median = sorted[sorted.count / 2]
            debug("fit pass", pass, "matches", keep.count, "rotation°", theta * 180 / .pi,
                  "median residual", median, "t", T.tx, T.ty)
            let limit = max(1.0, median * 2.5)
            let next = q.indices.filter { res[$0] <= limit }
            if next == keep { break }
            keep = next
        }
        return result
    }

    static func debug(_ items: Any...) {
        if ProcessInfo.processInfo.environment["LIT_DEBUG"] != nil {
            print("[pc]", items.map { "\($0)" }.joined(separator: " "))
        }
    }

    // MARK: -

    /// Renders `img` over exactly `bounds` (pixels outside the image are invalid).
    static func gray(_ img: CIImage, bounds: CGRect, context: CIContext) -> Gray {
        render(img, bounds, context: context)
    }

    static func gray(_ img: CIImage, scale: Double, context: CIContext) -> Gray {
        var src = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if scale < 0.999 {
            src = src.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
            ])
        }
        return render(src, CGRect(x: 0, y: 0, width: floor(src.extent.width), height: floor(src.extent.height)),
                      context: context)
    }

    private static func render(_ src: CIImage, _ e: CGRect, context: CIContext) -> Gray {
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(src, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf,
                       colorSpace: Renderer.linearSpace)
        var v = [Float](repeating: 0, count: w * h)
        var m = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = px[i * 4 + 3]
            if a > 0.98 {
                let y = (0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2]) / a
                v[i] = powf(max(y, 0), 1 / 2.2)
                m[i] = 1
            }
        }
        // Core Image renders bottom row first; flip so row 0 is the top.
        if renderIsBottomUp {
            v = flipRows(v, w: w, h: h)
            m = flipRows(m, w: w, h: h)
        }
        return Gray(w: w, h: h, v: v, m: m)
    }

    /// Determined once: does `render(toBitmap:)` put the image's bottom row first?
    static let renderIsBottomUp: Bool = {
        let ctx = CIContext()
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 2)))
        var px = [Float](repeating: 0, count: 8)
        ctx.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 2),
                   format: .RGBAf, colorSpace: nil)
        return px[0] > 0.5   // white is at CI y=0 (bottom)
    }()

    static func flipRows(_ a: [Float], w: Int, h: Int) -> [Float] {
        var out = a
        for y in 0..<h {
            out.replaceSubrange((y * w)..<((y + 1) * w), with: a[((h - 1 - y) * w)..<((h - y) * w)])
        }
        return out
    }

    static func crop(_ g: Gray, x: Int, y: Int, w: Int, h: Int) -> Gray {
        var v = [Float](repeating: 0, count: w * h), m = v
        for r in 0..<h {
            let s = (y + r) * g.w + x
            v.replaceSubrange((r * w)..<((r + 1) * w), with: g.v[s..<(s + w)])
            m.replaceSubrange((r * w)..<((r + 1) * w), with: g.m[s..<(s + w)])
        }
        return Gray(w: w, h: h, v: v, m: m)
    }

    /// Returns t such that b's pixel (x, y) shows a's content at (x + t.x, y + t.y).
    static func correlate(_ a: Gray, _ b: Gray, horizontal: Bool, maxResidual: Double?) throws -> (x: Double, y: Double, peak: Float) {
        var nw = 1, nh = 1
        while nw < a.w + b.w { nw <<= 1 }
        while nh < a.h + b.h { nh <<= 1 }
        let lw = vDSP_Length(log2(Double(nw))), lh = vDSP_Length(log2(Double(nh)))
        guard let setup = vDSP_create_fftsetup(max(lw, lh), FFTRadix(kFFTRadix2)) else {
            throw LitError.panorama("FFT setup failed.")
        }
        defer { vDSP_destroy_fftsetup(setup) }

        func prepared(_ g: Gray) -> [Float] {
            // Mean-subtract valid pixels, taper edges (Tukey window), zero-pad.
            var sum: Float = 0, cnt: Float = 0
            for i in 0..<(g.w * g.h) where g.m[i] > 0 { sum += g.v[i]; cnt += 1 }
            let mean = cnt > 0 ? sum / cnt : 0
            var out = [Float](repeating: 0, count: nw * nh)
            let bx = max(1, g.w / 8), by = max(1, g.h / 8)
            func taper(_ i: Int, _ n: Int, _ band: Int) -> Float {
                let d = min(i, n - 1 - i)
                return d >= band ? 1 : 0.5 - 0.5 * cosf(Float.pi * Float(d) / Float(band))
            }
            for y in 0..<g.h {
                let ty = taper(y, g.h, by)
                for x in 0..<g.w {
                    let i = y * g.w + x
                    out[y * nw + x] = (g.v[i] - mean) * g.m[i] * ty * taper(x, g.w, bx)
                }
            }
            return out
        }

        var ar = prepared(a), ai = [Float](repeating: 0, count: nw * nh)
        var br = prepared(b), bi = [Float](repeating: 0, count: nw * nh)
        let n = nw * nh

        ar.withUnsafeMutableBufferPointer { arp in ai.withUnsafeMutableBufferPointer { aip in
        br.withUnsafeMutableBufferPointer { brp in bi.withUnsafeMutableBufferPointer { bip in
            var A = DSPSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!)
            var B = DSPSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
            vDSP_fft2d_zip(setup, &A, 1, 0, lw, lh, FFTDirection(kFFTDirection_Forward))
            vDSP_fft2d_zip(setup, &B, 1, 0, lw, lh, FFTDirection(kFFTDirection_Forward))
            // R = A * conj(B) / |A * conj(B)|  (stored back in A)
            for k in 0..<n {
                let re = arp[k] * brp[k] + aip[k] * bip[k]
                let im = aip[k] * brp[k] - arp[k] * bip[k]
                let mag = sqrtf(re * re + im * im) + 1e-9
                arp[k] = re / mag
                aip[k] = im / mag
            }
            vDSP_fft2d_zip(setup, &A, 1, 0, lw, lh, FFTDirection(kFFTDirection_Inverse))
        }}}}

        // Peak search within the plausible region.
        var best: Float = -.greatestFiniteMagnitude, bx = 0, by = 0
        for y in 0..<nh {
            let dy = y > nh / 2 ? y - nh : y
            for x in 0..<nw {
                let dx = x > nw / 2 ? x - nw : x
                if let r = maxResidual {
                    if Double(abs(dx)) > r || Double(abs(dy)) > r { continue }
                } else if horizontal {
                    if abs(dx) < a.w / 20 || abs(dx) > a.w * 97 / 100 || abs(dy) > a.h * 35 / 100 { continue }
                } else {
                    if abs(dy) < a.h / 20 || abs(dy) > a.h * 97 / 100 || abs(dx) > a.w * 35 / 100 { continue }
                }
                let v = ar[y * nw + x]
                if v > best { best = v; bx = x; by = y }
            }
        }
        guard best > -.greatestFiniteMagnitude else { throw LitError.panorama("Couldn't find overlap between frames.") }

        // Sub-pixel parabolic refinement.
        func at(_ x: Int, _ y: Int) -> Float { ar[((y + nh) % nh) * nw + ((x + nw) % nw)] }
        func parabola(_ l: Float, _ c: Float, _ r: Float) -> Double {
            let d = l - 2 * c + r
            return abs(d) < 1e-9 ? 0 : Double(0.5 * (l - r) / d)
        }
        let sx = parabola(at(bx - 1, by), at(bx, by), at(bx + 1, by))
        let sy = parabola(at(bx, by - 1), at(bx, by), at(bx, by + 1))
        let dx = Double(bx > nw / 2 ? bx - nw : bx) + max(-0.5, min(0.5, sx))
        let dy = Double(by > nh / 2 ? by - nh : by) + max(-0.5, min(0.5, sy))
        return (dx, dy, best / Float(n))
    }
}

import Foundation
import CoreImage

/// The develop pipeline. Order (roughly Camera Raw's):
/// white balance → exposure → tone (highlights/shadows/whites/blacks/contrast)
/// → vibrance/saturation → gradient masks → sharpening.
public enum Pipeline {
    /// - Parameters:
    ///   - base: white-balanced, scene-linear image (see `PhotoSource.whiteBalanced`).
    ///   - scale: render scale relative to full resolution (sizes radii).
    ///   - guide: optional low-res copy of `base` (any scale, same framing). When rendering only
    ///     part of a big image, it supplies the regional luminance for highlights/shadows so the
    ///     whole full-res image needn't be decoded.
    public static func develop(_ base: CIImage, _ adj: Adjustments, scale: Double, guide: CIImage? = nil) -> CIImage {
        let extent = base.extent
        var img = base
        var small = guide

        if adj.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj.exposure])
            small = small?.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj.exposure])
        }

        let glowSource = img
        img = tone(img, highlights: adj.highlights, shadows: adj.shadows, whites: adj.whites,
                   blacks: adj.blacks, contrast: adj.contrast, local: true, guide: small)

        if adj.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": adj.vibrance / 100])
        }
        if adj.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + adj.saturation / 100,
                kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
            ])
        }

        if !adj.color.isNeutral {
            img = colorMix(img, adj.color)
        }

        for g in adj.gradients where g.isEnabled && !g.local.isNeutral {
            let adjusted = applyLocal(g.local, to: img)
            let mask = gradientMask(g, extent: extent)
            img = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask,
            ])
        }

        if adj.glow > 0 {
            img = glow(img, amount: adj.glow / 100, source: small ?? glowSource)
        }

        if adj.sharpenAmount > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adj.sharpenAmount / 100,
                kCIInputRadiusKey: max(adj.sharpenRadius * scale * 1.5, 0.25),
            ])
        }

        return img.cropped(to: extent)
    }

    /// Geometry, applied to the white-balanced base before developing: lens corrections, then
    /// straightening. Masks and crops are positioned on the result.
    public static func prepare(_ base: CIImage, _ adj: Adjustments, profile: LensProfile?) -> CIImage {
        var img = LensProfile.correct(base, profile: profile, settings: adj.lens)
        if let angle = adj.crop?.angle, angle != 0 {
            let e = img.extent
            let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                .rotated(by: -angle * .pi / 180)
                .translatedBy(x: -e.midX, y: -e.midY)
            img = img.clampedToExtent().transformed(by: t).cropped(to: e)
        }
        return healDust(img, adj.dust)
    }

    /// Heals dust specks by copying nearby texture (never generating any): each speck is
    /// replaced with the patch at its source, scaled so the two surroundings match, and
    /// feathered in.
    static func healDust(_ input: CIImage, _ spots: [DustSpot]) -> CIImage {
        var img = input
        let e = input.extent
        for s in spots {
            let c = CGPoint(x: e.minX + s.center.x * e.width, y: e.maxY - s.center.y * e.height)
            let src = CGPoint(x: e.minX + s.source.x * e.width, y: e.maxY - s.source.y * e.height)
            let r = max(s.radius * e.width, 0.75)
            let o = CIVector(x: src.x - c.x, y: src.y - c.y)
            let p = CIVector(x: c.x, y: c.y, z: r)
            // Tiles that touch the speck read its ring, the source patch and the source's ring;
            // every other tile only passes its own pixels through. (Asking for the rings
            // everywhere makes far-away tiles request huge regions.)
            let disk = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let roi: CIKernelROICallback = { _, rect in
                guard rect.intersects(disk) else { return rect }
                let ring = CGRect(x: c.x - r * 1.7, y: c.y - r * 1.7, width: r * 3.4, height: r * 3.4)
                return rect.union(ring).union(ring.offsetBy(dx: o.x, dy: o.y)).insetBy(dx: -2, dy: -2)
            }
            guard let healed = Kernels.dustHeal.apply(extent: e, roiCallback: roi,
                                                      arguments: [img.clampedToExtent(), p, o]) else { continue }
            img = healed
        }
        return img
    }

    /// The "find dust" view of a rendered image: dark marks where local contrast is high.
    public static func dustView(_ img: CIImage, sensitivity: Double) -> CIImage {
        let e = img.extent
        let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: e)
        return Kernels.dustView.apply(extent: e, arguments: [img, blurred, Float(3 + sensitivity * 30)]) ?? img
    }

    /// Glow: the bright parts, blurred wide at low resolution, added back softly.
    /// `source` is the exposure-adjusted image (or a small copy of it) the light comes from.
    static func glow(_ img: CIImage, amount: Double, source: CIImage) -> CIImage {
        let e = img.extent, ge = source.extent
        let s = min(1, 512 / max(ge.width, ge.height))
        let small = source.transformed(by: CGAffineTransform(translationX: -ge.minX, y: -ge.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let se = small.extent
        guard let bright = Kernels.glowPass.apply(extent: se, arguments: [small]) else { return img }
        let near = bright.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: se)
        let far = bright.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: se)
        guard let light = Kernels.addScaled.apply(extent: se, arguments: [near, far, 1.0]) else { return img }
        let up = light.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: e.width / se.width, y: e.height / se.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
        return Kernels.addScaled.apply(extent: e, arguments: [img, up, Float(amount * 0.6)]) ?? img
    }

    /// Paints clipped highlights red and clipped shadows blue.
    public static func clippingWarning(_ img: CIImage, highlights: Bool, shadows: Bool) -> CIImage {
        guard highlights || shadows else { return img }
        return Kernels.clipping.apply(extent: img.extent, arguments: [img, Float(highlights ? 1 : 0), Float(shadows ? 1 : 0)]) ?? img
    }

    static func colorMix(_ img: CIImage, _ m: ColorMix) -> CIImage {
        func pack(_ v: [Double]) -> (CIVector, CIVector) {
            (CIVector(x: v[0] / 100, y: v[1] / 100, z: v[2] / 100, w: v[3] / 100), CIVector(x: v[4] / 100, y: v[5] / 100))
        }
        let (h0, h1) = pack(m.hue), (s0, s1) = pack(m.saturation), (l0, l1) = pack(m.luminance)
        return Kernels.colorMix.apply(extent: img.extent, arguments: [img, h0, h1, s0, s1, l0, l1]) ?? img
    }

    /// Crops a developed image (origin at `extent`'s corner) to the adjustments' crop.
    public static func crop(_ img: CIImage, _ adj: Adjustments) -> CIImage {
        let e = img.extent
        guard let c = adj.crop, !c.isFullFrame else { return img }
        let r = CGRect(x: e.minX + c.rect.minX * e.width, y: e.maxY - c.rect.maxY * e.height,
                       width: c.rect.width * e.width, height: c.rect.height * e.height).integral
        return img.cropped(to: r.intersection(e))
    }

    /// The full-effect → no-effect ramp for a gradient, in the image's CI coordinates.
    public static func gradientMask(_ g: GradientMask, extent: CGRect) -> CIImage {
        func ci(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
        }
        return CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": ci(g.start), "inputPoint1": ci(g.end),
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: extent)
    }

    static func applyLocal(_ l: LocalAdjustments, to input: CIImage) -> CIImage {
        var img = input
        if l.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: l.exposure])
        }
        if l.temperature != 0 {
            img = whiteBalanceShift(img, temperature: l.temperature)
        }
        img = tone(img, highlights: l.highlights, shadows: l.shadows, whites: l.whites,
                   blacks: l.blacks, contrast: l.contrast, local: false)
        if l.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + l.saturation / 100,
                kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
            ])
        }
        return img
    }

    static func tone(_ img: CIImage, highlights: Double, shadows: Double, whites: Double,
                     blacks: Double, contrast: Double, local: Bool, guide: CIImage? = nil) -> CIImage {
        if highlights == 0, shadows == 0, whites == 0, blacks == 0, contrast == 0 { return img }
        let base = (local && (highlights != 0 || shadows != 0)) ? smoothedLuminanceBase(img, guide: guide) : img
        let out = Kernels.tone.apply(extent: img.extent, arguments: [
            img, base,
            Float(highlights / 100), Float(shadows / 100), Float(whites / 100),
            Float(blacks / 100), Float(contrast / 100),
        ])
        return out ?? img
    }

    /// An edge-aware blurred copy of the image: drives highlights/shadows so they act
    /// on regions rather than pixels (local tone mapping) without big halos.
    static func smoothedLuminanceBase(_ img: CIImage, guide: CIImage? = nil) -> CIImage {
        let e = img.extent
        let src = guide ?? img
        let ge = src.extent
        let s = min(1, 320 / max(ge.width, ge.height))
        var small = src.transformed(by: CGAffineTransform(translationX: -ge.minX, y: -ge.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let smallExtent = small.extent
        small = small.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: smallExtent)
        let up = img.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": small, "inputSpatialSigma": 3.0, "inputLumaSigma": 0.15,
        ])
        return up.cropped(to: e)
    }

    /// Relative white balance for bitmaps and masks, -100...100. Positive = warmer.
    public static func whiteBalanceShift(_ img: CIImage, temperature: Double) -> CIImage {
        if temperature == 0 { return img }
        let target = 6500 * pow(2, -temperature / 100 * 0.9)
        return img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: target, y: 0),
        ])
    }
}

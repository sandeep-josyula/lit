import CoreImage

/// Small GPU kernels written in the Core Image Kernel Language.
/// (CIKL is deprecated in favour of Metal kernels but still fully supported,
/// and keeps the package buildable with plain `swift build`.)
enum Kernels {
    /// Tone: exposure-style highlights/shadows driven by a smoothed (local) luminance
    /// `b`, then whites / blacks / contrast as a curve on the pixel's own luminance.
    /// Colour is preserved by scaling RGB by the luminance ratio.
    /// All amounts are -1...1.
    static let tone = CIColorKernel(source: """
    kernel vec4 litTone(__sample s, __sample b, float hi, float sh, float wh, float bl, float con)
    {
        vec3 c = max(s.rgb, vec3(0.0));
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float L  = dot(c, w);
        float Lb = max(dot(b.rgb, w), 0.0);

        float pb = pow(Lb, 1.0 / 2.2);
        float ws = 1.0 - smoothstep(0.0, 0.6, pb);
        ws = ws * ws;
        float wh2 = smoothstep(0.35, 1.0, pb);
        float stops = sh * 1.8 * ws + hi * 1.6 * wh2;

        float p = pow(max(L * exp2(stops), 0.0), 1.0 / 2.2);

        p = p + wh * 0.30 * p * p * p;
        float q = clamp(1.0 - p, 0.0, 1.0);
        p = p + bl * 0.20 * q * q * q;

        float pc = clamp(p, 0.0, 1.0);
        float sc = pc * pc * (3.0 - 2.0 * pc);
        p = (con >= 0.0) ? p + (sc - pc) * con
                         : mix(p, 0.46 + (p - 0.46) * 0.55, -con);

        p = max(p, 0.0);
        float Ln = pow(p, 2.2);
        vec3 o = (L > 1e-6) ? c * (Ln / L) : vec3(Ln);
        return vec4(o, s.a);
    }
    """)!

    /// Per-colour hue / saturation / luminance. Six bands with tent-shaped weights centred on
    /// 0, 30, 60, 120, 220 and 285 degrees (they sum to 1 around the hue circle). Effects fade
    /// out on near-neutral pixels so greys and skin-neutral whites stay put.
    /// Arguments are per-band amounts in -1...1 (bands 0–3 in the vec4, 4–5 in the vec2).
    static let colorMix = CIColorKernel(source: """
    vec3 litRgb2hsv(vec3 c)
    {
        vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
        vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
    }
    vec3 litHsv2rgb(vec3 c)
    {
        vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }
    float litWrap(float d) { return d - 360.0 * floor((d + 180.0) / 360.0); }
    float litTent(float h, float prev, float c, float next)
    {
        float d = litWrap(h - c);
        float left = litWrap(c - prev); left = left <= 0.0 ? left + 360.0 : left;
        float right = litWrap(next - c); right = right <= 0.0 ? right + 360.0 : right;
        return d < 0.0 ? max(0.0, 1.0 + d / left) : max(0.0, 1.0 - d / right);
    }
    kernel vec4 litColorMix(__sample s, vec4 h0, vec2 h1, vec4 s0, vec2 s1, vec4 l0, vec2 l1)
    {
        vec3 c = max(s.rgb, vec3(0.0));
        vec3 g = pow(c, vec3(1.0 / 2.2));
        vec3 hsv = litRgb2hsv(g);
        float h = hsv.x * 360.0;
        float w0 = litTent(h, 285.0, 0.0, 30.0);
        float w1 = litTent(h, 0.0, 30.0, 60.0);
        float w2 = litTent(h, 30.0, 60.0, 120.0);
        float w3 = litTent(h, 60.0, 120.0, 220.0);
        float w4 = litTent(h, 120.0, 220.0, 285.0);
        float w5 = litTent(h, 220.0, 285.0, 360.0);
        vec4 wa = vec4(w0, w1, w2, w3);
        vec2 wb = vec2(w4, w5);
        float amount = smoothstep(0.04, 0.22, hsv.y);
        float dh = (dot(wa, h0) + dot(wb, h1)) * amount;
        float ds = (dot(wa, s0) + dot(wb, s1)) * amount;
        float dl = (dot(wa, l0) + dot(wb, l1)) * amount;
        hsv.x = fract(hsv.x + dh * 30.0 / 360.0 + 1.0);
        hsv.y = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
        vec3 o = pow(max(litHsv2rgb(hsv), vec3(0.0)), vec3(2.2)) * exp2(dl * 0.8);
        return vec4(o, s.a);
    }
    """)!

    /// Cylindrical projection. Maps a destination coordinate to the source image.
    /// (cx, cy) source centre, f focal length in px, (ox, oy) output centre.
    static let cylindrical = CIWarpKernel(source: """
    kernel vec2 litCylinder(float cx, float cy, float f, float ox, float oy)
    {
        vec2 d = destCoord();
        float th = (d.x - ox) / f;
        float h  = (d.y - oy) / f;
        return vec2(f * tan(th) + cx, h * f / cos(th) + cy);
    }
    """)!

    /// Flat (rectilinear) view of a cylindrical mosaic: maps a destination point on the plane
    /// back to the cylinder. (cx, cy) is the point the plane faces, f the focal length in px.
    static let rectilinear = CIWarpKernel(source: """
    kernel vec2 litRectilinear(float cx, float cy, float f)
    {
        vec2 d = destCoord();
        float X = d.x - cx;
        float th = atan(X / f);
        return vec2(f * th + cx, (d.y - cy) * cos(th) + cy);
    }
    """)!

    /// Multiplies a panorama frame by a feathered "hat" weight (r = frame rect, sharp = exponent).
    /// Output is premultiplied colour * weight with the weight in alpha.
    static let panoWeight = CIColorKernel(source: """
    kernel vec4 litPanoWeight(__sample s, vec4 r, float sharp)
    {
        vec2 d = destCoord();
        float wx = clamp(1.0 - abs(d.x - (r.x + 0.5 * r.z)) / (0.5 * r.z), 0.0, 1.0);
        float wy = clamp(1.0 - abs(d.y - (r.y + 0.5 * r.w)) / (0.5 * r.w), 0.0, 1.0);
        float k = max(pow(wx, sharp) * pow(wy, sharp), 1e-30);
        float a = (s.a > 0.98) ? 1.0 : 0.0;
        return vec4(s.rgb / max(s.a, 1e-6), 1.0) * (k * a);
    }
    """)!

    /// Lens correction: distortion and red/blue fringing as per-channel radial scales, and
    /// vignetting as a radial gain — read from a 2-pixel-high lookup (`LensProfile`).
    /// geo = (centre x, centre y, 1 / half-diagonal, 1 / zoom), info.x = knot count.
    static let lens = CIKernel(source: """
    kernel vec4 litLens(sampler src, sampler lut, vec4 geo, vec2 info)
    {
        vec2 c = geo.xy;
        vec2 v = (destCoord() - c) * geo.w;
        float n = info.x;
        float r = length(v) * geo.z;
        // Bitmap row 0 sits at the top (y 1–2 in Core Image's y-up space), row 1 below it.
        vec4 k = sample(lut, samplerTransform(lut, vec2(clamp(r * (n - 1.0) - 0.5, 0.0, n - 1.0) + 0.5, 1.5)));
        vec4 g = sample(src, samplerTransform(src, c + v * k.r));
        vec4 rr = sample(src, samplerTransform(src, c + v * k.g));
        vec4 bb = sample(src, samplerTransform(src, c + v * k.b));
        float rs = r * k.r;
        float vig = sample(lut, samplerTransform(lut, vec2(clamp(rs * (n - 1.0) - 0.5, 0.0, n - 1.0) + 0.5, 0.5))).r;
        return vec4(vec3(rr.r, g.g, bb.b) / max(vig, 1e-4), g.a);
    }
    """)!

    /// The bright part of an image, for Glow: a soft knee from mid-tones up.
    static let glowPass = CIColorKernel(source: """
    kernel vec4 litGlowPass(__sample s)
    {
        vec3 c = max(s.rgb, vec3(0.0));
        float L = dot(c, vec3(0.2126, 0.7152, 0.0722));
        return vec4(c * smoothstep(0.12, 0.9, L), 1.0);
    }
    """)!

    /// a + b · k (colour only).
    static let addScaled = CIColorKernel(source: """
    kernel vec4 litAddScaled(__sample a, __sample b, float k) { return vec4(a.rgb + b.rgb * k, a.a); }
    """)!

    /// Clipping warning: pure-white areas red, pure-black areas blue.
    static let clipping = CIColorKernel(source: """
    kernel vec4 litClipping(__sample s, float hi, float lo)
    {
        float mx = max(max(s.r, s.g), s.b);
        if (hi > 0.5 && mx >= 0.996) return vec4(1.0, 0.05, 0.05, 1.0);
        if (lo > 0.5 && mx <= 0.0004) return vec4(0.1, 0.35, 1.0, 1.0);
        return s;
    }
    """)!

    /// Dust healing in one pass. Pixels inside the speck (p = centre x, centre y, radius) are
    /// replaced by the texture at the source (offset o = source − centre), scaled so the two
    /// surroundings match: both rings (1.2–1.6 × radius) are sampled at 32 points each.
    static let dustHeal = CIKernel(source: """
    kernel vec4 litDustHeal(sampler img, vec3 p, vec2 o)
    {
        vec2 d = destCoord();
        vec4 here = sample(img, samplerCoord(img));
        float w = 1.0 - smoothstep(p.z * 0.6, p.z, distance(d, p.xy));
        if (w <= 0.0) return here;
        vec3 aDst = vec3(0.0);
        vec3 aSrc = vec3(0.0);
        for (int i = 0; i < 16; i++) {
            float a = float(i) * 0.392699;
            vec2 u = vec2(cos(a), sin(a));
            for (int j = 0; j < 2; j++) {
                vec2 q = p.xy + u * p.z * (1.2 + 0.4 * float(j));
                aDst += max(sample(img, samplerTransform(img, q)).rgb, vec3(0.0));
                aSrc += max(sample(img, samplerTransform(img, q + o)).rgb, vec3(0.0));
            }
        }
        vec3 gain = clamp(aDst / max(aSrc, vec3(1e-5)), vec3(0.33), vec3(3.0));
        vec3 src = sample(img, samplerTransform(img, d + o)).rgb;
        return vec4(mix(here.rgb, src * gain, w), here.a);
    }
    """)!

    /// "Find dust" view: local contrast as dark marks on white, so specks stand out in skies.
    static let dustView = CIColorKernel(source: """
    kernel vec4 litDustView(__sample s, __sample b, float gain)
    {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float L = pow(max(dot(s.rgb, w), 0.0), 1.0 / 2.2);
        float B = pow(max(dot(b.rgb, w), 0.0), 1.0 / 2.2);
        float v = 1.0 - clamp(abs(L - B) * gain, 0.0, 1.0);
        return vec4(v, v, v, 1.0);
    }
    """)!

    static let add = CIColorKernel(source: """
    kernel vec4 litAdd(__sample a, __sample b) { return a + b; }
    """)!

    /// Divides accumulated colour by accumulated weight. (Weights can be tiny — the stitcher
    /// renders in 32-bit float, so keep these thresholds far below the weight floor.)
    static let normalize = CIColorKernel(source: """
    kernel vec4 litNormalize(__sample s)
    {
        return (s.a > 1e-33) ? vec4(s.rgb / s.a, 1.0) : vec4(0.0);
    }
    """)!
}

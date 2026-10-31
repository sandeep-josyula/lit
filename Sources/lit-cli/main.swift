import Foundation
import CoreImage
import ImageIO
import LitCore

// Headless tool for testing the pipeline.
//   lit-cli info <photo>
//   lit-cli render <photo> <out.jpg> [adjustments.json]
//   lit-cli pano <out.jpg> <rows> <photo>...
//   lit-cli split <image> <outdir> <count> <overlap 0-1> [rows]   (make synthetic pano frames)

let args = CommandLine.arguments
func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }
guard args.count >= 2 else { fail("usage: lit-cli info|render|pano|split …") }

let tLaunch = Date()
let renderer = Renderer()

switch args[1] {
case "info":
    let s = try PhotoSource(url: URL(fileURLWithPath: args[2]))
    print("raw:", s.isRAW, "size:", s.fullSize, "asShot:", s.asShotTemperature,
          "focal35:", s.focalLength35mm ?? -1, "lens profile:", s.lensProfile != nil)

case "render":
    let s = try PhotoSource(url: URL(fileURLWithPath: args[2]))
    var adj = Adjustments()
    if args.count > 4 {
        adj = try JSONDecoder().decode(Adjustments.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
    }
    let t0 = Date()
    var opts = ExportOptions()
    opts.limitLongEdge = ProcessInfo.processInfo.environment["FULL"] == nil
    opts.longEdge = 2400
    try renderer.exportJPEG(s, adj, to: URL(fileURLWithPath: args[3]), options: opts)
    print(String(format: "rendered in %.2fs", Date().timeIntervalSince(t0)))

case "pano":
    let out = URL(fileURLWithPath: args[2])
    var opts = PanoramaOptions()
    opts.rows = Int(args[3]) ?? 1
    // PROJ=rectilinear | flat (default cylindrical)
    if let p = ProcessInfo.processInfo.environment["PROJ"].flatMap(PanoramaProjection.init(rawValue:)) { opts.projection = p }
    let inputs = PanoramaStitcher.bestInputs(for: args[4...].map { URL(fileURLWithPath: $0) })
    print("inputs:", inputs.map(\.lastPathComponent).joined(separator: " "))
    let sources = try inputs.map { try PhotoSource(url: $0) }
    let t0 = Date()
    let stitcher = PanoramaStitcher(renderer: renderer)
    let pano = try stitcher.stitch(sources, options: opts) { p, msg in print(String(format: "%3.0f%% %@", p * 100, msg)) }
    let merged = try stitcher.renderInMemory(pano)
    print(String(format: "merged in memory: %.1fs", Date().timeIntervalSince(t0)))
    let src = PhotoSource(image: merged, url: out, metadata: sources[0].metadata)
    var opts2 = ExportOptions()
    opts2.quality = 0.95
    try renderer.exportJPEG(src, Adjustments(), to: out, options: opts2)
    print("pano:", src.fullSize, "->", out.path, String(format: "%.1fs", Date().timeIntervalSince(t0)))

case "detail":
    // lit-cli detail <photo> <out.jpg> <x> <y> <w> <h> <scale>   (region normalized, top-left)
    let s = try PhotoSource(url: URL(fileURLWithPath: args[2]))
    var adj = Adjustments()
    adj.shadows = 40; adj.highlights = -40
    let v = args[4...8].map { Double($0)! }
    for i in 0..<3 {
        let t0 = Date()
        guard let d = renderer.detail(s, adj, region: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), scale: v[4]) else { fail("no detail") }
        print(String(format: "detail %dx%d in %.0f ms", d.image.width, d.image.height, Date().timeIntervalSince(t0) * 1000))
        if i == 2 {
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, d.image, nil); CGImageDestinationFinalize(dest)
        }
        adj.exposure += 0.1
    }

case "panopreview":
    // lit-cli panopreview <outdir> <rows> <photo>...   (align once, preview both projections)
    let dir = URL(fileURLWithPath: args[2])
    let sources = try PanoramaStitcher.bestInputs(for: args[4...].map { URL(fileURLWithPath: $0) }).map { try PhotoSource(url: $0) }
    var opts = PanoramaOptions()
    opts.rows = Int(args[3]) ?? 1
    let stitcher = PanoramaStitcher(renderer: renderer)
    var t = Date()
    let plan = try stitcher.plan(sources, options: opts)
    print(String(format: "align: %.0f ms", Date().timeIntervalSince(t) * 1000))
    for proj in [PanoramaProjection.cylindrical, .rectilinear] {
        t = Date()
        opts.projection = proj
        let pano = try stitcher.compose(plan, options: opts, preview: true)
        let cg = stitcher.previewImage(pano, maxWidth: 1100)!
        print(String(format: "%@ preview: %.0f ms, full size ≈ %@", proj.rawValue, Date().timeIntervalSince(t) * 1000,
                     "\(plan.fullSize(ofPreview: pano.extent.size))"))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(proj.rawValue).jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
    }

case "split":
    // Cut a big image into overlapping frames with known offsets (planar).
    guard let img = CIImage(contentsOf: URL(fileURLWithPath: args[2])) else { fail("can't read") }
    let dir = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let n = Int(args[4])!, overlap = Double(args[5])!, rows = args.count > 6 ? Int(args[6])! : 1
    let cols = n / rows
    let W = img.extent.width, H = img.extent.height
    let fw = (W / (Double(cols) - overlap * Double(cols - 1))).rounded(.down)
    let fh = rows == 1 ? (H * 0.8).rounded(.down) : (H / (Double(rows) - overlap * Double(rows - 1))).rounded(.down)
    for i in 0..<n {
        let r = i / cols, c = i % cols
        let jitter = Double((i * 37) % 23) - 11   // small vertical misalignment
        let x = Double(c) * fw * (1 - overlap)
        let yTop = rows == 1 ? (H - fh) / 2 + jitter : Double(r) * fh * (1 - overlap)
        let rect = CGRect(x: x, y: H - yTop - fh, width: fw, height: fh).integral
        // Slightly different exposure per frame to exercise gain matching.
        let frame = img.cropped(to: rect)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Double(i % 3) * 0.15 - 0.15])
        let url = dir.appendingPathComponent(String(format: "frame_%d.jpg", i))
        try renderer.context.writeJPEGRepresentation(of: frame, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print(url.lastPathComponent, "at", rect.origin.x, H - rect.maxY)
    }

case "bench":
    // Simulates slider drags: preview renders with changing adjustments.
    let s = try PhotoSource(url: URL(fileURLWithPath: args[2]))
    var adj = Adjustments()
    if args.count > 3 {
        adj = try JSONDecoder().decode(Adjustments.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
    }
    _ = renderer.preview(s, adj, longEdge: 2560)
    let t0 = Date()
    for i in 0..<20 {
        adj.exposure = Double(i) * 0.02
        adj.shadows = Double(i)
        _ = renderer.preview(s, adj, longEdge: 2560)
    }
    print(String(format: "preview: %.0f ms/frame", Date().timeIntervalSince(t0) / 20 * 1000))

case "open":
    // Cold-start timing of what the app does when a photo is opened.
    func ms(_ t: Date) -> String { String(format: "%5.0f ms", Date().timeIntervalSince(t) * 1000) }
    let url = URL(fileURLWithPath: args[2])
    var t = Date()
    if ProcessInfo.processInfo.environment["WARM"] != nil {
        renderer.warmUp()
        print("warm-up         ", ms(t))
        t = Date()
    }
    let s = try PhotoSource(url: url)
    print("source init     ", ms(t), "(since launch", ms(tLaunch) + ")")
    t = Date()
    var adj = Adjustments()
    _ = renderer.preview(s, adj, longEdge: 2560)
    print("first preview   ", ms(t))
    t = Date()
    adj.exposure = 0.3; adj.shadows = 20
    _ = renderer.preview(s, adj, longEdge: 2560)
    print("next preview    ", ms(t))
    print("total           ", ms(tLaunch))

default:
    fail("unknown command")
}

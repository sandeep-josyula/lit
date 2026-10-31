import SwiftUI
import AppKit
import LitCore

/// The crop frame, drawn over the whole (uncropped) photo:
/// drag inside to move, drag a corner or edge to resize (keeping the chosen shape).
struct CropOverlay: View {
    @Bindable var model: EditorModel
    /// Where the whole image sits in the view.
    let rect: CGRect

    private enum Handle: Equatable {
        case move
        case corner(Int)   // 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
        case edge(Int)     // 0 top, 1 right, 2 bottom, 3 left
    }
    @State private var drag: (handle: Handle, start: CGRect)?

    private let minSize: CGFloat = 24

    var body: some View {
        Canvas { ctx, _ in
            let c = cropView
            // Areas the straighten rotation leaves empty: almost black.
            if angle != 0 {
                var empty = Path(rect)
                empty.addLines(rotatedCorners)
                empty.closeSubpath()
                ctx.fill(empty, with: .color(.black.opacity(0.9)), style: FillStyle(eoFill: true))
            }
            // Dim everything outside the crop.
            var outside = Path(rect)
            outside.addRect(c)
            ctx.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))

            // A fine grid when the photo is turned (to line up horizons), thirds while adjusting.
            if angle != 0 {
                var grid = Path()
                let step = max(18, min(c.width, c.height) / 8)
                var x = c.minX + step
                while x < c.maxX { grid.move(to: CGPoint(x: x, y: c.minY)); grid.addLine(to: CGPoint(x: x, y: c.maxY)); x += step }
                var y = c.minY + step
                while y < c.maxY { grid.move(to: CGPoint(x: c.minX, y: y)); grid.addLine(to: CGPoint(x: c.maxX, y: y)); y += step }
                ctx.stroke(grid, with: .color(.white.opacity(0.28)), lineWidth: 0.5)
            } else if drag != nil {
                var grid = Path()
                for k in 1...2 {
                    let x = c.minX + c.width * CGFloat(k) / 3, y = c.minY + c.height * CGFloat(k) / 3
                    grid.move(to: CGPoint(x: x, y: c.minY)); grid.addLine(to: CGPoint(x: x, y: c.maxY))
                    grid.move(to: CGPoint(x: c.minX, y: y)); grid.addLine(to: CGPoint(x: c.maxX, y: y))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.5)
            }
            ctx.stroke(Path(c), with: .color(.white.opacity(0.9)), lineWidth: 1)

            // Corner brackets and edge ticks.
            var handles = Path()
            let L = min(18, c.width / 3, c.height / 3)
            for (p, dx, dy) in [(CGPoint(x: c.minX, y: c.minY), 1.0, 1.0), (CGPoint(x: c.maxX, y: c.minY), -1.0, 1.0),
                                (CGPoint(x: c.maxX, y: c.maxY), -1.0, -1.0), (CGPoint(x: c.minX, y: c.maxY), 1.0, -1.0)] {
                handles.move(to: CGPoint(x: p.x + dx * L, y: p.y))
                handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x, y: p.y + dy * L))
            }
            for (a, b) in [(CGPoint(x: c.midX - 9, y: c.minY), CGPoint(x: c.midX + 9, y: c.minY)),
                           (CGPoint(x: c.midX - 9, y: c.maxY), CGPoint(x: c.midX + 9, y: c.maxY)),
                           (CGPoint(x: c.minX, y: c.midY - 9), CGPoint(x: c.minX, y: c.midY + 9)),
                           (CGPoint(x: c.maxX, y: c.midY - 9), CGPoint(x: c.maxX, y: c.midY + 9))] {
                handles.move(to: a); handles.addLine(to: b)
            }
            ctx.stroke(handles, with: .color(.black.opacity(0.4)), lineWidth: 5)
            ctx.stroke(handles, with: .color(.white), lineWidth: 3)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                switch hit(p) {
                case .corner?: NSCursor.crosshair.set()
                case .edge(let e)?: (e % 2 == 0 ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                case .move?: NSCursor.openHand.set()
                case nil: NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: Geometry

    private var angle: Double { model.crop.angle }

    /// The photo's outline after straightening, in view coordinates.
    private var rotatedCorners: [CGPoint] {
        let a = angle * .pi / 180, ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
        return [CGPoint(x: -rect.width / 2, y: -rect.height / 2), CGPoint(x: rect.width / 2, y: -rect.height / 2),
                CGPoint(x: rect.width / 2, y: rect.height / 2), CGPoint(x: -rect.width / 2, y: rect.height / 2)].map {
            CGPoint(x: rect.midX + $0.x * ca - $0.y * sa, y: rect.midY + $0.x * sa + $0.y * ca)
        }
    }

    /// Keeps a proposed crop inside the (turned) photo: if it doesn't fit, goes as far as possible
    /// from the starting rectangle towards it.
    private func constrained(_ r: CGRect, from start: CGRect) -> CGRect {
        guard angle != 0, !Crop.fits(r, in: rect, angle: angle) else { return r }
        func lerp(_ t: CGFloat) -> CGRect {
            CGRect(x: start.minX + (r.minX - start.minX) * t, y: start.minY + (r.minY - start.minY) * t,
                   width: start.width + (r.width - start.width) * t, height: start.height + (r.height - start.height) * t)
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if Crop.fits(lerp(mid), in: rect, angle: angle) { lo = mid } else { hi = mid }
        }
        return lerp(lo)
    }

    private var cropView: CGRect {
        let n = model.crop.rect
        return CGRect(x: rect.minX + n.minX * rect.width, y: rect.minY + n.minY * rect.height,
                      width: n.width * rect.width, height: n.height * rect.height)
    }

    /// Width / height of the chosen shape (view and pixel aspect are the same).
    private var ratio: CGFloat? {
        guard let src = model.source else { return nil }
        return model.crop.ratio(imageSize: src.fullSize).map { CGFloat($0) }
    }

    private func hit(_ p: CGPoint) -> Handle? {
        let c = cropView
        let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
                       CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.minX, y: c.maxY)]
        if let i = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 14 }) { return .corner(i) }
        let tol: CGFloat = 8
        let inX = p.x > c.minX && p.x < c.maxX, inY = p.y > c.minY && p.y < c.maxY
        if inX && abs(p.y - c.minY) < tol { return .edge(0) }
        if inY && abs(p.x - c.maxX) < tol { return .edge(1) }
        if inX && abs(p.y - c.maxY) < tol { return .edge(2) }
        if inY && abs(p.x - c.minX) < tol { return .edge(3) }
        if c.contains(p) { return .move }
        return nil
    }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    guard let h = hit(g.startLocation) else { return }
                    model.checkpoint()
                    drag = (h, cropView)
                    if h == .move { NSCursor.closedHand.set() }
                }
                guard let d = drag else { return }
                let r: CGRect
                switch d.handle {
                case .move:
                    var m = d.start.offsetBy(dx: g.translation.width, dy: g.translation.height)
                    m.origin.x = min(max(m.minX, rect.minX), rect.maxX - m.width)
                    m.origin.y = min(max(m.minY, rect.minY), rect.maxY - m.height)
                    r = m
                case .corner(let k): r = resizeCorner(d.start, corner: k, to: g.location)
                case .edge(let e): r = resizeEdge(d.start, edge: e, to: g.location)
                }
                let r2 = constrained(r, from: d.start)
                var c = model.crop
                c.rect = CGRect(x: (r2.minX - rect.minX) / rect.width, y: (r2.minY - rect.minY) / rect.height,
                                width: r2.width / rect.width, height: r2.height / rect.height)
                model.setCrop(c)
            }
            .onEnded { _ in drag = nil }
    }

    private func resizeCorner(_ s: CGRect, corner k: Int, to p: CGPoint) -> CGRect {
        let right = k == 1 || k == 2, bottom = k == 2 || k == 3
        // The opposite corner stays put.
        let ax = right ? s.minX : s.maxX, ay = bottom ? s.minY : s.maxY
        let availW = right ? rect.maxX - ax : ax - rect.minX
        let availH = bottom ? rect.maxY - ay : ay - rect.minY
        var w = max(minSize, right ? p.x - ax : ax - p.x)
        var h = max(minSize, bottom ? p.y - ay : ay - p.y)
        if let r = ratio {
            if w / h > r { h = w / r } else { w = h * r }
            if w > availW { w = availW; h = w / r }
            if h > availH { h = availH; w = h * r }
        } else {
            w = min(w, availW); h = min(h, availH)
        }
        return CGRect(x: right ? ax : ax - w, y: bottom ? ay : ay - h, width: w, height: h)
    }

    private func resizeEdge(_ s: CGRect, edge e: Int, to p: CGPoint) -> CGRect {
        let vertical = e == 0 || e == 2   // top / bottom edge: changes the height
        if vertical {
            let ay = e == 2 ? s.minY : s.maxY
            let availH = e == 2 ? rect.maxY - ay : ay - rect.minY
            var h = min(max(minSize, e == 2 ? p.y - ay : ay - p.y), availH)
            var w = s.width
            if let r = ratio {
                w = h * r
                if w > rect.width { w = rect.width; h = w / r }
            }
            let x = min(max(s.midX - w / 2, rect.minX), rect.maxX - w)
            return CGRect(x: x, y: e == 2 ? ay : ay - h, width: w, height: h)
        } else {
            let ax = e == 1 ? s.minX : s.maxX
            let availW = e == 1 ? rect.maxX - ax : ax - rect.minX
            var w = min(max(minSize, e == 1 ? p.x - ax : ax - p.x), availW)
            var h = s.height
            if let r = ratio {
                h = w / r
                if h > rect.height { h = rect.height; w = h * r }
            }
            let y = min(max(s.midY - h / 2, rect.minY), rect.maxY - h)
            return CGRect(x: e == 1 ? ax : ax - w, y: y, width: w, height: h)
        }
    }
}

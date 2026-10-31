import SwiftUI
import AppKit
import LitCore

/// Draws and edits linear gradient masks, Camera Raw style:
/// - drag on the photo to create one (full effect where you press, none where you release);
///   hold ⇧ to keep it level or vertical
/// - drag the centre pin to move it
/// - drag the outer lines to change the fade width
/// - drag the centre line (away from the pin) to rotate
struct GradientOverlay: View {
    @Bindable var model: EditorModel
    let rect: CGRect

    private enum Mode {
        case pendingCreate(CGPoint)
        case create(UUID)
        case move(UUID, s0: CGPoint, e0: CGPoint)
        case startLine(UUID, s0: CGPoint, dir: CGVector)
        case endLine(UUID, e0: CGPoint, dir: CGVector)
        case rotate(UUID, s0: CGPoint, e0: CGPoint, center: CGPoint, angle0: Double)
    }
    @State private var mode: Mode?
    @State private var hoverMask: UUID?

    private var active: Bool { model.tool == .gradient }

    var body: some View {
        Canvas { ctx, _ in
            guard active else { return }
            for mask in model.adjustments.gradients {
                let selected = mask.id == model.selectedMaskID
                let s = view(mask.start), e = view(mask.end)
                if selected && model.showMaskOverlay {
                    drawOverlay(ctx, s, e, enabled: mask.isEnabled)
                }
                if selected { drawLines(ctx, s, e) }
                drawPin(ctx, mid(s, e), selected: selected, enabled: mask.isEnabled, hover: hoverMask == mask.id)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(active)
        .gesture(dragGesture)
        .onContinuousHover { phase in
            guard active else { return }
            switch phase {
            case .active(let p):
                hoverMask = model.adjustments.gradients.first { dist(mid(view($0.start), view($0.end)), p) < 10 }?.id
                if hoverMask != nil { NSCursor.pointingHand.set() } else { NSCursor.crosshair.set() }
            case .ended:
                hoverMask = nil
                NSCursor.arrow.set()
            }
        }
    }


    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if mode == nil { mode = beginMode(at: g.startLocation) }
                update(with: g)
            }
            .onEnded { _ in mode = nil }
    }

    private func beginMode(at p: CGPoint) -> Mode {
        // Handles of the selected mask first.
        if let m = model.selectedMask {
            let s = view(m.start), e = view(m.end), c = mid(s, e)
            let dir = unit(s, e)
            if dist(p, c) < 10 { model.checkpoint(); return .move(m.id, s0: m.start, e0: m.end) }
            if abs(dot(p - s, dir)) < 6 { model.checkpoint(); return .startLine(m.id, s0: s, dir: dir) }
            if abs(dot(p - e, dir)) < 6 { model.checkpoint(); return .endLine(m.id, e0: e, dir: dir) }
            if abs(dot(p - c, dir)) < 6 {
                model.checkpoint()
                return .rotate(m.id, s0: s, e0: e, center: c, angle0: atan2(Double(p.y - c.y), Double(p.x - c.x)))
            }
        }
        // Any other pin selects that mask.
        if let hit = model.adjustments.gradients.last(where: { dist(mid(view($0.start), view($0.end)), p) < 10 }) {
            model.selectedMaskID = hit.id
            model.checkpoint()
            return .move(hit.id, s0: hit.start, e0: hit.end)
        }
        return .pendingCreate(p)
    }

    private func update(with g: DragGesture.Value) {
        guard let current = mode else { return }
        let p = g.location
        switch current {
        case .pendingCreate(let start):
            if dist(start, p) > 4 {
                let id = model.addGradient(start: norm(start), end: norm(p))
                mode = .create(id)
                update(with: g)
            } else {
                model.selectedMaskID = nil
            }
        case .create(let id):
            var end = p
            if NSEvent.modifierFlags.contains(.shift) {
                let s = g.startLocation
                if abs(p.x - s.x) > abs(p.y - s.y) { end.y = s.y } else { end.x = s.x }
            }
            model.updateMask(id) { $0.end = norm(end) }
        case .move(let id, let s0, let e0):
            let d = CGPoint(x: g.translation.width / rect.width * region.width,
                            y: g.translation.height / rect.height * region.height)
            model.updateMask(id) { $0.start = s0 + d; $0.end = e0 + d }
        case .startLine(let id, let s0, let dir):
            let along = dot(CGPoint(x: g.translation.width, y: g.translation.height), dir)
            model.updateMask(id) { $0.start = norm(s0 + dir * along) }
        case .endLine(let id, let e0, let dir):
            let along = dot(CGPoint(x: g.translation.width, y: g.translation.height), dir)
            model.updateMask(id) { $0.end = norm(e0 + dir * along) }
        case .rotate(let id, let s0, let e0, let c, let a0):
            var da = atan2(Double(p.y - c.y), Double(p.x - c.x)) - a0
            if NSEvent.modifierFlags.contains(.shift) { da = (da / (.pi / 12)).rounded() * (.pi / 12) }
            model.updateMask(id) {
                $0.start = norm(rotate(s0, around: c, by: da))
                $0.end = norm(rotate(e0, around: c, by: da))
            }
        }
    }

    // MARK: Drawing

    private func drawOverlay(_ ctx: GraphicsContext, _ s: CGPoint, _ e: CGPoint, enabled: Bool) {
        var c = ctx
        c.clip(to: Path(rect))
        c.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color.red.opacity(enabled ? 0.45 : 0.15), Color.red.opacity(0)]),
            startPoint: s, endPoint: e))
    }

    private func drawLines(_ ctx: GraphicsContext, _ s: CGPoint, _ e: CGPoint) {
        var c = ctx
        c.clip(to: Path(rect.insetBy(dx: -1, dy: -1)))
        let dir = unit(s, e)
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        let L = hypot(rect.width, rect.height)
        func line(through p: CGPoint) -> Path {
            var path = Path()
            path.move(to: p - perp * L)
            path.addLine(to: p + perp * L)
            return path
        }
        let center = mid(s, e)
        for (p, dash) in [(s, false), (e, false), (center, true)] {
            let style = StrokeStyle(lineWidth: 1, dash: dash ? [5, 4] : [])
            c.stroke(line(through: p), with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 3, dash: style.dash))
            c.stroke(line(through: p), with: .color(.white), style: style)
        }
        // Small grips where the outer lines cross the axis.
        for p in [s, e] {
            let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            c.fill(Path(ellipseIn: r), with: .color(.white))
            c.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawPin(_ ctx: GraphicsContext, _ c: CGPoint, selected: Bool, enabled: Bool, hover: Bool) {
        let r: CGFloat = selected ? 7 : (hover ? 7 : 6)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(ellipseIn: rect), with: .color(.white))
        let inner = rect.insetBy(dx: 2.5, dy: 2.5)
        ctx.fill(Path(ellipseIn: inner),
                 with: .color(selected ? Theme.accent : (enabled ? Color(white: 0.35) : Color(white: 0.7))))
    }

    // MARK: Geometry

    // Mask points are normalized to the whole image; the canvas may show only the crop.
    private var region: CGRect { model.previewRegion }
    private func view(_ n: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + (n.x - region.minX) / region.width * rect.width,
                y: rect.minY + (n.y - region.minY) / region.height * rect.height)
    }
    private func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: region.minX + (p.x - rect.minX) / rect.width * region.width,
                y: region.minY + (p.y - rect.minY) / rect.height * region.height)
    }
}

// Tiny vector helpers.
private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
private func unit(_ a: CGPoint, _ b: CGPoint) -> CGVector {
    let d = hypot(b.x - a.x, b.y - a.y)
    return d < 0.001 ? CGVector(dx: 0, dy: 1) : CGVector(dx: (b.x - a.x) / d, dy: (b.y - a.y) / d)
}
private func dot(_ p: CGPoint, _ v: CGVector) -> CGFloat { p.x * v.dx + p.y * v.dy }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func + (a: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: a.x + v.dx, y: a.y + v.dy) }
private func - (a: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: a.x - v.dx, y: a.y - v.dy) }
private func * (v: CGVector, s: CGFloat) -> CGVector { CGVector(dx: v.dx * s, dy: v.dy * s) }
private func rotate(_ p: CGPoint, around c: CGPoint, by a: Double) -> CGPoint {
    let x = Double(p.x - c.x), y = Double(p.y - c.y)
    return CGPoint(x: c.x + CGFloat(x * cos(a) - y * sin(a)), y: c.y + CGFloat(x * sin(a) + y * cos(a)))
}

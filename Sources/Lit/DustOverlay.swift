import SwiftUI
import AppKit
import LitCore

/// The Dust Speck tool on the canvas:
/// - click a speck to heal it (lit picks a matching source nearby)
/// - drag a speck's circle to move it, drag its dashed source circle to copy from elsewhere
/// - the brush outline follows the pointer so you can size it to the speck
struct DustOverlay: View {
    @Bindable var model: EditorModel
    let rect: CGRect

    private enum Mode {
        case pending(CGPoint)
        case moveSpot(UUID, CGPoint)     // original centre (normalized)
        case moveSource(UUID, CGPoint)   // original source (normalized)
    }
    @State private var mode: Mode?
    @State private var hover: CGPoint?

    var body: some View {
        Canvas { ctx, _ in
            for spot in model.adjustments.dust {
                let selected = spot.id == model.selectedSpotID
                let c = view(spot.center), r = viewRadius(spot.radius)
                if selected {
                    let s = view(spot.source)
                    var link = Path()
                    let d = hypot(s.x - c.x, s.y - c.y)
                    if d > 2 * r {
                        let ux = (s.x - c.x) / d, uy = (s.y - c.y) / d
                        link.move(to: CGPoint(x: c.x + ux * r, y: c.y + uy * r))
                        link.addLine(to: CGPoint(x: s.x - ux * r, y: s.y - uy * r))
                    }
                    ctx.stroke(link, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    circle(ctx, s, r, color: .white, dashed: true)
                }
                circle(ctx, c, r, color: selected ? Theme.accent : .white, dashed: false)
            }
            // Brush outline under the pointer.
            if let h = hover, mode == nil, hit(h) == nil {
                let r = viewRadius(model.dustBrush)
                ctx.stroke(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hover = p
                (hit(p) != nil ? NSCursor.pointingHand : NSCursor.crosshair).set()
            case .ended:
                hover = nil
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: Drawing

    private func circle(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, color: Color, dashed: Bool) {
        let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
    }

    // MARK: Gesture

    private enum Hit { case spot(UUID), source(UUID) }

    private func hit(_ p: CGPoint) -> Hit? {
        if let sel = model.selectedSpot {
            let s = view(sel.source)
            if hypot(p.x - s.x, p.y - s.y) <= viewRadius(sel.radius) + 3 { return .source(sel.id) }
        }
        for spot in model.adjustments.dust.reversed() {
            let c = view(spot.center)
            if hypot(p.x - c.x, p.y - c.y) <= viewRadius(spot.radius) + 3 { return .spot(spot.id) }
        }
        return nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if mode == nil {
                    switch hit(g.startLocation) {
                    case .spot(let id)?:
                        model.selectedSpotID = id
                        model.checkpoint()
                        mode = .moveSpot(id, model.selectedSpot!.center)
                    case .source(let id)?:
                        model.checkpoint()
                        mode = .moveSource(id, model.selectedSpot!.source)
                    case nil:
                        mode = .pending(g.startLocation)
                    }
                }
                let d = CGPoint(x: g.translation.width / rect.width * model.previewRegion.width,
                                y: g.translation.height / rect.height * model.previewRegion.height)
                switch mode {
                case .moveSpot(let id, let c0)?:
                    model.updateSpot(id) { $0.center = CGPoint(x: c0.x + d.x, y: c0.y + d.y) }
                case .moveSource(let id, let s0)?:
                    model.updateSpot(id) { $0.source = CGPoint(x: s0.x + d.x, y: s0.y + d.y) }
                default: break
                }
            }
            .onEnded { g in
                if case .pending(let start)? = mode, hypot(g.translation.width, g.translation.height) < 4 {
                    model.addDustSpot(at: norm(start))
                }
                mode = nil
            }
    }

    // MARK: Geometry (spots are normalized to the whole image; the canvas may show a crop)

    private var region: CGRect { model.previewRegion }
    private func view(_ n: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + (n.x - region.minX) / region.width * rect.width,
                y: rect.minY + (n.y - region.minY) / region.height * rect.height)
    }
    private func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: region.minX + (p.x - rect.minX) / rect.width * region.width,
                y: region.minY + (p.y - rect.minY) / rect.height * region.height)
    }
    /// Radius (fraction of image width) in view points.
    private func viewRadius(_ r: Double) -> CGFloat { CGFloat(r) * rect.width / region.width }
}

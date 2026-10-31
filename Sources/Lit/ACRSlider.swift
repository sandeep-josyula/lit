import SwiftUI

/// The slider under the pointer, so ← / → can nudge it (see the key monitor in LitApp).
@MainActor
enum SliderKeys {
    static var owner: String?
    static var nudge: ((Double, Bool) -> Void)?
}

/// A Camera Raw–style slider: label and value on one line, a track below.
/// - drag anywhere on the slider (label or track): the value moves with the pointer, no jump
/// - click the track to jump there; double-click to reset
/// - hold ⌥ while dragging for 10× finer control
/// - click the number to type a value; hover and press ← / → (⇧ for bigger steps)
struct ACRSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = ACRSlider.signedInt
    var track: [Color]? = nil
    /// Arrow-key step (defaults to 1/200 of the range).
    var step: Double? = nil
    var onBegin: () -> Void = {}

    @State private var drag: (value: Double, x: CGFloat, moved: Bool)?
    @State private var size: CGSize = .zero
    @State private var hovering = false
    @State private var editing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private let trackHeight: CGFloat = 18

    static func signedInt(_ v: Double) -> String {
        let r = v.rounded()
        return r == 0 ? "0" : String(format: "%+.0f", r)
    }
    static func signed2(_ v: Double) -> String {
        abs(v) < 0.005 ? "0.00" : String(format: "%+.2f", v)
    }
    static func plain(_ v: Double) -> String { String(format: "%.0f", v.rounded()) }
    static func plain1(_ v: Double) -> String { String(format: "%.1f", v) }

    private var span: Double { range.upperBound - range.lowerBound }
    private func fraction(_ v: Double) -> CGFloat { CGFloat((v - range.lowerBound) / span) }
    private var active: Bool { hovering || drag != nil }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                valueLabel
            }
            .panelLabel()
            .frame(height: 16)
            trackView.frame(height: trackHeight)
        }
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { size = geo.size }
                .onChange(of: geo.size) { _, s in size = s }
        })
        .gesture(dragGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onBegin()
            value = defaultValue
        })
        .onHover { h in
            hovering = h
            if h {
                SliderKeys.owner = title
                SliderKeys.nudge = { dir, big in nudge(dir, big: big) }
            } else if SliderKeys.owner == title {
                SliderKeys.owner = nil
                SliderKeys.nudge = nil
            }
        }
        .help("Drag to adjust · ⌥ for fine control · double-click to reset · click the number to type · ← → to nudge")
    }

    // MARK: Pieces

    @ViewBuilder private var valueLabel: some View {
        if editing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 56)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35)))
                .focused($fieldFocused)
                .onSubmit { commitText() }
                .onExitCommand { editing = false }
                .onChange(of: fieldFocused) { _, f in if !f { commitText() } }
        } else {
            Text(format(value)).monospacedDigit()
                .foregroundStyle(value == defaultValue ? Theme.secondaryText : Theme.text)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? Color.white.opacity(0.08) : .clear))
                .onTapGesture {
                    text = format(value)
                    editing = true
                    fieldFocused = true
                }
        }
    }

    private var trackView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = max(0, min(1, fraction(value)))
            let d = max(0, min(1, fraction(defaultValue)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) }
                          ?? AnyShapeStyle(Theme.track))
                    .frame(height: 4)
                    .opacity(track == nil ? (active ? 1 : 0.85) : (active ? 1 : 0.8))
                // How far the value is from its default.
                if track == nil, abs(t - d) > 0.001 {
                    Capsule()
                        .fill(Theme.text.opacity(0.75))
                        .frame(width: abs(t - d) * w, height: 4)
                        .offset(x: min(t, d) * w)
                }
                // Default mark (where double-click returns).
                if d > 0.001 && d < 0.999 {
                    Rectangle()
                        .fill(Theme.secondaryText.opacity(0.8))
                        .frame(width: 1, height: 9)
                        .offset(x: d * w - 0.5)
                }
                Circle()
                    .fill(Color(white: drag != nil ? 1 : 0.93))
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: active ? 2.5 : 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .scaleEffect(active ? 1.12 : 1)
                    .offset(x: t * w - 7)
                    .animation(.easeOut(duration: 0.12), value: active)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    onBegin()
                    drag = (value, g.startLocation.x, false)
                }
                guard var s = drag, size.width > 0 else { return }
                let dx = g.location.x - s.x
                if !s.moved && abs(dx) < 2 { return }
                if !s.moved { s.moved = true; s.x = g.location.x; drag = s; return }
                let fine = NSEvent.modifierFlags.contains(.option)
                value = clamp(s.value + Double(dx / size.width) * span * (fine ? 0.1 : 1), snap: !fine)
            }
            .onEnded { g in
                defer { drag = nil }
                // A click on the track (no drag) jumps there.
                guard let s = drag, !s.moved, size.width > 0,
                      g.startLocation.y > size.height - trackHeight - 2 else { return }
                value = clamp(range.lowerBound + Double(max(0, min(1, g.startLocation.x / size.width))) * span, snap: true)
            }
    }

    private func nudge(_ dir: Double, big: Bool) {
        onBegin()
        let st = step ?? span / 200
        value = clamp(((value + dir * st * (big ? 10 : 1)) / st).rounded() * st, snap: false)
    }

    private func commitText() {
        guard editing else { return }
        editing = false
        let cleaned = text.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned) else { return }
        onBegin()
        value = clamp(v, snap: false)
    }

    private func clamp(_ v: Double, snap: Bool) -> Double {
        var v = min(max(v, range.lowerBound), range.upperBound)
        // Gentle snap to the default so it's easy to get back to zero by hand.
        if snap, abs(v - defaultValue) < span * 0.006 { v = defaultValue }
        return v
    }
}

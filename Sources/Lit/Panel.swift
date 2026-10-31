import SwiftUI
import LitCore

/// The right-hand adjustments column.
struct AdjustmentPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HistogramView(histogram: model.histogram)
                .overlay(alignment: .topLeading) {
                    ClipButton(on: $model.clipShadows, clipped: model.hasClippedShadows, color: .blue,
                               help: "Show crushed shadows in blue (J)")
                }
                .overlay(alignment: .topTrailing) {
                    ClipButton(on: $model.clipHighlights, clipped: model.hasClippedHighlights, color: .red,
                               help: "Show blown highlights in red (J)", flipped: true)
                }
                .frame(height: 92)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            VStack(spacing: 2) {
                Text(model.exifSummary)
                Text(model.pixelSizeText)
            }
            .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
            .padding(.vertical, 8)

            InsightsView(model: model)

            ToolTabs(model: model)

            Divider().overlay(Theme.divider)

            ScrollView {
                VStack(spacing: 0) {
                    switch model.tool {
                    case .gradient:
                        MaskPanel(model: model)
                    case .crop:
                        CropPanel(model: model)
                    case .dust:
                        DustPanel(model: model)
                    case .edit:
                        EditSections(model: model)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .disabled(model.source == nil)
        .opacity(model.source == nil ? 0.45 : 1)
        .background(Theme.panel)
    }
}

// MARK: - Tabs

/// Edit · Gradient · Crop: all tools live in this one sidebar.
struct ToolTabs: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 4) {
            tab(.edit, "slider.horizontal.3", "Edit", key: "E")
            tab(.gradient, "square.tophalf.filled", "Gradient", key: "G")
            tab(.crop, "crop", "Crop", key: "C")
            tab(.dust, "circle.dotted", "Dust", key: "D")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tab(_ tool: Tool, _ icon: String, _ title: String, key: String) -> some View {
        let active = model.tool == tool
        return Button { model.tool = tool } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .selectable(active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(key))")
    }
}

// MARK: - Insights

/// Experimental: gentle notes from the histogram.
struct InsightsView: View {
    @Bindable var model: EditorModel
    @AppStorage("showInsights") private var show = true

    var body: some View {
        if !model.insights.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "lightbulb").font(.system(size: 10))
                    Text("Notes").font(.system(size: 10, weight: .semibold))
                    Text("experimental").font(.system(size: 9)).foregroundStyle(Theme.secondaryText.opacity(0.7))
                    Spacer()
                    Button(show ? "Hide" : "Show") { show.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
                }
                .foregroundStyle(Theme.secondaryText)
                if show {
                    ForEach(model.insights) { insight in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(color(insight.kind)).frame(width: 5, height: 5).padding(.top, 5)
                            Text(insight.text)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func color(_ k: Insight.Kind) -> Color {
        switch k {
        case .balanced: return .green.opacity(0.8)
        case .highlights, .shadows, .color: return .orange.opacity(0.9)
        default: return Theme.secondaryText
        }
    }
}

// MARK: - Edit

struct EditSections: View {
    @Bindable var model: EditorModel

    var body: some View {
        PanelSection("Basic") {
            if model.isRAW {
                ACRSlider(title: "Temperature", value: model.temperatureBinding, range: 2000...12000,
                          defaultValue: model.asShotTemperature, format: ACRSlider.plain,
                          track: Theme.tempTrack, onBegin: model.checkpoint)
            } else {
                ACRSlider(title: "Temperature", value: model.temperatureBinding, range: -100...100,
                          track: Theme.tempTrack, onBegin: model.checkpoint)
            }
            Spacer().frame(height: 8)
            ACRSlider(title: "Exposure", value: model.binding(\.exposure), range: -5...5,
                      format: ACRSlider.signed2, track: Theme.exposureTrack, onBegin: model.checkpoint)
            ACRSlider(title: "Contrast", value: model.binding(\.contrast), range: -100...100, onBegin: model.checkpoint)
            Spacer().frame(height: 8)
            ACRSlider(title: "Highlights", value: model.binding(\.highlights), range: -100...100, onBegin: model.checkpoint)
            ACRSlider(title: "Shadows", value: model.binding(\.shadows), range: -100...100, onBegin: model.checkpoint)
            ACRSlider(title: "Whites", value: model.binding(\.whites), range: -100...100, onBegin: model.checkpoint)
            ACRSlider(title: "Blacks", value: model.binding(\.blacks), range: -100...100, onBegin: model.checkpoint)
            Spacer().frame(height: 8)
            ACRSlider(title: "Vibrance", value: model.binding(\.vibrance), range: -100...100,
                      track: Theme.satTrack, onBegin: model.checkpoint)
            ACRSlider(title: "Saturation", value: model.binding(\.saturation), range: -100...100,
                      track: Theme.satTrack, onBegin: model.checkpoint)
        } trailing: {
            if model.adjustments.temperature != nil {
                Button("As Shot") {
                    model.checkpoint()
                    model.adjustments.temperature = nil
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }

        ColorSection(model: model)

        PanelSection("Lens") {
            if model.hasLensProfile {
                Toggle("Camera lens profile", isOn: model.lensProfileBinding)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Vignetting, distortion and colour-fringe corrections stored in the RAW file by your camera")
            }
            ACRSlider(title: "Distortion", value: model.binding(\.lens.distortion), range: -100...100,
                      step: 1, onBegin: model.checkpoint)
            ACRSlider(title: "Vignetting", value: model.binding(\.lens.vignetting), range: -100...100,
                      track: [Color(white: 0.15), Color(white: 0.85)], step: 1, onBegin: model.checkpoint)
        } trailing: {
            if model.adjustments.lens != LensSettings() {
                Button("Reset") {
                    model.checkpoint()
                    model.adjustments.lens = LensSettings()
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }

        PanelSection("Effects") {
            ACRSlider(title: "Glow", value: model.binding(\.glow), range: 0...100,
                      format: ACRSlider.plain, track: [Color(white: 0.3), Color(red: 1, green: 0.85, blue: 0.6)],
                      step: 1, onBegin: model.checkpoint)
        }

        PanelSection("Detail") {
            ACRSlider(title: "Sharpening", value: model.binding(\.sharpenAmount), range: 0...150,
                      defaultValue: 25, format: ACRSlider.plain, step: 1, onBegin: model.checkpoint)
            ACRSlider(title: "Radius", value: model.binding(\.sharpenRadius), range: 0.5...3,
                      defaultValue: 1, format: ACRSlider.plain1, step: 0.1, onBegin: model.checkpoint)
            Text("Zoom to 100% (Z) to judge sharpening.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Color

/// Pick one of six colours, then nudge its hue, saturation and luminance.
struct ColorSection: View {
    @Bindable var model: EditorModel
    @State private var band: ColorBand = .orange

    var body: some View {
        PanelSection("Color") {
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases) { b in
                    Button { band = b } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(ColorSection.swatch(b))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.white, lineWidth: band == b ? 2 : 0).padding(-3))
                            Circle()
                                .fill(model.adjustments.color.isNeutral(b) ? Color.clear : Theme.text)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(b.name)
                }
            }
            .padding(.bottom, 2)
            ACRSlider(title: "\(band.name) Hue", value: model.colorBinding(\.hue, band), range: -100...100,
                      track: [ColorSection.swatch(band, shift: -30), ColorSection.swatch(band), ColorSection.swatch(band, shift: 30)],
                      onBegin: model.checkpoint)
            ACRSlider(title: "Saturation", value: model.colorBinding(\.saturation, band), range: -100...100,
                      track: [Color(white: 0.5), ColorSection.swatch(band)], onBegin: model.checkpoint)
            ACRSlider(title: "Luminance", value: model.colorBinding(\.luminance, band), range: -100...100,
                      track: [ColorSection.swatch(band, brightness: 0.25), ColorSection.swatch(band, brightness: 1)],
                      onBegin: model.checkpoint)
        } trailing: {
            if !model.adjustments.color.isNeutral {
                Button("Reset") {
                    model.checkpoint()
                    model.adjustments.color = ColorMix()
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }
    }

    static func swatch(_ b: ColorBand, shift: Double = 0, brightness: Double = 0.95) -> Color {
        var h = (b.hue + shift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return Color(hue: h / 360, saturation: 0.8, brightness: brightness)
    }
}

// MARK: - Masks

struct MaskPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        PanelSection("Gradients") {
            if model.adjustments.gradients.isEmpty {
                Text("Drag on the photo to add a gradient.\nFull effect where you start, fading out where you let go. Hold ⇧ to keep it straight.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.adjustments.gradients.enumerated()), id: \.element.id) { i, mask in
                MaskRow(model: model, mask: mask, index: i + 1)
            }
            Toggle("Show overlay", isOn: $model.showMaskOverlay)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }

        if model.selectedMask != nil {
            PanelSection("Gradient Adjustments") {
                ACRSlider(title: "Exposure", value: model.localBinding(\.exposure), range: -4...4,
                          format: ACRSlider.signed2, track: Theme.exposureTrack, step: 0.05, onBegin: model.checkpoint)
                ACRSlider(title: "Contrast", value: model.localBinding(\.contrast), range: -100...100, onBegin: model.checkpoint)
                ACRSlider(title: "Highlights", value: model.localBinding(\.highlights), range: -100...100, onBegin: model.checkpoint)
                ACRSlider(title: "Shadows", value: model.localBinding(\.shadows), range: -100...100, onBegin: model.checkpoint)
                ACRSlider(title: "Whites", value: model.localBinding(\.whites), range: -100...100, onBegin: model.checkpoint)
                ACRSlider(title: "Blacks", value: model.localBinding(\.blacks), range: -100...100, onBegin: model.checkpoint)
                Spacer().frame(height: 8)
                ACRSlider(title: "Temperature", value: model.localBinding(\.temperature), range: -100...100,
                          track: Theme.tempTrack, onBegin: model.checkpoint)
                ACRSlider(title: "Saturation", value: model.localBinding(\.saturation), range: -100...100,
                          track: Theme.satTrack, onBegin: model.checkpoint)
            } trailing: {
                Button("Reset") {
                    guard let id = model.selectedMaskID else { return }
                    model.checkpoint()
                    model.updateMask(id) { $0.local = LocalAdjustments() }
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - Dust

struct DustPanel: View {
    @Bindable var model: EditorModel
    var body: some View {
        PanelSection("Dust Specks") {
            ACRSlider(title: "Size", value: model.dustSizeBinding,
                      range: DustSpot.minRadius...DustSpot.maxRadius, defaultValue: 0.003,
                      format: { v in "\(Int((v * 2 * (model.source?.fullSize.width ?? 0)).rounded())) px" },
                      step: 0.0002, onBegin: model.checkpoint)
            Toggle("Find dust", isOn: $model.showDustView)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("A high-contrast view that makes sensor dust stand out, especially in skies")
            if model.showDustView {
                ACRSlider(title: "Sensitivity", value: $model.dustSensitivity, range: 0...1, defaultValue: 0.5,
                          format: { "\(Int(($0 * 100).rounded()))" }, step: 0.01)
            }
            HStack {
                Text(model.adjustments.dust.isEmpty ? "No specks healed"
                     : "\(model.adjustments.dust.count) speck\(model.adjustments.dust.count == 1 ? "" : "s") healed")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if let id = model.selectedSpotID {
                    Button("Delete") { model.deleteSpot(id) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .help("Delete the selected speck (⌫)")
                }
            }
            Text("Click a speck to heal it with texture copied from nearby. Drag the dashed circle to copy from somewhere else. [ and ] change the size. For sensor and lens dust only, so the brush stays small.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            if !model.adjustments.dust.isEmpty {
                Button("Clear all") { model.clearDust() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        PanelSection("Crop") {
            let current = model.crop
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(CropAspect.allCases) { aspect in
                    let selected = current.aspect == aspect
                    Button { model.setCropAspect(aspect) } label: {
                        VStack(spacing: 1) {
                            Text(aspect.name).font(.system(size: 11, weight: .medium))
                            Text(detail(aspect, current)).font(.system(size: 9))
                                .opacity(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .selectable(selected, cornerRadius: 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button {
                    model.rotateCropShape()
                } label: {
                    Label("Rotate shape", systemImage: "rotate.right").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canRotate(current) ? Theme.text : Theme.secondaryText.opacity(0.5))
                .disabled(!canRotate(current))
                .help("Switch between landscape and portrait (X)")
                Spacer()
            }
            .padding(.top, 2)
            ACRSlider(title: "Straighten", value: model.straightenBinding, range: -45...45,
                      format: { String(format: "%+.1f°", $0).replacingOccurrences(of: "+0.0", with: "0.0") },
                      step: 0.1, onBegin: model.beginStraighten)
                .padding(.top, 4)
            Text("Drag inside the frame to move it, drag the corners or edges to resize. Press Return when you're done.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            if model.adjustments.crop != nil {
                Button("Reset") { model.resetCrop() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func canRotate(_ c: Crop) -> Bool { c.aspect != .free && c.aspect != .square }

    /// "16:9", or "9:16" when rotated.
    private func detail(_ a: CropAspect, _ c: Crop) -> String {
        guard c.aspect == a, c.rotated else { return a.detail }
        let parts = a.detail.split(separator: ":")
        return parts.count == 2 ? "\(parts[1]):\(parts[0])" : a.detail
    }
}

struct MaskRow: View {
    @Bindable var model: EditorModel
    let mask: GradientMask
    let index: Int

    var body: some View {
        let selected = model.selectedMaskID == mask.id
        HStack(spacing: 8) {
            Button {
                model.checkpoint()
                model.updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("Show / hide this gradient")

            Image(systemName: "square.tophalf.filled").font(.system(size: 11))
            Text("Gradient \(index)").font(.system(size: 11))
            Spacer()
            Button {
                model.deleteMask(mask.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Delete gradient (⌫)")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .selectable(selected, cornerRadius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedMaskID = mask.id }
    }
}

// MARK: - Section chrome

/// Collapsible panel section with a Camera Raw–style header.
struct PanelSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
    @AppStorage private var expanded: Bool

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
        _expanded = AppStorage(wrappedValue: true, "section.\(title)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                trailing
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.panelHeader)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                VStack(spacing: 10) { content }
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            Divider().overlay(Theme.divider)
        }
    }
}

extension PanelSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, trailing: { EmptyView() })
    }
}

// MARK: - Histogram

/// Camera Raw–style clipping triangle: lights up when something is clipped, click to show where.
struct ClipButton: View {
    @Binding var on: Bool
    let clipped: Bool
    let color: Color
    let help: String
    var flipped = false

    var body: some View {
        Button { on.toggle() } label: {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 9, y: 0)); p.addLine(to: CGPoint(x: 0, y: 9))
                p.closeSubpath()
            }
            .fill(clipped ? color : Color(white: 0.35))
            .overlay(Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 9, y: 0)); p.addLine(to: CGPoint(x: 0, y: 9))
                p.closeSubpath()
            }.stroke(Color.white, lineWidth: on ? 1.5 : 0))
            .frame(width: 9, height: 9)
            .scaleEffect(x: flipped ? -1 : 1, y: 1)
            .padding(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HistogramView: View {
    let histogram: [[UInt]]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.09)))
            guard histogram.count == 3 else { return }
            let peak = histogram.flatMap { $0[2..<254] }.max().map(Double.init) ?? 1
            guard peak > 0 else { return }
            let colors: [Color] = [.red, .green, .blue]
            var c = ctx
            c.blendMode = .plusLighter
            for (ch, bins) in histogram.enumerated() {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, n) in bins.enumerated() {
                    let x = CGFloat(i) / 255 * size.width
                    let h = CGFloat(min(1, sqrt(Double(n) / peak))) * (size.height - 2)
                    path.addLine(to: CGPoint(x: x, y: size.height - h))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                c.fill(path, with: .color(colors[ch].opacity(0.55)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

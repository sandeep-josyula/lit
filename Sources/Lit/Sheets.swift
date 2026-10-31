import SwiftUI
import ImageIO
import LitCore

// MARK: - Export

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export JPEG").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text("\(Int((model.exportOptions.quality * 100).rounded()))").monospacedDigit()
                }
                Slider(value: $model.exportOptions.quality, in: 0.5...1, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Resize to fit long edge", isOn: $model.exportOptions.limitLongEdge)
                HStack {
                    TextField("", value: $model.exportOptions.longEdge, format: .number)
                        .frame(width: 80)
                        .disabled(!model.exportOptions.limitLongEdge)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                    Text(outputSize).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Text("sRGB · EXIF and GPS kept").font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { model.export() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var outputSize: String {
        guard let full = model.source?.fullSize else { return "" }
        let s = model.adjustments.outputSize(for: full)
        var w = s.width, h = s.height
        let long = max(w, h)
        if model.exportOptions.limitLongEdge, CGFloat(model.exportOptions.longEdge) < long {
            let k = CGFloat(model.exportOptions.longEdge) / long
            w = (w * k).rounded(); h = (h * k).rounded()
        }
        return "\(Int(w)) × \(Int(h))"
    }
}

// MARK: - Panorama

struct PanoramaSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var urls: [URL] = []
    @State private var rows = 1
    @State private var autoCrop = true
    @AppStorage("panoramaProjection") private var projection = PanoramaProjection.cylindrical.rawValue
    @State private var thumbs: [URL: CGImage] = [:]

    private var rowChoices: [Int] { (1...3).filter { urls.count % $0 == 0 && urls.count / $0 >= 1 && $0 <= urls.count } }
    private var cols: Int { max(1, urls.count / max(rows, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build Panorama").font(.headline)
            Text("Frames are placed row by row, left → right, top row first. Use ◀ ▶ to fix the order.")
                .font(.caption).foregroundStyle(.secondary)

            // Layout preview.
            VStack(spacing: 6) {
                ForEach(0..<max(1, urls.count / cols), id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < urls.count { frameCell(i) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))

            HStack(spacing: 20) {
                Picker("Layout", selection: $rows) {
                    ForEach(rowChoices, id: \.self) { r in
                        Text("\(urls.count / r) × \(r)").tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button("Reverse order") { urls.reverse() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Projection", selection: $projection) {
                    Text("Cylindrical").tag(PanoramaProjection.cylindrical.rawValue)
                    Text("Rectilinear").tag(PanoramaProjection.rectilinear.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Text(projection == PanoramaProjection.rectilinear.rawValue
                     ? "Like one very wide lens: straight lines stay straight and more height survives the crop. Edges stretch, so it suits panoramas up to about 120° across."
                     : "Wraps the scene around you: works for any width and keeps verticals straight. Long horizontal lines may bow slightly.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Auto crop to fill the frame", isOn: $autoCrop)

            previewBox

            if let note = model.panoramaInputNote {
                Label(note, systemImage: "checkmark.seal").font(.caption)
            }
            Text("The merged panorama opens for editing at full quality. Export it (⌘E) to save a JPEG.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") { model.mergePanorama(urls, options: options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urls.count < 2 || model.panoramaPreviewError != nil)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            urls = model.panoramaURLs
            rows = 1
            loadThumbnails()
            refreshPreview()
        }
        .onChange(of: urls) { _, _ in refreshPreview() }
        .onChange(of: rows) { _, _ in refreshPreview() }
        .onChange(of: projection) { _, _ in refreshPreview() }
        .onChange(of: autoCrop) { _, _ in refreshPreview() }
    }

    private var options: PanoramaOptions {
        var o = PanoramaOptions()
        o.rows = rows
        o.autoCrop = autoCrop
        o.projection = PanoramaProjection(rawValue: projection) ?? .cylindrical
        return o
    }

    private func refreshPreview() {
        guard urls.count >= 2, urls.count % max(rows, 1) == 0 else { return }
        model.updatePanoramaPreview(urls, options: options)
    }

    /// A quick, low-resolution render of the result with the current settings.
    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                if let img = model.panoramaPreview {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        .opacity(model.panoramaPreviewBusy ? 0.5 : 1)
                }
                if let err = model.panoramaPreviewError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if model.panoramaPreviewBusy {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.panoramaPreview == nil ? "Aligning frames…" : "Updating…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 200)
            HStack {
                Text("Preview").font(.caption.weight(.semibold))
                Spacer()
                if let s = model.panoramaPreviewSize, model.panoramaPreviewError == nil {
                    Text("≈ \(Int(s.width)) × \(Int(s.height)) px · \(String(format: "%.0f", s.width * s.height / 1_000_000)) MP")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func frameCell(_ i: Int) -> some View {
        let url = urls[i]
        VStack(spacing: 4) {
            ZStack {
                if let t = thumbs[url] {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
            }
            .frame(width: 140 * 3 / CGFloat(max(cols, 3)), height: 90 * 3 / CGFloat(max(cols, 3)))
            HStack(spacing: 4) {
                Button { move(i, by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(i == 0)
                Text(url.lastPathComponent).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                Button { move(i, by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(i == urls.count - 1)
            }
            .font(.system(size: 9))
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard urls.indices.contains(j) else { return }
        urls.swapAt(i, j)
    }

    private func loadThumbnails() {
        let list = urls
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [URL: CGImage] = [:]
            for url in list {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { out[url] = t }
            }
            DispatchQueue.main.async { thumbs = out }
        }
    }
}

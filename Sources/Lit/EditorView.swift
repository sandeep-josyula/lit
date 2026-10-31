import SwiftUI
import LitCore

/// One window: photo on the left, one sidebar on the right (Edit · Gradient · Crop tabs).
struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar(model: model)
                CanvasView(model: model)
            }
            AdjustmentPanel(model: model)
                .frame(width: 300)
        }
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .overlay { BusyOverlay(model: model) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 7) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(toast)
                }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(white: 0.2)))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .sheet(isPresented: $model.showExportSheet) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showPanoramaSheet, onDismiss: { model.clearPanoramaPreview() }) { PanoramaSheet(model: model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct TopBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Brand.wordmark(height: 17)
                .padding(.trailing, 6)
                .help("LIT · " + Brand.tagline)
            barButton("photo", "Open Image", help: "Open a photo (⌘O)") { model.showOpenPanel() }
            barButton("pano", "Build Panorama", help: "Merge photos into a panorama (⇧⌘P)") { model.choosePanoramaFrames() }
            if !model.fileName.isEmpty {
                Divider().frame(height: 16).overlay(Theme.divider)
            }
            Text(model.fileName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.panoramaNeedsExport {
                Text("Not exported yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(Theme.divider))
                    .help("This panorama only exists in LIT until you export it (⌘E).")
            }
            Spacer(minLength: 8)
            if model.source != nil {
                Menu {
                    Button("Fit  (⌘0)") { model.zoomToFit() }
                    Button("100%  (⌘1)") { model.zoomToActualPixels() }
                    Button("200%") { model.setZoom(model.zoom100 * 2) }
                    Divider()
                    Button("Zoom In  (⌘+)") { model.zoomIn() }
                    Button("Zoom Out  (⌘−)") { model.zoomOut() }
                } label: {
                    Label(model.zoom > 1.01 ? "\(model.zoomPercent)%" : "Fit", systemImage: "magnifyingglass")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(model.zoom > 1.01 ? Theme.accent : Theme.secondaryText)
                .help("Zoom: pinch, Z, or double-click the photo. Drag, space-drag or scroll to look around.")

                Button {
                    model.background = model.background.next
                } label: {
                    Circle()
                        .fill(model.background.color)
                        .overlay(Circle().stroke(Theme.secondaryText, lineWidth: 1))
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Flip the background: jet black ↔ pure white (B)")

                Button {
                    model.showOriginal.toggle()
                } label: {
                    Label(model.showOriginal ? "Before" : "After",
                          systemImage: model.showOriginal ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.showOriginal ? Theme.accent : Theme.secondaryText)
                .help("Toggle before / after ( \\ )")

                Button {
                    model.showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(AmberButtonStyle())
                .help("Export JPEG (⌘E)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.canvas)
    }

    private func barButton(_ icon: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .help(help)
    }
}

struct BusyOverlay: View {
    let model: EditorModel
    var body: some View {
        if let msg = model.busyMessage {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 12) {
                    if let p = model.busyProgress {
                        ProgressView(value: p).frame(width: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(msg).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16)))
            }
            .ignoresSafeArea()
        }
    }
}

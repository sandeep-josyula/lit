import SwiftUI
import AppKit

/// Jet-black palette.
enum Theme {
    static let canvas = Color.black
    static let panel = Color.black
    static let panelHeader = Color(white: 0.06)
    static let divider = Color(white: 0.15)
    static let text = Color(white: 0.88)
    static let secondaryText = Color(white: 0.55)
    static let track = Color(white: 0.28)
    /// LIT amber — the dot of the "i". Used sparingly: the current tool, selections, Export.
    static let accent = Color(red: 1.0, green: 0.69, blue: 0.13)

    static let tempTrack = [Color(red: 0.25, green: 0.45, blue: 0.95), Color(red: 0.95, green: 0.85, blue: 0.25)]
    static let satTrack = [Color(white: 0.5), Color(red: 0.90, green: 0.25, blue: 0.25)]
    static let exposureTrack = [Color(white: 0.12), Color(white: 0.9)]
}

extension View {
    func panelLabel() -> some View {
        font(.system(size: 11)).foregroundStyle(Theme.text)
    }
}

/// The LIT name, as shown in the app: the white "lit" with its amber dot, same as the icon.
enum Brand {
    static let tagline = "Simple, honest photo editing."

    /// The wordmark drawn by scripts/make-icon.swift (falls back to text outside the app bundle).
    static let image: NSImage? = Bundle.main.url(forResource: "Wordmark", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    @ViewBuilder static func wordmark(height: CGFloat) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(height: height)
        } else {
            Text("lit").font(.system(size: height * 1.1, weight: .semibold)).foregroundStyle(Color.white)
        }
    }
}

/// The one filled button: amber with black text (Export, Merge).
struct AmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1)))
            .foregroundStyle(Color.black)
    }
}

/// Selected state for tabs, crop shapes and gradient rows: amber text on a faint amber wash.
extension View {
    func selectable(_ selected: Bool, cornerRadius: CGFloat = 6) -> some View {
        self
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(selected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
    }
}

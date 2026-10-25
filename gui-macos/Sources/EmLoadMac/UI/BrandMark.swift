import AppKit
import SwiftUI

/// The EmLoad "E" mark from `Resources/E.png`.
///
/// The assembled `.app` copies the image into `Contents/Resources`, so a plain
/// `Bundle.main` lookup is enough. If the image is missing (for example when
/// running the raw SwiftPM binary without the bundle), the view falls back to
/// the SF Symbol tile so the sidebar never shows an empty slot.
struct BrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let image = Self.bundledImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
        .accessibilityLabel("EmLoad")
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: size * 0.47, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private static let bundledImage: NSImage? = {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "E", withExtension: "png"),
            Bundle.main.url(forResource: "E", withExtension: "png", subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("E.png"),
        ]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }()
}

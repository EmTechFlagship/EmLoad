import AppKit
import SwiftUI

/// True when the process is running on macOS 26 (Tahoe) or newer, where the
/// Liquid Glass design language and its SwiftUI/AppKit APIs are available.
enum LiquidGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var reducesTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

// MARK: - Window backdrop

/// The window's own backdrop. On macOS 26 this is a real `NSGlassEffectView`
/// (Liquid Glass); older releases get the closest equivalent, a behind-window
/// vibrancy material. Reduce Transparency swaps in a solid window colour.
struct LiquidGlassBackdrop: View {
    var body: some View {
        if LiquidGlass.reducesTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else if #available(macOS 26.0, *) {
            // Vibrancy keeps the window legible if the glass has nothing to
            // sample (for example, over a flat desktop); the glass view on top
            // supplies the Liquid Glass refraction.
            ZStack {
                VisualEffectBackdrop(material: .underWindowBackground, blending: .behindWindow)
                GlassBackdropView()
            }
            .ignoresSafeArea()
        } else {
            VisualEffectBackdrop(material: .underWindowBackground, blending: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

@available(macOS 26.0, *)
private struct GlassBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.style = .regular
        nsView.cornerRadius = 0
    }
}

struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .followsWindowActiveState
    }
}

// MARK: - Window configuration

/// Applies the transparent title bar / full-size content view needed for the
/// glass backdrop to reach every edge, including behind the traffic lights.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.title = "EmLoad"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.hasShadow = true

        if LiquidGlass.reducesTransparency {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        } else {
            // Let the glass / vibrancy sample the desktop behind the window.
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}

// MARK: - Glass surfaces

/// A card/panel that uses Liquid Glass on macOS 26 and an ultra-thin material
/// on macOS 13–15.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 18
    private let content: Content

    init(
        padding: CGFloat = 18,
        cornerRadius: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        }
    }
}

// MARK: - Buttons

extension View {
    /// Prominent action button: Liquid Glass on macOS 26, bordered prominent
    /// everywhere else.
    @ViewBuilder
    func emPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action button: Liquid Glass on macOS 26, bordered elsewhere.
    @ViewBuilder
    func emSecondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Small, unobtrusive button for row actions.
    @ViewBuilder
    func emCompactButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
                .controlSize(.small)
        } else {
            self.buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

// MARK: - Window drag area

/// An invisible strip that lets the user drag the window by the custom header.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

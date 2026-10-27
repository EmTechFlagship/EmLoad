import AppKit
import SwiftUI

/// Flat dark chrome matching the EmLoad window: one charcoal surface, a
/// hairline sidebar split, and a solid blue action color.
enum EmTheme {
    static let windowNS = NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1)
    static let window = Color(nsColor: windowNS)
    static let elevated = Color.white.opacity(0.06)
    static let elevatedPressed = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(nsColor: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1))
    static let label = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
}

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
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = EmTheme.windowNS

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}

// MARK: - Glass surfaces

/// A flat raised surface. Same corner and fill as the setup notice in the
/// library, so cards sit on the charcoal window instead of a glass material.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 12
    private let content: Content

    init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = 12,
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
        content
            .background(
                EmTheme.elevated,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(EmTheme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

extension View {
    /// Solid blue action, white label, the same shape as Import IPA.
    func emPrimaryButton() -> some View {
        buttonStyle(EmPrimaryButtonStyle())
    }

    /// Quiet filled button for secondary actions.
    func emSecondaryButton() -> some View {
        buttonStyle(EmSecondaryButtonStyle())
    }

    /// Small text button used inside cards.
    func emCompactButton() -> some View {
        buttonStyle(EmCompactButtonStyle())
    }
}

private struct EmPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(EmTheme.accent.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct EmSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(EmTheme.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? EmTheme.elevatedPressed : EmTheme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(EmTheme.hairline, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct EmCompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EmTheme.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? EmTheme.elevatedPressed : EmTheme.elevated)
            )
            .opacity(isEnabled ? 1 : 0.45)
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

import AppKit
import ObjectiveC
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

enum LiquidGlass {
    static var reducesTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
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

private var nativeSidebarToggleRemoverKey: UInt8 = 0

/// Keeps SwiftUI's automatic sidebar toggle out of the title bar.
///
/// On macOS 26 `NavigationSplitView` ignores `.toolbar(removing: .sidebarToggle)`
/// and re-adds its own toggle whenever the window or column state changes, so a
/// one-shot removal is not enough. Observe each insertion and drop it again.
private final class NativeSidebarToggleRemover {
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSToolbar.willAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let toolbar = notification.object as? NSToolbar,
                  toolbar === self.window?.toolbar else { return }
            // The item is not in `items` yet; remove it once insertion finishes.
            DispatchQueue.main.async { [weak self] in self?.remove() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func remove() {
        guard let toolbar = window?.toolbar else { return }
        let identifier = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        while let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier.rawValue == identifier
        }) {
            toolbar.removeItem(at: index)
        }
    }
}

/// Applies the transparent title bar / full-size content view needed for the
/// flat window surface to reach every edge, including behind the traffic lights.
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
        window.isOpaque = false
        window.backgroundColor = EmTheme.windowNS

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        let remover: NativeSidebarToggleRemover
        if let existing = objc_getAssociatedObject(
            window, &nativeSidebarToggleRemoverKey
        ) as? NativeSidebarToggleRemover {
            remover = existing
        } else {
            remover = NativeSidebarToggleRemover(window: window)
            objc_setAssociatedObject(
                window,
                &nativeSidebarToggleRemoverKey,
                remover,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        remover.remove()
        DispatchQueue.main.async { remover.remove() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { remover.remove() }
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

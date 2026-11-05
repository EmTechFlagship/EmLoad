import SwiftUI

struct SidebarView: View {
    @Binding var section: AppSection
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var membership: PatreonSubscription

    private var items: [AppSection] {
        AppSection.visible(deviceConnected: !state.devices.isEmpty, membership: membership)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 0)

            VStack(spacing: 2) {
                ForEach(items) { item in
                    SidebarNavigationRow(item: item, selected: section == item) {
                        section = item
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 20)

            Spacer(minLength: 12)

            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            if LiquidGlass.reducesTransparency {
                EmTheme.window
            } else {
                VisualEffectBackdrop(material: .sidebar, blending: .withinWindow)
            }
        }
    }
}

/// Compact navigation row matching EmLoad's original window design.
private struct SidebarNavigationRow: View {
    let item: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isMembershipSection ? Color.yellow : (selected ? EmTheme.label : EmTheme.secondary))
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? EmTheme.label : EmTheme.label.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.subtitle)
    }

    private var isMembershipSection: Bool {
        item == .subscription || item == .plusBenefits || item == .proBenefits
    }
}

struct SidebarGlassSurface: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = .regular
        view.cornerRadius = cornerRadius
    }
}

struct SidebarToggleButton: View {
    @Binding var visible: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                visible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EmTheme.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visible ? "Hide sidebar" : "Show sidebar")
    }
}

struct LibraryToggleButton: View {
    @Binding var visible: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                visible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EmTheme.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visible ? "Hide Library" : "Show Library")
        .accessibilityLabel(visible ? "Hide Library" : "Show Library")
    }
}

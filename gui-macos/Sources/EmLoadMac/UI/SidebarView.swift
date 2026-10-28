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
                .frame(height: 38)

            VStack(spacing: 2) {
                ForEach(items) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 18)
                                .foregroundStyle(
                                    item == .subscription || item == .plusBenefits || item == .proBenefits
                                        ? Color.yellow
                                        : (section == item ? EmTheme.accent : EmTheme.label)
                                )
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? EmTheme.accent : EmTheme.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background {
                            if section == item {
                                if #available(macOS 26.0, *) {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(EmTheme.accent.opacity(0.18))
                                        .glassEffect(
                                            .regular.tint(EmTheme.accent.opacity(0.28)).interactive(),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(EmTheme.accent.opacity(0.16))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(item.subtitle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

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

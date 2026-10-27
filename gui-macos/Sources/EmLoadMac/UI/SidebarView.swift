import SwiftUI

struct SidebarView: View {
    @Binding var section: AppSection
    @EnvironmentObject private var state: AppState

    private var items: [AppSection] {
        AppSection.visible(deviceConnected: !state.devices.isEmpty)
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
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? EmTheme.accent : EmTheme.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
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

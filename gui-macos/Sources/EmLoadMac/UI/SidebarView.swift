import SwiftUI

struct SidebarView: View {
    @Binding var section: AppSection
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 38)
                .padding(.horizontal, 20)

            VStack(spacing: 4) {
                ForEach(AppSection.visible) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 20)
                                .foregroundStyle(section == item ? Color.accentColor : .secondary)
                            Text(item.title)
                                .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(SidebarItemBackground(selected: section == item))
                    .help(item.subtitle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 26)

            Spacer(minLength: 12)

            engineFooter
                .padding(18)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            BrandMark(size: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("EmLoad")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("iOS Sideloading")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.isReady ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(state.isReady ? "Engine connected" : "Engine offline")
                    .font(.caption.weight(.medium))
            }

            Text("emload \(state.engineVersion) · Python")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let email = state.account?.email, state.account?.authenticated == true {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarItemBackground: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            if #available(macOS 26.0, *) {
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            } else {
                content.background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        } else {
            content
        }
    }
}

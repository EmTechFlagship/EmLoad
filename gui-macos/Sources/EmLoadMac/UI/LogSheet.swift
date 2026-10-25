import SwiftUI

struct LogSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine activity")
                        .font(.title3.weight(.semibold))
                    Text("Requests, progress steps and Python stderr.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copyToPasteboard(state.logText) }
                    .emSecondaryButton()
                Button("Close") { dismiss() }
                    .emPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                Text(state.logText.isEmpty ? "Nothing logged yet." : state.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 820, height: 560)
    }
}

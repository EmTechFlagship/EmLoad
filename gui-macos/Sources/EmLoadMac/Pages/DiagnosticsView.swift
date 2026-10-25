import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState

    @State private var checks: [DoctorCheck] = []
    @State private var summary = "Run the checks to see whether EmLoad is ready."
    @State private var running = false
    @State private var errorMessage: String?

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Diagnostics",
                subtitle: "Checks Python packages, usbmuxd, Anisette, signing and the data folder."
            ) {
                Button {
                    Task { await run() }
                } label: {
                    Label("Run checks", systemImage: "stethoscope")
                }
                .emPrimaryButton()
                .disabled(running)
            }

            GlassPanel {
                HStack(spacing: 10) {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: summarySymbol)
                            .foregroundStyle(summaryColor)
                    }
                    Text(summary)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if !checks.isEmpty {
                        Text("\(checks.filter { $0.status == "error" }.count) errors · \(checks.filter { $0.status == "warn" }.count) warnings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                GlassPanel {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !checks.isEmpty {
                GlassPanel(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                            if index > 0 {
                                Divider().opacity(0.3).padding(.leading, 48)
                            }
                            row(check)
                        }
                    }
                }
            }
        }
        .task(id: state.isReady) {
            if state.isReady { await run() }
        }
    }

    private func row(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.symbol)
                .font(.system(size: 15))
                .foregroundStyle(color(for: check.status))
                .frame(width: 20)
                .padding(.top, 1)

            Text(check.name)
                .font(.callout.weight(.semibold))
                .frame(width: 150, alignment: .leading)

            Text(check.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summarySymbol: String {
        if checks.contains(where: { $0.status == "error" }) { return "xmark.octagon.fill" }
        if checks.contains(where: { $0.status == "warn" }) { return "exclamationmark.triangle.fill" }
        return checks.isEmpty ? "stethoscope" : "checkmark.circle.fill"
    }

    private var summaryColor: Color {
        if checks.contains(where: { $0.status == "error" }) { return .red }
        if checks.contains(where: { $0.status == "warn" }) { return .orange }
        return checks.isEmpty ? .secondary : .green
    }

    private func color(for status: String) -> Color {
        switch status {
        case "ok": return .green
        case "warn": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    private func run() async {
        guard !running else { return }
        running = true
        errorMessage = nil
        summary = "Running checks…"
        defer { running = false }

        do {
            let raw = try await state.call("doctor.check")
            checks = DoctorCheck.list(from: raw)
            let errors = checks.filter { $0.status == "error" }.count
            let warnings = checks.filter { $0.status == "warn" }.count
            summary = errors == 0 && warnings == 0
                ? "All checks passed"
                : "\(errors) error(s), \(warnings) warning(s)"
            state.statusMessage = summary
        } catch {
            checks = []
            summary = "Could not run diagnostics"
            errorMessage = error.localizedDescription
            state.statusMessage = summary
        }
    }
}

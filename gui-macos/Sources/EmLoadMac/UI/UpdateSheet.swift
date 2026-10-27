import AppKit
import SwiftUI

/// Asks before replacing this copy of EmLoad with a newer GitHub release.
struct UpdateSheet: View {
    @EnvironmentObject private var state: AppState

    let update: AppUpdate

    @State private var phase: Phase = .prompt

    private enum Phase {
        case prompt
        case downloading(Double)
        case installing
        case saved(URL)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !update.notes.isEmpty, case .prompt = phase {
                Text(update.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch phase {
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(update.assetName)")
                        .font(.caption)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing and reopening…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .saved(let url):
                Text("Saved to \(url.lastPathComponent). Replace EmLoad.app with the copy inside, then open it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .prompt:
                EmptyView()
            }

            HStack {
                Button("Later") { state.availableUpdate = nil }
                    .emSecondaryButton()
                    .disabled(isBusy)
                Spacer()
                Button("View Release") { NSWorkspace.shared.open(update.htmlURL) }
                    .emSecondaryButton()
                    .disabled(isBusy)
                actionButton
            }
        }
        .padding(24)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
    }

    private var heading: String {
        switch phase {
        case .saved: return "Update downloaded"
        case .failed: return "Update failed"
        default: return update.prerelease ? "Pre-release available" : "Update available"
        }
    }

    private var subtitle: String {
        switch phase {
        case .saved:
            return "This copy of EmLoad could not replace itself."
        case .installing:
            return "EmLoad will quit, replace this app, and open the new version."
        case .failed:
            return "You are running \(ReleaseVersion.current().description)."
        case .prompt, .downloading:
            let kind = update.prerelease ? "pre-release" : "release"
            return "You have \(ReleaseVersion.current().description). \(update.version.description) is a newer GitHub \(kind)."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .prompt, .failed:
            Button("Download and Restart") { Task { await start() } }
                .emPrimaryButton()
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
        case .saved:
            Button("Done") { state.availableUpdate = nil }
                .emPrimaryButton()
                .keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            ProgressView().controlSize(.small)
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        case .prompt, .saved, .failed: return false
        }
    }

    private func start() async {
        phase = .downloading(0)
        do {
            let result = try await AppUpdateInstaller.apply(update) { fraction in
                Task { @MainActor in
                    phase = .downloading(fraction)
                }
            }
            switch result {
            case .relaunching:
                phase = .installing
                state.appendLog("Installing \(update.version.description) and reopening.")
                NSApp.terminate(nil)
            case .savedToDownloads(let url):
                phase = .saved(url)
                state.appendLog("Saved update to \(url.path)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            state.appendLog("Update failed: \(error.localizedDescription)")
        }
    }
}

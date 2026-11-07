import AppKit
import SwiftUI

/// Separate window that shows a newer GitHub release and its notes.
struct UpdatePopup: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let update = state.availableUpdate {
                UpdateSheet(update: update)
            }
        }
        .background(UpdateWindowConfigurator())
        .onChange(of: state.availableUpdate?.tag) { _, tag in
            if tag == nil {
                dismissWindow(id: AppWindow.update)
            }
        }
    }
}

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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 16)

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    versionCard
                    detailsCard
                    statusBlock
                }
                .padding(20)
            }
            .frame(minHeight: 220, maxHeight: 420)

            Divider().opacity(0.45)

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
            .padding(16)
        }
        .frame(width: 520)
        .background(EmTheme.window)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(EmTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if update.prerelease, case .prompt = phase {
                Text("Pre-release")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(EmTheme.accent.opacity(0.22), in: Capsule())
            }
        }
    }

    private var versionCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("Installed", ReleaseVersion.current().description)
                detailRow("Update", update.version.description)
                detailRow("Download", update.assetName)
            }
        }
    }

    private var detailsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Details")
                    .font(.callout.weight(.semibold))
                Text(update.notes.isEmpty ? "This release has no written notes." : update.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
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
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: String {
        switch phase {
        case .saved: return "Update downloaded"
        case .failed: return "Update failed"
        default: return update.title
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

/// Dark utility window for the update prompt. Closing it dismisses the offer.
private struct UpdateWindowConfigurator: NSViewRepresentable {
    @EnvironmentObject private var state: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
        DispatchQueue.main.async { context.coordinator.configure(nsView.window) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    final class Coordinator: NSObject {
        var state: AppState
        private weak var window: NSWindow?

        init(state: AppState) {
            self.state = state
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self] in
                self?.configure(view.window)
            }
        }

        func configure(_ window: NSWindow?) {
            guard let window else { return }
            applyChrome(window)
            guard window !== self.window else { return }
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        private func applyChrome(_ window: NSWindow?) {
            guard let window else { return }
            window.title = "Software Update"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = EmTheme.windowNS
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }

        @objc func windowWillClose(_ notification: Notification) {
            let state = state
            Task { @MainActor in
                state.availableUpdate = nil
            }
        }
    }
}

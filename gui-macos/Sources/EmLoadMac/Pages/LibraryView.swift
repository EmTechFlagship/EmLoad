import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var state: AppState

    @State private var apps: [LibraryApp] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var status = ""
    @State private var pendingAction: PendingAction?

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Your Library",
                subtitle: "Apps EmLoad has installed, with the time left on each signature."
            ) {
                HStack(spacing: 8) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .emSecondaryButton()
                    .disabled(isLoading || isRefreshing)
                    .help("Reload the library")

                    Button {
                        Task { await refresh(bundleIds: apps.map(\.bundleId)) }
                    } label: {
                        Label("Refresh all", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .emPrimaryButton()
                    .disabled(apps.isEmpty || isRefreshing)
                }
            }

            if let notice = setupNotice {
                NoticeBanner(text: notice)
            }

            if !status.isEmpty {
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                }
            }

            if apps.isEmpty {
                EmptyState(
                    symbol: "square.grid.2x2",
                    title: "No tracked apps",
                    message: "Sideload an app and it will appear here. Refresh re-signs and reinstalls before the profile expires."
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(apps) { app in
                        row(app)
                    }
                }
            }
        }
        .task(id: state.isReady) {
            if state.isReady { await reload() }
        }
        .alert(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.buttonTitle ?? "Continue", role: .destructive) {
                if let action = pendingAction {
                    Task { await perform(action) }
                }
                pendingAction = nil
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    // MARK: - Row

    private var setupNotice: String? {
        guard state.isReady else { return nil }
        let signedIn = state.account?.authenticated == true
        let hasDevice = !state.devices.isEmpty
        if !signedIn && !hasDevice {
            return "Personal-team signing and connected-device installation are not configured yet."
        }
        if !signedIn {
            return "Personal-team signing is not configured yet."
        }
        if !hasDevice {
            return "Connected-device installation is not configured yet."
        }
        return nil
    }

    private func installedLine(_ app: LibraryApp) -> String {
        guard let installedAt = app.installedAt else { return app.compactStatus }
        return "Installed \(Self.installedFormatter.string(from: installedAt))"
    }

    private static let installedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()

    private func row(_ app: LibraryApp) -> some View {
        HStack(spacing: 14) {
            AppIconView(dataURI: app.icon, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                Text(installedLine(app))
                    .font(.system(size: 12))
                    .foregroundStyle(EmTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(app.timeLeftText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(app.expired ? Color.red.opacity(0.9) : EmTheme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))

            HStack(spacing: 4) {
                Button {
                    Task { await refresh(bundleIds: [app.bundleId]) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.tertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("Re-sign and reinstall")

                Button {
                    pendingAction = .uninstall(app)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.tertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("Uninstall from the device")

                Menu {
                    Button("Stop tracking") { pendingAction = .forget(app) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(EmTheme.tertiary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("More actions")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func reload() async {
        guard state.engine != nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            apps = LibraryApp.list(from: try await state.call("library.list"))
            if apps.isEmpty {
                status = ""
            }
        } catch {
            state.report(error)
        }
    }

    private func refresh(bundleIds: [String]) async {
        guard !bundleIds.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        status = "Refreshing \(bundleIds.count) app(s)…"
        state.setBusy(true, status)
        defer {
            isRefreshing = false
            state.setBusy(false)
        }

        var params: [String: Any] = [
            "bundleIds": bundleIds,
            "keepSigned": state.settings.keepSigned,
        ]
        if !state.settings.signedDir.isEmpty {
            params["signedDir"] = state.settings.signedDir
        }

        do {
            let raw = try await state.call(
                "library.refresh",
                params,
                onProgress: { update in
                    if let step = update.step, !step.isEmpty {
                        status = "[\(update.phase)] \(step)"
                    }
                }
            )
            let result = JSON.dict(raw) ?? [:]
            let failed = JSON.int(result["failed"]) ?? 0
            let rows = result["results"] as? [[String: Any]] ?? []
            var failures: [String] = []
            for row in rows {
                let bundle = JSON.string(row["bundle_id"]) ?? "app"
                if JSON.string(row["status"]) == "error" {
                    failures.append("\(bundle): \(JSON.string(row["error"]) ?? "failed")")
                } else if JSON.string(row["status"]) == "not_tracked" {
                    failures.append("\(bundle): not tracked")
                }
            }
            status = failed == 0
                ? "Refreshed \(rows.count - failed) app(s)."
                : "Refreshed \(rows.count - failed) app(s); \(failed) failed."
            state.statusMessage = status

            if !failures.isEmpty {
                state.alertMessage = failures.joined(separator: "\n")
            }
        } catch {
            status = "Refresh failed: \(error.localizedDescription)"
            state.report(error)
        }

        await reload()
    }

    private func perform(_ action: PendingAction) async {
        switch action {
        case .uninstall(let app):
            do {
                _ = try await state.call("apps.uninstall", ["bundleId": app.bundleId])
                status = "Uninstalled \(app.bundleId)."
                state.statusMessage = status
                await reload()
            } catch {
                state.report(error)
            }

        case .forget(let app):
            do {
                _ = try await state.call("library.forget", ["bundleId": app.bundleId])
                status = "Stopped tracking \(app.bundleId)."
                await reload()
            } catch {
                state.report(error)
            }
        }
    }

    // MARK: - Confirmation

    private enum PendingAction: Identifiable {
        case uninstall(LibraryApp)
        case forget(LibraryApp)

        var id: String {
            switch self {
            case .uninstall(let app): return "uninstall-\(app.bundleId)"
            case .forget(let app): return "forget-\(app.bundleId)"
            }
        }

        var title: String {
            switch self {
            case .uninstall: return "Uninstall app?"
            case .forget: return "Stop tracking this app?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .uninstall: return "Uninstall"
            case .forget: return "Forget"
            }
        }

        var message: String {
            switch self {
            case .uninstall(let app):
                return "Uninstall \(app.displayName) from the device? The app is removed; the sideload record is kept."
            case .forget(let app):
                return "Remove the sideload record for \(app.displayName)? This does not uninstall it or delete its signing certificate."
            }
        }
    }
}

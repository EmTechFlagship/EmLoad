import SwiftUI

enum LibraryLayout {
    case list
    case grid
}

/// Shared state for the titlebar tray. The Library owns the real work; the
/// toolbar only needs enough to reflect busy/app-count state.
@MainActor
final class LibraryToolbarModel: ObservableObject {
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var appCount = 0
}

struct LibraryView: View {
    var inspector = false
    @Binding var layout: LibraryLayout
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var toolbarModel: LibraryToolbarModel

    @State private var apps: [LibraryApp] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var activeRefreshBundleID: String?
    @State private var refreshProgress: Double?
    @State private var status = ""
    @State private var pendingAction: PendingAction?

    init(inspector: Bool = false, layout: Binding<LibraryLayout> = .constant(.list)) {
        self.inspector = inspector
        self._layout = layout
    }

    var body: some View {
        PageScroll(horizontalPadding: inspector ? 12 : 32) {
            if inspector {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    LibraryToolbar(
                        layout: $layout,
                        isBusy: isLoading || isRefreshing,
                        hasApps: !apps.isEmpty,
                        reload: { Task { await reload() } },
                        refreshAll: {
                            Task { await refresh(bundleIds: apps.map(\.bundleId)) }
                        }
                    )
                }
            } else {
                PageHeader(
                    title: "Your Library",
                    subtitle: "Apps EmLoad has installed, with the time left on each signature."
                )
            }

            if !inspector, let notice = setupNotice {
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
                    message: inspector
                        ? "Sideload an app and it will appear here."
                        : "Sideload an app and it will appear here. Refresh re-signs and reinstalls before the profile expires."
                )
            } else {
                if layout == .grid {
                    LazyVGrid(columns: gridColumns, spacing: inspector ? 8 : 12) {
                        ForEach(apps) { app in
                            if inspector { inspectorGridCard(app) } else { gridCard(app) }
                        }
                    }
                } else {
                    VStack(spacing: 2) {
                        ForEach(apps) { app in
                            if inspector { inspectorRow(app) } else { row(app) }
                        }
                    }
                }
            }
        }
        .task(id: state.isReady) {
            if state.isReady { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emloadLibraryReload)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emloadLibraryRefreshAll)) { _ in
            if !isRefreshing && !apps.isEmpty {
                Task { await refresh(bundleIds: apps.map(\.bundleId)) }
            }
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

    private var gridColumns: [GridItem] {
        if inspector {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 12)]
    }

    private func inspectorRow(_ app: LibraryApp) -> some View {
        HStack(spacing: 9) {
            AppIconView(dataURI: app.icon, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                    .lineLimit(1)
                Text(app.timeLeftText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(app.expired ? Color.red.opacity(0.9) : EmTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await refresh(bundleIds: [app.bundleId]) }
                }
                Button("Uninstall", systemImage: "trash", role: .destructive) {
                    pendingAction = .uninstall(app)
                }
                Button("Stop tracking") { pendingAction = .forget(app) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(EmTheme.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(isRefreshing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EmTheme.hairline).frame(height: 1)
        }
    }

    private func inspectorGridCard(_ app: LibraryApp) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                AppIconView(dataURI: app.icon, size: 38)
                Spacer(minLength: 0)
                appMenu(app)
            }
            Text(app.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(EmTheme.label)
                .lineLimit(1)
            Text(app.timeLeftText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(app.expired ? Color.red.opacity(0.9) : EmTheme.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .background(EmTheme.elevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(EmTheme.hairline, lineWidth: 1)
        }
    }

    private func appMenu(_ app: LibraryApp) -> some View {
        Menu {
            Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                Task { await refresh(bundleIds: [app.bundleId]) }
            }
            Button("Uninstall", systemImage: "trash", role: .destructive) {
                pendingAction = .uninstall(app)
            }
            Button("Stop tracking") { pendingAction = .forget(app) }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(EmTheme.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(isRefreshing)
    }

    private func gridCard(_ app: LibraryApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                AppIconView(dataURI: app.icon, size: 44)
                Spacer(minLength: 0)
                appMenu(app)
            }
            Text(app.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EmTheme.label)
                .lineLimit(1)
            Text(installedLine(app))
                .font(.system(size: 11))
                .foregroundStyle(EmTheme.secondary)
                .lineLimit(1)
            Text(app.timeLeftText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(app.expired ? Color.red.opacity(0.9) : EmTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(EmTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(EmTheme.hairline, lineWidth: 1)
        }
    }

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
                if activeRefreshBundleID == app.bundleId {
                    HStack(spacing: 6) {
                        if let refreshProgress {
                            ProgressView(value: refreshProgress)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        if let refreshProgress {
                            Text("\(Int(refreshProgress * 100))%")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(EmTheme.secondary)
                        }
                    }
                    .frame(maxWidth: 210)
                    .tint(EmTheme.accent)
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(EmTheme.secondary)
                        .lineLimit(1)
                } else {
                    Text(installedLine(app))
                        .font(.system(size: 12))
                        .foregroundStyle(EmTheme.secondary)
                        .lineLimit(1)
                }
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
        toolbarModel.isLoading = true
        defer {
            isLoading = false
            toolbarModel.isLoading = false
        }
        do {
            apps = LibraryApp.list(from: try await state.call("library.list"))
            toolbarModel.appCount = apps.count
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
        toolbarModel.isRefreshing = true
        activeRefreshBundleID = nil
        refreshProgress = nil
        status = "Refreshing \(bundleIds.count) app(s)…"
        state.setBusy(true, status)
        defer {
            isRefreshing = false
            toolbarModel.isRefreshing = false
            activeRefreshBundleID = nil
            refreshProgress = nil
            state.setBusy(false)
        }

        var params: [String: Any] = [
            "bundleIds": bundleIds,
            "keepSigned": state.settings.keepSigned,
        ]
        if !state.settings.signedDir.isEmpty {
            params["signedDir"] = state.settings.signedDir
        }

        var totalFailed = 0
        var totalRefreshed = 0
        var failures: [String] = []
        for (index, bundleId) in bundleIds.enumerated() {
            activeRefreshBundleID = bundleId
            refreshProgress = nil
            let appName = apps.first(where: { $0.bundleId == bundleId })?.displayName ?? bundleId
            status = "Refreshing \(appName) (\(index + 1) of \(bundleIds.count))…"
            var appParams = params
            appParams["bundleIds"] = [bundleId]

            do {
                let raw = try await state.call(
                    "library.refresh",
                    appParams,
                    onProgress: { update in
                        if let percent = update.percent {
                            refreshProgress = min(1, max(0, percent / 100))
                        }
                        if let step = update.step, !step.isEmpty {
                            status = "[\(update.phase)] \(step)"
                        }
                    }
                )
                let result = JSON.dict(raw) ?? [:]
                let rows = result["results"] as? [[String: Any]] ?? []
                let failed = JSON.int(result["failed"]) ?? 0
                totalFailed += failed
                totalRefreshed += rows.count - failed
                for row in rows {
                let bundle = JSON.string(row["bundle_id"]) ?? "app"
                if JSON.string(row["status"]) == "error" {
                    failures.append("\(bundle): \(JSON.string(row["error"]) ?? "failed")")
                } else if JSON.string(row["status"]) == "not_tracked" {
                    failures.append("\(bundle): not tracked")
                }
                }
            } catch {
                totalFailed += 1
                failures.append("\(bundleId): \(error.localizedDescription)")
            }
        }

        status = totalFailed == 0
            ? "Refreshed \(totalRefreshed) app(s)."
            : "Refreshed \(totalRefreshed) app(s); \(totalFailed) failed."
        state.statusMessage = status
        if !failures.isEmpty {
            state.alertMessage = failures.joined(separator: "\n")
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

/// The grouped library actions shown at the trailing edge of the titlebar.
struct LibraryToolbar: View {
    @Binding var layout: LibraryLayout
    var isBusy = false
    var hasApps = false
    let reload: () -> Void
    let refreshAll: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            LibraryToolbarButton(
                systemImage: "arrow.clockwise",
                help: "Reload the library",
                disabled: isBusy,
                action: reload
            )

            LibraryToolbarButton(
                systemImage: "arrow.triangle.2.circlepath",
                help: "Re-sign and reinstall all apps",
                disabled: isBusy || !hasApps,
                action: refreshAll
            )

            LibraryToolbarButton(
                systemImage: "list.bullet",
                help: "List view",
                selected: layout == .list
            ) {
                layout = .list
            }

            LibraryToolbarButton(
                systemImage: "square.grid.2x2",
                help: "Grid view",
                selected: layout == .grid
            ) {
                layout = .grid
            }
        }
        .padding(3)
        .background {
            if LiquidGlass.reducesTransparency {
                Capsule().fill(EmTheme.elevated)
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.02))
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}

/// One icon button inside the library's rounded action tray. The selected
/// view mode gets a raised, outlined capsule so the active layout reads at a
/// glance.
private struct LibraryToolbarButton: View {
    let systemImage: String
    let help: String
    var selected = false
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    private let width: CGFloat = 32
    private let height: CGFloat = 27

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? EmTheme.label : EmTheme.secondary)
                .frame(width: width, height: height)
                .background {
                    if selected {
                        shape
                            .fill(Color.white.opacity(0.10))
                            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    } else if hovering {
                        shape.fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

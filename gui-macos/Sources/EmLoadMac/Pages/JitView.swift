import SwiftUI

struct JitView: View {
    @EnvironmentObject private var state: AppState

    @State private var selectedUDID: String?
    @State private var apps: [JitApp] = []
    @State private var isLoading = false
    @State private var enablingBundleId: String?
    @State private var relaunchFirst = false
    @State private var status = ""
    @State private var activity: [String] = []

    var body: some View {
        PageScroll {
            PageHeader(
                title: "JIT",
                subtitle: "Attach the device debugger to a sideloaded app, then detach. That marks the process as debugged so it can compile code at runtime until it quits."
            ) {
                Button {
                    Task { await loadApps() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .emSecondaryButton()
                .disabled(isLoading || enablingBundleId != nil || selectedUDID == nil)
            }

            destinationCard
            requirementsCard

            if !status.isEmpty {
                HStack(spacing: 8) {
                    if enablingBundleId != nil { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            appsCard

            if !activity.isEmpty {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel("Activity")
                            Spacer()
                            Button("Clear") { activity.removeAll() }
                                .emCompactButton()
                        }
                        ActivityLog(lines: activity, height: 140)
                    }
                }
            }
        }
        .onAppear {
            if selectedUDID == nil { selectedUDID = state.devices.first?.udid }
        }
        .onChange(of: state.devices) { devices in
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) { return }
            selectedUDID = devices.first?.udid
        }
        .task(id: loadToken) {
            await loadApps()
        }
    }

    private var loadToken: String {
        "\(state.isReady)-\(selectedUDID ?? "")"
    }

    // MARK: - Cards

    private var destinationCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Device")
                Picker("", selection: $selectedUDID) {
                    if state.devices.isEmpty {
                        Text("No device connected").tag(String?.none)
                    }
                    ForEach(state.devices) { device in
                        Text("\(device.displayName) — \(device.shortUDID)")
                            .tag(Optional(device.udid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)

                Toggle("Relaunch the app first", isOn: $relaunchFirst)
                    .font(.callout)
                    .disabled(enablingBundleId != nil)
                Text("Leave this off to attach to an app that is already open. Turn it on for apps that check for JIT as they start: EmLoad quits the app, launches it paused, then enables JIT before its own code runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requirementsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Before you enable JIT")
                requirement("Developer Mode is on (Settings → Privacy & Security → Developer Mode).")
                requirement("The phone is unlocked, and this Mac is trusted.")
                requirement("The app was sideloaded with a development profile. EmLoad profiles include get-task-allow.")
                requirement("JIT lasts until the app quits. Enable it again the next time you open the app.")
            }
        }
    }

    private func requirement(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var appsCard: some View {
        if selectedUDID == nil {
            GlassPanel {
                EmptyState(
                    symbol: "iphone.gen3",
                    title: "No device connected",
                    message: "Plug in your iPhone or iPad, unlock it, and tap Trust. Installed apps will show up here."
                )
            }
        } else if apps.isEmpty {
            GlassPanel {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading installed apps…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                } else {
                    EmptyState(
                        symbol: "square.stack.3d.up",
                        title: "No user apps",
                        message: "Sideload an app first. System apps are hidden because they cannot be debugged with a free development profile."
                    )
                }
            }
        } else {
            GlassPanel(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            Divider().opacity(0.35).padding(.leading, 16)
                        }
                        row(app)
                    }
                }
            }
        }
    }

    private func row(_ app: JitApp) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    Text(app.bundleId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !app.versionText.isEmpty {
                        Text(app.versionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await enable(app) }
            } label: {
                if enablingBundleId == app.bundleId {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Enable JIT", systemImage: "bolt")
                }
            }
            .emSecondaryButton()
            .disabled(enablingBundleId != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    // MARK: - Actions

    private func loadApps() async {
        guard state.isReady, let udid = selectedUDID, enablingBundleId == nil else {
            if selectedUDID == nil { apps = [] }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let raw = try await state.call("jit.apps", ["udid": udid])
            apps = JitApp.list(from: raw)
        } catch {
            apps = []
            state.report(error)
        }
    }

    private func enable(_ app: JitApp) async {
        guard enablingBundleId == nil, let udid = selectedUDID else { return }
        enablingBundleId = app.bundleId
        status = "Enabling JIT for \(app.displayName)…"
        state.setBusy(true, status)
        append("Enabling JIT for \(app.displayName) (\(app.bundleId)).")
        defer {
            enablingBundleId = nil
            state.setBusy(false)
        }

        do {
            let raw = try await state.call(
                "jit.enable",
                [
                    "udid": udid,
                    "bundleId": app.bundleId,
                    "relaunch": relaunchFirst,
                ],
                onProgress: { update in
                    if let step = update.step, !step.isEmpty {
                        status = step
                        append(step)
                    }
                }
            )
            let result = JSON.dict(raw) ?? [:]
            let pid = JSON.int(result["pid"])
            let launched = JSON.bool(result["launched"]) == true
            let pidText = pid.map { "pid \($0)" } ?? "the app"
            status = launched
                ? "Launched \(app.displayName) with JIT enabled (\(pidText)). It stays on until the app quits."
                : "JIT is enabled for \(app.displayName) (\(pidText)). It stays on until the app quits."
            state.statusMessage = status
            append(status)
            state.appendLog(status)
        } catch {
            status = "JIT failed: \(error.localizedDescription)"
            append(status)
            state.report(error)
        }
    }

    private func append(_ line: String) {
        activity.append(line)
        if activity.count > 200 {
            activity.removeFirst(activity.count - 200)
        }
    }
}

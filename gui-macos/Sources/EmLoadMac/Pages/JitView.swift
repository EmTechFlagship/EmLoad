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
    @State private var query = ""
    @State private var showNotes = false

    var body: some View {
        PageScroll {
            PageHeader(
                title: "JIT",
                subtitle: "Enable it for a sideloaded app. It stays on until the app quits."
            )

            if selectedUDID == nil {
                GlassPanel {
                    EmptyState(
                        symbol: "iphone.gen3",
                        title: "No device connected",
                        message: "Plug in your iPhone or iPad, unlock it, and tap Trust. Installed apps will show up here."
                    )
                }
            } else {
                appsPanel
                if !activity.isEmpty {
                    activityCard
                }
            }
        }
        .onAppear {
            if selectedUDID == nil { selectedUDID = state.devices.first?.udid }
        }
        .onChange(of: state.devices) { _, devices in
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) { return }
            selectedUDID = devices.first?.udid
        }
        .onChange(of: selectedUDID) { _, _ in
            query = ""
        }
        .task(id: loadToken) {
            await loadApps()
        }
    }

    private var loadToken: String {
        "\(state.isReady)-\(selectedUDID ?? "")"
    }

    private var selectedDevice: Device? {
        state.devices.first { $0.udid == selectedUDID }
    }

    // MARK: - Panel

    private var appsPanel: some View {
        GlassPanel(padding: 0) {
            VStack(spacing: 0) {
                toolbar
                if !status.isEmpty {
                    statusBanner
                }
                if !apps.isEmpty {
                    searchField
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
                listBody
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            devicePicker

            Spacer(minLength: 12)

            Toggle("Relaunch first", isOn: $relaunchFirst)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EmTheme.secondary)
                .toggleStyle(.checkbox)
                .disabled(enablingBundleId != nil)
                .help("Quit the app, launch it paused, then enable JIT before its own code runs. Leave this off to attach to an app that is already open.")

            Button {
                showNotes.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EmTheme.tertiary)
            }
            .buttonStyle(.plain)
            .help("What JIT needs")
            .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                notesPopover
            }

            Button {
                Task { await loadApps() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .emCompactButton()
            .help("Reload apps")
            .disabled(isLoading || enablingBundleId != nil || selectedUDID == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var devicePicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EmTheme.accent)
            Picker("Device", selection: $selectedUDID) {
                ForEach(state.devices) { device in
                    Text(device.displayName).tag(Optional(device.udid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if let device = selectedDevice {
                Text(device.connectionLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(EmTheme.tertiary)
            }
        }
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you enable JIT")
                .font(.system(size: 13, weight: .semibold))
            note("Developer Mode is on.")
            note("The device is unlocked, and this Mac is trusted.")
            note("The app was sideloaded with a development profile.")
            note("JIT lasts until the app quits.")
            Text("Turn on Relaunch first for apps that check for JIT as they start.")
                .font(.system(size: 12))
                .foregroundStyle(EmTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(EmTheme.accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(EmTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            if enablingBundleId != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.hasPrefix("JIT failed") ? "exclamationmark.circle" : "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.hasPrefix("JIT failed") ? Color.red.opacity(0.9) : EmTheme.accent)
            }
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(EmTheme.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private var listBody: some View {
        if apps.isEmpty {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading installed apps…")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                EmptyState(
                    symbol: "square.stack.3d.up",
                    title: "No user apps",
                    message: "Sideload an app first. System apps stay hidden because a free development profile cannot debug them."
                )
            }
        } else if filteredApps.isEmpty {
            Text("No apps match “\(query)”.")
                .font(.system(size: 13))
                .foregroundStyle(EmTheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 {
                        Divider().opacity(0.35).padding(.leading, 14)
                    }
                    row(app)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var filteredApps: [JitApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(trimmed)
                || app.bundleId.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EmTheme.tertiary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(EmTheme.label)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(EmTheme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Text(countLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EmTheme.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EmTheme.hairline, lineWidth: 1)
        )
    }

    private var countLabel: String {
        let shown = filteredApps.count
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shown == 1 ? "1 app" : "\(shown) apps"
        }
        return "\(shown) of \(apps.count)"
    }

    private func row(_ app: JitApp) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(EmTheme.label)
                        .lineLimit(1)
                    if !app.versionText.isEmpty {
                        Text(app.versionText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(EmTheme.tertiary)
                    }
                }
                Text(app.bundleId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EmTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                Task { await enable(app) }
            } label: {
                if enablingBundleId == app.bundleId {
                    ProgressView().controlSize(.small)
                        .frame(width: 72)
                } else {
                    Text("Enable")
                        .frame(width: 72)
                }
            }
            .emSecondaryButton()
            .disabled(enablingBundleId != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var activityCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Activity")
                    Spacer()
                    Button("Clear") { activity.removeAll() }
                        .emCompactButton()
                }
                ActivityLog(lines: activity, height: 120)
            }
        }
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

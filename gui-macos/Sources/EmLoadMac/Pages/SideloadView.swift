import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SideloadView: View {
    @EnvironmentObject private var state: AppState

    @State private var ipaPath: String?
    @State private var ipa: IpaSummary?
    @State private var displayName = ""
    @State private var bundleId = ""
    @State private var version = ""
    @State private var removeExtensions = true
    @State private var removeUisd = true
    @State private var fileSharing = false
    @State private var keepSigned = false

    @State private var selectedUDID: String?
    @State private var isInspecting = false
    @State private var isSideloading = false
    @State private var progress: Double = 0
    @State private var progressKnown = false
    @State private var phase = ""
    @State private var activity: [String] = []
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var showResetConfirm = false
    @State private var loadedDefaults = false

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Sideload",
                subtitle: "Sign an IPA with your Apple ID and install it. Signatures last seven days."
            )

            sourceCard
            installCard
            optionsCard

            if !activity.isEmpty {
                activityCard
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [ipaContentType],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await loadIPA(url.path) }
            }
        }
        .alert("Reset App ID and profiles?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await resetAppID() }
            }
        } message: {
            Text("This deletes EmLoad's cached Apple App ID, removes its provisioning profiles from the device, and clears the local profile. The signing certificate is kept.")
        }
        .onAppear {
            if !loadedDefaults {
                keepSigned = state.settings.keepSigned
                loadedDefaults = true
            }
            if selectedUDID == nil { selectedUDID = state.devices.first?.udid }
            consumePendingIPA()
        }
        .onChange(of: state.pendingIPAPath) { _ in consumePendingIPA() }
        .onChange(of: state.devices) { devices in
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) { return }
            selectedUDID = devices.first?.udid
        }
    }

    private var ipaContentType: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }

    // MARK: - Source

    private var sourceCard: some View {
        Group {
            if let ipa {
                GlassPanel { ipaIdentity(ipa) }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(dropTargeted ? EmTheme.accent : Color.clear, lineWidth: 1.5)
                    )
            } else {
                dropZone
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else {
                return false
            }
            Task { await loadIPA(url.path) }
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(EmTheme.accent.opacity(dropTargeted ? 0.18 : 0.10))
                if isInspecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(EmTheme.accent)
                }
            }
            .frame(width: 52, height: 52)

            VStack(spacing: 4) {
                Text(dropTargeted ? "Release to add" : "Drop an IPA")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                Text("Or browse for a file on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(EmTheme.secondary)
            }

            Button("Browse…") { showImporter = true }
                .emSecondaryButton()
                .disabled(isInspecting || isSideloading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            EmTheme.elevated.opacity(dropTargeted ? 1 : 0.45),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    dropTargeted ? EmTheme.accent : EmTheme.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [] : [5, 4])
                )
        )
    }

    private func ipaIdentity(_ summary: IpaSummary) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(dataURI: summary.icon, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName ?? summary.bundleId ?? "Unknown app")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                    .lineLimit(1)
                Text(summary.bundleId ?? "No bundle identifier")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EmTheme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    metaChip("\(summary.version ?? "?") (\(summary.build ?? "?"))")
                    metaChip("iOS \(summary.minimumOS ?? "—")")
                    if let platform = summary.platform, platform != "ios" {
                        StatusPill(text: platform, color: .orange)
                    }
                    if summary.encrypted {
                        StatusPill(text: "FairPlay", color: .red)
                    }
                }

                if summary.encrypted {
                    Text("App Store encryption blocks sideloading this IPA.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                } else if !summary.extensions.isEmpty {
                    Text(summary.extensions.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(EmTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .emSecondaryButton()
                .disabled(isInspecting || isSideloading)

                Button {
                    clearIPA()
                } label: {
                    Image(systemName: "xmark")
                }
                .emCompactButton()
                .help("Remove this IPA")
                .disabled(isSideloading)
            }
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(EmTheme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    // MARK: - Install

    private var installCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(EmTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(
                            EmTheme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                    Picker("Device", selection: $selectedUDID) {
                        if state.devices.isEmpty {
                            Text("No device connected").tag(String?.none)
                        }
                        ForEach(state.devices) { device in
                            Text("\(device.displayName) · \(device.shortUDID)")
                                .tag(Optional(device.udid))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 340, alignment: .leading)

                    Button {
                        Task { await state.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .emCompactButton()
                    .help("Refresh devices")
                    .disabled(isSideloading)

                    Spacer(minLength: 8)

                    resetButton

                    Button {
                        Task { await runSideload() }
                    } label: {
                        Label(isSideloading ? "Installing…" : "Install", systemImage: "arrow.down.app")
                    }
                    .emPrimaryButton()
                    .disabled(!canSideload)
                }

                if isSideloading || progressKnown {
                    SideloadProgressBar(percent: progressKnown ? progress : nil)
                }

                if showsStatusLine {
                    HStack(spacing: 8) {
                        if isSideloading || isInspecting {
                            ProgressView().controlSize(.small)
                        }
                        Text(statusLine)
                            .font(.system(size: 12))
                            .foregroundStyle(EmTheme.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var resetButton: some View {
        Button("Reset App ID") {
            showResetConfirm = true
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(EmTheme.secondary)
        .disabled(selectedUDID == nil || isSideloading)
        .help("Delete the cached App ID and provisioning profiles. The signing certificate is kept.")
    }

    private var showsStatusLine: Bool {
        isSideloading || isInspecting || !phase.isEmpty
    }

    private var statusLine: String {
        if !phase.isEmpty { return phase }
        if isInspecting { return "Reading IPA…" }
        return "Installing…"
    }

    private var canSideload: Bool {
        ipa != nil && ipaPath != nil && selectedUDID != nil && !isSideloading && !isInspecting
    }

    // MARK: - Options

    private var optionsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Signing")

                HStack(alignment: .top, spacing: 12) {
                    labeledField("Display name", text: $displayName, prompt: "From the IPA")
                    labeledField("Version", text: $version, prompt: "1.0")
                        .frame(maxWidth: 180)
                }

                labeledField(
                    "Bundle ID",
                    text: $bundleId,
                    prompt: "Blank uses a team-scoped identifier"
                )

                Rectangle()
                    .fill(EmTheme.hairline)
                    .frame(height: 1)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 14
                ) {
                    optionToggle(
                        "Remove extensions",
                        detail: "Free accounts cannot sign app extensions.",
                        isOn: $removeExtensions
                    )
                    optionToggle(
                        "Ignore device limits",
                        detail: "Strip UISupportedDevices before signing.",
                        isOn: $removeUisd
                    )
                    optionToggle(
                        "Files sharing",
                        detail: "Show this app’s documents in Files.",
                        isOn: $fileSharing
                    )
                    optionToggle(
                        "Keep signed IPA",
                        detail: "Save the signed archive after install.",
                        isOn: $keepSigned
                    )
                    .onChange(of: keepSigned) { value in
                        Task { await state.saveSettings(["keep_signed": value]) }
                    }
                }
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EmTheme.secondary)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(EmTheme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(EmTheme.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(EmTheme.hairline, lineWidth: 1)
                )
        }
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EmTheme.label)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(EmTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
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
                ActivityLog(lines: activity, height: 160)
            }
        }
    }

    // MARK: - Actions

    private func clearIPA() {
        ipa = nil
        ipaPath = nil
        displayName = ""
        bundleId = ""
        version = ""
        progress = 0
        progressKnown = false
        phase = ""
    }

    private func loadIPA(_ path: String) async {
        guard !isInspecting else { return }
        isInspecting = true
        let name = (path as NSString).lastPathComponent
        append("Reading \(name)…")
        defer { isInspecting = false }

        do {
            let raw = try await state.call("ipa.inspect", ["path": path])
            let summary = IpaSummary(dictionary: JSON.dict(raw) ?? [:], path: path)
            ipa = summary
            ipaPath = path
            displayName = summary.displayName ?? ""
            version = summary.version ?? ""
            bundleId = ""
            append("Loaded \(summary.appBundle ?? name).")
            state.statusMessage = "IPA loaded"
        } catch {
            ipa = nil
            ipaPath = nil
            append("Could not read the IPA: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func consumePendingIPA() {
        guard let path = state.pendingIPAPath else { return }
        state.pendingIPAPath = nil
        Task { await loadIPA(path) }
    }

    private func runSideload() async {
        guard let ipaPath, let udid = selectedUDID else { return }
        isSideloading = true
        progress = 0
        progressKnown = false
        phase = "Starting…"
        let appName = displayName.isEmpty ? "app" : displayName
        state.setBusy(true, "Sideloading \(appName)…")
        append("Starting sideload…")
        defer {
            isSideloading = false
            state.setBusy(false)
        }

        var params: [String: Any] = [
            "ipa": ipaPath,
            "udid": udid,
            "bundleId": bundleId.trimmingCharacters(in: .whitespaces),
            "displayName": displayName.trimmingCharacters(in: .whitespaces),
            "version": version.trimmingCharacters(in: .whitespaces),
            "removeExtensions": removeExtensions,
            "removeUisd": removeUisd,
            "enableFileSharing": fileSharing,
            "keepSigned": keepSigned,
        ]
        if !state.settings.signedDir.isEmpty {
            params["signedDir"] = state.settings.signedDir
        }

        do {
            let raw = try await state.call(
                "sideload.run",
                params,
                onProgress: { update in
                    if let percent = update.percent {
                        progress = min(max(percent, 0), 100)
                        progressKnown = true
                    }
                    if let step = update.step, !step.isEmpty {
                        phase = "[\(update.phase)] \(step)"
                        append(phase)
                    }
                },
                onLog: { message in
                    append(message)
                }
            )

            let result = JSON.dict(raw) ?? [:]
            let status = JSON.string(result["status"]) ?? "done"
            if status != "installed" {
                throw EngineFailure(
                    message: JSON.string(result["error"]) ?? status,
                    kind: "NotInstalled"
                )
            }

            progress = 100
            progressKnown = true
            let name = JSON.string(result["name"]) ?? appName
            append("Installed \(name) on \(udid).")
            if let regenerations = JSON.int(result["profile_regenerations"]), regenerations > 0 {
                append("Device verification failed \(regenerations) time(s); re-issued a fresh profile.")
            }
            if let expires = JSON.date(result["expires_at"]) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                append("Profile expires \(formatter.string(from: expires)) — refresh before then.")
            }
            state.statusMessage = "Installed \(name)"
        } catch {
            append("Sideload failed: \(error.localizedDescription)")
            state.statusMessage = "Sideload failed"
            state.report(error)
        }
    }

    private func resetAppID() async {
        guard let udid = selectedUDID else { return }
        append("Resetting App ID and profiles…")
        do {
            let raw = try await state.call("provision.reset", ["udid": udid])
            let result = JSON.dict(raw) ?? [:]
            let appID = JSON.string(result["app_id"]) ?? "unknown"
            append("Reset App ID \(appID) and removed cached profile.")

            if let profiles = JSON.dict(result["profiles"]),
               let failed = profiles["failed"] as? [Any],
               !failed.isEmpty {
                let messages = failed.compactMap { JSON.string($0) }
                append("Some device profiles could not be removed: \(messages.joined(separator: "; "))")
            }
            state.statusMessage = "App ID and provisioning profiles reset"
        } catch {
            append("App ID reset failed: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func append(_ message: String) {
        activity.append(message)
        if activity.count > 500 {
            activity.removeFirst(activity.count - 500)
        }
    }
}

/// A track that stays visible on the charcoal card. Provisioning and signing
/// do not report a percent, so the bar slides until the install phase does.
private struct SideloadProgressBar: View {
    var percent: Double?

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    if let percent {
                        Capsule()
                            .fill(EmTheme.accent)
                            .frame(width: width * min(max(percent, 0), 100) / 100)
                            .animation(.easeOut(duration: 0.25), value: percent)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let chunk = max(36, width * 0.32)
                            let travel = max(0, width - chunk)
                            let cycle = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1.4) / 1.4
                            let ping = cycle < 0.5 ? cycle * 2 : 2 - cycle * 2
                            Capsule()
                                .fill(EmTheme.accent)
                                .frame(width: chunk)
                                .offset(x: travel * ping)
                        }
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            Text(percent.map { "\(Int($0.rounded()))%" } ?? "")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(EmTheme.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sideload progress")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "In progress")
    }
}

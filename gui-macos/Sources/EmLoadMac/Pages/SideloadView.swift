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
                subtitle: "Sign and install an .ipa with your own Apple ID. Signatures last seven days."
            )

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 14) {
                    dropZone
                    if let ipa { ipaCard(ipa) }
                    optionsCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 14) {
                    destinationCard
                    activityCard
                }
                .frame(width: 356)
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
        }
        .onChange(of: state.devices) { devices in
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) { return }
            selectedUDID = devices.first?.udid
        }
    }

    private var ipaContentType: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        GlassPanel {
            VStack(spacing: 10) {
                if isInspecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ipa == nil ? "arrow.down.doc" : "checkmark.seal.fill")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(ipa == nil ? Color.secondary : Color.green)
                }

                Text(dropText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Button("Browse…") { showImporter = true }
                    .emSecondaryButton()
                    .disabled(isInspecting || isSideloading)
            }
            .frame(maxWidth: .infinity, minHeight: 118)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
        )
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

    private var dropText: String {
        if let ipa {
            return "IPA: \(ipa.appBundle ?? ipa.fileName)"
        }
        return "Drag & drop an .ipa here, or browse"
    }

    // MARK: - IPA details

    private func ipaCard(_ summary: IpaSummary) -> some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 14) {
                AppIconView(dataURI: summary.icon, size: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.displayName ?? summary.bundleId ?? "Unknown app")
                        .font(.system(size: 16, weight: .semibold))
                    Text(summary.bundleId ?? "no bundle identifier")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("version \(summary.version ?? "?") (\(summary.build ?? "?"))   ·   min iOS \(summary.minimumOS ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let platform = summary.platform, platform != "ios" {
                        Text("Platform: \(platform) — this IPA is not an iOS app.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if summary.encrypted {
                        Text("App Store-encrypted (FairPlay): this IPA cannot be sideloaded.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !summary.extensions.isEmpty {
                        Text("Extensions: \(summary.extensions.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Options

    private var optionsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Options")

                optionRow("Display name") {
                    TextField("", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                optionRow("Bundle ID") {
                    TextField("blank = team-scoped", text: $bundleId)
                        .textFieldStyle(.roundedBorder)
                }
                optionRow("Version") {
                    TextField("", text: $version)
                        .textFieldStyle(.roundedBorder)
                }

                Divider().opacity(0.4)

                Toggle("Remove app extensions (free accounts can't sign them)", isOn: $removeExtensions)
                    .font(.callout)
                Toggle("Remove device restrictions (UISupportedDevices)", isOn: $removeUisd)
                    .font(.callout)
                Toggle("Enable Files-app sharing", isOn: $fileSharing)
                    .font(.callout)
                Toggle("Keep the signed .ipa on disk", isOn: $keepSigned)
                    .font(.callout)
                    .onChange(of: keepSigned) { value in
                        Task { await state.saveSettings(["keep_signed": value]) }
                    }
            }
        }
    }

    private func optionRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            content()
        }
    }

    // MARK: - Destination / actions

    private var destinationCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Destination")

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
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .emCompactButton()

                Divider().opacity(0.4)

                Button {
                    Task { await runSideload() }
                } label: {
                    Label("Sideload to iPhone", systemImage: "arrow.down.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .emPrimaryButton()
                .disabled(!canSideload)

                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset App ID & Profiles", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .emSecondaryButton()
                .disabled(selectedUDID == nil || isSideloading)

                if isSideloading || progress > 0 {
                    ProgressView(value: progress, total: 100)
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 8) {
                    if isSideloading {
                        ProgressView().controlSize(.small)
                    }
                    Text(phase.isEmpty ? (canSideload ? "Ready" : "Choose an IPA and a device") : phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var canSideload: Bool {
        ipa != nil && ipaPath != nil && selectedUDID != nil && !isSideloading && !isInspecting
    }

    private var activityCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("Activity")
                    Spacer()
                    if !activity.isEmpty {
                        Button("Clear") { activity.removeAll() }
                            .emCompactButton()
                    }
                }
                ActivityLog(lines: activity, height: 210)
            }
        }
    }

    // MARK: - Actions

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

    private func runSideload() async {
        guard let ipaPath, let udid = selectedUDID else { return }
        isSideloading = true
        progress = 0
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

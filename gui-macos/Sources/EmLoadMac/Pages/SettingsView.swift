import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var connection = "auto"
    @State private var signedDir = ""
    @State private var keepSigned = false
    @State private var emstoreServer = false
    @State private var dataDir = ""
    @State private var configFile = ""

    @State private var zsign: SigningStatus?
    @State private var zsignMessage = ""
    @State private var downloadingZsign = false

    @State private var emstore: EmStoreStatus?
    @State private var installingEmStore = false
    @State private var emstorePhase = ""

    @State private var loaded = false

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Settings",
                subtitle: "Preferences are stored in EmLoad's macOS Application Support folder and shared with the CLI."
            )

            connectionCard
            signingCard
            // EmSideStore settings are disabled until further notice. The card
            // and its actions stay in this file, ready to be re-enabled.
            // emstoreCard
            dataCard
        }
        .task(id: state.isReady) {
            if state.isReady { await load() }
        }
    }

    // MARK: - Connection / signing

    private var connectionCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Connection")

                HStack(spacing: 12) {
                    Text("Device transport")
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: connectionBinding) {
                        Text("Automatic").tag("auto")
                        Text("USB only").tag("usb")
                        Text("Wi-Fi only").tag("wifi")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                }

                Text("Automatic prefers USB and falls back to Wi-Fi for devices already paired on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().opacity(0.4)

                Toggle("Keep signed .ipa files on disk", isOn: keepSignedBinding)
                    .font(.callout)

                HStack(spacing: 8) {
                    TextField("Signed folder (blank = EmLoad data folder)", text: $signedDir)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await save(["signed_dir": signedDir]) }
                        }
                    Button("Choose…") { chooseSignedFolder() }
                        .emSecondaryButton()
                    Button("Open") { openFolder(signedDir.isEmpty ? dataDir : signedDir) }
                        .emSecondaryButton()
                        .disabled(signedDir.isEmpty && dataDir.isEmpty)
                }
            }
        }
    }

    private var signingCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Signing")

                HStack(spacing: 12) {
                    Image(systemName: zsign?.available == true ? "checkmark.seal.fill" : "signature")
                        .font(.system(size: 22))
                        .foregroundStyle(zsign?.available == true ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(zsign?.available == true ? "zsign is installed" : "zsign not found")
                            .font(.callout.weight(.semibold))
                        if let zsign, zsign.available {
                            Text(zsign.path ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let version = zsign.version {
                                Text(version)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(zsign?.error ?? (zsignMessage.isEmpty
                                 ? "Download zsign here or set EMLOAD_ZSIGN to a compatible binary."
                                 : zsignMessage))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if downloadingZsign { ProgressView().controlSize(.small) }
                    Button(zsign?.available == true ? "Recheck" : "Download zsign") {
                        Task { await zsignAction() }
                    }
                    .emSecondaryButton()
                    .disabled(downloadingZsign)
                }

                Text("EmLoad downloads the official Apple silicon zsign release. The macOS app requires an Apple silicon Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - EmSideStore

    private var emstoreCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("EmSideStore")

                Toggle("Automatically install SideStore when a device connects", isOn: emstoreBinding)
                    .font(.callout)

                Text("EmLoad watches usbmuxd and sideloads SideStore to every new device, just like AltServer. This needs a signed-in Apple ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                HStack(spacing: 24) {
                    stat("Apple ID", emstore?.account.authenticated == true
                         ? (emstore?.account.email ?? "signed in")
                         : "not signed in")
                    stat("Local IPAs", "\(emstore?.ipas.count ?? 0)")
                    stat("Devices", "\(emstore?.devices.count ?? 0)")
                    Spacer()
                    if installingEmStore {
                        ProgressView().controlSize(.small)
                        Text(emstorePhase.isEmpty ? "Installing…" : emstorePhase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button {
                        Task { await installEmStore() }
                    } label: {
                        Label("Install on all devices", systemImage: "arrow.down.app")
                    }
                    .emSecondaryButton()
                    .disabled(installingEmStore || state.devices.isEmpty)
                    Button {
                        Task { await refreshEmStore() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .emSecondaryButton()
                    .disabled(installingEmStore)
                }

                if let ipa = emstore?.ipas.first {
                    Text(ipa)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Data folder

    private var dataCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Data")
                InfoRow(label: "Application Support", value: dataDir, mono: true)
                InfoRow(label: "config.json", value: configFile, mono: true)
                HStack {
                    Button {
                        openFolder(dataDir)
                    } label: {
                        Label("Open data folder", systemImage: "folder")
                    }
                    .emSecondaryButton()
                    .disabled(dataDir.isEmpty)
                    Spacer()
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Bindings

    private var connectionBinding: Binding<String> {
        Binding(
            get: { connection },
            set: { value in
                connection = value
                Task { await save(["connection": value]) }
            }
        )
    }

    private var keepSignedBinding: Binding<Bool> {
        Binding(
            get: { keepSigned },
            set: { value in
                keepSigned = value
                Task { await save(["keep_signed": value]) }
            }
        )
    }

    private var emstoreBinding: Binding<Bool> {
        Binding(
            get: { emstoreServer },
            set: { value in
                emstoreServer = value
                Task { await save(["emstore_server": value]) }
            }
        )
    }

    // MARK: - Actions

    private func load() async {
        await state.reloadSettings()
        apply(state.settings)
        loaded = true
        await refreshZsign()
        // EmSideStore is disabled until further notice.
        // await refreshEmStore()
    }

    private func apply(_ settings: SettingsSnapshot) {
        connection = settings.connection
        signedDir = settings.signedDir
        keepSigned = settings.keepSigned
        emstoreServer = settings.emstoreServer
        dataDir = settings.dataDir
        configFile = settings.configFile
    }

    private func save(_ patch: [String: Any]) async {
        guard loaded else { return }
        await state.saveSettings(patch)
        apply(state.settings)
    }

    private func refreshZsign() async {
        do {
            let raw = try await state.call("signing.status")
            zsign = SigningStatus(dictionary: JSON.dict(raw) ?? [:])
            zsignMessage = ""
        } catch {
            zsignMessage = error.localizedDescription
        }
    }

    private func zsignAction() async {
        if zsign?.available == true {
            await refreshZsign()
            return
        }
        downloadingZsign = true
        state.setBusy(true, "Downloading zsign…")
        defer {
            downloadingZsign = false
            state.setBusy(false)
        }
        do {
            _ = try await state.call("signing.download")
            await refreshZsign()
            state.statusMessage = "zsign installed"
        } catch {
            zsignMessage = error.localizedDescription
            state.report(error)
        }
    }

    private func refreshEmStore() async {
        do {
            let raw = try await state.call("emstore.status")
            let status = EmStoreStatus(dictionary: JSON.dict(raw) ?? [:])
            emstore = status
            state.emstore = status
        } catch {
            state.appendLog("EmSideStore status unavailable: \(error.localizedDescription)")
        }
    }

    private func installEmStore() async {
        installingEmStore = true
        emstorePhase = "Starting…"
        state.setBusy(true, "Installing SideStore…")
        defer {
            installingEmStore = false
            emstorePhase = ""
            state.setBusy(false)
        }
        do {
            let raw = try await state.call(
                "emstore.install",
                [:],
                onProgress: { update in
                    if let step = update.step, !step.isEmpty { emstorePhase = step }
                },
                onLog: { message in
                    state.appendLog(message)
                }
            )
            let result = JSON.dict(raw) ?? [:]
            let failed = JSON.int(result["failed"]) ?? 0
            state.statusMessage = failed > 0
                ? "SideStore install finished with \(failed) failure(s)"
                : "SideStore install finished"
        } catch {
            state.report(error)
        }
        await refreshEmStore()
    }

    private func chooseSignedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Where should EmLoad keep signed .ipa files?"
        if !signedDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: signedDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        signedDir = url.path
        Task { await save(["signed_dir": url.path]) }
    }

    private func openFolder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

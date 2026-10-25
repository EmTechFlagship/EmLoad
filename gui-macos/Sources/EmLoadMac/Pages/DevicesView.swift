import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var state: AppState

    @State private var emstore: EmStoreStatus?
    @State private var loadingEmStore = false
    @State private var installingKey: String?
    @State private var installPhase = ""
    @State private var activity: [String] = []

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Devices",
                subtitle: "Connect an iPhone or iPad with a cable, unlock it, and tap Trust. Wi-Fi devices appear after the first USB pairing."
            ) {
                Button {
                    Task { await state.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .emSecondaryButton()
            }

            if state.devices.isEmpty {
                GlassPanel {
                    EmptyState(
                        symbol: "iphone.gen3",
                        title: "No device connected",
                        message: "Plug in your iPhone or iPad, unlock it, and tap Trust on the device. EmLoad watches usbmuxd and will pick it up automatically."
                    )
                }
            } else {
                ForEach(state.devices) { device in
                    deviceCard(device)
                }
            }

            if !activity.isEmpty {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel("Activity")
                            Spacer()
                            Button("Clear") { activity.removeAll() }
                                .emCompactButton()
                        }
                        ActivityLog(lines: activity, height: 150)
                    }
                }
            }
        }
        .task(id: state.isReady) {
            if state.isReady { await state.refreshDevices() }
        }
    }

    // MARK: - Device card

    private func deviceCard(_ device: Device) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                        Image(systemName: "iphone")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(device.displayName)
                                .font(.system(size: 16, weight: .semibold))
                            StatusPill(text: device.connectionLabel, color: .blue)
                            StatusPill(
                                text: device.responded ? "paired" : "not paired",
                                color: device.responded ? .green : .orange
                            )
                        }
                        Text(device.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(device.udid)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Button {
                        copyToPasteboard(device.udid)
                        state.statusMessage = "Copied device UDID"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .emCompactButton()
                    .help("Copy UDID")
                }
            }
        }
    }

    // MARK: - EmSideStore summary

    private var emstoreCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EmSideStore")
                            .font(.headline)
                        Text("AltServer-style SideStore installation from \(emstore?.repo ?? "embabyty/EmStore").")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loadingEmStore { ProgressView().controlSize(.small) }
                }

                if let emstore {
                    HStack(spacing: 26) {
                        stat("Apple ID", emstore.account.authenticated ? (emstore.account.email ?? "signed in") : "not signed in")
                        stat("Local IPAs", "\(emstore.ipas.count)")
                        stat("Devices", "\(emstore.devices.count)")
                    }

                    if let first = emstore.ipas.first {
                        Text(first)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("SideStore status is unavailable. Run Diagnostics to check the engine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Turn on automatic installation in Settings to install SideStore whenever a new device attaches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await installSideStore(udid: nil) }
                    } label: {
                        Label("Install on all devices", systemImage: "square.stack.3d.down.right")
                    }
                    .emSecondaryButton()
                    .disabled(installingKey != nil || state.devices.isEmpty)
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

    // MARK: - Actions

    private func refreshAll() async {
        await state.refreshDevices()
        await loadEmStore()
    }

    private func loadEmStore() async {
        guard state.engine != nil else { return }
        loadingEmStore = true
        defer { loadingEmStore = false }
        do {
            let raw = try await state.call("emstore.status")
            let status = EmStoreStatus(dictionary: JSON.dict(raw) ?? [:])
            emstore = status
            state.emstore = status
        } catch {
            // Keep the snapshot AppState already loaded during startup.
            emstore = emstore ?? state.emstore
            append("Could not read SideStore status: \(error.localizedDescription)")
        }
    }

    private func installSideStore(udid: String?) async {
        let key = udid ?? "*"
        installingKey = key
        installPhase = "Starting…"
        append(udid == nil ? "Installing SideStore on all devices…" : "Installing SideStore on \(udid!)…")
        defer { installingKey = nil; installPhase = "" }

        var params: [String: Any] = [:]
        if let udid { params["udid"] = udid }

        do {
            let raw = try await state.call(
                "emstore.install",
                params,
                onProgress: { update in
                    if let step = update.step, !step.isEmpty {
                        installPhase = step
                    }
                },
                onLog: { message in
                    append(message)
                }
            )
            let result = JSON.dict(raw) ?? [:]
            let failed = JSON.int(result["failed"]) ?? 0
            let rows = result["results"] as? [[String: Any]] ?? []
            for row in rows {
                let device = JSON.string(row["udid"]) ?? "device"
                let status = JSON.string(row["status"]) ?? "unknown"
                if let error = JSON.string(row["error"]) {
                    append("\(device): \(status) — \(error)")
                } else {
                    append("\(device): \(status)")
                }
            }
            if failed > 0 {
                state.statusMessage = "SideStore install finished with \(failed) failure(s)"
            } else {
                state.statusMessage = "SideStore install finished"
            }
        } catch {
            append("SideStore install failed: \(error.localizedDescription)")
            state.report(error)
        }

        await loadEmStore()
    }

    private func append(_ message: String) {
        activity.append(message)
        if activity.count > 400 {
            activity.removeFirst(activity.count - 400)
        }
    }
}

import SwiftUI

struct MiscView: View {
    @EnvironmentObject private var state: AppState

    @State private var selectedGroup = "springboard"
    @State private var groups: [String: TweakGroup] = [:]
    @State private var loading = false
    @State private var selectedUDID: String?
    @State private var respringAfter = false
    @State private var reboot = true
    @State private var applyMethod = "auto"
    @State private var transferMode = "localhost"
    @State private var skipSetup = true
    @State private var isApplying = false
    @State private var progress: Double = 0
    @State private var phase = ""
    @State private var activity: [String] = []

    private let groupOrder = ["springboard", "daemons", "liquidglass"]

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Misc Tweaks",
                subtitle: "SpringBoard, daemon and Liquid Glass tweaks applied through sparserestore."
            )

            warning

            HStack(spacing: 12) {
                Picker("", selection: $selectedGroup) {
                    Text("SpringBoard").tag("springboard")
                    Text("Daemons").tag("daemons")
                    Text("Liquid Glass").tag("liquidglass")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 440)

                if loading { ProgressView().controlSize(.small) }

                Spacer()

                Button {
                    Task { await reloadGroup(selectedGroup) }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .emSecondaryButton()
                .disabled(loading || isApplying || !state.isReady)
            }

            if let group = groups[selectedGroup] {
                controlsCard(group)
            } else if loading {
                GlassPanel {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading tweak schema…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
            } else {
                GlassPanel {
                    EmptyState(
                        symbol: "wand.and.stars",
                        title: "Tweaks unavailable",
                        message: "EmLoad could not read this tweak group. Check Diagnostics, then reload."
                    )
                }
            }

            applyCard

            if !activity.isEmpty {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 8) {
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
            if state.isReady { await loadGroup(selectedGroup) }
        }
        .onChange(of: selectedGroup) { group in
            guard state.isReady else { return }
            Task { await loadGroup(group) }
        }
        .onAppear {
            if selectedUDID == nil { selectedUDID = state.devices.first?.udid }
        }
        .onChange(of: state.devices) { devices in
            if let selectedUDID, devices.contains(where: { $0.udid == selectedUDID }) { return }
            selectedUDID = devices.first?.udid
        }
    }

    // MARK: - Banner / controls

    private var warning: some View {
        GlassPanel(padding: 14, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("These tweaks modify iOS system files")
                        .font(.callout.weight(.semibold))
                    Text("Apply only to a device you own. Keep a backup and re-apply after iOS updates. Some options need a respring or reboot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func controlsCard(_ group: TweakGroup) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(group.title)
                    .font(.headline)
                Text(group.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider().opacity(0.4)

                ForEach(group.controls) { control in
                    controlView(group.group, control)
                }
            }
        }
    }

    @ViewBuilder
    private func controlView(_ group: String, _ control: TweakControl) -> some View {
        switch control.kind {
        case "separator":
            Divider().opacity(0.35).padding(.vertical, 2)
        case "label":
            SectionLabel(control.text ?? "")
                .padding(.top, 4)
        case "tri":
            TweakTriRow(group: group, control: control)
        case "daemon":
            TweakToggleRow(group: group, control: control, parameter: "checked")
        case "master":
            TweakToggleRow(group: group, control: control, parameter: "value")
        case "check":
            TweakToggleRow(group: group, control: control, parameter: "value")
        case "text":
            TweakTextRow(group: group, control: control)
        case "number":
            TweakNumberRow(group: group, control: control)
        default:
            if let label = control.label {
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Apply card

    private var applyCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Apply")

                HStack(spacing: 10) {
                    Text("Device")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
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
                    Spacer()
                }

                Toggle("Respring after applying", isOn: $respringAfter)
                    .font(.callout)
                    .onChange(of: respringAfter) { value in
                        if value { reboot = false }
                    }
                Toggle("Reboot the device", isOn: $reboot)
                    .font(.callout)
                    .onChange(of: reboot) { value in
                        if value { respringAfter = false }
                    }
                Toggle("Skip Setup Assistant after restore", isOn: $skipSetup)
                    .font(.callout)

                HStack(spacing: 10) {
                    Text("Apply method")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $applyMethod) {
                        Text("Auto").tag("auto")
                        Text("AFC").tag("afc")
                        Text("Restore").tag("restore")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                HStack(spacing: 10) {
                    Text("Transfer")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $transferMode) {
                        Text("Localhost").tag("localhost")
                        Text("On device").tag("ondevice")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Button {
                        Task { await applyTweaks() }
                    } label: {
                        Label("Apply tweaks", systemImage: "wand.and.stars")
                    }
                    .emPrimaryButton()
                    .disabled(selectedUDID == nil || isApplying)

                    Button {
                        Task { await respring() }
                    } label: {
                        Label("Respring", systemImage: "arrow.clockwise.circle")
                    }
                    .emSecondaryButton()
                    .disabled(selectedUDID == nil || isApplying)

                    Spacer()

                    if isApplying { ProgressView().controlSize(.small) }
                    Text(phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isApplying || progress > 0 {
                    ProgressView(value: progress, total: 100)
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    // MARK: - Loading / actions

    private func loadGroup(_ group: String) async {
        guard groups[group] == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let raw = try await state.call("nugget.schema", ["group": group])
            groups[group] = TweakGroup(dictionary: JSON.dict(raw) ?? [:])
        } catch {
            state.report(error)
        }
    }

    private func reloadGroup(_ group: String) async {
        groups.removeValue(forKey: group)
        await loadGroup(group)
    }

    private func applyTweaks() async {
        guard let udid = selectedUDID else { return }
        isApplying = true
        progress = 0
        phase = "Applying…"
        state.setBusy(true, "Applying tweaks…")
        append("Applying \(groups[selectedGroup]?.title ?? "tweaks") to \(udid)…")
        defer {
            isApplying = false
            state.setBusy(false)
        }

        let params: [String: Any] = [
            "udid": udid,
            "respring": respringAfter,
            "reboot": reboot,
            "applyMethod": applyMethod,
            "transferMode": transferMode,
            "skipSetup": skipSetup,
        ]

        do {
            _ = try await state.call(
                "nugget.apply",
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
                onLog: { append($0) }
            )
            progress = 100
            append("Tweaks applied.")
            state.statusMessage = "Tweaks applied"
        } catch {
            append("Apply failed: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func respring() async {
        guard let udid = selectedUDID else { return }
        isApplying = true
        phase = "Respringe requested…"
        state.setBusy(true, "Respringe device…")
        append("Respringe \(udid)…")
        defer {
            isApplying = false
            state.setBusy(false)
        }

        do {
            _ = try await state.call(
                "nugget.respring",
                ["udid": udid],
                onProgress: { update in
                    if let step = update.step, !step.isEmpty { phase = step }
                },
                onLog: { append($0) }
            )
            append("Respringe requested.")
            state.statusMessage = "Respringe requested"
        } catch {
            append("Respring failed: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func append(_ message: String) {
        activity.append(message)
        if activity.count > 400 {
            activity.removeFirst(activity.count - 400)
        }
    }
}

// MARK: - Dynamic control rows

private struct TweakTriRow: View {
    let group: String
    let control: TweakControl
    @EnvironmentObject private var state: AppState
    @State private var value: String

    init(group: String, control: TweakControl) {
        self.group = group
        self.control = control
        _value = State(initialValue: control.state ?? "default")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(control.label ?? control.id)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Picker("", selection: $value) {
                Text("Default").tag("default")
                Text("Enabled").tag("enabled")
                Text("Disabled").tag("disabled")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
            .onChange(of: value) { newValue in
                Task { await save(newValue) }
            }
        }
        .padding(.vertical, 1)
    }

    private func save(_ newValue: String) async {
        do {
            _ = try await state.call(
                "nugget.set",
                ["group": group, "id": control.id, "state": newValue]
            )
        } catch {
            state.report(error)
        }
    }
}

private struct TweakToggleRow: View {
    let group: String
    let control: TweakControl
    let parameter: String
    @EnvironmentObject private var state: AppState
    @State private var isOn: Bool

    init(group: String, control: TweakControl, parameter: String) {
        self.group = group
        self.control = control
        self.parameter = parameter
        _isOn = State(initialValue: JSON.bool(control.value) ?? false)
    }

    var body: some View {
        Toggle(control.label ?? control.id, isOn: $isOn)
            .font(.callout)
            .onChange(of: isOn) { newValue in
                Task { await save(newValue) }
            }
    }

    private func save(_ newValue: Bool) async {
        do {
            _ = try await state.call(
                "nugget.set",
                ["group": group, "id": control.id, parameter: newValue]
            )
        } catch {
            state.report(error)
        }
    }
}

private struct TweakTextRow: View {
    let group: String
    let control: TweakControl
    @EnvironmentObject private var state: AppState
    @State private var text: String

    init(group: String, control: TweakControl) {
        self.group = group
        self.control = control
        _text = State(initialValue: JSON.string(control.value) ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(control.label ?? control.id)
                .font(.callout)
                .frame(width: 220, alignment: .leading)
            TextField(control.placeholder ?? "", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await save() } }
            Button("Save") { Task { await save() } }
                .emCompactButton()
        }
    }

    private func save() async {
        do {
            _ = try await state.call(
                "nugget.set",
                ["group": group, "id": control.id, "value": text]
            )
        } catch {
            state.report(error)
        }
    }
}

private struct TweakNumberRow: View {
    let group: String
    let control: TweakControl
    @EnvironmentObject private var state: AppState
    @State private var text: String

    init(group: String, control: TweakControl) {
        self.group = group
        self.control = control
        _text = State(initialValue: String(JSON.int(control.value) ?? 0))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(control.label ?? control.id)
                .font(.callout)
                .frame(width: 220, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { Task { await save() } }
            if let minimum = control.minimum, let maximum = control.maximum {
                Text("\(minimum)–\(maximum)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Save") { Task { await save() } }
                .emCompactButton()
        }
    }

    private func save() async {
        guard var value = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        if let minimum = control.minimum { value = max(minimum, value) }
        if let maximum = control.maximum { value = min(maximum, value) }
        text = String(value)
        do {
            _ = try await state.call(
                "nugget.set",
                ["group": group, "id": control.id, "value": value]
            )
        } catch {
            state.report(error)
        }
    }
}

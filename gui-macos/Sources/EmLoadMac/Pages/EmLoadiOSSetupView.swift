import AppKit
import EmLoadServerKit
import SwiftUI
import UniformTypeIdentifiers

struct EmLoadiOSSetupView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var membership: PatreonSubscription

    @StateObject private var signIn = StoreSignInCoordinator()
    @State private var account: EmLoadiOSSetup.Account?
    @State private var showSignIn = false
    @State private var selectedUDID: String?
    @State private var retryInstallDevices: [EmLoadiOSSetup.Device]?
    @State private var busy = false
    @State private var status = ""
    @State private var installProgress: Double? = 0
    @State private var installPhase = ""
    @State private var activity: [String] = []

    var body: some View {
        PageScroll {
            if !membership.canInstallEmLoadiOS {
                PageHeader(
                    title: "EmLoadiOS unavailable",
                    subtitle: membership.normalizedTier == "pro"
                        ? "EmLoad Pro includes EmLoad Plus benefits, but companion installs are not available on this plan."
                        : "EmLoadiOS is turned off in your EmLoad Plus benefit settings."
                )
            } else {
                PageHeader(
                    title: "EmLoad iOS Setup",
                    subtitle: "Sign in on this Mac, install EmLoad, and pair your iPhone or iPad for EmLoad iOS."
                ) {
                    if account == nil {
                        Button {
                            showSignIn = true
                        } label: {
                            Label("Sign In", systemImage: "person.badge.key")
                        }
                        .emPrimaryButton()
                        .disabled(busy)
                    } else {
                        Button("Sign Out") {
                            signOut()
                        }
                        .emSecondaryButton()
                        .disabled(busy)
                    }
                }

                accountCard
                deviceCard

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
        }
        .task { if membership.canInstallEmLoadiOS { refreshAccount() } }
        .onChange(of: usbDevices.map(\.udid)) { udids in
            if let selectedUDID, udids.contains(selectedUDID) { return }
            selectedUDID = udids.first
        }
        .sheet(isPresented: $showSignIn, onDismiss: signIn.cancel) {
            StoreSignInSheet(coordinator: signIn) { appleID in
                account = EmLoadiOSSetup.Account(appleID: appleID)
                state.appendLog("EmLoadServer signed in as \(appleID).")
                state.statusMessage = "Signed in as \(appleID)"
                note("Signed in as \(appleID).")
                if let retryInstallDevices {
                    self.retryInstallDevices = nil
                    Task { await installCompanion(on: retryInstallDevices) }
                }
            }
        }
    }

    private var usbDevices: [Device] {
        state.devices.filter { ($0.connection ?? "").localizedCaseInsensitiveContains("usb") }
    }

    private var accountCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("EmLoadServer")
                if let account {
                    Text("Signed in as \(account.appleID)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(EmTheme.label)
                    Text("The session stays in this Mac’s Keychain. The password is not saved.")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                } else {
                    Text("No Apple ID session is saved for EmLoadServer.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(EmTheme.label)
                    Text("Sign in here to create the certificate that signs EmLoad. This is separate from the account EmLoad uses for other sideloads.")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var deviceCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Pair EmLoad iOS")

                if usbDevices.isEmpty {
                    Text("Connect your iPhone or iPad by USB, unlock it, and tap Trust. EmLoad will pair the device and export its private pairing file for import in EmLoad iOS.")
                        .font(.system(size: 13))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Device", selection: udidBinding) {
                        ForEach(usbDevices) { device in
                            Text("\(device.displayName) · \(device.shortUDID)").tag(Optional(device.udid))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        Button {
                            Task { await installCompanion() }
                        } label: {
                            Label("Install EmLoad (iOS)", systemImage: "arrow.down.app")
                        }
                        .emPrimaryButton()
                        .disabled(busy || account == nil || usbDevices.isEmpty)

                        Button {
                            exportPairing()
                        } label: {
                            Label("Pair EmLoad iOS", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .emSecondaryButton()
                        .disabled(busy || selectedUDID == nil)

                    }

                    Text("Pairing validates the USB connection and saves a private pairing file. Choose a location available in the Files app on your iPhone, then import that file from EmLoad iOS Setup. Export and import a fresh file after updating EmLoad so the Mac authorizes IPA imports. Keep it private.")
                        .font(.system(size: 12))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("After importing this pairing file, EmLoad iOS can securely send IPA files to EmLoadServer on this Mac. The Mac signs and installs them over USB; EmLoad iOS also imports the encrypted EmLoad certificate and Apple sign-in session so it can use the same account.")
                        .font(.system(size: 12))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if busy {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(installPhase)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(EmTheme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            if let installProgress {
                                Text("\(Int(installProgress * 100))%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(EmTheme.secondary)
                            }
                        }
                        ProgressView(value: installProgress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel(installPhase)
                    }
                    .frame(maxWidth: 420)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var udidBinding: Binding<String?> {
        Binding(
            get: { selectedUDID ?? usbDevices.first?.udid },
            set: { selectedUDID = $0 }
        )
    }

    private func refreshAccount() {
        do {
            account = try EmLoadiOSSetup.savedAccount()
        } catch {
            account = nil
            note(error.localizedDescription)
        }
    }

    private func signOut() {
        do {
            try EmLoadiOSSetup.signOut()
            account = nil
            note("Apple ID session removed from this Mac.")
            state.appendLog("EmLoadServer signed out.")
        } catch {
            state.report(error)
        }
    }

    private func installCompanion() async {
        guard membership.canInstallEmLoadiOS else { return }
        let targets = usbDevices.map {
            EmLoadiOSSetup.Device(
                udid: $0.udid,
                name: $0.displayName,
                productType: $0.model ?? "iPhone"
            )
        }
        await installCompanion(on: targets)
    }

    private func installCompanion(on targets: [EmLoadiOSSetup.Device]) async {
        guard membership.canInstallEmLoadiOS else { return }
        guard !targets.isEmpty, !busy else { return }
        busy = true
        installProgress = 0
        let names = targets.map(\.name).joined(separator: ", ")
        installPhase = "Preparing Apple signing and device pairing…"
        note("Preparing Apple signing and device pairing, then building a fresh private IPA with Xcode for \(names)…")
        state.setBusy(true, "Preparing and installing EmLoad (iOS)…")
        defer {
            busy = false
            state.setBusy(false)
        }
        do {
            try await EmLoadiOSSetup.installCompanion(on: targets) { fraction, phase in
                Task { @MainActor in
                    installProgress = fraction
                    installPhase = phase
                }
            }
            installProgress = 1
            installPhase = "Installed successfully"
            note("Built a fresh signed IPA privately and installed EmLoad on \(names). The temporary IPA was removed.")
            state.appendLog("Installed EmLoad on \(names).")
            state.statusMessage = "EmLoad installed"
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("session expired") {
                try? EmLoadiOSSetup.signOut()
                account = nil
                state.statusMessage = "Apple sign-in expired. Sign in again to install EmLoad iOS."
                if !usbDevices.isEmpty {
                    retryInstallDevices = targets
                    note("Apple sign-in expired. Sign in again and EmLoad will retry the install.")
                    showSignIn = true
                } else {
                    note("Apple sign-in expired. Reconnect the iPhone, sign in again, then install EmLoad (iOS).")
                }
                state.appendLog("EmLoad iOS install needs a renewed Apple sign-in.")
            } else {
                note("Install failed: \(error.localizedDescription)")
                state.report(error)
            }
        }
    }

    private func exportPairing() {
        guard let udid = selectedUDID ?? usbDevices.first?.udid else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "plist") ?? .data]
        panel.nameFieldStringValue = "\(udid).plist"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Pair & Save"
        panel.message = "EmLoad will pair this iPhone or iPad and export a private pairing file. Choose an iCloud Drive location to make it available in Files on that device. Existing files are not overwritten."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busy = true
        defer { busy = false }
        do {
            try EmLoadiOSSetup.exportPairing(udid: udid, to: url)
            note("Paired the device and saved its pairing file to \(url.path). Import it in EmLoad iOS Setup.")
            state.appendLog("Paired device and exported pairing record for \(udid).")
            state.statusMessage = "EmLoad iOS paired"
        } catch {
            note("Pairing export failed: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func note(_ message: String) {
        status = message
        activity.append(message)
    }
}

@MainActor
private final class StoreSignInCoordinator: ObservableObject {
    @Published var challenge: EmLoadiOSSetup.Challenge?
    private var continuation: CheckedContinuation<EmLoadiOSSetup.Answer, Never>?

    func respond(to challenge: EmLoadiOSSetup.Challenge) async -> EmLoadiOSSetup.Answer {
        await withCheckedContinuation { continuation in
            self.challenge = challenge
            self.continuation = continuation
        }
    }

    func submit(_ answer: EmLoadiOSSetup.Answer) {
        guard continuation != nil else { return }
        challenge = nil
        continuation?.resume(returning: answer)
        continuation = nil
    }

    func cancel() {
        submit(.cancel)
    }
}

private struct StoreSignInSheet: View {
    @ObservedObject var coordinator: StoreSignInCoordinator
    var onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            form

            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    coordinator.cancel()
                    dismiss()
                }
                .emSecondaryButton()
                .disabled(busy && coordinator.challenge == nil)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(primaryTitle) { submit() }
                    .emPrimaryButton()
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var form: some View {
        if let challenge = coordinator.challenge {
            switch challenge {
            case .chooseMethod(_, let phones):
                VStack(alignment: .leading, spacing: 8) {
                    methodButton("Approve on a trusted device") {
                        coordinator.submit(.trustedDevice)
                    }
                    ForEach(phones) { phone in
                        methodButton("Text \(phone.number)") {
                            coordinator.submit(.sms(id: phone.id))
                        }
                        methodButton("Call \(phone.number)") {
                            coordinator.submit(.voice(id: phone.id))
                        }
                    }
                }
            case .trustedDeviceCode, .smsCode, .voiceCode:
                TextField("Verification code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            }
        } else {
            TextField("Apple ID email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
        }
    }

    private func methodButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .emSecondaryButton()
    }

    private var title: String {
        coordinator.challenge == nil ? "Sign in to EmLoadServer" : "Two-factor verification"
    }

    private var detail: String {
        switch coordinator.challenge {
        case nil:
            return "The password is sent to Apple and is not stored. The session stays in the macOS Keychain."
        case .chooseMethod:
            return "Choose how Apple should reach you."
        case .trustedDeviceCode(let error):
            return error ?? "Enter the code from a trusted Apple device."
        case .smsCode(let number, let error):
            return error ?? "Enter the text-message code\(number.map { " for \($0)" } ?? "")."
        case .voiceCode(let number, let error):
            return error ?? "Enter the phone-call code\(number.map { " for \($0)" } ?? "")."
        }
    }

    private var primaryTitle: String {
        switch coordinator.challenge {
        case .chooseMethod:
            return "Continue"
        case .trustedDeviceCode, .smsCode, .voiceCode:
            return "Verify"
        case nil:
            return "Sign In"
        }
    }

    private var canSubmit: Bool {
        switch coordinator.challenge {
        case .chooseMethod:
            return false
        case .trustedDeviceCode, .smsCode, .voiceCode:
            return !code.trimmingCharacters(in: .whitespaces).isEmpty
        case nil:
            return !busy
                && !email.trimmingCharacters(in: .whitespaces).isEmpty
                && !password.isEmpty
        }
    }

    private func submit() {
        if coordinator.challenge != nil {
            let entered = code.trimmingCharacters(in: .whitespaces)
            guard !entered.isEmpty else { return }
            code = ""
            coordinator.submit(.code(entered))
            return
        }
        guard canSubmit else { return }
        let appleID = email.trimmingCharacters(in: .whitespaces)
        let secret = password
        password = ""
        busy = true
        message = ""
        Task {
            do {
                let account = try await EmLoadiOSSetup.signIn(
                    appleID: appleID,
                    password: secret,
                    respond: { challenge in
                        await coordinator.respond(to: challenge)
                    }
                )
                await MainActor.run {
                    busy = false
                    onSuccess(account.appleID)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription
                }
            }
        }
    }
}

import AppKit
import EmLoadServerKit
import SwiftUI
import UniformTypeIdentifiers

struct EmLoadStoreSetupView: View {
    @EnvironmentObject private var state: AppState

    @StateObject private var signIn = StoreSignInCoordinator()
    @State private var account: EmLoadStoreSetup.Account?
    @State private var showSignIn = false
    @State private var selectedUDID: String?
    @State private var busy = false
    @State private var status = ""
    @State private var activity: [String] = []

    var body: some View {
        PageScroll {
            PageHeader(
                title: "EmLoadStore Setup",
                subtitle: "Sign in on this Mac, install EmLoadStoreCompanion, and save a pairing record for the connected device."
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
        .task { refreshAccount() }
        .onChange(of: usbDevices.map(\.udid)) { udids in
            if let selectedUDID, udids.contains(selectedUDID) { return }
            selectedUDID = udids.first
        }
        .sheet(isPresented: $showSignIn, onDismiss: signIn.cancel) {
            StoreSignInSheet(coordinator: signIn) { appleID in
                account = EmLoadStoreSetup.Account(appleID: appleID)
                state.appendLog("EmLoadServer signed in as \(appleID).")
                state.statusMessage = "Signed in as \(appleID)"
                note("Signed in as \(appleID).")
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
                    Text("Sign in here to create the certificate that signs EmLoadStoreCompanion. This is separate from the account EmLoad uses for other sideloads.")
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
                SectionLabel("Connected by USB")

                if usbDevices.isEmpty {
                    Text("A phone or iPad is visible, but companion install and pairing need a USB connection. Unlock it and tap Trust.")
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
                            Label("Install Companion", systemImage: "arrow.down.app")
                        }
                        .emPrimaryButton()
                        .disabled(busy || account == nil || usbDevices.isEmpty)

                        Button {
                            exportPairing()
                        } label: {
                            Label("Export Pairing Record", systemImage: "square.and.arrow.up")
                        }
                        .emSecondaryButton()
                        .disabled(busy || selectedUDID == nil)

                        if busy {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text("Install signs EmLoadStoreCompanion with the saved Apple ID and copies it to every USB device. The pairing file is a credential: keep it for your own device.")
                        .font(.system(size: 12))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            account = try EmLoadStoreSetup.savedAccount()
        } catch {
            account = nil
            note(error.localizedDescription)
        }
    }

    private func signOut() {
        do {
            try EmLoadStoreSetup.signOut()
            account = nil
            note("Apple ID session removed from this Mac.")
            state.appendLog("EmLoadServer signed out.")
        } catch {
            state.report(error)
        }
    }

    private func installCompanion() async {
        let targets = usbDevices.map {
            EmLoadStoreSetup.Device(
                udid: $0.udid,
                name: $0.displayName,
                productType: $0.model ?? "iPhone"
            )
        }
        guard !targets.isEmpty, !busy else { return }
        busy = true
        let names = targets.map(\.name).joined(separator: ", ")
        note("Installing EmLoadStoreCompanion on \(names)…")
        state.setBusy(true, "Installing EmLoadStoreCompanion…")
        defer {
            busy = false
            state.setBusy(false)
        }
        do {
            try await EmLoadStoreSetup.installCompanion(on: targets)
            note("Installed EmLoadStoreCompanion on \(names).")
            state.appendLog("Installed EmLoadStoreCompanion on \(names).")
            state.statusMessage = "EmLoadStoreCompanion installed"
        } catch {
            note("Install failed: \(error.localizedDescription)")
            state.report(error)
        }
    }

    private func exportPairing() {
        guard let udid = selectedUDID ?? usbDevices.first?.udid else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "plist") ?? .data]
        panel.nameFieldStringValue = "\(udid).plist"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Export"
        panel.message = "Save a new pairing record. Existing files are not overwritten."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busy = true
        defer { busy = false }
        do {
            try EmLoadStoreSetup.exportPairing(udid: udid, to: url)
            note("Pairing record saved to \(url.path).")
            state.appendLog("Exported pairing record for \(udid).")
            state.statusMessage = "Pairing record saved"
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
    @Published var challenge: EmLoadStoreSetup.Challenge?
    private var continuation: CheckedContinuation<EmLoadStoreSetup.Answer, Never>?

    func respond(to challenge: EmLoadStoreSetup.Challenge) async -> EmLoadStoreSetup.Answer {
        await withCheckedContinuation { continuation in
            self.challenge = challenge
            self.continuation = continuation
        }
    }

    func submit(_ answer: EmLoadStoreSetup.Answer) {
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
                let account = try await EmLoadStoreSetup.signIn(
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

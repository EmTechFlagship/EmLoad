import SwiftUI

/// Apple ID sign-in with the two-step 2FA flow. The password is handed to the
/// engine once; Python keeps it in memory only until the code arrives.
struct LoginSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var pending2FA = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending2FA ? "Two-factor verification" : "Sign in to Apple")
                        .font(.title3.weight(.semibold))
                    Text(pending2FA
                         ? "Enter the code Apple sent to your trusted device or phone."
                         : "EmLoad uses your Apple ID only to create certificates and profiles.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if pending2FA {
                TextField("Verification code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submit() } }
            } else {
                TextField("Apple ID email", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submit() } }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .emSecondaryButton()
                    .disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(pending2FA ? "Verify" : "Sign In") {
                    Task { await submit() }
                }
                .emPrimaryButton()
                .disabled(busy || !canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private var canSubmit: Bool {
        if pending2FA { return !code.trimmingCharacters(in: .whitespaces).isEmpty }
        return !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func submit() async {
        guard canSubmit, !busy else { return }
        busy = true
        message = ""
        defer { busy = false }

        do {
            if pending2FA {
                let raw = try await state.call(
                    "account.login2fa",
                    ["email": email.trimmingCharacters(in: .whitespaces), "code": code.trimmingCharacters(in: .whitespaces)]
                )
                let status = JSON.string((raw as? [String: Any])?["status"]) ?? ""
                if status == "authenticated" {
                    finish()
                } else {
                    message = "Apple returned: \(status.isEmpty ? "no status" : status)"
                }
            } else {
                let raw = try await state.call(
                    "account.login",
                    ["email": email.trimmingCharacters(in: .whitespaces), "password": password]
                )
                let result = raw as? [String: Any] ?? [:]
                let status = JSON.string(result["status"]) ?? ""
                if status == "2fa_required" {
                    pending2FA = true
                    code = ""
                    let method = JSON.string(result["method"]) == "trusteddevice"
                        ? "trusted device"
                        : "phone"
                    message = "Apple sent a code to your \(method)."
                } else if status == "authenticated" {
                    finish()
                } else {
                    message = "Apple returned: \(status.isEmpty ? "no status" : status)"
                    password = ""
                }
            }
        } catch {
            message = error.localizedDescription
            if !pending2FA { password = "" }
        }
    }

    private func finish() {
        state.appendLog("Signed in as \(email).")
        state.statusMessage = "Signed in as \(email)"
        Task {
            await state.refreshAccount()
            await state.refreshEmStore()
        }
        dismiss()
    }
}

import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var state: AppState

    @State private var status: AccountStatus?
    @State private var teams: [[String: Any]] = []
    @State private var teamsError: String?
    @State private var certificates: [DeveloperCertificate] = []
    @State private var certificatesError: String?
    @State private var certificateToRevoke: DeveloperCertificate?
    @State private var showRevokeConfirmation = false
    @State private var busy = false
    @State private var showSignOut = false

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Account",
                subtitle: "EmLoad signs in directly with Apple. Your password is held in memory only until two-factor verification finishes."
            ) {
                HStack(spacing: 8) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .emSecondaryButton()
                    .disabled(busy)

                    if status?.authenticated == true {
                        Button("Sign Out") { showSignOut = true }
                            .emSecondaryButton()
                            .disabled(busy)
                    } else {
                        Button {
                            state.showLogin = true
                        } label: {
                            Label("Sign In", systemImage: "person.badge.key")
                        }
                        .emPrimaryButton()
                        .disabled(busy)
                    }
                }
            }

            accountCard

            if status?.authenticated == true {
                teamsCard
                certificatesCard
            }
        }
        .task(id: state.isReady) {
            if state.isReady { await refresh() }
        }
        .onChange(of: state.showLogin) { showing in
            if !showing { Task { await refresh() } }
        }
        .alert("Sign out of EmLoad?", isPresented: $showSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
        } message: {
            Text("This clears the saved Apple session. Apps already installed stay on the device.")
        }
        .alert("Revoke certificate?", isPresented: $showRevokeConfirmation) {
            Button("Cancel", role: .cancel) { certificateToRevoke = nil }
            Button("Revoke Certificate", role: .destructive) {
                if let certificateToRevoke {
                    Task { await revoke(certificateToRevoke) }
                }
            }
        } message: {
            Text("Apple will revoke \(certificateToRevoke?.name ?? "this certificate"). Apps signed with it may stop launching. This action cannot be undone.")
        }
    }

    // MARK: - Cards

    private var accountCard: some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill((status?.authenticated == true ? Color.green : Color.secondary).opacity(0.14))
                    Image(systemName: status?.authenticated == true ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(status?.authenticated == true ? .green : .secondary)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 6) {
                    if busy && status == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading account status…").foregroundStyle(.secondary)
                        }
                    } else if let status, status.authenticated {
                        Text(status.email ?? "Signed in")
                            .font(.system(size: 18, weight: .semibold))
                        InfoRow(label: "Team", value: status.teamId ?? "not provisioned yet", mono: true)
                        InfoRow(label: "Developer token", value: status.hasAuthToken ? "available" : "not yet issued")
                        InfoRow(label: "Saved accounts", value: "\(status.accountCount)")
                    } else {
                        Text("Not signed in")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Sign in to create certificates, register App IDs and install profiles. Free Apple IDs work; signatures last seven days.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let count = status?.accountCount, count > 0 {
                            Text("\(count) saved account(s) found. Refresh to resume the session.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var teamsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Developer teams")
                    Spacer()
                    if let teamsError {
                        Text(teamsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                if teams.isEmpty {
                    Text("No teams returned by Apple.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(teams.enumerated()), id: \.offset) { _, team in
                        HStack(spacing: 10) {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(.secondary)
                            Text(teamName(team))
                                .font(.callout.weight(.medium))
                            Text(teamId(team))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            if let type = teamType(team), !type.isEmpty {
                                StatusPill(text: type.uppercased(), color: .blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var certificatesCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Apple Development certificates")
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }

                Text("Certificates belong to the selected Apple developer team. Revoking one can invalidate apps signed with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let certificatesError {
                    Text(certificatesError)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if certificates.isEmpty {
                    Text(busy ? "Loading certificates…" : "No active development certificates found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(certificates) { certificate in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(certificate.name)
                                    .font(.callout.weight(.medium))
                                Text("\(certificate.teamName) · \(certificate.teamID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Serial \(certificate.serialNumber)\(certificate.expiresAt.map { " · Expires \($0)" } ?? "")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button("Revoke", role: .destructive) {
                                certificateToRevoke = certificate
                                showRevokeConfirmation = true
                            }
                            .emSecondaryButton()
                            .disabled(busy)
                        }
                        .padding(.vertical, 5)
                        if certificate.id != certificates.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        await state.refreshAccount()
        status = state.account

        guard status?.authenticated == true else {
            teams = []
            certificates = []
            teamsError = nil
            certificatesError = nil
            return
        }

        do {
            let raw = try await state.call("account.teams")
            teams = raw as? [[String: Any]] ?? []
            teamsError = nil
        } catch {
            teams = []
            certificates = []
            teamsError = error.localizedDescription
            certificatesError = nil
            return
        }

        do {
            certificates = try await loadCertificates(for: teams)
            certificatesError = nil
        } catch {
            certificates = []
            certificatesError = error.localizedDescription
        }
    }

    private func loadCertificates(for teams: [[String: Any]]) async throws -> [DeveloperCertificate] {
        var result: [DeveloperCertificate] = []
        for team in teams {
            let id = teamId(team)
            guard !id.isEmpty else { continue }
            let raw = try await state.call("certificate.list", ["teamId": id])
            let values = raw as? [[String: Any]] ?? []
            result.append(contentsOf: values.compactMap { value in
                guard let serial = JSON.string(value["serial_number"]) else { return nil }
                return DeveloperCertificate(
                    teamID: id,
                    teamName: teamName(team),
                    serialNumber: serial,
                    name: JSON.string(value["name"]) ?? "Apple Development",
                    expiresAt: JSON.string(value["expires_at"])
                )
            })
        }
        return result
    }

    private func revoke(_ certificate: DeveloperCertificate) async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            certificateToRevoke = nil
        }
        do {
            _ = try await state.call("certificate.revoke", [
                "teamId": certificate.teamID,
                "serialNumber": certificate.serialNumber
            ])
            certificates.removeAll { $0.id == certificate.id }
            state.appendLog("Revoked Apple development certificate \(certificate.serialNumber).")
            state.statusMessage = "Certificate revoked"
        } catch {
            certificatesError = error.localizedDescription
            state.report(error)
        }
    }

    private func signOut() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await state.call("account.logout")
            state.appendLog("Signed out.")
            state.statusMessage = "Signed out"
            await refresh()
        } catch {
            state.report(error)
        }
    }

    private func teamName(_ team: [String: Any]) -> String {
        JSON.string(team["name"])
            ?? JSON.string(team["teamName"])
            ?? "Team"
    }

    private func teamId(_ team: [String: Any]) -> String {
        JSON.string(team["team_id"])
            ?? JSON.string(team["teamId"])
            ?? ""
    }

    private func teamType(_ team: [String: Any]) -> String? {
        JSON.string(team["type"]) ?? JSON.string(team["team_type"])
    }
}

private struct DeveloperCertificate: Identifiable, Equatable {
    let teamID: String
    let teamName: String
    let serialNumber: String
    let name: String
    let expiresAt: String?

    var id: String { "\(teamID):\(serialNumber)" }
}

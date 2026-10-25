import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var state: AppState

    @State private var status: AccountStatus?
    @State private var teams: [[String: Any]] = []
    @State private var teamsError: String?
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

    // MARK: - Actions

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        await state.refreshAccount()
        status = state.account

        guard status?.authenticated == true else {
            teams = []
            teamsError = nil
            return
        }

        do {
            let raw = try await state.call("account.teams")
            teams = raw as? [[String: Any]] ?? []
            teamsError = nil
        } catch {
            teams = []
            teamsError = error.localizedDescription
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

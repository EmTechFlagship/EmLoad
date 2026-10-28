import AppKit
import Combine
import Foundation

@MainActor
final class PatreonSubscription: ObservableObject {
    @Published private(set) var tier: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var message = "Connect Patreon to check your membership."
    @Published private(set) var jitBenefitEnabled: Bool
    @Published private(set) var emLoadStoreBenefitEnabled: Bool

    private let workerURL = URL(string: "https://emload-patreon.ios11emiry.workers.dev")!
    private let defaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?

    init() {
        jitBenefitEnabled = defaults.object(forKey: "patreonBenefitJITEnabled") as? Bool ?? true
        emLoadStoreBenefitEnabled = defaults.object(forKey: "patreonBenefitEmLoadStoreEnabled") as? Bool ?? true
        let savedAt = defaults.double(forKey: "patreonMembershipCheckedAt")
        let cachedTier = defaults.string(forKey: "patreonMembershipTier")
        if Date().timeIntervalSince1970 - savedAt < 12 * 60 * 60 {
            tier = cachedTier
            message = cachedTier.map { "EmLoad \($0) verified with Patreon recently." }
                ?? "No active Em Basic or Em Pro membership was found."
        }
    }

    var normalizedTier: String? { tier?.lowercased() }
    var isSubscribed: Bool { normalizedTier == "plus" || normalizedTier == "pro" }
    var hasJITAccess: Bool { isSubscribed && jitBenefitEnabled }
    var canInstallEmLoadStore: Bool {
        normalizedTier != "pro" && (normalizedTier != "plus" || emLoadStoreBenefitEnabled)
    }

    func setJITBenefitEnabled(_ enabled: Bool) {
        jitBenefitEnabled = enabled
        defaults.set(enabled, forKey: "patreonBenefitJITEnabled")
    }

    func setEmLoadStoreBenefitEnabled(_ enabled: Bool) {
        emLoadStoreBenefitEnabled = enabled
        defaults.set(enabled, forKey: "patreonBenefitEmLoadStoreEnabled")
    }

    func connect() {
        guard !isConnecting else { return }
        let sessionID = UUID().uuidString.lowercased()
        var components = URLComponents(url: workerURL.appending(path: "/auth/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
        guard let url = components.url else {
            message = "Could not create the Patreon authorization link."
            return
        }

        guard NSWorkspace.shared.open(url) else {
            message = "Could not open Patreon in your browser."
            return
        }

        isConnecting = true
        message = "Finish signing in to Patreon in your browser."
        pollTask?.cancel()
        pollTask = Task { await waitForResult(sessionID: sessionID) }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        isConnecting = false
        message = "Patreon connection cancelled."
    }

    private func waitForResult(sessionID: String) async {
        defer { isConnecting = false }
        for _ in 0..<300 {
            if Task.isCancelled { return }
            do {
                var components = URLComponents(url: workerURL.appending(path: "/api/session"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
                let (data, response) = try await URLSession.shared.data(from: components.url!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let result = try JSONDecoder().decode(PatreonSessionResult.self, from: data)
                if result.status == "complete" {
                    tier = result.tier
                    if let tier = result.tier {
                        defaults.set(tier, forKey: "patreonMembershipTier")
                    } else {
                        defaults.removeObject(forKey: "patreonMembershipTier")
                    }
                    defaults.set(Date().timeIntervalSince1970, forKey: "patreonMembershipCheckedAt")
                    message = result.tier.map { "EmLoad \($0) is active through Patreon." }
                        ?? "No active Em Basic or Em Pro membership was found for EmAppleFlagship."
                    return
                }
            } catch {
                message = "Waiting for Patreon to finish…"
            }
            try? await Task.sleep(for: .seconds(2))
        }
        message = "Patreon sign-in timed out. Try connecting again."
    }
}

private struct PatreonSessionResult: Decodable {
    let status: String
    let tier: String?
}

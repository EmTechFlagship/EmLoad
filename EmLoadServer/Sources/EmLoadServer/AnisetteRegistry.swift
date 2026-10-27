import Foundation

struct AnisetteServer: Decodable, Hashable {
    let name: String
    let address: String
    let kind: Int

    var url: URL? {
        guard kind == 2 else { return nil }
        return endpoint
    }

    /// Registry entries stay HTTPS. An explicit proxy (`kind != 2`) may use HTTP
    /// on a trusted network.
    var endpoint: URL? {
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && kind != 2),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        return components.url
    }
}

enum AnisetteServerRegistry {
    static let registryURL = URL(string: "https://servers.sidestore.io/servers.json")!
    static let defaultAddress = "https://new.ani.sidestore.io"

    static func load(session: URLSession = .shared) async throws -> [AnisetteServer] {
        var request = URLRequest(url: registryURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw RegistryError.invalidResponse
        }
        guard data.count <= 1_048_576 else {
            throw RegistryError.responseTooLarge
        }

        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [AnisetteServer] {
        guard data.count <= 1_048_576 else {
            throw RegistryError.responseTooLarge
        }
        let decoded = try JSONDecoder().decode(Registry.self, from: data)
        var seenAddresses = Set<String>()
        let servers = decoded.servers.filter { server in
            guard !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  server.url != nil else {
                return false
            }
            return seenAddresses.insert(server.address.lowercased()).inserted
        }
        guard !servers.isEmpty else {
            throw RegistryError.noSupportedServers
        }
        return servers
    }

    static func select(
        server selection: String?,
        preferredAddress: String? = nil,
        from servers: [AnisetteServer]
    ) throws -> AnisetteServer {
        let requested = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let server: AnisetteServer?
        if let requested, !requested.isEmpty {
            server = servers.first {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.address.caseInsensitiveCompare(requested) == .orderedSame
            }
        } else if let preferredAddress {
            server = servers.first {
                $0.address.caseInsensitiveCompare(preferredAddress) == .orderedSame
            }
        } else {
            server = servers.first {
                $0.address.caseInsensitiveCompare(defaultAddress) == .orderedSame
            }
        }
        guard let server else {
            throw RegistryError.serverNotFound(requested ?? preferredAddress)
        }
        return server
    }

    static func customEndpoint(from selection: String) -> AnisetteServer? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") else { return nil }
        let candidate = AnisetteServer(name: "Custom anisette proxy", address: trimmed, kind: 0)
        guard let endpoint = candidate.endpoint else { return nil }
        return AnisetteServer(
            name: "Custom anisette proxy",
            address: endpoint.absoluteString,
            kind: 0
        )
    }

    private struct Registry: Decodable {
        let servers: [AnisetteServer]
    }

    private enum RegistryError: LocalizedError {
        case invalidResponse
        case responseTooLarge
        case noSupportedServers
        case serverNotFound(String?)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "SideStore's Anisette registry returned an unsuccessful response."
            case .responseTooLarge:
                return "SideStore's Anisette registry exceeded the 1 MB limit."
            case .noSupportedServers:
                return "SideStore's registry contained no HTTPS Mac-ADI servers."
            case .serverNotFound(let selection):
                if let selection {
                    return "No supported Mac-ADI server named or addressed '\(selection)' was found. Run 'emloadserver anisette-servers' to list current choices."
                }
                return "The default SideStore (New) Mac-ADI server is not listed. Run 'emloadserver anisette-servers' and pass a server name with --server."
            }
        }
    }
}

import Foundation

/// Classifies LLM endpoint URLs. Single source of truth for "is this a local
/// server the user runs themselves" — used to waive the API-key requirement,
/// pick retry/timeout policy, and word connection errors.
nonisolated enum EndpointClassifier {
    /// True for loopback and private-network hosts (localhost, 127/8, ::1,
    /// 10/8, 172.16/12, 192.168/16), e.g. Ollama, LM Studio or llama-server.
    static func isLocal(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }

        let hostLower = host.lowercased()

        // Loopback
        if hostLower == "localhost" || hostLower == "::1" || hostLower.hasPrefix("127.") {
            return true
        }

        // 10.x.x.x and 192.168.x.x
        if hostLower.hasPrefix("10.") || hostLower.hasPrefix("192.168.") {
            return true
        }

        // 172.16.x.x - 172.31.x.x
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31
            {
                return true
            }
        }

        return false
    }
}

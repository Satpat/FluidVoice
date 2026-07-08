// Shared LLM plumbing for meeting features (Q&A, summaries).
//
// Resolves the user's AI Enhancement provider selection (built-in providers,
// custom OpenAI-compatible endpoints like Ollama or llama-server, or Apple
// Intelligence on-device) and runs a chat completion against it.

import Foundation

enum MeetingAIClient {
    struct Turn {
        let role: String // "user" | "assistant"
        let content: String
    }

    static func complete(systemPrompt: String, turns: [Turn]) async throws -> String {
        let resolved = Self.resolveProvider()

        if resolved.providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                let flattened = turns
                    .map { "\($0.role == "user" ? "User" : "Assistant"): \($0.content)" }
                    .joined(separator: "\n")
                return try await provider.process(systemPrompt: systemPrompt, userText: flattened)
            }
            #endif
            throw MeetingRecordingError("Apple Intelligence is not available on this system.")
        }

        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingRecordingError("No AI model selected. Configure one under AI Enhancement.")
        }
        let isLocal = ModelRepository.shared.isLocalEndpoint(resolved.baseURL)
        if !isLocal, resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MeetingRecordingError("Missing API key for \(resolved.providerID). Configure it under AI Enhancement.")
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in turns {
            messages.append(["role": turn.role, "content": turn.content])
        }

        var config = LLMClient.Config(
            messages: messages,
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: SettingsStore.shared.isTemperatureUnsupported(resolved.model) ? nil : 0.3,
            extraParameters: [:]
        )
        config.timeoutSeconds = 180

        let response = try await LLMClient.shared.call(config)
        return response.content
    }

    // MARK: - Provider resolution

    struct ResolvedProvider {
        let providerID: String
        let baseURL: String
        let model: String
        let apiKey: String
    }

    /// Mirror of the AI Enhancement provider resolution (see
    /// DictationPostProcessingService.resolveProvider), without the
    /// dictation-slot and Private AI special cases.
    static func resolveProvider() -> ResolvedProvider {
        let settings = SettingsStore.shared
        let providerID = settings.selectedProviderID
        let selectedModels = settings.selectedModelByProvider
        let providerKeys = settings.providerAPIKeys

        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            let key = "custom:\(saved.id)"
            return ResolvedProvider(
                providerID: providerID,
                baseURL: saved.baseURL,
                model: selectedModels[key] ?? saved.models.first ?? "",
                apiKey: providerKeys[key] ?? providerKeys[providerID] ?? ""
            )
        }

        if ModelRepository.shared.isBuiltIn(providerID) {
            return ResolvedProvider(
                providerID: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: selectedModels[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? "",
                apiKey: providerKeys[providerID] ?? ""
            )
        }

        return ResolvedProvider(
            providerID: providerID,
            baseURL: "",
            model: selectedModels[providerID] ?? "",
            apiKey: providerKeys[providerID] ?? ""
        )
    }
}

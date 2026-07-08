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

    // MARK: - Context-window handling

    /// Rough chars-per-token heuristic; good enough for budgeting.
    static func approxTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Context budget by provider. Apple Intelligence's on-device model has a
    /// hard ~4k window. Every other provider starts effectively unbounded so
    /// the FULL transcript is sent — accuracy is never silently degraded by
    /// trimming a transcript the model could have held. If a provider really
    /// rejects the prompt as too long, the retry loop below backs the budget
    /// down until it fits.
    static func contextBudgetTokens(for provider: ResolvedProvider) -> Int {
        provider.providerID == "apple-intelligence" ? 4096 : 1_000_000
    }

    /// Keep the most recent transcript lines within a token budget, with an
    /// omission marker so the model knows earlier content is missing.
    static func trimmedTranscript(_ transcript: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        guard transcript.count > maxChars else { return transcript }

        let lines = transcript.components(separatedBy: "\n")
        var kept: [String] = []
        var chars = 0
        for line in lines.reversed() {
            chars += line.count + 1
            if chars > maxChars { break }
            kept.append(line)
        }
        let omitted = max(0, lines.count - kept.count)
        return "[Earlier part of the meeting (\(omitted) lines) omitted to fit the model's context window; the most recent part follows.]\n"
            + kept.reversed().joined(separator: "\n")
    }

    /// Run a completion whose system prompt embeds a (possibly long) meeting
    /// transcript. The transcript is pre-trimmed to the provider's budget,
    /// and when a provider still reports a context overflow the budget is
    /// halved and the call retried.
    static func completeAboutTranscript(
        transcript: String,
        turns: [Turn],
        systemPrompt: (String) -> String
    ) async throws -> String {
        var budgetTokens = Self.contextBudgetTokens(for: Self.resolveProvider())
        let overheadTokens = Self.approxTokens(systemPrompt(""))
            + turns.reduce(0) { $0 + Self.approxTokens($1.content) }
            + 1024 // response reserve

        var attempt = 0
        while true {
            attempt += 1
            let transcriptBudget = max(512, budgetTokens - overheadTokens)
            let fitted = Self.trimmedTranscript(transcript, maxTokens: transcriptBudget)
            do {
                return try await Self.complete(systemPrompt: systemPrompt(fitted), turns: turns)
            } catch {
                let message = error.localizedDescription.lowercased()
                let isContextOverflow = message.contains("context")
                    || message.contains("too long")
                    || message.contains("maximum length")
                    || message.contains("token limit")
                guard isContextOverflow, attempt < 4, transcriptBudget > 512 else { throw error }
                budgetTokens /= 2
            }
        }
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

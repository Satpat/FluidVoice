import Foundation

nonisolated struct MeetAILLMTurn: Equatable, Sendable {
    let role: String // "user" | "assistant"
    let content: String
}

nonisolated struct MeetAIProviderDescriptor: Equatable, Sendable {
    let providerID: String
    let modelID: String
}

nonisolated struct MeetAIResolvedProvider: Equatable, Sendable {
    let providerID: String
    let baseURL: String
    let model: String
    let apiKey: String

    var isLocal: Bool { EndpointClassifier.isLocal(self.baseURL) }
}

nonisolated struct MeetAILLMError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { self.message }
}

@MainActor
protocol MeetAILLMCompleting {
    func complete(systemPrompt: String, turns: [MeetAILLMTurn]) async throws -> String
    func completeAboutTranscript(transcript: String, turns: [MeetAILLMTurn], systemPrompt: (String) -> String) async throws -> String
    func descriptor() -> MeetAIProviderDescriptor
}

/// Meeting LLM calls through the user's AI Enhancement provider (spec §5.4, §12.1).
@MainActor
struct MeetAILLM: MeetAILLMCompleting {
    static let requestTimeout: TimeInterval = 180

    /// MeetAI-owned session so long meeting requests never change the shared client's timeouts.
    private static let client: LLMClient = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = 600
        return LLMClient(session: URLSession(configuration: configuration))
    }()

    func descriptor() -> MeetAIProviderDescriptor {
        guard let provider = try? Self.resolveProvider() else {
            return MeetAIProviderDescriptor(providerID: "unknown", modelID: "unknown")
        }
        return MeetAIProviderDescriptor(providerID: provider.providerID, modelID: provider.model)
    }

    func complete(systemPrompt: String, turns: [MeetAILLMTurn]) async throws -> String {
        let provider = try Self.resolveProvider()
        if provider.isLocal { await Self.waitForLocalEndpoint(provider.baseURL) }
        let settings = SettingsStore.shared
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages += turns.map { ["role": $0.role, "content": $0.content] }
        var config = LLMClient.Config(
            messages: messages,
            model: provider.model,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            streaming: false,
            tools: [],
            temperature: settings.isTemperatureUnsupported(provider.model) ? nil : 0.3,
            maxTokens: settings.isReasoningModel(provider.model) ? 32_000 : nil,
            extraParameters: Self.reasoningParameters(model: provider.model, providerID: provider.providerID)
        )
        config.timeoutSeconds = Self.requestTimeout
        let response = try await Self.client.call(config)
        return response.content
    }

    func completeAboutTranscript(transcript: String, turns: [MeetAILLMTurn], systemPrompt: (String) -> String) async throws -> String {
        let provider = try Self.resolveProvider()
        return try await Self.completeFittingContext(
            transcript: transcript,
            turns: turns,
            systemPrompt: systemPrompt,
            startingBudgetTokens: 1_000_000,
            maxAttempts: provider.isLocal ? 20 : 4,
            complete: { try await self.complete(systemPrompt: $0, turns: $1) }
        )
    }

    // MARK: Provider resolution

    static func resolveProvider(settings: SettingsStore = .shared) throws -> MeetAIResolvedProvider {
        let providerID = settings.selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            throw MeetAILLMError("No AI provider is selected. Choose one under AI Enhancement.")
        }
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            throw MeetAILLMError("Meeting AI features need a cloud or local-server provider. Private AI isn't supported for meetings yet; choose another provider under AI Enhancement.")
        }
        let isBuiltIn = ModelRepository.shared.isBuiltIn(providerID)
        let bareID = providerID.hasPrefix("custom:") ? String(providerID.dropFirst("custom:".count)) : providerID
        let key = isBuiltIn ? providerID : "custom:\(bareID)"
        let saved = settings.savedProviders.first { $0.id == bareID }
        let baseURL = (saved?.baseURL ?? (isBuiltIn ? ModelRepository.shared.defaultBaseURL(for: providerID) : ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = [settings.selectedModelByProvider[key], settings.selectedModelByProvider[providerID]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let model = selected ?? saved?.models.first ?? ModelRepository.shared.defaultModels(for: providerID).first ?? ""
        let apiKey = (settings.getAPIKey(for: providerID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            throw MeetAILLMError("No endpoint is configured for \(providerID). Check AI Enhancement.")
        }
        guard !model.isEmpty else {
            throw MeetAILLMError("No AI model is selected. Choose one under AI Enhancement.")
        }
        if !EndpointClassifier.isLocal(baseURL), apiKey.isEmpty {
            throw MeetAILLMError("Missing API key for \(providerID). Add it under AI Enhancement.")
        }
        return MeetAIResolvedProvider(providerID: providerID, baseURL: baseURL, model: model, apiKey: apiKey)
    }

    private static func reasoningParameters(model: String, providerID: String) -> [String: Any] {
        guard let config = SettingsStore.shared.getReasoningConfig(forModel: model, provider: providerID), config.isEnabled else { return [:] }
        if config.parameterName == "enable_thinking" {
            return [config.parameterName: config.parameterValue == "true"]
        }
        return [config.parameterName: config.parameterValue]
    }

    /// Waits up to ~40 s for a local server (Ollama, LM Studio, llama-server) to accept connections.
    private static func waitForLocalEndpoint(_ baseURL: String) async {
        guard let url = URL(string: baseURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        for attempt in 0..<20 {
            if (try? await URLSession.shared.data(for: request)) != nil {
                if attempt > 0 { DebugLogger.shared.info("Local AI endpoint reachable after \(attempt * 2)s", source: "MeetAI") }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        DebugLogger.shared.warning("Local AI endpoint unreachable: \(baseURL)", source: "MeetAI")
    }

    // MARK: Context window

    static func approxTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

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

    static func isContextOverflow(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("context") || message.contains("too long")
            || message.contains("maximum length") || message.contains("token limit")
    }

    /// Sends the full transcript first; on a context-overflow error halves what was actually sent and retries.
    static func completeFittingContext(
        transcript: String,
        turns: [MeetAILLMTurn],
        systemPrompt: (String) -> String,
        startingBudgetTokens: Int,
        maxAttempts: Int,
        complete: (String, [MeetAILLMTurn]) async throws -> String
    ) async throws -> String {
        var budgetTokens = startingBudgetTokens
        let overheadTokens = self.approxTokens(systemPrompt("")) + turns.reduce(0) { $0 + self.approxTokens($1.content) } + 1_024
        var attempt = 0
        while true {
            attempt += 1
            let transcriptBudget = max(512, budgetTokens - overheadTokens)
            let fitted = self.trimmedTranscript(transcript, maxTokens: transcriptBudget)
            do {
                return try await complete(systemPrompt(fitted), turns)
            } catch {
                guard self.isContextOverflow(error), attempt < maxAttempts, transcriptBudget > 512 else { throw error }
                budgetTokens = min(budgetTokens, overheadTokens + self.approxTokens(fitted)) / 2
            }
        }
    }
}

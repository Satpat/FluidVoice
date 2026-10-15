import Foundation

/// The single implementation of AI post-processing for dictated text, used by
/// dictation (ContentView / DictationCoordinator) and the Local API.
///
/// The two callers historically had separate implementations that diverged
/// in ~12 ways (prompt routing, Private AI gating, key fallback, timeout,
/// GAAV formatting, ...). `Mode` reproduces each caller's behaviour exactly;
/// every `switch mode` below marks one of those divergences. Aligning a
/// behaviour later means deleting its switch.
@MainActor
final class DictationAIProcessor {
    static let shared = DictationAIProcessor()

    enum Mode: Equatable {
        /// Dictation, prompt test, prompt mode and the AI chat playground.
        case dictation
        /// Local API `/postprocess`.
        case localAPI
    }

    struct AppContext: Equatable {
        let name: String
        let bundleID: String
        let windowTitle: String
    }

    struct Request {
        var text: String
        var mode: Mode
        /// Transient system prompt (prompt test / prompt mode). Non-nil — even
        /// blank — marks a dictation call; a blank value still falls back to
        /// the slot prompt.
        var overridePrompt: String? = nil
        /// Slot explicitly passed by the caller. Non-nil marks a dictation call.
        var slot: SettingsStore.DictationShortcutSlot? = nil
        /// Slot of the in-progress recording, used for prompt text and tracing
        /// when `slot` is nil.
        var activeSlot: SettingsStore.DictationShortcutSlot? = nil
        /// Target app for per-app prompt routing; nil = no app (Local API).
        var app: AppContext? = nil
    }

    struct Result: Equatable {
        let text: String
        let providerID: String
        let model: String
    }

    struct ProviderSettings {
        var selectedProviderID: String
        var savedProviders: [SettingsStore.SavedProvider]
        var selectedModelByProvider: [String: String]
        var providerAPIKeys: [String: String]

        static func current() -> ProviderSettings {
            let settings = SettingsStore.shared
            return ProviderSettings(
                selectedProviderID: settings.selectedProviderID,
                savedProviders: settings.savedProviders,
                selectedModelByProvider: settings.selectedModelByProvider,
                providerAPIKeys: settings.providerAPIKeys
            )
        }
    }

    struct ResolvedProvider: Equatable {
        let providerID: String
        let providerKey: String
        let baseURL: String
        let model: String
        let apiKey: String
    }

    enum PrivateAIDecision: Equatable {
        case use, skip, reject
    }

    private let providerSettings: @MainActor () -> ProviderSettings
    private let promptText: @MainActor (SettingsStore.DictationShortcutSlot?, String?) -> String
    private let promptSelection: @MainActor (SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection
    private let verifiedPrivateAIModelID: @MainActor () -> String?
    private let send: (LLMClient.Config) async throws -> LLMClient.Response

    init(
        providerSettings: @escaping @MainActor () -> ProviderSettings = { ProviderSettings.current() },
        promptText: @escaping @MainActor (SettingsStore.DictationShortcutSlot?, String?) -> String = { slot, bundleID in
            if let slot {
                return SettingsStore.shared.effectiveDictationSystemPrompt(for: slot, appBundleID: bundleID)
            }
            return SettingsStore.shared.effectiveSystemPrompt(for: .dictate, appBundleID: bundleID)
        },
        promptSelection: @escaping @MainActor (SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection = {
            SettingsStore.shared.dictationPromptSelection(for: $0)
        },
        verifiedPrivateAIModelID: @escaping @MainActor () -> String? = { PrivateAIProviderPromptFormat.verifiedModelID() },
        send: @escaping (LLMClient.Config) async throws -> LLMClient.Response = { try await LLMClient.shared.call($0) }
    ) {
        self.providerSettings = providerSettings
        self.promptText = promptText
        self.promptSelection = promptSelection
        self.verifiedPrivateAIModelID = verifiedPrivateAIModelID
        self.send = send
    }

    // MARK: - Entry point

    func process(_ request: Request) async throws -> Result {
        switch request.mode {
        case .dictation: return try await self.processDictation(request)
        case .localAPI: return try await self.processLocalAPI(request)
        }
    }

    // MARK: - Dictation (former ContentView.processTextWithAI)

    private func processDictation(_ request: Request) async throws -> Result {
        let settings = self.providerSettings()
        let selectedProviderID = settings.selectedProviderID
        let resolved = Self.resolveProvider(settings, mode: .dictation, privateAISelectionModelID: nil)

        guard !resolved.providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        if selectedProviderID != "apple-intelligence",
           resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AIProcessingError.missingModel(provider: resolved.providerKey)
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(resolved.providerKey), model=\(resolved.model)", source: "DictationAIProcessor")

        let inputText = request.text
        let isDictationCall = request.overridePrompt != nil || request.slot != nil
        let decision = Self.privateAIDecision(
            mode: .dictation,
            isDictationCall: isDictationCall,
            hasOverride: request.overridePrompt != nil,
            selectionIsPrivateAI: false,
            isPrivateAIProvider: Self.isPrivateAIProvider(providerID: selectedProviderID, providerKey: resolved.providerKey),
            modelHandledByPrivateAI: PrivateAIIntegrationService.shouldHandleDictation(model: resolved.model)
        )

        if decision == .use {
            if Self.shouldTracePromptProcessing {
                Self.trace("Private AI Provider task", value: "dictationEnhancement")
                Self.trace("Input transcription (Q)", value: inputText)
                Self.trace("Selected context text", value: "<none (dictation mode)>")
            }
            let apiKey = settings.providerAPIKeys[resolved.providerKey] ?? settings.providerAPIKeys[selectedProviderID] ?? ""
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                inputText,
                runtime: Self.privateAIRuntime(selectedProviderID: selectedProviderID, resolved: resolved, apiKey: apiKey),
                context: PrivateAIIntegrationService.AppContext(
                    appName: request.app?.name ?? "",
                    bundleID: request.app?.bundleID ?? "",
                    windowTitle: request.app?.windowTitle ?? "",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                )
            )
            if Self.shouldTracePromptProcessing {
                Self.trace("Model answer (A)", value: response.outputText)
            }
            return Result(text: response.outputText, providerID: selectedProviderID, model: resolved.model)
        }

        // Resolve the effective prompt once so every provider path honors
        // transient overrides such as "Transcribe with Prompt".
        let promptSlot = request.slot ?? request.activeSlot
        let promptText: String = {
            let override = request.overridePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !override.isEmpty { return override }
            return self.promptText(promptSlot, request.app?.bundleID)
        }()

        // Dictation enhancement folds the prompt + transcript into a single user
        // turn; the AI chat playground keeps system + user.
        let systemPrompt = isDictationCall ? "" : promptText
        let userMessageContent = isDictationCall
            ? SettingsStore.renderDictationUserMessage(promptText: promptText, transcript: inputText)
            : inputText

        if selectedProviderID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if Self.shouldTracePromptProcessing {
                    Self.tracePromptContext(request: request, systemPrompt: systemPrompt, userMessage: userMessageContent, includeOverride: false)
                }
                DebugLogger.shared.debug("Using Apple Intelligence for transcription enhancement", source: "DictationAIProcessor")
                let output = try await AppleIntelligenceProvider().process(systemPrompt: systemPrompt, userText: userMessageContent)
                if Self.shouldTracePromptProcessing {
                    Self.trace("Model answer (A)", value: output)
                }
                return Result(text: output, providerID: selectedProviderID, model: resolved.model)
            }
            #endif
            return Result(text: inputText, providerID: selectedProviderID, model: resolved.model) // Fallback if not available
        }

        // Skip API key validation for local endpoints
        if !EndpointClassifier.isLocal(resolved.baseURL),
           resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AIProcessingError.missingAPIKey(provider: resolved.providerKey)
        }

        if let app = request.app {
            DebugLogger.shared.debug("Using app context for AI: app=\(app.name), bundleId=\(app.bundleID), title=\(app.windowTitle)", source: "DictationAIProcessor")
        }
        if Self.shouldTracePromptProcessing {
            Self.tracePromptContext(request: request, systemPrompt: systemPrompt, userMessage: userMessageContent, includeOverride: true)
        }

        let extraParams = SettingsStore.shared.reasoningExtraParameters(
            forModel: resolved.model,
            provider: ModelRepository.shared.providerKey(for: selectedProviderID)
        )
        if !extraParams.isEmpty {
            DebugLogger.shared.debug("Added reasoning params: \(extraParams)", source: "DictationAIProcessor")
        }

        // Transcription doesn't need streaming - the full result appears at once.
        let config = LLMClient.Config(
            messages: Self.messages(systemPrompt: systemPrompt, user: userMessageContent),
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: SettingsStore.shared.isTemperatureUnsupported(resolved.model) ? nil : 0.2,
            extraParameters: extraParams
        )
        DebugLogger.shared.info("Using LLMClient for transcription (streaming=false)", source: "DictationAIProcessor")

        let response = try await self.send(config)
        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "DictationAIProcessor")
            if Self.shouldTracePromptProcessing {
                Self.trace("Model thinking", value: thinking)
            }
        }
        if Self.shouldTracePromptProcessing {
            Self.trace("Model answer (A)", value: response.content)
        }
        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return Result(text: response.content, providerID: selectedProviderID, model: resolved.model)
    }

    // MARK: - Local API (former DictationPostProcessingService.process)

    private func processLocalAPI(_ request: Request) async throws -> Result {
        let settings = self.providerSettings()
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(text: "", providerID: settings.selectedProviderID, model: "")
        }

        let slot = request.slot ?? .primary
        let selectionIsPrivateAI = self.promptSelection(slot) == .privateAI
        let resolved = Self.resolveProvider(
            settings,
            mode: .localAPI,
            privateAISelectionModelID: selectionIsPrivateAI ? self.verifiedPrivateAIModelID() : nil
        )
        guard !resolved.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        DebugLogger.shared.debug(
            "DictationPostProcessingService using provider=\(resolved.providerKey), model=\(resolved.model)",
            source: "DictationAIProcessor"
        )

        let decision = Self.privateAIDecision(
            mode: .localAPI,
            isDictationCall: true,
            hasOverride: false,
            selectionIsPrivateAI: selectionIsPrivateAI,
            isPrivateAIProvider: Self.isPrivateAIProvider(providerID: resolved.providerID, providerKey: resolved.providerKey),
            modelHandledByPrivateAI: PrivateAIIntegrationService.shouldHandleDictation(model: resolved.model)
        )
        switch decision {
        case .reject:
            throw AIProcessingError.noVerifiedProvider
        case .use:
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                trimmed,
                runtime: Self.privateAIRuntime(selectedProviderID: resolved.providerID, resolved: resolved, apiKey: resolved.apiKey),
                context: PrivateAIIntegrationService.AppContext(
                    appName: "",
                    bundleID: "",
                    windowTitle: "",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                )
            )
            return Result(text: ASRService.applyGAAVFormatting(response.outputText), providerID: resolved.providerID, model: resolved.model)
        case .skip:
            break
        }

        let userMessageContent = SettingsStore.renderDictationUserMessage(
            promptText: self.promptText(slot, nil),
            transcript: trimmed
        )

        if resolved.providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let output = try await AppleIntelligenceProvider().process(systemPrompt: "", userText: userMessageContent)
                guard !output.isEmpty else { throw AIProcessingError.emptyResponse }
                return Result(text: ASRService.applyGAAVFormatting(output), providerID: resolved.providerID, model: resolved.model)
            }
            #endif
            return Result(text: trimmed, providerID: resolved.providerID, model: resolved.model)
        }

        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.missingModel(provider: resolved.providerKey)
        }
        if !EndpointClassifier.isLocal(resolved.baseURL),
           resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AIProcessingError.missingAPIKey(provider: resolved.providerKey)
        }

        var config = LLMClient.Config(
            messages: Self.messages(systemPrompt: "", user: userMessageContent),
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: SettingsStore.shared.isTemperatureUnsupported(resolved.model) ? nil : 0.2,
            extraParameters: SettingsStore.shared.reasoningExtraParameters(forModel: resolved.model, provider: resolved.providerKey)
        )
        config.timeoutSeconds = 120

        let response = try await self.send(config)
        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return Result(text: ASRService.applyGAAVFormatting(response.content), providerID: resolved.providerID, model: resolved.model)
    }

    // MARK: - Shared pieces

    static func privateAIDecision(
        mode: Mode,
        isDictationCall: Bool,
        hasOverride: Bool,
        selectionIsPrivateAI: Bool,
        isPrivateAIProvider: Bool,
        modelHandledByPrivateAI: Bool
    ) -> PrivateAIDecision {
        switch mode {
        case .dictation:
            return !hasOverride && isDictationCall && (isPrivateAIProvider || modelHandledByPrivateAI) ? .use : .skip
        case .localAPI:
            guard selectionIsPrivateAI || !isPrivateAIProvider else { return .reject }
            return selectionIsPrivateAI && (isPrivateAIProvider || modelHandledByPrivateAI) ? .use : .skip
        }
    }

    /// Saved/custom, built-in, or unknown (fail closed: empty base URL).
    /// `privateAISelectionModelID` (Local API only) routes a `.privateAI`
    /// prompt selection to the verified Private AI model.
    static func resolveProvider(
        _ settings: ProviderSettings,
        mode: Mode,
        privateAISelectionModelID: String?
    ) -> ResolvedProvider {
        if mode == .localAPI, let modelID = privateAISelectionModelID {
            let providerID = PrivateAIProviderFeature.shared.providerID
            return ResolvedProvider(
                providerID: providerID,
                providerKey: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: modelID,
                apiKey: ""
            )
        }

        let providerID = settings.selectedProviderID
        let keys = settings.providerAPIKeys
        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            let key = "custom:\(saved.id)"
            let apiKey: String
            switch mode {
            case .dictation: apiKey = keys[key] ?? ""
            case .localAPI: apiKey = keys[key] ?? keys[providerID] ?? ""
            }
            return ResolvedProvider(
                providerID: providerID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: settings.selectedModelByProvider[key] ?? saved.models.first ?? "",
                apiKey: apiKey
            )
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ResolvedProvider(
                providerID: providerID,
                providerKey: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: settings.selectedModelByProvider[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? "",
                apiKey: keys[providerID] ?? ""
            )
        }
        return ResolvedProvider(
            providerID: providerID,
            providerKey: providerID,
            baseURL: "",
            model: settings.selectedModelByProvider[providerID] ?? "",
            apiKey: keys[providerID] ?? ""
        )
    }

    private static func isPrivateAIProvider(providerID: String, providerKey: String) -> Bool {
        let privateID = PrivateAIProviderFeature.shared.providerID
        return providerID == privateID || providerKey == privateID || providerKey == "custom:\(privateID)"
    }

    private static func privateAIRuntime(
        selectedProviderID: String,
        resolved: ResolvedProvider,
        apiKey: String
    ) -> PrivateAIIntegrationService.RuntimeConfiguration {
        PrivateAIIntegrationService.RuntimeConfiguration(
            selectedProviderID: selectedProviderID,
            providerKey: resolved.providerKey,
            baseURL: resolved.baseURL,
            model: resolved.model,
            apiKey: apiKey,
            localModelPath: PrivateAIIntegrationService.configuredLocalModelPath,
            usesStablePromptPrefixKVCache: SettingsStore.shared.privateAIPrefixKVCacheEnabled,
            usesFluid1Boost: SettingsStore.shared.privateAIBoostEnabled,
            contextTokenLimit: SettingsStore.shared.privateAIContextTokenLimit
        )
    }

    private static func messages(systemPrompt: String, user: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": user])
        return messages
    }

    // MARK: - Prompt tracing (dictation only)

    static var shouldTracePromptProcessing: Bool {
        Self.forcePromptTraceToConsole || UserDefaults.standard.bool(forKey: "EnableDebugLogs")
    }

    private static var forcePromptTraceToConsole: Bool {
        ProcessInfo.processInfo.environment["FLUID_PROMPT_TRACE"] == "1"
    }

    static func trace(_ title: String, value: String) {
        let line = "[PromptTrace][Dictate] \(title):\n\(value)"
        if Self.forcePromptTraceToConsole {
            print(line)
        }
        DebugLogger.shared.debug(line, source: "ContentView")
    }

    private static func tracePromptContext(request: Request, systemPrompt: String, userMessage: String, includeOverride: Bool) {
        let activeSlot = request.slot ?? request.activeSlot ?? .primary
        let bundleID = request.app?.bundleID ?? ""
        let settings = SettingsStore.shared
        let selectedProfile = settings.resolvedDictationPromptProfile(for: activeSlot, appBundleID: bundleID)
        let selectedPromptName: String = {
            if settings.dictationPromptSelection(for: activeSlot) == .off {
                return "Off"
            }
            if let profile = selectedProfile {
                return profile.name.isEmpty ? "Untitled Prompt" : profile.name
            }
            return "Default"
        }()
        Self.trace("Selected prompt profile", value: selectedPromptName)
        Self.trace("Prompt body (custom/default body)", value: settings.effectiveDictationPromptBody(for: activeSlot, appBundleID: bundleID))
        Self.trace("Built-in default system prompt (baseline)", value: SettingsStore.defaultSystemPromptText(for: .dictate))
        if includeOverride {
            Self.trace("Prompt override in use", value: (request.overridePrompt?.isEmpty == false) ? "yes" : "no")
            if let overridePrompt = request.overridePrompt, !overridePrompt.isEmpty {
                Self.trace("Override system prompt", value: overridePrompt)
            }
        }
        Self.trace("Final system prompt sent to model", value: systemPrompt)
        Self.trace("Input transcription (Q)", value: request.text)
        if userMessage != request.text {
            Self.trace("Final user message sent to model", value: userMessage)
        }
        Self.trace("Selected context text", value: "<none (dictation mode)>")
    }
}

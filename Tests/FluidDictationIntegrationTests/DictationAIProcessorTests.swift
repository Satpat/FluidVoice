@testable import FluidVoice_Debug
import XCTest

// Characterization tests for DictationAIProcessor. `.dictation` must behave
// exactly like the old ContentView.processTextWithAI and `.localAPI` exactly
// like the old DictationPostProcessingService. Settings, prompt text and the
// network send are stubbed: no Keychain, UserDefaults or network access.

@MainActor
final class DictationAIProcessorTests: XCTestCase {
    private var sent: [LLMClient.Config] = []
    private var reply = "ENHANCED"

    private func makeProcessor(
        _ settings: DictationAIProcessor.ProviderSettings,
        selection: SettingsStore.DictationPromptSelection = .default
    ) -> DictationAIProcessor {
        DictationAIProcessor(
            providerSettings: { settings },
            promptText: { slot, bundleID in "PROMPT[\(slot?.rawValue ?? "nil")|\(bundleID ?? "nil")]" },
            promptSelection: { _ in selection },
            verifiedPrivateAIModelID: { nil },
            send: { [unowned self] config in
                self.sent.append(config)
                return LLMClient.Response(thinking: nil, content: self.reply, toolCalls: [])
            }
        )
    }

    private func settings(
        provider: String,
        saved: [SettingsStore.SavedProvider] = [],
        models: [String: String] = [:],
        keys: [String: String] = [:]
    ) -> DictationAIProcessor.ProviderSettings {
        DictationAIProcessor.ProviderSettings(
            selectedProviderID: provider,
            savedProviders: saved,
            selectedModelByProvider: models,
            providerAPIKeys: keys
        )
    }

    private let app = DictationAIProcessor.AppContext(name: "Notes", bundleID: "com.apple.Notes", windowTitle: "Doc")

    private func messages(_ config: LLMClient.Config) -> [[String: String]] {
        config.messages.map { $0.compactMapValues { $0 as? String } }
    }

    // MARK: - Built-in provider

    func testDictation_builtInProvider_singleUserTurnWithAppPrompt() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "test-model-a"], keys: ["openai": "sk-1"]))
        let result = try await processor.process(.init(text: "hello there", mode: .dictation, slot: .primary, app: self.app))

        XCTAssertEqual(result.text, "ENHANCED")
        let config = try XCTUnwrap(self.sent.first)
        XCTAssertEqual(config.model, "test-model-a")
        XCTAssertEqual(config.baseURL, ModelRepository.shared.defaultBaseURL(for: "openai"))
        XCTAssertEqual(config.apiKey, "sk-1")
        XCTAssertEqual(config.temperature, 0.2)
        XCTAssertNil(config.timeoutSeconds)
        XCTAssertFalse(config.streaming)
        XCTAssertEqual(self.messages(config), [[
            "role": "user",
            "content": SettingsStore.renderDictationUserMessage(promptText: "PROMPT[primary|com.apple.Notes]", transcript: "hello there"),
        ]])
    }

    func testLocalAPI_builtInProvider_noAppPrompt120sTimeoutAndGAAV() async throws {
        self.reply = "hello world"
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "test-model-a"], keys: ["openai": "sk-1"]))
        let result = try await processor.process(.init(text: "  hello there ", mode: .localAPI, slot: .primary))

        XCTAssertEqual(result, .init(text: ASRService.applyGAAVFormatting("hello world"), providerID: "openai", model: "test-model-a"))
        let config = try XCTUnwrap(self.sent.first)
        XCTAssertEqual(config.timeoutSeconds, 120)
        XCTAssertEqual(self.messages(config), [[
            "role": "user",
            "content": SettingsStore.renderDictationUserMessage(promptText: "PROMPT[primary|nil]", transcript: "hello there"),
        ]])
    }

    // MARK: - Custom providers

    func testCustomProviderKeyFallback_differsByMode() async throws {
        let saved = SettingsStore.SavedProvider(id: "abc", name: "Mine", baseURL: "https://llm.example.com/v1", models: ["m1"])
        let settings = self.settings(provider: "abc", saved: [saved], keys: ["abc": "sk-bare"])

        do {
            _ = try await self.makeProcessor(settings).process(.init(text: "hi", mode: .dictation, slot: .primary, app: self.app))
            XCTFail("dictation must not fall back to the bare-id key")
        } catch AIProcessingError.missingAPIKey(let provider) {
            XCTAssertEqual(provider, "custom:abc")
        }

        _ = try await self.makeProcessor(settings).process(.init(text: "hi", mode: .localAPI, slot: .primary))
        XCTAssertEqual(self.sent.last?.apiKey, "sk-bare")
        XCTAssertEqual(self.sent.last?.model, "m1")
    }

    func testLocalEndpointWithoutKey_isAllowed() async throws {
        let saved = SettingsStore.SavedProvider(id: "llama", name: "Llama", baseURL: "http://localhost:8080/v1", models: ["local-m"])
        let processor = self.makeProcessor(self.settings(provider: "llama", saved: [saved]))
        _ = try await processor.process(.init(text: "hi", mode: .dictation, slot: .primary, app: self.app))
        XCTAssertEqual(self.sent.first?.apiKey, "")
        XCTAssertEqual(self.sent.first?.baseURL, "http://localhost:8080/v1")
    }

    // MARK: - Failure modes

    func testEmptyProvider_throwsNoVerifiedProvider() async {
        for mode in [DictationAIProcessor.Mode.dictation, .localAPI] {
            do {
                _ = try await self.makeProcessor(self.settings(provider: "")).process(.init(text: "hi", mode: mode, slot: .primary, app: self.app))
                XCTFail("\(mode) should throw")
            } catch AIProcessingError.noVerifiedProvider {
            } catch {
                XCTFail("\(mode) threw \(error)")
            }
        }
    }

    func testUnknownProviderWithoutModel_throwsMissingModel() async {
        for mode in [DictationAIProcessor.Mode.dictation, .localAPI] {
            do {
                _ = try await self.makeProcessor(self.settings(provider: "mystery")).process(.init(text: "hi", mode: mode, slot: .primary, app: self.app))
                XCTFail("\(mode) should throw")
            } catch AIProcessingError.missingModel(let provider) {
                XCTAssertEqual(provider, "mystery")
            } catch {
                XCTFail("\(mode) threw \(error)")
            }
        }
        XCTAssertTrue(self.sent.isEmpty)
    }

    func testEmptyModelReply_throwsEmptyResponse() async {
        self.reply = ""
        for mode in [DictationAIProcessor.Mode.dictation, .localAPI] {
            do {
                _ = try await self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
                    .process(.init(text: "hi", mode: mode, slot: .primary, app: self.app))
                XCTFail("\(mode) should throw")
            } catch AIProcessingError.emptyResponse {
            } catch {
                XCTFail("\(mode) threw \(error)")
            }
        }
    }

    func testLocalAPI_emptyInputShortCircuits() async throws {
        let result = try await self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
            .process(.init(text: "   \n", mode: .localAPI, slot: .primary))
        XCTAssertEqual(result, .init(text: "", providerID: "openai", model: ""))
        XCTAssertTrue(self.sent.isEmpty)
    }

    // MARK: - Prompt shapes

    func testOverridePrompt_replacesSlotPrompt() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
        _ = try await processor.process(.init(text: "hola", mode: .dictation, overridePrompt: "Translate to English", app: self.app))
        XCTAssertEqual(self.messages(try XCTUnwrap(self.sent.first)), [[
            "role": "user",
            "content": SettingsStore.renderDictationUserMessage(promptText: "Translate to English", transcript: "hola"),
        ]])
    }

    func testBlankOverride_fallsBackToSlotPromptButStaysDictationLayout() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
        _ = try await processor.process(.init(text: "hola", mode: .dictation, overridePrompt: "   ", activeSlot: .secondary, app: self.app))
        XCTAssertEqual(self.messages(try XCTUnwrap(self.sent.first)), [[
            "role": "user",
            "content": SettingsStore.renderDictationUserMessage(promptText: "PROMPT[secondary|com.apple.Notes]", transcript: "hola"),
        ]])
    }

    func testChatCall_usesActiveSlotPromptWithSystemUserLayout() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
        _ = try await processor.process(.init(text: "What is 2+2?", mode: .dictation, activeSlot: .secondary, app: self.app))
        XCTAssertEqual(self.messages(try XCTUnwrap(self.sent.first)), [
            ["role": "system", "content": "PROMPT[secondary|com.apple.Notes]"],
            ["role": "user", "content": "What is 2+2?"],
        ])
    }

    func testChatCall_withoutActiveSlotUsesDictatePrompt() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "m"], keys: ["openai": "k"]))
        _ = try await processor.process(.init(text: "q", mode: .dictation, app: self.app))
        XCTAssertEqual(self.messages(try XCTUnwrap(self.sent.first)).first?["content"], "PROMPT[nil|com.apple.Notes]")
    }

    func testTemperatureUnsupportedModel_omitsTemperature() async throws {
        let processor = self.makeProcessor(self.settings(provider: "openai", models: ["openai": "claude-opus-4-7"], keys: ["openai": "k"]))
        _ = try await processor.process(.init(text: "hi", mode: .dictation, slot: .primary, app: self.app))
        XCTAssertNil(self.sent.first?.temperature)
    }

    // MARK: - Private AI routing (pure)

    func testPrivateAIDecision_dictation() {
        typealias P = DictationAIProcessor
        XCTAssertEqual(P.privateAIDecision(mode: .dictation, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: false, isPrivateAIProvider: true, modelHandledByPrivateAI: false), .use)
        XCTAssertEqual(P.privateAIDecision(mode: .dictation, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: false, isPrivateAIProvider: false, modelHandledByPrivateAI: true), .use)
        XCTAssertEqual(P.privateAIDecision(mode: .dictation, isDictationCall: true, hasOverride: true, selectionIsPrivateAI: false, isPrivateAIProvider: true, modelHandledByPrivateAI: true), .skip)
        XCTAssertEqual(P.privateAIDecision(mode: .dictation, isDictationCall: false, hasOverride: false, selectionIsPrivateAI: false, isPrivateAIProvider: true, modelHandledByPrivateAI: true), .skip)
    }

    func testPrivateAIDecision_localAPI() {
        typealias P = DictationAIProcessor
        XCTAssertEqual(P.privateAIDecision(mode: .localAPI, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: false, isPrivateAIProvider: true, modelHandledByPrivateAI: false), .reject)
        XCTAssertEqual(P.privateAIDecision(mode: .localAPI, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: true, isPrivateAIProvider: true, modelHandledByPrivateAI: false), .use)
        XCTAssertEqual(P.privateAIDecision(mode: .localAPI, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: true, isPrivateAIProvider: false, modelHandledByPrivateAI: false), .skip)
        XCTAssertEqual(P.privateAIDecision(mode: .localAPI, isDictationCall: true, hasOverride: false, selectionIsPrivateAI: false, isPrivateAIProvider: false, modelHandledByPrivateAI: true), .skip)
    }
}

# Dictation Coordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move FluidVoice's dictation runtime out of `ContentView` into an `AppServices`-owned `DictationCoordinator`, and merge the two AI post-processing paths into one `DictationAIProcessor`, with no behaviour change.

**Architecture:** The work is done in three phases, each committed separately.

- **P1** adds `DictationAIProcessor`. A `Mode` (`.dictation` / `.localAPI`) reproduces each caller's current behaviour. Settings, prompt text and the network send are injected so the processor can be characterization-tested.
- **P2** moves session state and the dictation flow, function by function, into `DictationCoordinator` extensions. The move goes in dependency order, so every commit builds.
- **P3** moves `GlobalHotkeyManager` ownership and wiring into the coordinator. Boot timing is unchanged.

**Tech Stack:** Swift 6.x compiler in Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, SwiftUI/AppKit, XCTest. The project is Xcode-only (`Fluid.xcodeproj`, scheme `Fluid`).

**Spec:** `docs/superpowers/specs/2026-10-15-dictation-coordinator-design.md`

**Refinements vs spec**, all of them decided while writing this plan with the code in front of us:

1. **§1 `Policy` struct becomes `enum Mode { case dictation, localAPI }`, with a `switch` at each divergence point.** The divergences include check ordering, which flags can't express cleanly.
2. **§1 `Prompt` enum becomes `overridePrompt: String?` + `slot` + `activeSlot` fields.** This preserves today's exact `isDictationCall = override != nil || slot != nil` rule, including an empty-but-non-nil override.
3. **§1 adds injected `providerSettings` / `promptText` / `promptSelection` / `verifiedPrivateAIModelID` closures.** Without them, tests would write your real Keychain API keys and depend on your prompt settings.
4. **§2 `SidebarBridge` becomes `DictationHostBridge`.** It also carries `isAccessibilityEnabled()`, which the hotkey health re-check reads.
5. **§2 `MenuBarManager` is held strongly** as an implicitly-unwrapped property set at attach time. It lives for the whole app, and moved code keeps its `self.menuBarManager.x` calls verbatim.
6. **§3 `applyShortcutSettings()` excludes `setHotkeyMode`.** That call resets press state and can stop an active press, so it keeps its own path.

## Global Constraints

- No behaviour change (spec "Hard constraint").
- Every commit builds with `./build.sh`. Run every build and test from the repo root `/Users/satyaveer/projects/MeetAI2/FluidVoice`.
- Every commit passes the full test suite (command below).
- Every commit keeps compiler warnings ≤ 76. Count them with:

  ```bash
  ./build.sh > /tmp/fv-build.log 2>&1; grep -E "\.swift:[0-9]+:[0-9]+: warning" /tmp/fv-build.log | sort -u | wc -l
  ```

  (`/tmp` is fine here. It's a local build log, not a project file.)
- Full test command (about 4 minutes):

  ```bash
  xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -only-testing:FluidDictationIntegrationTests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= 2>&1 | grep -E "Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|error:" | tail -5
  ```

- Tests import the app with `@testable import FluidVoice_Debug`, and test classes are `@MainActor final class ...: XCTestCase`.
- New **test** files need pbxproj registration via `scripts/add_test_file_to_xcodeproj.py` (created in Task 1). New **app** source files under `Sources/Fluid/` are picked up automatically (synchronized folder).
- Commit on branch `meetai-v2-hardening`. Never push. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Code style:
  - `self.`-prefixed member access;
  - `DebugLogger.shared.debug/info/warning/error(..., source:)`;
  - comment density matching the surrounding code.

## Review Focus

These are inputs the spec implies that are most likely to break silently. Each one has a test in the owning task.

1. **Custom provider whose key is stored under the bare id** (not `custom:<id>`). Dictation must still raise `missingAPIKey`; the Local API must use the key. → Task 1 `testCustomProviderKeyFallback_differsByMode`.
2. **Prompt override that is whitespace-only.** It must fall back to the slot prompt but keep the dictation single-user-turn layout. → Task 1 `testBlankOverride_fallsBackToSlotPromptButStaysDictationLayout`.
3. **AI chat playground call with no slot, during an active prompt-mode recording.** It must use the active slot's prompt text but the system+user layout. → Task 1 `testChatCall_usesActiveSlotPromptWithSystemUserLayout`.
4. **Local API with whitespace-only input.** It must return `""` without calling the provider. → Task 1 `testLocalAPI_emptyInputShortCircuits`.
5. **Hotkey stop during onboarding step 4 or 5 in dictation/prompt mode.** It must route to the onboarding sandbox, and use `.normal` otherwise. → Task 3 `testOutputRoute_onboardingSandboxOnlyForDictationModesOnSteps4And5`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Fluid/Services/DictationAIProcessor.swift` (new) | Single AI post-processing engine. |
| `Sources/Fluid/Services/DictationPostProcessingService.swift` (modify) | Thin Local API adapter over the processor. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator.swift` (new) | State, enums, host bridge, attach/boot entry points, pure decisions. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator+Context.swift` (new) | App context capture, typing target, focus, overlay lifecycle, model info, audio persistence, AI wrapper. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator+Modes.swift` (new) | Command/rewrite voice routes, live mode switches, prompt configuration, Private AI prewarm. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator+Pipeline.swift` (new) | `beginDictationRecording`, `startRecording`, `stopAndProcessTranscription`. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator+History.swift` (new) | Paste/copy/undo/reprocess last dictation. |
| `Sources/Fluid/Services/Dictation/DictationCoordinator+Hotkeys.swift` (new) | Hotkey manager creation, callbacks, cancel, `applyShortcutSettings`, reinitialize. |
| `Sources/Fluid/Services/AppServices.swift` (modify) | Lazily owns `dictation`. |
| `Sources/Fluid/ContentView.swift` (modify) | Keeps UI and settings editing; delegates to the coordinator. |
| `Sources/Fluid/Persistence/SettingsStore.swift` (modify) | `playgroundUsed` setter publishes the change. |
| `scripts/add_test_file_to_xcodeproj.py` (new) | Registers test files in pbxproj. |
| `Tests/FluidDictationIntegrationTests/DictationAIProcessorTests.swift` (new) | P1 characterization tests. |
| `Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift` (new) | Coordinator decision tests. |
| `docs/ARCHITECTURE.md` (modify) | §1.2 / §1.3 / §2.9 updated. |

---

### Task 1: `DictationAIProcessor` with characterization tests

**Files:**
- Create: `scripts/add_test_file_to_xcodeproj.py`
- Create: `Sources/Fluid/Services/DictationAIProcessor.swift`
- Create: `Tests/FluidDictationIntegrationTests/DictationAIProcessorTests.swift`
- Modify: `Fluid.xcodeproj/project.pbxproj` (via the script)

**Interfaces:**
- Consumes: `LLMClient.Config`, `LLMClient.Response(thinking:content:toolCalls:)`, `SettingsStore.SavedProvider`, `SettingsStore.DictationShortcutSlot`, `SettingsStore.DictationPromptSelection`, `SettingsStore.renderDictationUserMessage(promptText:transcript:)`, `SettingsStore.shared.reasoningExtraParameters(forModel:provider:)`, `SettingsStore.shared.isTemperatureUnsupported(_:)`, `ModelRepository.shared.{isBuiltIn,defaultBaseURL(for:),defaultModels(for:),providerKey(for:)}`, `EndpointClassifier.isLocal(_:)`, `ASRService.applyGAAVFormatting(_:)`, `PrivateAIIntegrationService`, `PrivateAIProviderFeature.shared.providerID`, `PrivateAIProviderPromptFormat.verifiedModelID()`, `AppleIntelligenceProvider`, `AIProcessingError` (defined at the top of `ContentView.swift`).
- Produces:
  - `DictationAIProcessor.shared`
  - `DictationAIProcessor.Mode { case dictation, localAPI }`
  - `DictationAIProcessor.AppContext(name:bundleID:windowTitle:)`
  - `DictationAIProcessor.Request(text:mode:overridePrompt:slot:activeSlot:app:)`
  - `DictationAIProcessor.Result { text, providerID, model }`
  - `DictationAIProcessor.ProviderSettings`
  - `func process(_:) async throws -> Result`
  - `static func privateAIDecision(...) -> PrivateAIDecision`

- [ ] **Step 1: Create the pbxproj helper**

`scripts/add_test_file_to_xcodeproj.py`:

```python
#!/usr/bin/env python3
"""Register a Swift test file in the FluidDictationIntegrationTests target.

usage: scripts/add_test_file_to_xcodeproj.py <FileName.swift>

App sources under Sources/Fluid are a synchronized folder and need no
registration; the test target uses explicit file references.
"""
import secrets
import sys

PBXPROJ = "Fluid.xcodeproj/project.pbxproj"
GROUP_ANCHOR = "980330F3CE464336ADCE3E23 /* TemperatureSupportTests.swift */,"
PHASE_ANCHOR = "272BFB5CB271489892CAE50C /* TemperatureSupportTests.swift in Sources */,"


def new_id(text):
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text:
            return candidate


def main():
    name = sys.argv[1]
    text = open(PBXPROJ).read()
    if "/* %s */ = {isa = PBXFileReference" % name in text:
        sys.exit("%s already registered" % name)
    file_id, build_id = new_id(text), new_id(text)
    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (build_id, name, file_id, name),
        1,
    )
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };\n'
        % (file_id, name, name),
        1,
    )
    for anchor, entry in ((GROUP_ANCHOR, "%s /* %s */," % (file_id, name)),
                          (PHASE_ANCHOR, "%s /* %s in Sources */," % (build_id, name))):
        idx = text.index(anchor)
        indent = text[text.rfind("\n", 0, idx) + 1:idx]
        text = text[:idx + len(anchor)] + "\n" + indent + entry + text[idx + len(anchor):]
    open(PBXPROJ, "w").write(text)
    print("registered", name)


main()
```

Run: `python3 scripts/add_test_file_to_xcodeproj.py DictationAIProcessorTests.swift`
Expected: `registered DictationAIProcessorTests.swift`

- [ ] **Step 2: Write the failing tests**

`Tests/FluidDictationIntegrationTests/DictationAIProcessorTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: the full test command with `-only-testing:FluidDictationIntegrationTests/DictationAIProcessorTests`
Expected: a build failure that includes `cannot find 'DictationAIProcessor' in scope`.

- [ ] **Step 4: Implement the processor**

`Sources/Fluid/Services/DictationAIProcessor.swift`:

```swift
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

    private let providerSettings: () -> ProviderSettings
    private let promptText: (SettingsStore.DictationShortcutSlot?, String?) -> String
    private let promptSelection: (SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection
    private let verifiedPrivateAIModelID: () -> String?
    private let send: (LLMClient.Config) async throws -> LLMClient.Response

    init(
        providerSettings: @escaping () -> ProviderSettings = { ProviderSettings.current() },
        promptText: @escaping (SettingsStore.DictationShortcutSlot?, String?) -> String = { slot, bundleID in
            if let slot {
                return SettingsStore.shared.effectiveDictationSystemPrompt(for: slot, appBundleID: bundleID)
            }
            return SettingsStore.shared.effectiveSystemPrompt(for: .dictate, appBundleID: bundleID)
        },
        promptSelection: @escaping (SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection = {
            SettingsStore.shared.dictationPromptSelection(for: $0)
        },
        verifiedPrivateAIModelID: @escaping () -> String? = { PrivateAIProviderPromptFormat.verifiedModelID() },
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
```

Notes:
- Tests rely on the public build's Private AI stub (`PrivateAIProvider.swift:376`, `shouldHandleDictation` → `false`). On a private Fluid Intelligence build, pick test model names that build's provider doesn't claim.
- The trace `source` stays `"ContentView"` so existing log filters keep working.
- The original passed the `appInfo.bundleId` *string* to `resolvedDictationPromptProfile`. `request.app?.bundleID ?? ""` keeps it a non-optional `String` for dictation calls, which always pass an app.

- [ ] **Step 5: Run the tests to verify they pass**

Run: the full test command with `-only-testing:FluidDictationIntegrationTests/DictationAIProcessorTests`
Expected: `Executed 15 tests, with 0 failures` and `TEST SUCCEEDED`.

If `testTemperatureUnsupportedModel_omitsTemperature` fails, check `SettingsStore.isTemperatureUnsupported("claude-opus-4-7")` in `TemperatureSupportTests`, and use a model listed there as unsupported.

- [ ] **Step 6: Commit**

```bash
git add scripts/add_test_file_to_xcodeproj.py Sources/Fluid/Services/DictationAIProcessor.swift Tests/FluidDictationIntegrationTests/DictationAIProcessorTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add DictationAIProcessor: one AI post-processing engine, two modes

Reproduces ContentView.processTextWithAI (.dictation) and
DictationPostProcessingService (.localAPI) exactly; each divergence is a
switch on Mode. Settings, prompt text and the network send are injected
so behaviour is pinned by characterization tests without touching the
Keychain or UserDefaults.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Route both callers through the processor

**Files:**
- Modify: `Sources/Fluid/ContentView.swift`. Replace the body of `processTextWithAI(_:overrideSystemPrompt:dictationSlot:)`, then delete `buildSystemPrompt`, `shouldTracePromptProcessing`, `forcePromptTraceToConsole` and `logDictationPromptTrace` **only if** grep shows no remaining callers.
- Modify: `Sources/Fluid/Services/DictationPostProcessingService.swift`

**Interfaces:**
- Consumes: `DictationAIProcessor.shared.process(_:)`, `DictationAIProcessor.Request`, `DictationAIProcessor.AppContext`.
- Produces: unchanged signatures `ContentView.processTextWithAI(_:overrideSystemPrompt:dictationSlot:) -> String` and `DictationPostProcessingService.process(_:dictationSlot:) -> Result`.

- [ ] **Step 1: Replace the `processTextWithAI` body in ContentView**

```swift
    private func processTextWithAI(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) async throws -> String {
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let result = try await DictationAIProcessor.shared.process(DictationAIProcessor.Request(
            text: inputText,
            mode: .dictation,
            overridePrompt: overrideSystemPrompt,
            slot: dictationSlot,
            activeSlot: self.currentDictationShortcutSlot(for: self.activeRecordingMode),
            app: DictationAIProcessor.AppContext(name: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle)
        ))
        return result.text
    }
```

- [ ] **Step 2: Remove helpers that are now dead**

Run: `grep -n "buildSystemPrompt\|shouldTracePromptProcessing\|logDictationPromptTrace\|forcePromptTraceToConsole" Sources/Fluid/ContentView.swift`

Delete each function or computed property whose only remaining hit is its own declaration. Any helper with other callers stays. Then replace its body with a forwarder to the processor's static (`DictationAIProcessor.shouldTracePromptProcessing` / `DictationAIProcessor.trace(_:value:)`).

- [ ] **Step 3: Replace `DictationPostProcessingService`**

Replace the whole file with:

```swift
import Foundation

/// Local API `/postprocess` adapter. The implementation lives in
/// DictationAIProcessor (`.localAPI` mode), shared with dictation.
@MainActor
final class DictationPostProcessingService {
    static let shared = DictationPostProcessingService()

    private init() {}

    struct Result {
        let text: String
        let providerID: String
        let model: String
    }

    func process(_ inputText: String, dictationSlot: SettingsStore.DictationShortcutSlot = .primary) async throws -> Result {
        let result = try await DictationAIProcessor.shared.process(DictationAIProcessor.Request(
            text: inputText,
            mode: .localAPI,
            slot: dictationSlot
        ))
        return Result(text: result.text, providerID: result.providerID, model: result.model)
    }
}
```

- [ ] **Step 4: Fix the stale comment in MeetingAIClient**

`Sources/Fluid/Services/MeetingRecording/MeetingAIClient.swift` (around line 208) mentions `DictationPostProcessingService.resolveProvider`. Change that mention to `DictationAIProcessor.resolveProvider`.

- [ ] **Step 5: Build, test, count warnings**

Run, in order:
1. `./build.sh` → expected `** BUILD SUCCEEDED **`.
2. The full test command → expected `TEST SUCCEEDED`, with 120 tests: the 105 existing plus the 15 new ones.
3. The warning count command → expected ≤ 76.

- [ ] **Step 6: Commit**

```bash
git add Sources/Fluid/ContentView.swift Sources/Fluid/Services/DictationPostProcessingService.swift Sources/Fluid/Services/MeetingRecording/MeetingAIClient.swift
git commit -m "Route dictation and Local API AI processing through DictationAIProcessor

Removes ~300 lines of duplicated provider resolution, prompt building and
LLM plumbing from ContentView and DictationPostProcessingService.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## P2 move rules (apply in Tasks 3–7)

Move function **bodies verbatim**, matched by **function name**; line numbers shift after every task. The only edits allowed are the ones in this table. A compile error not covered by the table means a dependency hasn't moved yet. Move that function in the current task as well, rather than adding a call back into ContentView.

| In moved code | Becomes |
|---|---|
| `private func f(` | `func f(` (internal, because coordinator extensions span files) |
| `self.asr` | unchanged (coordinator has `var asr: ASRService { AppServices.shared.asr }`) |
| `self.menuBarManager` | unchanged (coordinator `var menuBarManager: MenuBarManager!`, set in `attach`) |
| `self.settings` | unchanged (coordinator `var settings: SettingsStore { .shared }`) |
| reading `self.selectedSidebarItem` | `self.host?.currentSidebarItem()` |
| `self.selectedSidebarItem = X` | `self.host?.selectSidebarItem(X)` |
| `self.accessibilityEnabled` | `(self.host?.isAccessibilityEnabled() ?? false)` |
| `self.playgroundUsed = V` | delete the line; the sibling `self.settings.playgroundUsed = V` stays |
| `ActiveRecordingMode` / `DictationOutputRoute` | unchanged (now nested in `DictationCoordinator`) |

In ContentView, every remaining reference to moved state or functions becomes `self.dictation.<name>`. ContentView gets this accessor in Task 3:

```swift
    private var dictation: DictationCoordinator { self.appServices.dictation }
```

---

### Task 3: Coordinator skeleton, session state and pure decisions

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator.swift`
- Create: `Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift` (register it with the script)
- Modify: `Sources/Fluid/Services/AppServices.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Modify: `Sources/Fluid/Persistence/SettingsStore.swift` (the `playgroundUsed` setter)

**Interfaces:**
- Produces:
  - `DictationCoordinator`
  - nested `ActiveRecordingMode`, `DictationOutputRoute`
  - `DictationHostBridge { currentSidebarItem: () -> SidebarItem?; selectSidebarItem: (SidebarItem) -> Void; isAccessibilityEnabled: () -> Bool }`
  - `func attach(menuBar: MenuBarManager, host: DictationHostBridge)`
  - state properties `activeRecordingMode`, `activeDictationShortcutSlot`, `isRecordingForRewrite`, `isRecordingForCommand`, `promptModeOverrideText`, `recordingAppInfo`, `recordingPrecedingText`, `overlayLifecycleID`, `prewarmDictationTask`, `pendingAIReprocessText`
  - `setActiveRecordingMode(_:)`, `clearActiveRecordingMode()`, `cancelPrewarmDictationIfNeeded()`, `currentDictationShortcutSlot(for:)`, `clearActiveDictationShortcutState()`, `currentDictationOutputRouteForHotkeyStop()`
  - `static func outputRoute(mode:onboardingCompleted:onboardingStep:)`
  - `AppServices.shared.dictation`

- [ ] **Step 1: Write the failing tests**

Register the file: `python3 scripts/add_test_file_to_xcodeproj.py DictationCoordinatorTests.swift`

`Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift`:

```swift
@testable import FluidVoice_Debug
import XCTest

// Pure decisions moved from ContentView into DictationCoordinator.

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testOutputRoute_onboardingSandboxOnlyForDictationModesOnSteps4And5() {
        typealias C = DictationCoordinator
        for step in [4, 5] {
            XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: step), .onboardingSandbox)
            XCTAssertEqual(C.outputRoute(mode: .promptMode, onboardingCompleted: false, onboardingStep: step), .onboardingSandbox)
            XCTAssertEqual(C.outputRoute(mode: .command, onboardingCompleted: false, onboardingStep: step), .normal)
            XCTAssertEqual(C.outputRoute(mode: .edit, onboardingCompleted: false, onboardingStep: step), .normal)
            XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: true, onboardingStep: step), .normal)
        }
        XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: 3), .normal)
        XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: 6), .normal)
    }

    func testCurrentSlot_defaultsPerModeAndHonoursActiveSlot() {
        let coordinator = DictationCoordinator()
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .dictate), .primary)
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .promptMode), .secondary)
        XCTAssertNil(coordinator.currentDictationShortcutSlot(for: .command))
        XCTAssertNil(coordinator.currentDictationShortcutSlot(for: .none))
        coordinator.activeDictationShortcutSlot = .secondary
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .dictate), .secondary)
    }

    func testSetActiveRecordingMode_setsFlagsAndClearsSlotOutsideDictation() {
        let coordinator = DictationCoordinator()
        coordinator.activeDictationShortcutSlot = .secondary
        coordinator.promptModeOverrideText = "x"

        coordinator.setActiveRecordingMode(.edit)
        XCTAssertTrue(coordinator.isRecordingForRewrite)
        XCTAssertFalse(coordinator.isRecordingForCommand)
        XCTAssertNil(coordinator.activeDictationShortcutSlot)
        XCTAssertNil(coordinator.promptModeOverrideText)

        coordinator.setActiveRecordingMode(.command)
        XCTAssertTrue(coordinator.isRecordingForCommand)
        XCTAssertFalse(coordinator.isRecordingForRewrite)

        coordinator.activeDictationShortcutSlot = .primary
        coordinator.setActiveRecordingMode(.dictate)
        XCTAssertEqual(coordinator.activeDictationShortcutSlot, .primary, "dictation keeps its slot")
        XCTAssertFalse(coordinator.isRecordingForCommand)

        coordinator.clearActiveRecordingMode()
        XCTAssertEqual(coordinator.activeRecordingMode, .none)
    }

    func testCancelPrewarm_cancelsAndClearsTask() {
        let coordinator = DictationCoordinator()
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        coordinator.prewarmDictationTask = task
        coordinator.cancelPrewarmDictationIfNeeded()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.prewarmDictationTask)
    }
}
```

Run: the full test command with `-only-testing:FluidDictationIntegrationTests/DictationCoordinatorTests`
Expected: a build failure, `cannot find 'DictationCoordinator' in scope`.

- [ ] **Step 2: Create the coordinator skeleton**

`Sources/Fluid/Services/Dictation/DictationCoordinator.swift`:

```swift
import AppKit
import Combine
import Foundation

/// Owns the dictation runtime: recording-session state, the start → transcribe
/// → AI → format → type flow, the command/rewrite voice routes, history actions
/// and (from P3) the global hotkey manager. Previously all of this lived inside
/// ContentView, a SwiftUI view. Created lazily by AppServices; ContentView only
/// binds UI to it.
@MainActor
final class DictationCoordinator: ObservableObject {
    enum ActiveRecordingMode: String {
        case none
        case dictate
        case promptMode
        case edit
        case command
    }

    enum DictationOutputRoute: String {
        case normal
        case onboardingSandbox
    }

    /// The only couplings to view state the flow needs. Installed by
    /// ContentView in `attach`.
    struct DictationHostBridge {
        let currentSidebarItem: () -> SidebarItem?
        let selectSidebarItem: (SidebarItem) -> Void
        let isAccessibilityEnabled: () -> Bool
    }

    // MARK: - Collaborators

    var asr: ASRService { AppServices.shared.asr }
    var settings: SettingsStore { .shared }
    /// FluidApp's @StateObject; lives for the whole app. Set in `attach`
    /// before any recording can start.
    var menuBarManager: MenuBarManager!
    var host: DictationHostBridge?

    // MARK: - Session state (moved from ContentView @State)

    var activeRecordingMode: ActiveRecordingMode = .none
    var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot?
    var isRecordingForRewrite: Bool = false
    var isRecordingForCommand: Bool = false
    var promptModeOverrideText: String?
    var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)?
    var recordingPrecedingText: String = ""
    var overlayLifecycleID: UInt64 = 0
    var prewarmDictationTask: Task<Void, Never>?
    var pendingAIReprocessText: String?

    init() {}

    func attach(menuBar: MenuBarManager, host: DictationHostBridge) {
        self.menuBarManager = menuBar
        self.host = host
    }

    // MARK: - Pure decisions

    static func outputRoute(mode: ActiveRecordingMode, onboardingCompleted: Bool, onboardingStep: Int) -> DictationOutputRoute {
        let onboardingPlaygroundStep = 4
        let onboardingAIEnhancementStep = 5
        let isSandboxStep = !onboardingCompleted
            && (onboardingStep == onboardingPlaygroundStep || onboardingStep == onboardingAIEnhancementStep)
        let isDictationMode = mode == .dictate || mode == .promptMode
        return isSandboxStep && isDictationMode ? .onboardingSandbox : .normal
    }

    var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
    }

    func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        Self.outputRoute(
            mode: self.activeRecordingMode,
            onboardingCompleted: self.settings.onboardingCompleted,
            onboardingStep: self.settings.onboardingCurrentStep
        )
    }
}
```

Then move these verbatim from ContentView into the class body, under `// MARK: - Mode state`, applying the move rules:
- `setActiveRecordingMode(_:)`
- `clearActiveRecordingMode()`
- `cancelPrewarmDictationIfNeeded()`
- `currentDictationShortcutSlot(for:)`
- `clearActiveDictationShortcutState()`

Delete from ContentView:
- the `ActiveRecordingMode` and `DictationOutputRoute` enums;
- the 10 session `@State` properties listed in the skeleton;
- the five functions above;
- `isOnboardingVoicePlaygroundStepActive`, `isOnboardingSandboxRouteActive` and `currentDictationOutputRouteForHotkeyStop()`.

Check that `onboardingCurrentStep` is an `Int`. If it isn't, convert at the `outputRoute` call site so the test signature stays the same.

- [ ] **Step 3: Wire AppServices and ContentView**

In `AppServices.swift`, add this next to the other lazy services:

```swift
    /// Dictation runtime (lazily initialized; attached by ContentView on appear)
    private var _dictation: DictationCoordinator?
    var dictation: DictationCoordinator {
        if let existing = self._dictation {
            return existing
        }
        let coordinator = DictationCoordinator()
        self._dictation = coordinator
        return coordinator
    }
```

In ContentView:
- Add `private var dictation: DictationCoordinator { self.appServices.dictation }`.
- Make the first statement of `handleContentAppear()`:

```swift
        self.dictation.attach(
            menuBar: self.menuBarManager,
            host: DictationCoordinator.DictationHostBridge(
                currentSidebarItem: { self.selectedSidebarItem },
                selectSidebarItem: { self.selectedSidebarItem = $0 },
                isAccessibilityEnabled: { self.accessibilityEnabled }
            )
        )
```

- Replace every reference to a moved state property or function with `self.dictation.<name>`. Find them with:

```bash
grep -nE "self\.(activeRecordingMode|activeDictationShortcutSlot|isRecordingForRewrite|isRecordingForCommand|promptModeOverrideText|recordingAppInfo|recordingPrecedingText|overlayLifecycleID|prewarmDictationTask|pendingAIReprocessText|setActiveRecordingMode|clearActiveRecordingMode|cancelPrewarmDictationIfNeeded|currentDictationShortcutSlot|clearActiveDictationShortcutState|isOnboardingVoicePlaygroundStepActive|isOnboardingSandboxRouteActive|currentDictationOutputRouteForHotkeyStop)\b" Sources/Fluid/ContentView.swift
```

- Replace references to the nested enum types with `DictationCoordinator.ActiveRecordingMode` / `DictationCoordinator.DictationOutputRoute`.

- [ ] **Step 4: Make `playgroundUsed` publish**

In `SettingsStore.swift`, replace the `playgroundUsed` setter with:

```swift
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.playgroundUsed)
        }
```

Leave ContentView's `@State playgroundUsed` alone for now. Task 6 removes it once its writers have moved.

- [ ] **Step 5: Build, run tests, count warnings**

- `./build.sh` → `** BUILD SUCCEEDED **`
- full test command → `TEST SUCCEEDED`, 124 tests
- warning count → ≤ 76

- [ ] **Step 6: Commit**

```bash
git add Sources/Fluid/Services/Dictation/DictationCoordinator.swift Sources/Fluid/Services/AppServices.swift Sources/Fluid/ContentView.swift Sources/Fluid/Persistence/SettingsStore.swift Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add DictationCoordinator and move recording-session state into it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Move context, focus, overlay and model-info helpers

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator+Context.swift`
- Modify: `Sources/Fluid/ContentView.swift`

**Interfaces:**
- Consumes: Task 3's state and the `attach` collaborators.
- Produces, all internal methods on `DictationCoordinator`, signatures unchanged:
  - `getCurrentAppInfo()`, `getFrontmostWindowTitle(ownerPid:)`
  - `captureRecordingTargetContext()`, `captureRecordingFormattingContextIfNeeded(...)`, `captureRecordingContext()`
  - `resolveTypingTargetPID(...)`, `restoreFocusToRecordingTarget(...)`
  - `advanceOverlayLifecycle()`, `hideOverlayAsync(...)`, `hideOverlayAfterOutput(...)`
  - `appBench(_:)`
  - `currentDictationAIModelInfo()`, `currentTranscriptionModelInfo()`
  - `persistDictationAudioIfNeeded(...)`
  - `processTextWithAI(_:overrideSystemPrompt:dictationSlot:)` (Task 2's wrapper)

- [ ] **Step 1: Move the functions**

Create the file with this header, then move each listed function verbatim by name, applying the move rules:

```swift
import AppKit
import Foundation

// App/target context capture, focus restore, overlay lifecycle and model
// metadata for the dictation flow. Moved verbatim from ContentView.

extension DictationCoordinator {
}
```

- [ ] **Step 2: Repoint ContentView callers**

Run: `grep -nE "self\.(getCurrentAppInfo|getFrontmostWindowTitle|captureRecording\w*|resolveTypingTargetPID|restoreFocusToRecordingTarget|advanceOverlayLifecycle|hideOverlay\w*|appBench|currentDictationAIModelInfo|currentTranscriptionModelInfo|persistDictationAudioIfNeeded|processTextWithAI)\(" Sources/Fluid/ContentView.swift`

Prefix each hit with `dictation.`, for example `self.dictation.appBench(`. That includes the AI chat playground's `processTextWithAI(aiInputText)` call, which becomes `self.dictation.processTextWithAI(self.aiInputText)`.

- [ ] **Step 3: Build, run tests, count warnings**

Same commands and expectations as Task 3, Step 5 (124 tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/Fluid/Services/Dictation/DictationCoordinator+Context.swift Sources/Fluid/ContentView.swift
git commit -m "Move dictation context, focus and overlay helpers into DictationCoordinator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Move the command/rewrite modes and prompt configuration

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator+Modes.swift`
- Modify: `Sources/Fluid/Services/Dictation/DictationCoordinator.swift`, adding:

```swift
    let commandModeService = CommandModeService()
    let rewriteModeService = RewriteModeService()
```

- Modify: `Sources/Fluid/ContentView.swift`

**Interfaces:**
- Produces:
  - `DictationCoordinator.commandModeService`, `DictationCoordinator.rewriteModeService`
  - `processRewriteWithVoiceInstruction(...)`, `processCommandWithVoice(...)`
  - `handleLivePromptModeSwitch(...)`, `handleLiveOverlayModeSwitch(...)`
  - `applyDictationShortcutSelectionContext(...)`, `applyDictationPromptConfiguration(...)`
  - `prewarmPrivateAIDictationIfNeeded(...)`

- [ ] **Step 1: Move service ownership**

- Delete `@StateObject private var commandModeService` and `@StateObject private var rewriteModeService` from ContentView.
- Replace `self.commandModeService` with `self.dictation.commandModeService`, and do the same for `rewriteModeService`. That covers the notch callbacks (`[weak commandModeService]` captures become `[weak commandModeService = self.dictation.commandModeService]`), `CommandModeView(service:)`, `RewriteModeView(service:)`, and the `clearState()` calls.

- [ ] **Step 2: Move the functions**

Move the seven functions listed under Produces verbatim into `DictationCoordinator+Modes.swift`, with the same header style as Task 4. Apply the move rules.

- [ ] **Step 3: Repoint ContentView callers**

Run: `grep -nE "self\.(processRewriteWithVoiceInstruction|processCommandWithVoice|handleLivePromptModeSwitch|handleLiveOverlayModeSwitch|applyDictationShortcutSelectionContext|applyDictationPromptConfiguration|prewarmPrivateAIDictationIfNeeded)\(" Sources/Fluid/ContentView.swift`

Prefix each hit with `dictation.`.

- [ ] **Step 4: Build, run tests, count warnings**

Same as Task 3, Step 5.

- [ ] **Step 5: Commit**

```bash
git add Sources/Fluid/Services/Dictation/ Sources/Fluid/ContentView.swift
git commit -m "Move command/rewrite voice routes and mode services into DictationCoordinator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Move the recording pipeline

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator+Pipeline.swift`
- Modify: `Sources/Fluid/ContentView.swift`

**Interfaces:**
- Produces:
  - both `beginDictationRecording(...)` overloads
  - `startRecording()`
  - `stopAndProcessTranscription(route:)`, with default `.normal` kept

- [ ] **Step 1: Move the functions**

Move them verbatim with the move rules. `stopAndProcessTranscription` contains the onboarding-playground writes. Per the rules, `self.playgroundUsed = true` is deleted and `self.settings.playgroundUsed = true` stays. `beginDictationRecording` has the same pattern with `false`.

- [ ] **Step 2: Repoint ContentView callers and drop the `playgroundUsed` mirror**

- `stopAndProcessTranscription: { await self.stopAndProcessTranscription() }` (two sites) → `{ await self.dictation.stopAndProcessTranscription() }`
- `startRecording: self.startRecording` (three sites) → `startRecording: { self.dictation.startRecording() }`
- Remaining calls found by `grep -nE "self\.(beginDictationRecording|startRecording|stopAndProcessTranscription)\(" Sources/Fluid/ContentView.swift` → `self.dictation.`
- Delete `@State private var playgroundUsed`. Replace its readers (welcome view parameter, backup-restore reload) with `self.settings.playgroundUsed`, and delete any `self.playgroundUsed = ...` assignment left in ContentView. `settings` is `@ObservedObject` and Task 3 made the setter publish, so the welcome view still re-renders.

- [ ] **Step 3: Build, run tests, count warnings**

Same as Task 3, Step 5.

- [ ] **Step 4: Commit**

```bash
git add Sources/Fluid/Services/Dictation/DictationCoordinator+Pipeline.swift Sources/Fluid/ContentView.swift
git commit -m "Move the dictation recording pipeline into DictationCoordinator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Move the history actions

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator+History.swift`
- Modify: `Sources/Fluid/ContentView.swift`

**Interfaces:**
- Produces:
  - `reprocessLastDictation()`
  - `copyLastDictationFromHistory()`
  - `pasteLastDictationFromHistory()`
  - `undoLastAIProcessingFromHistory()`
  - `applyHistoryTextOutput(...)`
  - `reprocessDictationText(...)`

- [ ] **Step 1: Move the functions**

Move them verbatim with the move rules. Include any private helper that sits between them in ContentView and is only called by them; `grep` its name to confirm.

- [ ] **Step 2: Repoint callers**

These are only called from `initializeHotkeyManagerIfNeeded`, which is still in ContentView until Task 8. Prefix those calls with `dictation.`.

- [ ] **Step 3: Build, run tests, count warnings**

Same as Task 3, Step 5.

- [ ] **Step 4: Verify the flow left ContentView**

Run:

```bash
grep -cE "func (stopAndProcessTranscription|beginDictationRecording|processTextWithAI|processRewriteWithVoiceInstruction|pasteLastDictationFromHistory|getCurrentAppInfo)\b" Sources/Fluid/ContentView.swift
```

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Fluid/Services/Dictation/DictationCoordinator+History.swift Sources/Fluid/ContentView.swift
git commit -m "Move dictation history actions into DictationCoordinator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Move hotkey ownership and wiring (P3)

**Files:**
- Create: `Sources/Fluid/Services/Dictation/DictationCoordinator+Hotkeys.swift`
- Modify: `Sources/Fluid/Services/Dictation/DictationCoordinator.swift`, adding:

```swift
    @Published private(set) var hotkeyManager: GlobalHotkeyManager?
    @Published var hotkeyManagerInitialized: Bool = false
```

- Modify: `Sources/Fluid/ContentView.swift`
- Test: `Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift` (one test added)

**Interfaces:**
- Produces:
  - `bootIfNeeded()` (the former `initializeHotkeyManagerIfNeeded`, verbatim)
  - `handleCancelShortcut()`
  - `applyShortcutSettings()`
  - `reinitializeHotkeys()`
  - `refreshHotkeyHealth()`

- [ ] **Step 1: Write the failing test**

Append to `DictationCoordinatorTests`:

```swift
    func testApplyShortcutSettings_isSafeBeforeBoot() {
        let coordinator = DictationCoordinator()
        XCTAssertNil(coordinator.hotkeyManager)
        coordinator.applyShortcutSettings() // no manager yet: must be a no-op, not a crash
        XCTAssertFalse(coordinator.hotkeyManagerInitialized)
    }
```

Run: the full test command with `-only-testing:FluidDictationIntegrationTests/DictationCoordinatorTests`
Expected: a build failure, `value of type 'DictationCoordinator' has no member 'applyShortcutSettings'`.

- [ ] **Step 2: Move the functions and add the new ones**

- Move `initializeHotkeyManagerIfNeeded()` verbatim, renamed to `bootIfNeeded()`, and `handleCancelShortcut()`, into `DictationCoordinator+Hotkeys.swift`, applying the move rules.
- Inside the moved code, replace reads of the ContentView shortcut `@State` values with `SettingsStore`:

| Was | Becomes |
|---|---|
| `self.primaryDictationShortcuts` | `self.settings.primaryDictationShortcuts` |
| `self.promptModeHotkeyShortcut` | `self.settings.promptModeHotkeyShortcut` |
| `self.commandModeHotkeyShortcut` | `self.settings.commandModeHotkeyShortcut` |
| `self.rewriteModeHotkeyShortcut` | `self.settings.rewriteModeHotkeyShortcut` |
| `self.isPromptModeShortcutEnabled` | `self.settings.promptModeShortcutEnabled` |
| `self.isCommandModeShortcutEnabled` | `self.settings.commandModeShortcutEnabled` |
| `self.isRewriteModeShortcutEnabled` | `self.settings.rewriteModeShortcutEnabled` |
| `self.hotkeyMode` | `self.settings.hotkeyMode` |

- Add to the same file:

```swift
    /// Push every persisted shortcut setting into the hotkey manager. All
    /// calls are plain setters (idempotent); hotkey *mode* is deliberately
    /// excluded because setHotkeyMode resets press state and can stop an
    /// active press — it keeps its own call path.
    func applyShortcutSettings() {
        guard let manager = self.hotkeyManager else { return }
        manager.updatePrimaryShortcuts(self.settings.primaryDictationShortcuts)
        manager.updatePromptModeShortcut(self.settings.promptModeHotkeyShortcut)
        manager.updatePromptModeShortcutEnabled(self.settings.promptModeShortcutEnabled)
        manager.updatePromptShortcutAssignments(self.settings.dictationPromptShortcutAssignments())
        manager.updateCommandModeShortcut(self.settings.commandModeHotkeyShortcut)
        manager.updateCommandModeShortcutEnabled(self.settings.commandModeShortcutEnabled)
        manager.updateRewriteModeShortcut(self.settings.rewriteModeHotkeyShortcut)
        manager.updateRewriteModeShortcutEnabled(self.settings.rewriteModeShortcutEnabled)
    }

    func reinitializeHotkeys() {
        self.hotkeyManager?.reinitialize()
    }

    /// Re-check the event tap after a shortcut change (was an inline
    /// asyncAfter in ContentView's primary-shortcut onChange).
    func refreshHotkeyHealth(after delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
            DebugLogger.shared.debug("Hotkey manager initialized: \(self.hotkeyManagerInitialized)", source: "ContentView")
        }
    }
```

- `bootIfNeeded()` assigns `self.hotkeyManager = GlobalHotkeyManager(...)`. Because the setter is `private(set)` it must be in the class file, so put `bootIfNeeded` in `DictationCoordinator.swift` instead if the compiler rejects the assignment from the extension file.

- [ ] **Step 3: Rewire ContentView**

- Delete `@State private var hotkeyManager` and `@State private var hotkeyManagerInitialized`.
- Add `@ObservedObject private var dictationObserver = AppServices.shared.dictation`. It's needed only so `SettingsView`'s `hotkeyManagerInitialized` binding updates the UI.
- In `handleContentAppear`, change `self.initializeHotkeyManagerIfNeeded()` to `self.dictation.bootIfNeeded()`. It stays at the same position, right after `attach` and otherwise unchanged in order.
- `SettingsView(...)`: pass `hotkeyManagerInitialized: self.$dictationObserver.hotkeyManagerInitialized` and `hotkeyManager: self.dictation.hotkeyManager`.
- `self.handleCancelShortcut()` → `self.dictation.handleCancelShortcut()`.
- Every `self.hotkeyManager?.updateX(...)` in the shortcut change handlers (body `onChange`/`onReceive`, the `handle*ShortcutEnabledChange` functions, the capture-monitor apply block, and the backup-restore reload that pushes all shortcuts) → `self.dictation.applyShortcutSettings()`.
  - Before that call, confirm the handler has already persisted the value to `SettingsStore`. Each one does today (spec risk 3). If one doesn't, add the persisting assignment it is missing.
- `self.hotkeyManager?.resetModifierOnlyShortcutTracking()` → `self.dictation.hotkeyManager?.resetModifierOnlyShortcutTracking()`.
- `self.hotkeyManager?.reinitialize()` (the accessibility grant paths) → `self.dictation.reinitializeHotkeys()`.
- The primary-shortcut `onChange` `asyncAfter` health re-check → `self.dictation.refreshHotkeyHealth()`.
- The accessibility `onChange` guard `self.hotkeyManager != nil && !self.hotkeyManagerInitialized` → `self.dictation.hotkeyManager != nil && !self.dictation.hotkeyManagerInitialized`.
- `SettingsView` line ~827 (`self.hotkeyManager?.setHotkeyMode(newValue)`) is unchanged, because it now receives the coordinator's manager.

Then run: `grep -nE "hotkeyManager\b" Sources/Fluid/ContentView.swift`
Expected: only `self.dictation.hotkeyManager`, `self.dictationObserver` and `SettingsView` argument hits.

- [ ] **Step 4: Build, run tests, count warnings**

- `./build.sh` → `** BUILD SUCCEEDED **`
- full test command → `TEST SUCCEEDED`, 125 tests
- warning count → ≤ 76

- [ ] **Step 5: Confirm the success criteria**

Run:

```bash
grep -cE "@State private var (hotkeyManager|hotkeyManagerInitialized|activeRecordingMode|recordingAppInfo|promptModeOverrideText|overlayLifecycleID|prewarmDictationTask)\b|@StateObject private var (commandModeService|rewriteModeService)" Sources/Fluid/ContentView.swift
```

Expected: `0`. Then run `wc -l Sources/Fluid/ContentView.swift` and record the line count in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Sources/Fluid/Services/Dictation/ Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationCoordinatorTests.swift
git commit -m "Move GlobalHotkeyManager ownership into DictationCoordinator

Boot timing unchanged: ContentView.handleContentAppear calls
bootIfNeeded() where it previously initialized the manager. Shortcut
change handlers call one applyShortcutSettings() that reads SettingsStore.
ContentView is now <wc -l result> lines (was 4458).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Docs and the handoff checklist

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update the diagrams and roadmap**

1. **§1.2 component map:** under `dictation[Dictation services]`, add a `coord[DictationCoordinator<br/>session state · flow · hotkeys]` node. Edges:
   - `services --> coord`
   - `content -- binds UI --> coord`
   - `coord --> hotkey & asr & typing & gate & cmd & rewrite`
   - `coord --> proc[DictationAIProcessor] --> llm`

   Remove `content --> hotkey & asr & typing & gate & llm & cmd & rewrite`. Replace the "Notable: the dictation pipeline is owned by a SwiftUI view" paragraph with one saying ContentView binds to `AppServices.shared.dictation` and calls `bootIfNeeded()` on appear.
2. **§1.3 sequence diagram:** rename participant `C` to `DictationCoordinator`, and add a participant `AI as DictationAIProcessor` between `G` and `L`, used by the "processTextWithAI" step.
3. **§2.9 roadmap:** mark item 1 done with this branch's commit range, and note the follow-up: "SettingsView still binds to ContentView shortcut @State editor copies."
4. Validate the Mermaid with:

```bash
npx -y @mermaid-js/mermaid-cli@11.4.2 -i docs/ARCHITECTURE.md -o /tmp/arch-check.md
```

Expected: exit 0. If `npx` isn't available, validate however Task 9 of the hardening work did: render the blocks with mermaid@11.4.1 in a browser page and check `mermaid.render` resolves for every block.

- [ ] **Step 2: Commit**

```bash
git add -f docs/ARCHITECTURE.md
git commit -m "Architecture doc: DictationCoordinator and DictationAIProcessor

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Hand the manual checklist to your human partner**

Report the spec's §Verification list, items 1–9, verbatim. Then ask them to:
1. quit FluidVoice;
2. run `./build.sh install`;
3. relaunch;
4. walk the checklist.

Nothing is pushed.

# Dictation Coordinator — Design

- **Date:** 2026-10-15
- **Branch:** `meetai-v2-hardening`
- **Roadmap item:** `docs/ARCHITECTURE.md` §2.9 #1
- **Status:** approved in conversation (approach 1, sections §1–§3)

## Intent

**Outcome.** `ContentView` (≈4.4k lines) stops owning the dictation runtime. A `@MainActor DictationCoordinator`, owned by `AppServices`, takes over:
- `GlobalHotkeyManager`;
- the start → transcribe → AI → format → type flow.

`ContentView` binds UI to the coordinator. The two near-duplicate AI post-processing paths become one engine.

**Hard constraint: no behaviour change.** Each of these must behave exactly as before:
- hotkey modes (hold / toggle / automatic);
- command, rewrite and prompt-test routing;
- formatting-chain order;
- overlay timing;
- focus restore;
- history persistence;
- the onboarding playground sandbox route;
- Local API `/postprocess` output.

**Success criteria.**
1. `ContentView` holds no hotkey-manager or dictation-session state. The shortcut *editor* values bound to `SettingsView` are allowed to stay (see §3).
2. One AI post-processing implementation, used by both dictation and the Local API.
3. Release build (`./build.sh`) passes.
4. All test suites pass: 105 existing tests plus the new ones.
5. Compiler warnings do not rise above 76.
6. `docs/ARCHITECTURE.md` §1.2 and §1.3 are updated.
7. The manual smoke checklist (§Verification) passes on your machine.

**Assumption.** Characterization tests plus a manual smoke run are acceptable evidence. Global hotkeys, Accessibility insertion and real typing cannot be exercised in automated tests.

## Current state (measured)

- **Size of the flow.** The closure reachable from `initializeHotkeyManagerIfNeeded`, `stopAndProcessTranscription` and `beginDictationRecording` is 42 functions, about 2,000 lines. It reads 32 `ContentView` properties.
- **Shortcut wiring.** Shortcut edits reach the hotkey manager through about 15 scattered `hotkeyManager?.updateX(...)` calls.
- **Two AI paths that differ.** `ContentView.processTextWithAI` (dictation, prompt-test, AI chat playground) and `DictationPostProcessingService.process` (Local API) diverge in these ways:

| Behaviour | Dictation (`processTextWithAI`) | Local API (`DictationPostProcessingService`) |
|---|---|---|
| Prompt | slot or active-mode prompt with per-app routing (`appBundleID` of the recording target); override prompt supported; chat layout for the playground | slot prompt, `appBundleID: nil` |
| Private AI routing | used when there is no override, it is a dictation call, and (provider is Private AI or `shouldHandleDictation(model)`) | used when the slot selection is `.privateAI` and (provider is Private AI or `shouldHandleDictation`); a Private AI provider without `.privateAI` selection → `noVerifiedProvider` |
| Provider resolution | saved / built-in / unknown | same, plus a `.privateAI` slot selection resolves to the verified Private AI model |
| API-key lookup (custom provider) | `keys["custom:<id>"]` | `keys["custom:<id>"] ?? keys[<id>]` |
| Private AI app context | real app name / bundle / window | empty |
| Apple Intelligence | output returned even if empty; unavailable → input returned | empty output → `emptyResponse`; unavailable → trimmed input |
| Missing-model check | before routing (skipped for Apple Intelligence) | after the Apple Intelligence branch |
| Reasoning-params provider key | `providerKey(for: selectedProviderID)` | resolved provider key |
| Timeout | `LLMClient` default (30 s) | 120 s |
| GAAV formatting | applied later in the dictation formatting chain | applied inside the result |
| Prompt trace (`[PromptTrace][Dictate]`) | yes | no |
| Empty input | processed | returns `""` early |

## Design

### §1 — `DictationAIProcessor` (phase P1)

New file `Services/DictationAIProcessor.swift`, `@MainActor final class`, `static let shared`.

```swift
struct AppContext { let name: String; let bundleID: String; let windowTitle: String }

enum Prompt {
    case slot(SettingsStore.DictationShortcutSlot?)  // dictation; nil = .dictate system prompt
    case override(String)                            // prompt test / prompt mode
    case chat                                        // AI playground: system + user layout
}

enum PrivateAIRouting { case dictationCall, promptSelection }

struct Policy {
    var privateAIRouting: PrivateAIRouting
    var resolvesPrivateAISelection: Bool            // service's resolveProvider override
    var apiKeyFallsBackToProviderID: Bool
    var timeoutSeconds: TimeInterval?               // nil = LLMClient default
    var emptyAppleIntelligenceOutputThrows: Bool
    var appliesGAAVFormatting: Bool
    var returnsEmptyForEmptyInput: Bool
    var tracesPrompt: Bool
    static let dictation: Policy                    // reproduces ContentView exactly
    static let localAPI: Policy                     // reproduces DictationPostProcessingService exactly
}

struct Request { var text: String; var prompt: Prompt; var app: AppContext?; var policy: Policy }
struct Result { let text: String; let providerID: String; let model: String }

init(send: @escaping (LLMClient.Config) async throws -> LLMClient.Response = { try await LLMClient.shared.call($0) })
func process(_ request: Request) async throws -> Result
```

**Shared internals**

| Function | Notes |
|---|---|
| `resolveProvider(policy:slot:)` | Fail-closed for unknown providers. |
| `route(...) -> Route` | Pure: `.privateAI` / `.appleIntelligence` / `.llm`. |
| `messages(prompt:promptText:input:)` | Dictation folds prompt and transcript into one user turn via `SettingsStore.renderDictationUserMessage`. `.chat` keeps a system turn plus a user turn. |
| Prompt text | `effectiveDictationSystemPrompt(for:appBundleID:)` or `effectiveSystemPrompt(for: .dictate, appBundleID:)`, keyed by the request's app bundle. |
| Reasoning params | `SettingsStore.reasoningExtraParameters`. |

Every row of the divergence table is reproduced, either by a `Policy` flag or by the `Prompt` / `AppContext` inputs. Ordering differences (when the missing-model check runs) follow the policy too.

**Callers**

- **`ContentView.processTextWithAI`** keeps its signature for now, so P2 can move it verbatim. It builds a `Request`:
  - `.slot(slot ?? activeSlot)`, or `.override` when an override is passed, or `.chat` when neither an override nor a slot is passed;
  - app = `recordingAppInfo ?? getCurrentAppInfo()`;
  - policy `.dictation`.
  - `isDictationCall` stays defined exactly as today: override or slot present.
- **`DictationPostProcessingService.process`** builds `Request(text, .slot(slot), app: nil, policy: .localAPI)`. Its private `resolveProvider` is deleted.

**Trace logging** moves to the processor and keeps the same lines, `source` and env/defaults switches (`FLUID_PROMPT_TRACE`, `EnableDebugLogs`).

### §2 — `DictationCoordinator` (phase P2)

`@MainActor final class DictationCoordinator: ObservableObject`, lazily created as `AppServices.shared.dictation`.

**Owns** (moved from `ContentView`):

- **Session state:** `activeRecordingMode`, `activeDictationShortcutSlot`, `isRecordingForRewrite`, `isRecordingForCommand`, `promptModeOverrideText`, `recordingAppInfo`, `recordingPrecedingText`, `overlayLifecycleID`, `prewarmDictationTask`, `pendingAIReprocessText`. Only state the UI reads is `@Published`.
- **Services:** `CommandModeService` and `RewriteModeService` (previously `ContentView` `@StateObject`s). `CommandModeView`, `RewriteModeView` and the notch callbacks get them from the coordinator.
- **Flow:**
  - `beginDictationRecording` and `stopAndProcessTranscription`;
  - the rewrite and command voice routes;
  - prompt-test routing;
  - `processTextWithAI`, now a thin wrapper over §1;
  - the formatting chain call sites;
  - focus restore and overlay helpers (`advanceOverlayLifecycle`, `hideOverlayAfterOutput`, `hideOverlayAsync`);
  - history actions (paste, copy, undo AI, reprocess last);
  - app-context capture (`getCurrentAppInfo`, `captureRecordingContext`, …);
  - Private AI prewarm;
  - benchmark logging (`appBench`).

**View couplings**

| Coupling | How it is handled |
|---|---|
| Onboarding sandbox / playground checks | Read `SettingsStore` only; moved as they are. |
| `playgroundUsed` | Written to `SettingsStore`. `ContentView` drops its `@State` mirror and reads `settings.playgroundUsed`. |
| `selectedSidebarItem` | `SidebarBridge { current: () -> SidebarItem?; select: (SidebarItem) -> Void }`, installed by `ContentView` at boot. This is the only host hook. |
| `MenuBarManager` | A `FluidApp` `@StateObject`. Passed once at boot and held `weak`. |

**Files**

- `Services/Dictation/DictationCoordinator.swift`: state, `bootIfNeeded`, entry points.
- `+Pipeline.swift`: stop → AI → format → type.
- `+Modes.swift`: rewrite, command, prompt test.
- `+History.swift`
- `+Context.swift`: app info, focus, overlay.

Function bodies move verbatim where possible. Edits are limited to what the move forces: replacing `self.menuBarManager`, `self.asr` and sidebar access.

### §3 — Hotkeys and boot (phase P3)

**Hotkey ownership.** The coordinator owns:
- `GlobalHotkeyManager`;
- `@Published hotkeyManagerInitialized`;
- all callbacks wired in `initializeHotkeyManagerIfNeeded`: start/stop, cancel, paste-last, prompt / command / rewrite triggers, live mode switches, and event-tap health re-checks with reinitialize.

`SettingsView` gets `hotkeyManager` from the coordinator, and a binding to the coordinator's `hotkeyManagerInitialized`.

**Boot timing is unchanged.** `handleContentAppear` calls `appServices.dictation.bootIfNeeded(menuBar:sidebar:)` at the same point where it calls `initializeHotkeyManagerIfNeeded()` today. This deliberately deviates from the roadmap brief ("AppServices starts it"). `AppServices` documents past launch crashes and depends on a UI-ready gate plus a 1.5 s delay, so ownership moves and timing does not.

These stay in `ContentView`:
- menu bar init;
- delayed audio init;
- accessibility-permission UI flows, which call `coordinator.reinitializeHotkeys()` on grant.

**Shortcut settings.**
- The `ContentView` shortcut `@State` values remain only as `SettingsView` editor bindings.
- The coordinator never reads them. It reads `SettingsStore`, which they already persist to.
- Every change handler calls one `coordinator.applyShortcutSettings()`. This covers the `onChange`s, the capture monitor, the enable toggles, `hotkeyMode` and prompt shortcut assignments.
- `applyShortcutSettings()` replaces the ~15 scattered `hotkeyManager?.updateX(...)` calls.

**Out of scope**
- `SettingsView` binding refactor;
- moving the boot trigger into `AppServices`;
- internals of `GlobalHotkeyManager`, `ASRService` and `TypingService`;
- other roadmap items.

## Phasing and commits

Each phase is one or more commits. Each commit builds, passes all suites and does not raise the warning count.

1. **P1:** `DictationAIProcessor` plus characterization tests. Both callers switched over.
2. **P2:** `DictationCoordinator` with session state and flow. `ContentView` delegates; hotkey wiring is still in `ContentView` and calls the coordinator.
3. **P3:** hotkey manager and callbacks move into the coordinator. `applyShortcutSettings()` added. Docs updated.

## Testing

**P1 characterization tests** (`DictationAIProcessorTests`) run against a fake `send`:
- Both policies × provider kinds:
  - built-in;
  - saved/custom, including the key-fallback difference;
  - unknown (fail closed);
  - local without a key (allowed);
  - remote without a key (`missingAPIKey`).
- Prompt shapes: slot (with and without an app bundle), override, chat.
- Assertions on the exact `LLMClient.Config`: messages, model, baseURL, apiKey, temperature (including temperature-unsupported models), `timeoutSeconds`, extraParameters.
- Result text with and without GAAV.
- Empty-input behaviour.
- The `route(...)` decision for the Private AI and Apple Intelligence cases.

Settings are snapshotted and restored per test.

**P2/P3 coordinator tests:**
- output route on hotkey stop (normal vs onboarding sandbox, by onboarding step and mode);
- active slot resolution;
- mode set/clear transitions.

**Every phase:**
- `./build.sh` passes;
- the full suite passes;
- warning count ≤ 76.

## Verification (manual, after P3; your machine)

1. Hold and toggle dictation into TextEdit, with AI enhancement off and then on.
2. Prompt-mode shortcut with a custom prompt.
3. Command mode by voice.
4. Rewrite mode with selected text.
5. Cancel shortcut while recording.
6. Paste-last and copy-last shortcuts; undo AI processing.
7. Onboarding playground (via a fresh onboarding step, or a check on step 4/5 routing).
8. Local API: `curl` `/postprocess` returns the same text as before for the same input and settings.
9. Settings: change each shortcut and its enable toggle, then confirm the new binding works without a restart.

## Risks

- **Verbatim-move edits** (`self.` targets changing) can silently change which object holds state. *Mitigation:* the compiler catches missing members; the coordinator tests cover the decisions.
- **Weak `MenuBarManager` reference** could go nil. *Mitigation:* it lives for the app's lifetime as a `FluidApp` `@StateObject`; log if nil.
- **`SettingsStore` persistence lag.** If any shortcut editor ever wrote `@State` without persisting, the coordinator would read stale settings. *Mitigation:* audit every change handler in P3 so each persists before calling `applyShortcutSettings()`.

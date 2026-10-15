# FluidVoice Architecture

This document describes how FluidVoice works end to end: dictation, AI post-processing, text insertion, and the MeetAI meeting subsystem (recording, transcription, diarization, summaries). It has two halves:

- **Part 1 — Current state**: the app as it was at the start of the `meetai-v2-hardening` review (baseline commit `d2071ae` on top of `meetai-v2`).
- **Part 2 — Target state**: the app after the review fixes and refactor, with a delta table mapping each finding to the change that addressed it.

All paths are relative to `Sources/Fluid/` unless noted.

---

# Part 1 — Current state

## 1.1 System context

```mermaid
flowchart LR
    user([User])
    subgraph mac[macOS]
        fv[FluidVoice.app<br/>menu-bar + main window]
        focused[Focused app<br/>text field]
        coreaudio[(Core Audio<br/>mic + process tap)]
        ax[Accessibility / CGEvent]
        tcc[TCC permissions<br/>Mic · Accessibility · Audio capture]
    end
    subgraph local[Local, on-device]
        coreml[[CoreML ASR models<br/>Parakeet · Nemotron · Cohere]]
        whisper[[whisper.cpp<br/>ggml models]]
        applespeech[[Apple Speech /<br/>SpeechAnalyzer]]
        diar[[FluidAudio diarizer<br/>CoreML]]
        privai[[Private AI runtime<br/>on-device LLM]]
        afm[[Apple Intelligence<br/>FoundationModels]]
        llmlocal[[Local LLM server<br/>Ollama · LM Studio · llama-server]]
    end
    subgraph cloud[Remote]
        llmcloud[[OpenAI-compatible LLM APIs<br/>OpenAI · Anthropic · xAI · Groq · Cerebras · Google · OpenRouter · custom]]
        hf[(Hugging Face<br/>model downloads)]
        ph[(PostHog<br/>anonymous analytics)]
    end

    user -- hotkey / speech --> fv
    fv <--> coreaudio
    fv --> ax --> focused
    fv -.checks.-> tcc
    fv --> coreml & whisper & applespeech & diar
    fv --> privai & afm
    fv -- HTTPS / HTTP --> llmlocal & llmcloud
    fv -- first use --> hf
    fv -- opt-out --> ph
```

## 1.2 Process & component map

```mermaid
flowchart TB
    subgraph entry[App entry]
        app[fluidApp.swift<br/>FluidApp: App]
        delegate[AppDelegate<br/>logging · settings init · LocalAPIServer · analytics]
        services[AppServices.shared<br/>lazy ASRService · AudioHardwareObserver]
        menubar[MenuBarManager<br/>NSStatusItem · overlays]
    end
    subgraph ui[UI — SwiftUI]
        content[ContentView<br/>NavigationSplitView + <b>dictation orchestration</b>]
        meetings[MeetingsView]
        recorder[MeetingRecorderCard]
        qa[MeetingQAPanel]
        filetx[MeetingTranscriptionView<br/>File Transcription tab]
        settings[Settings · AI Enhancement · Voice Engine · Dictionary]
        overlay[Notch / Bottom overlay]
    end
    subgraph dictation[Dictation services]
        hotkey[GlobalHotkeyManager<br/>CGEventTap]
        asr[ASRService<br/>capture · streaming · final]
        providers[TranscriptionProvider impls]
        gate[DictationAIPostProcessingGate]
        llm[LLMClient.shared]
        typing[TypingService]
        cmd[CommandModeService]
        rewrite[RewriteModeService]
    end
    subgraph meeting[Meeting services]
        session[MeetingRecordingSession]
        live[MeetingLiveTranscriber]
        pipeline[MeetingTranscriptPipeline]
        aiclient[MeetingAIClient]
        namer[MeetingSpeakerNamer]
        relabel[MeetingRelabeler]
        reproc[MeetingReprocessor]
        importer[MeetingUploadImporter]
        activity[MeetingFolderActivity]
    end
    subgraph persist[Persistence]
        store[SettingsStore<br/>UserDefaults, ~120 keys]
        keychain[KeychainService<br/>provider API keys]
        hist[TranscriptionHistoryStore<br/>FileTranscriptionHistoryStore<br/>ChatHistoryStore]
        profiles[SpeakerProfileStore]
        disk[(Application Support/FluidVoice)]
    end

    app --> delegate & services & menubar & content
    content --> hotkey & asr & typing & gate & llm & cmd & rewrite
    content --> meetings & filetx & settings
    meetings --> recorder & qa
    menubar --> overlay
    services --> asr --> providers
    recorder --> session & live & pipeline
    meetings --> pipeline & relabel & reproc & activity
    filetx --> importer --> pipeline
    pipeline --> asr & aiclient & namer & profiles & hist
    aiclient --> llm
    qa --> aiclient
    gate & llm --> store --> keychain
    session & pipeline --> disk
```

Notable: the **dictation pipeline is owned by a SwiftUI view**. `ContentView.handleContentAppear()` boots the runtime (menu bar, delayed `asr.initialize()`, accessibility polling, hotkey manager), and `GlobalHotkeyManager` lives in ContentView `@State`. Callbacks injected from ContentView drive start/stop/AI/typing.

## 1.3 Dictation: hotkey → text inserted

```mermaid
sequenceDiagram
    autonumber
    participant K as CGEventTap
    participant H as GlobalHotkeyManager
    participant C as ContentView
    participant A as ASRService
    participant Cap as DirectCoreAudioInput /<br/>AVAudioEngine
    participant P as AudioCapturePipeline<br/>(16 kHz, levels)
    participant X as TranscriptionExecutor<br/>(actor)
    participant Pr as TranscriptionProvider
    participant G as DictationAIPostProcessingGate
    participant L as LLMClient / PrivateAI /<br/>AppleIntelligence
    participant T as TypingService

    K->>H: key/flags event
    H->>H: handlePrimaryDictationTriggerDown<br/>(hold · toggle · automatic)
    H->>C: dictationModeCallback
    C->>A: start(onCaptureStarted:)
    A->>Cap: start capture
    C->>C: captureRecordingContext()<br/>(frontmost app, focused PID, text before cursor)
    C->>C: show overlay · prewarm Private AI
    loop while recording
        Cap->>P: PCM frames (C SPSC ring)
        P->>A: ThreadSafeAudioBuffer
        A->>Pr: transcribeStreaming (runStreamingLoop, main actor)
        Pr-->>C: partial text → notch overlay
    end
    K->>H: release / toggle
    H->>C: stopAndProcessCallback
    C->>A: stop()
    A->>X: run { transcribeFinal(pcm) }
    X->>Pr: transcribeFinal
    Pr-->>A: text
    A->>A: removeFillerWords · applyCustomDictionary ·<br/>spoken punctuation
    A-->>C: raw transcript
    alt command / rewrite / prompt-test route
        C->>C: CommandModeService · RewriteModeService · DictationPromptTestCoordinator
    else dictation
        C->>G: isConfigured(for: appBundleID)?
        opt AI enhancement enabled & provider verified
            C->>L: processTextWithAI (prompt + transcript)
            L-->>C: enhanced text (fallback: raw + notification)
        end
        C->>C: literal · GAAV · continuous · terminal formatting<br/>→ makeDictationLiteralOutputPlan
        C->>C: TranscriptionHistoryStore.addEntry · audio history
        C->>T: typeOutputPlanInstantly (background queue)
        T->>T: reliable paste? → CGEvent unicode → AX insert →<br/>HID unicode → clipboard ⌘V → menu paste → per-char
    end
```

### ASR providers

| Provider | File | Backend | Streaming |
|---|---|---|---|
| `FluidAudioProvider` | `Services/FluidAudioProvider.swift` | FluidAudio Parakeet TDT v2/v3 (`AsrManager` ×2) — also handles `.qwen3Asr` | yes |
| `ParakeetRealtimeProvider` | `Services/ParakeetRealtimeProvider.swift` | FluidAudio `StreamingEouAsrManager` | yes |
| `NemotronProvider` | `Services/NemotronProvider.swift` | `NemotronStreamingAsrManager` (HF download) | yes; prefers native file transcription |
| `ExternalCoreMLTranscriptionProvider` | `Services/ExternalCoreMLTranscriptionProvider.swift` | Cohere 6-bit CoreML (`CohereTranscribeAsrManager`) | preview; prefers native file transcription |
| `WhisperProvider` | `Services/WhisperProvider.swift` | SwiftWhisper (whisper.cpp), ggml in `~/Library/Caches/WhisperModels` | small models only |
| `AppleSpeechProvider` | `Services/AppleSpeechProvider.swift` | `SFSpeechRecognizer` | yes |
| `AppleSpeechAnalyzerProvider` | `Services/AppleSpeechAnalyzerProvider.swift` | macOS 26 `SpeechAnalyzer` | yes |

FluidAudio-based providers are `#if arch(arm64)` only. Selection: `ASRService.transcriptionProvider` switches on `SettingsStore.SpeechModel`. Model preparation: `ensureAsrReady()` → `prepareProviderWithRecovery` → `provider.prepare`.

## 1.4 AI provider resolution

```mermaid
flowchart LR
    sel[SettingsStore.selectedProviderID] --> isCustom{custom:&lt;id&gt;?}
    isCustom -- yes --> saved[savedProviders<br/>baseURL · models]
    isCustom -- no --> repo[ModelRepository.shared<br/>defaultBaseURL · defaultModels]
    saved & repo --> model[selectedModelByProvider]
    sel --> key[SettingsStore.providerAPIKeys<br/>Keychain read on every access]
    model --> reasoning[getReasoningConfig<br/>reasoning_effort · enable_thinking · …]
    model & key & reasoning --> cfg[LLMClient.Config]
    cfg --> api{shouldUseResponsesAPI?}
    api -- yes --> resp[/responses SSE/]
    api -- no --> chat[/chat/completions SSE/]
```

- Apple Intelligence (`Networking/AppleIntelligenceProvider.swift`) and Private AI (`Services/PrivateAIIntegrationService.swift`, actor) bypass `LLMClient`.
- Gate: `DictationAIPostProcessingGate` requires a non-Off prompt, per-app routing scope, and a *verified* provider (SHA256 of `baseURL|apiKey` in `verifiedProviderFingerprints`).
- Duplicated logic (current): `isLocalEndpoint` in 5 copies + 2 wrappers; reasoning-param `extraParameters` block copied in 7 call sites; provider/key resolution in 5 places.

## 1.5 Meeting recording

```mermaid
flowchart LR
    subgraph capture[Capture — MeetingRecordingSession.start]
        tap[SystemAudioTap<br/>CATapDescription global tap<br/>excluding own PID → private aggregate device]
        tapRec[ProcessTapRecorder<br/>native Float32 stereo · gap-fill silence<br/>queue com.fluidvoice.meetai.tap-recorder]
        mic[MeetingMicRecorder<br/>AVAudioEngine input tap 4096 frames<br/>→ 16 kHz mono Int16]
        gate[Leak gate<br/>sys peak > 0.08 and mic < 0.35×sys → zero frame]
    end
    tap --> tapRec --> sysw[(system.wav)]
    mic --> gate --> micw[(mic.wav)]
    tapRec -. lastPeak .-> gate
    tapRec -- 16 kHz tee --> q1[LiveSampleQueue]
    mic -- tee --> q2[LiveSampleQueue]
    q1 & q2 --> live[MeetingLiveTranscriber<br/>tick every 10 s · cut at ≥0.3 s silence or 25 s<br/>Me / Them only, no diarization]
    live --> pane[Live pane + Q&A context<br/>memory only]
    stop[MeetingRecordingSession.stop] --> manifest[(session.json)]
    stop --> auto[MeetingRecorderCard.transcribe → pipeline.process]
```

### On-disk layout

```
~/Library/Application Support/FluidVoice/
├── MeetingRecordings/
│   └── <ISO8601 meetingFileSafe timestamp>/      one folder per meeting / upload
│       ├── system.wav      far end (tap) or uploaded audio (16 kHz Int16)
│       ├── mic.wav         local mic ("Me"); 0.1 s silence for uploads
│       ├── session.json    MeetingRecordingArtifacts (folder, wavs, startedAt, endedAt)
│       ├── transcript.md   **[MM:SS] Speaker:** text
│       ├── summary.md      LLM summary (selected style)
│       ├── title.txt       "Short title (Wed 9 Jul, 3:04 pm)"
│       └── speakers.json   label → L2-normalised voice centroid
├── SpeakerProfiles/profiles.json   enrolled voices (running weighted centroids)
└── DictationAudioHistory/          optional dictation audio
UserDefaults: SettingsStore keys · TranscriptionHistoryEntries ·
              FileTranscriptionHistoryEntries (cap 50, incl. meetings) · CommandModeChatSessions
Keychain:     com.fluidvoice.provider-api-keys / fluidApiKeys (JSON dict)
Logs:         ~/Library/Logs/Fluid/Fluid.log
```

## 1.6 Meeting post-processing pipeline (current)

`MeetingTranscriptPipeline.process(_:)` — a `@MainActor ObservableObject`; **every stage below runs on the main thread except the awaited ASR/LLM calls.**

```mermaid
flowchart TB
    start([process artifacts]) --> lock[1 · MeetingFolderActivity.begin folder<br/>throws if busy]
    lock --> ready[2 · asrService.ensureAsrReady · fileTranscriptionProvider]
    ready --> micload[3 · loadSamples16kMono mic.wav<br/>⚠ sync on main]
    micload --> mictx[4a · transcribeTrack Me<br/>splitOnSilence ⚠ main · 30 s cap +1 s tail<br/>provider.transcribe per utterance<br/>⚠ every error swallowed]
    mictx --> sysload[3b · loadSamples16kMono system.wav ⚠ main<br/>mic samples still alive]
    sysload --> systx[4b · transcribeTrack Them]
    systx --> diar[5 · resolveSpeakers<br/>DiarizerManager threshold 0.75<br/>performCompleteDiarization ⚠ sync CoreML on main<br/>drop clusters &lt; 2 s · centroid · profile match ≥ 0.7<br/>dominant-overlap label]
    diar --> merge[6 · merge tracks by start]
    merge --> echo[7 · suppressEcho<br/>Me line dropped if Them line ±5 s, token sim ≥ 0.6]
    echo --> name[8 · MeetingSpeakerNamer LLM<br/>Them N → real names JSON]
    name --> enrol[9 · enrollProfiles · speakers.json]
    enrol --> md[10 · renderMarkdown → transcript.md]
    md --> histentry[11 · FileTranscriptionHistoryStore<br/>replace 'Meeting &lt;folder&gt;' entry]
    histentry --> sum[12 · summarize → MeetingAIClient<br/>failure only sets summaryError]
    sum --> title[13 · generateTitleLine → title.txt]
    title --> del[14 · deleteAudioIfConfigured<br/>⚠ default ON, no toggle,<br/>runs even if transcript empty / summary failed]
    del --> done([Complete])
```

### MeetingAIClient

- `resolveProvider()` reuses AI Enhancement settings; `contextBudgetTokens` = 4096 for Apple Intelligence, effectively unbounded otherwise.
- On "context / too long / maximum length / token limit" errors, halves the budget based on what was actually sent; 20 attempts for local endpoints, 4 for remote.
- `complete()` → Apple Intelligence, or `LLMClient` with temperature 0.3, reasoning extras, **180 s timeout**. Local servers: `waitForLocalEndpoint` (~40 s).
- To fit 180 s, the **shared** `LLMClient` URLSession's `timeoutIntervalForResource` was raised to 600 s for *every* caller.

## 1.7 Post-hoc operations (current)

| Operation | Entry | Path | Lock |
|---|---|---|---|
| Re-transcribe | `MeetingsView.reprocess` | `MeetingReprocessor.artifacts(inFolder:)` (needs both WAVs) → `MeetingTranscriptPipeline.sharedReprocessor.process` | folder |
| Reprocess on launch | `ContentView` → `MeetingReprocessor.runLaunchReprocessIfRequested` | one-shot defaults flags `MeetAIReprocessAllOnLaunch` / `…LatestOnLaunch` | folder |
| Regenerate summary | Summarise menu | `regenerateSummary(folder:style:)` → `plainTranscript` → `generateSummaryBody` | folder; UI progress via single `@State summarizingFolder` ⚠ |
| Relabel speaker | Name speakers section | `SpeakerProfileStore` enrol/move → `MeetingRelabeler.relabel` (transcript.md · history · speakers.json · summary · title) | folder |
| Q&A | `MeetingQAPanel` | live transcript, else **newest** "Meeting " history entry ⚠ → `MeetingQAService.ask` → `completeAboutTranscript` | none |
| Upload | File Transcription tab | `MeetingTranscriptionService.transcribeFile` → `Task.detached { MeetingUploadImporter.importArtifacts }` (full file in memory) → `process()` decodes it **again on main** ⚠ → result looked up by `"Meeting <timestamp>"` (upload filename lost) ⚠ | folder |

Pipeline instances that can exist at once: MeetingRecorderCard's own `@StateObject` (progress lost on navigation), the shared reprocessor, one per upload, one per launch-reprocess folder. Only `MeetingFolderActivity` (a `Set<String>` of busy folders) serialises them per folder.

## 1.8 Concurrency map (current)

The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Consequences:

- Every type without an explicit annotation is main-actor isolated.
- A synchronous `nonisolated` function called from main **still runs on main**; a `nonisolated async` function runs on the caller's actor. Only `@concurrent` functions (or `Task.detached`) leave the main actor.

| Off main | On main (hot spots) |
|---|---|
| Audio IO threads (tap IOProc, AVAudioEngine tap, C ring) | `MeetingTranscriptPipeline`: decode, VAD, diarization, echo, markdown |
| `TranscriptionExecutor` actor (dictation ASR) | `MeetingLiveTranscriber.tick`: VAD every 10 s |
| `PrivateAIIntegrationService` actor | `ASRService.runStreamingLoop` |
| `TypingService` global queue | `usleep` in AVAudioEngine format retry; `TypingService.restoreCapturedFocus` sleeps |
| Upload import (`Task.detached`) | `SettingsStore.providerAPIKeys` Keychain read per access (29 call sites) |
| | History stores JSON-encode whole arrays into UserDefaults per save |

Also: `TypingService.virtualKeyCode` uses `DispatchQueue.main.sync` from a worker (deadlock-prone); `TypingService.isCurrentlyTyping` mutated off-main without synchronisation.

## 1.9 Build & dependencies (current)

- Real build: `Fluid.xcodeproj` (scheme `Fluid`), driven by `./build.sh` (ad-hoc signed; `install` copies to `/Applications`). `Package.swift` exists but cannot build the app (wrong target path, missing MediaRemoteAdapter, SwiftWhisper pin drift).

| Package | Pin (xcodeproj) | Used? |
|---|---|---|
| FluidAudio (altic-dev fork) | branch `B/cohere-coreml-asr` | yes — ASR, diarization (pulls swift-transformers, swift-jinja, swift-collections) |
| SwiftWhisper | 1.2.0 | yes |
| DynamicNotchKit (altic-dev fork) | branch `main` | yes — notch overlay |
| mediaremote-adapter | branch | yes — media pause/resume (arm64) |
| AppUpdater | 1.1.1 | **never imported** — only supplies PromiseKit transitively |
| PromiseKit | transitive 6.22.1 | yes — AppDelegate, MenuBarManager, SimpleUpdater, SettingsView |
| posthog-ios | Package.swift only | **never imported** (analytics posts raw HTTP) |

- Tests: single Xcode-only target `FluidDictationIntegrationTests` (dictation E2E, hotkeys, LLM request bodies, temperature support). **No meeting tests.**

## 1.10 Tech debt snapshot

- Largest files (lines): SettingsStore 4917 · ContentView 4458 · ASRService 3951 · BottomOverlayView 3286 · AISettingsView+AIConfiguration 2758 · WelcomeView 2669 · SettingsView 2611.
- Dead code: `Networking/AIProvider.swift`, `Networking/FunctionCallingProvider.swift`.
- `DictationPostProcessingService` near-duplicates `ContentView.processTextWithAI` (used only by the Local API).
- `.qwen3Asr` routes to the Parakeet provider with no Qwen-specific code.
- Meeting history in a 50-entry UserDefaults list: older meetings vanish from the Meetings list while their folders remain.

## 1.11 Code-review findings (baseline)

| # | Finding | Location |
|---|---|---|
| 1 | Audio deleted even when transcript empty or summary failed (default ON, no toggle) | `MeetingTranscriptPipeline.process` |
| 2 | Per-utterance catch swallows every error incl. cancellation and provider-wide failures | `transcribeTrack` |
| 3 | Decode / VAD / diarization on main; upload decodes the full file twice | pipeline, `MeetingTranscriptionService` |
| 4 | `MarkdownText` reads `components.first` → list items render as paragraphs | `UI/MarkdownText.swift` |
| 5 | Final utterance chunk can be 31 s, over the 30 s cap | `splitOnSilence` |
| 6 | Upload ignores `prefersNativeFileTranscription` | `MeetingTranscriptionService` |
| 7 | Upload result loses the original filename; empty-text guard dead; progress resets to 0 after "Complete!" | `MeetingTranscriptionService` |
| 8 | Single `summarizingFolder` state races across meetings | `MeetingsView` |
| 9 | `isLocalEndpoint` ×7 and reasoning-params ×7 duplicated | many |
| 10 | Session-wide 600 s resource timeout for all LLM calls | `LLMClient` |

---

# Part 2 — Target state

_Filled in once the hardening commits land._

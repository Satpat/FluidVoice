# MeetAI v3 Upstream Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run upstream FluidVoice v1.6.11 (with FluidMeet) as the base and re-add the fork's meeting features — persistent speakers, LLM speaker naming, titles, summaries, Q&A, audio import — plus migration of the 113 old fork meetings, as a thin MeetAI layer.

**Architecture:** All fork code lives in `Sources/Fluid/MeetAI/` and `Sources/Fluid/UI/MeetAI/`. It talks to FluidMeet through upstream's public `MeetingSessionCoordinator` / `MeetingSessionStore` APIs and six small hook points (H1–H6). MeetAI keeps its own sidecar JSON per session under `~/Library/Application Support/FluidVoice/MeetAI/`, and calls the user's AI Enhancement provider through upstream's `LLMClient`.

**Tech Stack:** Swift 5 language mode, default `MainActor` isolation with approachable concurrency, SwiftUI, AVFoundation, CryptoKit, FluidAudio (`EmbeddingExtractor`), XCTest (`@testable import FluidVoice_Debug`).

**Spec:** `docs/superpowers/specs/2026-10-16-meetai-v3-upstream-intake-design.md` (read §12 "Plan-time amendments" first — it refines §5–§7).

## Global Constraints

- Branch `meetai-v3`, worktree `.claude/worktrees/meetai-v3`, base upstream `v1.6.11` (`9bf99b4`). Never commit to `main`; never push without the user's go-ahead.
- Upstream files may only change at: H1 + H6 (`MeetingSessionCoordinator.swift`), H2 (`MeetingSessionCanvases.swift`, `MeetingWorkspaceComponents.swift`), H3 (`MeetingTranscriptionView.swift`), H4 (`AppDelegate.swift`), H5 (`SimpleUpdater.swift`), and `build.sh`. Everything else is new files.
- Deployment target macOS 15.0. Pure data types and `Codable` types are declared `nonisolated` (upstream convention under default `MainActor` isolation). CPU-heavy async work (`decode`, `embed`) is `@concurrent`.
- MeetAI storage root: `~/Library/Application Support/FluidVoice/MeetAI/`. Never write to `MeetingRecordings/` or the legacy `SpeakerProfiles/` (read only).
- Speaker matching: cosine ≥ `0.7`, 256-d WeSpeaker embeddings from FluidAudio `EmbeddingExtractor` + `ModelNames.Diarizer.embeddingFile`. Clips 3–10 s (48 000–160 000 samples at 16 kHz). Up to 30 s of clean turns per speaker; turns ≥ 1.5 s; skip speakers with < 3 s.
- H1 timeout: 30 s. Coordinator mutations retry up to 10 times, 1 s apart, on `MeetingCoordinatorError.activityInProgress` / `.maintenanceInProgress`.
- LLM: AI Enhancement provider via `LLMClient`; 180 s request timeout; context-overflow halving with max 20 attempts (local endpoint) / 4 (remote); temperature 0.3 unless `isTemperatureUnsupported`; `maxTokens: 32_000` for reasoning models; reasoning params from `getReasoningConfig`. Private AI provider → clear error. No Apple Intelligence branch.
- UserDefaults keys: `MeetAIAutoSummarize` (default true), `MeetAISummaryStyle` (default `standard`), `MeetAIAutoName` (default true), `MeetAISpeakerMatching` (default true).
- Test suite baseline (spec §11): exactly 11 known failures. After every task the failing set must be those 11 or a subset. No new failures.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Upstream `.gitignore` ignores `docs/`, `scripts/` and `*.md`: add such files with `git add -f`.

## Review Focus

1. **Meeting with no transcript text or only the local user speaking** → no LLM call for naming, summary shows "No transcript to summarise", nothing crashes. Pinned in Task 9 (`testNamingSkipsWhenOnlyLocalUser`) and Task 10 (`testSummaryOfEmptyTranscriptFailsCleanly`).
2. **AI provider missing, misconfigured, or Private AI selected** → the summary view shows the provider error with Retry; automation logs and continues; the transcript is untouched. Pinned in Task 10 (`testSummaryErrorIsRecordedNotThrown`).
3. **Two speakers in one meeting both match the same saved voice** → only the higher-scoring speaker gets the name. Pinned in Task 6 (`testSameProfileGoesToBestSpeakerOnly`).
4. **Meeting deleted (or coordinator busy) while MeetAI automation runs** → automation gives up quietly, no crash, no retry storm; the orphaned sidecar is swept on next launch. Pinned in Task 8 (`testMutationOnDeletedSessionIsSwallowed`, `testBusyCoordinatorIsRetriedThenGivesUp`).
5. **Legacy transcripts with odd lines** (header lines, blank lines, duplicate timestamps, colons in names, wrapped text) → parser keeps every line's text, segments always have `end > start`. Pinned in Task 14 (`testParserHandlesOddLines`).

Also: unit tests run hosted in the debug app, which shares `~/Library/Application Support/FluidVoice` with the real app. `MeetAIBootstrap.start()` returns early under XCTest (`isTestHost`), and every MeetAI test uses temp directories and its own `MeetingSessionStore(rootDirectory:)`. The only tests that touch real data are the opt-in spike/dry-run tests, which read (dry run copies first) or write one clearly named spike meeting.

---

## Conventions used by every task

**Scratch DerivedData** (keeps builds out of the worktree):

```bash
export DD="${TMPDIR:-/tmp}/meetai-v3-dd"
```

**Run one test class** (replace `<Class>`):

```bash
set -o pipefail; xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -only-testing:FluidDictationIntegrationTests/<Class> CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|error:|Executed|BUILD|TEST " | tail -40
```

**Run the full suite** (end of every task; compare the failing set to spec §11):

```bash
set -o pipefail; xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > "$DD-full.log" 2>&1; grep -E "Executed [0-9]+ tests" "$DD-full.log" | tail -1; grep -E "Test Case .* failed" "$DD-full.log" | sed -E "s/.*'-\[[A-Za-z_]+\.(.*)\]' failed.*/\1/" | sort -u
```

**Register a new test file** (app sources under `Sources/Fluid` are a synchronized folder and need no registration; the test target uses explicit references). The script arrives in Task 2:

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAIExampleTests.swift
```

**Opt-in tests** read environment variables passed with the `TEST_RUNNER_` prefix, e.g. `TEST_RUNNER_MEETAI_MODEL_TESTS=1 xcodebuild test …` exposes `MEETAI_MODEL_TESTS=1` to the test.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/Fluid/MeetAIBuildFlags.swift` | Fork build switches (updater off) | 1 |
| `Sources/Fluid/UI/MarkdownText.swift` | Markdown renderer (cherry-pick) | 2 |
| `Sources/Fluid/MeetAI/Import/MeetAIAudioDecoder.swift` | Any audio file → 16 kHz mono `[Float]` | 3 |
| `Sources/Fluid/MeetAI/Import/MeetAISyntheticSessionBuilder.swift` | Build FluidMeet sessions from audio or legacy transcripts | 3 |
| `Sources/Fluid/MeetAI/Import/MeetAISessionImport.swift` | Persist a synthetic audio session through a store | 3 |
| `Sources/Fluid/MeetAI/MeetAIPaths.swift` | All MeetAI and legacy file locations | 4 |
| `Sources/Fluid/MeetAI/MeetAISettings.swift` | MeetAI UserDefaults toggles | 4 |
| `Sources/Fluid/MeetAI/MeetAISidecarStore.swift` | Per-session sidecar JSON (summary, Q&A, speakers, meta) + orphan sweep | 4 |
| `Sources/Fluid/MeetAI/MeetAITranscript.swift` | Transcript text, stable hash, default-label detection | 4 |
| `Sources/Fluid/MeetAI/MeetAIHooks.swift` | H1/H6 entry points with timeout | 4 |
| `Sources/Fluid/MeetAI/MeetAIBootstrap.swift` | Launch wiring (H4) | 4, 8, 14 |
| `Sources/Fluid/MeetAI/LLM/EndpointClassifier.swift` | Local vs remote endpoint (port) | 5 |
| `Sources/Fluid/MeetAI/LLM/MeetAILLM.swift` | Provider resolution, completion, context-fit retry | 5 |
| `Sources/Fluid/MeetAI/Speakers/MeetAISpeakerMath.swift` | Vector maths | 6 |
| `Sources/Fluid/MeetAI/Speakers/MeetAISpeakerProfileStore.swift` | Persistent voice profiles (port) | 6 |
| `Sources/Fluid/MeetAI/Speakers/MeetAICleanTurns.swift` | Pick clean turns per speaker | 6 |
| `Sources/Fluid/MeetAI/Speakers/MeetAIProfileMatching.swift` | Match speakers → profiles | 6 |
| `Sources/Fluid/MeetAI/Speakers/MeetAISpeakerEmbedder.swift` | Segment audio → WeSpeaker centroid | 7 |
| `Sources/Fluid/MeetAI/MeetAISessionProcessor.swift` | Per-session orchestration (H1/H6 handlers) | 8–10 |
| `Sources/Fluid/MeetAI/Speakers/MeetAICorrectionDiff.swift` | Detect user renames/merges → enrolments | 8 |
| `Sources/Fluid/MeetAI/MeetAISpeakerNamer.swift` | LLM naming prompt + parser (port) | 9 |
| `Sources/Fluid/MeetAI/MeetAITitler.swift` | Title prompt, cleaning, ownership | 9 |
| `Sources/Fluid/MeetAI/MeetAISummaryStyle.swift` | Four summary styles (port) | 10 |
| `Sources/Fluid/MeetAI/MeetAISummarizer.swift` | Summary generation | 10 |
| `Sources/Fluid/UI/MeetAI/MeetAISummaryView.swift` | Summary tab | 10 |
| `Sources/Fluid/MeetAI/MeetAIQAService.swift` | Per-session Q&A | 11 |
| `Sources/Fluid/UI/MeetAI/MeetAIQAPanel.swift` | Ask tab | 11 |
| `Sources/Fluid/UI/MeetAI/MeetAIKnownSpeakersView.swift` | Profile list | 12 |
| `Sources/Fluid/UI/MeetAI/MeetAISettingsSheet.swift` | MeetAI settings | 12, 14, 15 |
| `Sources/Fluid/UI/MeetAI/MeetAIHomeActions.swift` | Meeting-home buttons (H3) | 12, 13 |
| `Sources/Fluid/MeetAI/Import/MeetAIAudioImporter.swift` | Import a file as a meeting | 13 |
| `Sources/Fluid/MeetAI/Migration/MeetAILegacyTranscriptParser.swift` | Parse fork `transcript.md` | 14 |
| `Sources/Fluid/MeetAI/Migration/MeetAIMigrator.swift` | Tier 1 + Tier 2 migration | 14, 15 |
| `Tests/FluidDictationIntegrationTests/MeetAI*.swift` | Tests per task | all |
| `docs/MEETAI.md` | Layer overview + hook list | 16 |

---

### Task 1: Updater kill switch and install profile

**Files:**
- Create: `Sources/Fluid/MeetAIBuildFlags.swift`
- Modify: `Sources/Fluid/AppDelegate.swift` (around line 119, `self.checkForUpdatesAutomatically()`)
- Modify: `Sources/Fluid/Services/SimpleUpdater.swift` (`checkForUpdatesAutomatically()` ~L389, `checkForUpdatesManually()` ~L394)
- Modify: `build.sh`

**Interfaces:**
- Produces: `MeetAIBuildFlags.updaterEnabled: Bool` (always `false`).

- [ ] **Step 1: Create the flag**

```swift
import Foundation

/// Build-level switches for the MeetAI fork of FluidVoice.
enum MeetAIBuildFlags {
    /// The updater installs upstream altic-dev release builds over the running app, which would
    /// replace this fork's binary. Keep disabled; update by merging upstream into the fork instead.
    static let updaterEnabled = false
}
```

- [ ] **Step 2: Guard the automatic check in `AppDelegate`**

Replace the single line `self.checkForUpdatesAutomatically()` (~L119) with:

```swift
        if MeetAIBuildFlags.updaterEnabled {
            self.checkForUpdatesAutomatically()
        }
```

- [ ] **Step 3: Guard both public entry points in `SimpleUpdater`**

At the top of the bodies of `func checkForUpdatesAutomatically()` and `func checkForUpdatesManually()` insert:

```swift
        guard MeetAIBuildFlags.updaterEnabled else {
            DebugLogger.shared.info("Updater disabled in the MeetAI fork build", source: "SimpleUpdater")
            return
        }
```

Do not touch `checkAndUpdate`, rollback or install-pipeline code: upstream's updater tests exercise those directly (and 10 of them already fail at baseline for signing reasons).

- [ ] **Step 4: Add the `install` profile to `build.sh`**

Usage block (lines 6–10) becomes:

```bash
# Usage:
#   ./build.sh                    # signed public OSS build
#   ./build.sh public             # signed public OSS build
#   ./build.sh unsigned           # unsigned public OSS build (CI/fallback)
#   ./build.sh install            # signed build with the release bundle ID, installed to /Applications
#   ./build.sh fi                 # private FI build
```

In `run_public_build`, change the build line (`xcodebuild "${build_args[@]}" DEVELOPMENT_TEAM="${development_team}"`) to pass an optional bundle-ID override:

```bash
    local -a extra_settings=()
    if [ -n "${FLUIDVOICE_BUNDLE_ID_OVERRIDE:-}" ]; then
        extra_settings+=(PRODUCT_BUNDLE_IDENTIFIER="${FLUIDVOICE_BUNDLE_ID_OVERRIDE}")
    fi
    xcodebuild "${build_args[@]}" DEVELOPMENT_TEAM="${development_team}" "${extra_settings[@]+"${extra_settings[@]}"}"
```

Add an `install` case before `fi|private|dev|full)`:

```bash
    install)
        # Upstream gives Debug builds the bundle ID com.FluidApp.app.debug to isolate test
        # preferences. The installed app must keep com.FluidApp.app so it reuses the user's
        # settings, keychain API keys and privacy permissions.
        FLUIDVOICE_BUNDLE_ID_OVERRIDE=com.FluidApp.app run_public_build signed
        installed_app="/Applications/FluidVoice.app"
        built_app="${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
        if pgrep -x "FluidVoice" >/dev/null 2>&1 || pgrep -x "FluidVoice Debug" >/dev/null 2>&1; then
            echo "Note: FluidVoice is running; quit it before relaunching the installed copy."
        fi
        rm -rf "${installed_app}"
        ditto "${built_app}" "${installed_app}"
        # ditto keeps the source bundle's timestamps; bump the bundle so Finder shows the install time.
        touch "${installed_app}"
        echo "Installed ${installed_app} ($(defaults read "${installed_app}/Contents/Info.plist" CFBundleIdentifier))"
        ;;
```

Update the `*)` case's "Valid profiles" line to include `install`.

- [ ] **Step 5: Verify**

```bash
grep -n "MeetAIBuildFlags.updaterEnabled" Sources/Fluid/AppDelegate.swift Sources/Fluid/Services/SimpleUpdater.swift
bash -n build.sh && echo "build.sh syntax ok"
```

Expected: three matches (1 in AppDelegate, 2 in SimpleUpdater); `build.sh syntax ok`. Do not run `./build.sh install` yet; it replaces the user's installed app (Task 16 does it, with a backup first).

- [ ] **Step 6: Build and run the full suite**

Run the full-suite command. Expected: same 11 failures as spec §11.

- [ ] **Step 7: Commit**

```bash
git add Sources/Fluid/MeetAIBuildFlags.swift Sources/Fluid/AppDelegate.swift Sources/Fluid/Services/SimpleUpdater.swift build.sh
git commit -m "Disable the upstream updater and add the install build profile

The updater would install upstream release builds over the fork. The
install profile builds with the release bundle ID so the installed app
keeps the user's settings, keychain keys and permissions.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Carry over fork files and ported tests

**Files:**
- Create (from `meetai-v2`): `Sources/Fluid/UI/MarkdownText.swift`, `Tests/FluidDictationIntegrationTests/MarkdownTextTests.swift`, `scripts/add_test_file_to_xcodeproj.py`, `docs/superpowers/specs/2026-10-15-dictation-coordinator-design.md`, `docs/superpowers/plans/2026-10-15-dictation-coordinator.md`
- Create: `Tests/FluidDictationIntegrationTests/FluidAudioSmokeTests.swift`, `Tests/FluidDictationIntegrationTests/MeetAIReasoningModelTests.swift`

**Interfaces:**
- Produces: `MarkdownText(markdown: String)` SwiftUI view; `MarkdownText.parse(_:) -> [MarkdownText.Block]`.

- [ ] **Step 1: Check out the files from `meetai-v2`**

```bash
git checkout meetai-v2 -- Sources/Fluid/UI/MarkdownText.swift Tests/FluidDictationIntegrationTests/MarkdownTextTests.swift scripts/add_test_file_to_xcodeproj.py docs/superpowers/specs/2026-10-15-dictation-coordinator-design.md docs/superpowers/plans/2026-10-15-dictation-coordinator.md
```

- [ ] **Step 2: Write the ported smoke test** (`Tests/FluidDictationIntegrationTests/FluidAudioSmokeTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

// Smoke test for the FluidAudio dependency at upstream's pin. Uses a model already in the
// local FluidAudio cache and skips otherwise, so it never triggers a large download.
@MainActor
final class FluidAudioSmokeTests: XCTestCase {
    private static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private func requireCachedModel(_ name: String) throws {
        let path = Self.modelsDirectory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("FluidAudio model \(name) is not cached at \(path)")
        }
    }

    func testParakeetV2TranscribesFixture() async throws {
        #if arch(arm64)
        try self.requireCachedModel("parakeet-tdt-0.6b-v2-coreml")
        let provider = FluidAudioProvider(modelOverride: .parakeetTDTv2, configureWordBoosting: false)
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribeFinal(samples)
        let text = result.text.lowercased()
        XCTAssertTrue(text.contains("hello"), "Got: \(result.text)")
        XCTAssertTrue(text.contains("fluid"), "Got: \(result.text)")
        #else
        throw XCTSkip("FluidAudio providers are arm64-only")
        #endif
    }
}
```

- [ ] **Step 3: Write the reasoning-model regression test** (`Tests/FluidDictationIntegrationTests/MeetAIReasoningModelTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

// Carried from the fork (90234f5): gpt-6.x models reject max_tokens and temperature.
// Upstream's isReasoningModel already covers them; this pins it so a narrowing fails loudly.
@MainActor
final class MeetAIReasoningModelTests: XCTestCase {
    func testGPT6GenerationIsReasoningModel() {
        let reasoning = ["gpt-6.1-sol", "gpt-6", "gpt-6-mini", "openai/gpt-6.1", "azure/gpt-6.1-sol"]
        for model in reasoning {
            XCTAssertTrue(SettingsStore.shared.isReasoningModel(model), "\(model) needs max_completion_tokens")
            XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported(model), "\(model) rejects temperature")
        }
        let chat = ["gpt-4.1", "gpt-4o", "gpt-4o-mini", "gpt-3.5-turbo", "gpt-4.1-nano"]
        for model in chat {
            XCTAssertFalse(SettingsStore.shared.isReasoningModel(model), "\(model) still uses max_tokens")
        }
    }
}
```

- [ ] **Step 4: Register the three test files**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MarkdownTextTests.swift
python3 scripts/add_test_file_to_xcodeproj.py FluidAudioSmokeTests.swift
python3 scripts/add_test_file_to_xcodeproj.py MeetAIReasoningModelTests.swift
```

- [ ] **Step 5: Run them**

Run the one-class command for `MarkdownTextTests`, `FluidAudioSmokeTests`, `MeetAIReasoningModelTests`. Expected: PASS (smoke test may SKIP if the model is not cached — record which).

- [ ] **Step 6: Full suite, then commit**

```bash
git add Sources/Fluid/UI/MarkdownText.swift Fluid.xcodeproj/project.pbxproj Tests/FluidDictationIntegrationTests/MarkdownTextTests.swift Tests/FluidDictationIntegrationTests/FluidAudioSmokeTests.swift Tests/FluidDictationIntegrationTests/MeetAIReasoningModelTests.swift
git add -f scripts/add_test_file_to_xcodeproj.py docs/superpowers/specs/2026-10-15-dictation-coordinator-design.md docs/superpowers/plans/2026-10-15-dictation-coordinator.md
git commit -m "Carry over MarkdownText, test tooling, coordinator docs and ported tests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Synthetic session builder and the opening spike

This task gates Tasks 13–15. If the opt-in spike (Step 9) fails, STOP, record the failure in spec §11, and ask the user before continuing (fallbacks in spec §6.6 / §7.4).

**Files:**
- Create: `Sources/Fluid/MeetAI/Import/MeetAIAudioDecoder.swift`
- Create: `Sources/Fluid/MeetAI/Import/MeetAISyntheticSessionBuilder.swift`
- Create: `Sources/Fluid/MeetAI/Import/MeetAISessionImport.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAISyntheticSessionBuilderTests.swift`

**Interfaces:**
- Produces:
  - `MeetAIAudioDecoder.load16kMono(url: URL, start: TimeInterval = 0, end: TimeInterval? = nil) throws -> [Float]` (`@concurrent static func decode(url:)` async wrapper)
  - `MeetAISyntheticSessionBuilder.LegacySpeaker { label: String; isLocalUser: Bool }`
  - `MeetAISyntheticSessionBuilder.LegacySegment { start: TimeInterval; end: TimeInterval; speakerLabel: String; text: String }`
  - `MeetAISyntheticSessionBuilder.TrackAudio { kind: MeetingAudioTrackKind; samples: [Float]; echoProtection: MeetingMicrophoneEchoProtection }`
  - `MeetAISyntheticSessionBuilder.audioSessionShell(id:title:languageCode:startedAt:duration:trackKinds:) -> MeetingSession`
  - `MeetAISyntheticSessionBuilder.writeChunks(samples:kind:sessionDirectory:) throws -> [MeetingAudioChunk]`
  - `MeetAISyntheticSessionBuilder.attach(_:kind:echoProtection:to:)`
  - `MeetAISyntheticSessionBuilder.transcriptOnlySession(id:title:startedAt:endedAt:speakers:segments:audioDeletedAt:) -> MeetingSession`
  - `MeetAISessionImport.createAudioSession(store:id:title:languageCode:startedAt:tracks:) async throws -> MeetingSession`

- [ ] **Step 1: Write the failing tests**

```swift
@testable import FluidVoice_Debug
import AVFoundation
import CryptoKit
import XCTest

@MainActor
final class MeetAISyntheticSessionBuilderTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetai-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sine(seconds: Double, frequency: Float = 220) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { 0.3 * sin(2 * .pi * frequency * Float($0) / 16_000) }
    }

    func testWriteChunksSplitsAtSixtySecondsAndHashesFiles() throws {
        let directory = try self.tempDirectory()
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(
            samples: self.sine(seconds: 130), kind: .microphone, sessionDirectory: directory
        )
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.presentationStart.seconds), [0, 60, 120])
        XCTAssertEqual(chunks.last?.presentationEnd.seconds ?? 0, 130, accuracy: 0.01)
        for chunk in chunks {
            XCTAssertEqual(chunk.finalizationState, .finalized)
            XCTAssertEqual(chunk.relativeFilePath, "tracks/microphone/\(String(format: "%06d", chunk.sequence)).wav")
            let data = try Data(contentsOf: chunk.fileURL(relativeTo: directory))
            XCTAssertEqual(chunk.byteCount, Int64(data.count))
            XCTAssertEqual(chunk.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let decoded = try MeetAIAudioDecoder.load16kMono(url: chunks[2].fileURL(relativeTo: directory))
        XCTAssertEqual(Double(decoded.count), 10 * 16_000, accuracy: 64)
    }

    func testDecoderReadsARange() throws {
        let directory = try self.tempDirectory()
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(samples: self.sine(seconds: 5), kind: .microphone, sessionDirectory: directory)
        let slice = try MeetAIAudioDecoder.load16kMono(url: chunks[0].fileURL(relativeTo: directory), start: 1, end: 3)
        XCTAssertEqual(Double(slice.count), 2 * 16_000, accuracy: 64)
    }

    func testDecoderRejectsGarbage() throws {
        let url = try self.tempDirectory().appendingPathComponent("garbage.wav")
        try Data("not audio".utf8).write(to: url)
        XCTAssertThrowsError(try MeetAIAudioDecoder.load16kMono(url: url))
    }

    func testAudioSessionRoundTripsThroughStoreAndIsRetryable() async throws {
        let root = try self.tempDirectory()
        let store = MeetingSessionStore(rootDirectory: root)
        let session = try await MeetAISessionImport.createAudioSession(
            store: store,
            title: "Imported call",
            languageCode: "en",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tracks: [.init(kind: .microphone, samples: self.sine(seconds: 70), echoProtection: .acousticallyClosed)]
        )
        let loaded = try await XCTUnwrapAsync(await store.load(id: session.id))
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded.mode, .inRoom)
        XCTAssertEqual(loaded.state, .interrupted)
        XCTAssertTrue(loaded.hasRetryableAudio)
        XCTAssertEqual(loaded.audioTracks.first?.chunks.count, 2)
        XCTAssertEqual(loaded.audioTracks.first?.captureEras?.first?.echoProtection, .acousticallyClosed)
    }

    func testTwoTrackAudioSessionIsOnlineCall() async throws {
        let store = MeetingSessionStore(rootDirectory: try self.tempDirectory())
        let session = try await MeetAISessionImport.createAudioSession(
            store: store, title: "Call", languageCode: "en", startedAt: Date(),
            tracks: [
                .init(kind: .applicationAudio, samples: self.sine(seconds: 3), echoProtection: .unprotected),
                .init(kind: .microphone, samples: self.sine(seconds: 3, frequency: 330), echoProtection: .legacyUnclassified),
            ]
        )
        XCTAssertEqual(session.mode, .onlineCall)
        XCTAssertEqual(Set(session.audioTracks.map(\.kind)), [.applicationAudio, .microphone])
        XCTAssertNoThrow(try MeetAISyntheticSessionBuilder.configuration(title: "Call", languageCode: "en", hasApplicationAudio: true).validate())
    }

    func testTranscriptOnlySessionRoundTrips() async throws {
        let store = MeetingSessionStore(rootDirectory: try self.tempDirectory())
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MeetAISyntheticSessionBuilder.transcriptOnlySession(
            title: "Legacy",
            startedAt: started,
            endedAt: started.addingTimeInterval(120),
            speakers: [.init(label: "Me", isLocalUser: true), .init(label: "Girish", isLocalUser: false)],
            segments: [
                .init(start: 0, end: 4, speakerLabel: "Girish", text: "Hello"),
                .init(start: 4, end: 9, speakerLabel: "Me", text: "Hi Girish"),
            ],
            audioDeletedAt: started.addingTimeInterval(120)
        )
        try await store.create(session)
        let loaded = try await XCTUnwrapAsync(await store.load(id: session.id))
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded.state, .completed)
        XCTAssertEqual(loaded.mode, .onlineCall)
        XCTAssertFalse(loaded.hasRetryableAudio)
        let trackIDs = Set(loaded.audioTracks.map(\.id))
        XCTAssertTrue(loaded.transcriptSegments.allSatisfy { trackIDs.contains($0.sourceTrackID) })
        XCTAssertEqual(loaded.speakers.first { $0.isLocalUser }?.displayName, "Me")
        XCTAssertEqual(MeetingSummaryInput.transcript(for: loaded).contains("Hi Girish"), true)
    }
}

/// `XCTUnwrap` for an async-produced optional.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
```

- [ ] **Step 2: Register and run to verify they fail**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAISyntheticSessionBuilderTests.swift
```

Run the one-class command for `MeetAISyntheticSessionBuilderTests`. Expected: build FAIL with "cannot find 'MeetAISyntheticSessionBuilder' in scope".

- [ ] **Step 3: Implement the decoder** (`MeetAIAudioDecoder.swift`)

```swift
import AVFoundation
import Foundation

/// Decodes any AVFoundation-readable file into 16 kHz mono Float32 samples.
nonisolated enum MeetAIAudioDecoder {
    static let sampleRate: Double = 16_000

    enum DecodeError: LocalizedError {
        case unreadable(String)
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "Couldn't read audio from \(name)."
            case .conversionFailed: "Couldn't convert the audio to 16 kHz mono."
            }
        }
    }

    /// Off-main wrapper for whole-file decoding.
    @concurrent static func decode(url: URL) async throws -> [Float] {
        try self.load16kMono(url: url)
    }

    /// The whole file, or `[start, end)` seconds of it.
    static func load16kMono(url: URL, start: TimeInterval = 0, end: TimeInterval? = nil) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DecodeError.unreadable(url.lastPathComponent) }
        let inputFormat = file.processingFormat
        let sourceRate = inputFormat.sampleRate
        guard sourceRate > 0 else { throw DecodeError.unreadable(url.lastPathComponent) }
        let startFrame = AVAudioFramePosition(max(0, start) * sourceRate)
        let endFrame = min(file.length, end.map { AVAudioFramePosition(max(0, $0) * sourceRate) } ?? file.length)
        guard endFrame > startFrame else { return [] }
        file.framePosition = startFrame

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw DecodeError.conversionFailed }
        converter.downmix = true

        var remaining = endFrame - startFrame
        var inputDone = false
        var readError: Error?
        let inputCapacity: AVAudioFrameCount = 32_768
        var output: [Float] = []
        output.reserveCapacity(Int(Double(remaining) * self.sampleRate / sourceRate) + 1_024)

        while true {
            let outCapacity = AVAudioFrameCount(Double(inputCapacity) * self.sampleRate / sourceRate) + 1_024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                throw DecodeError.conversionFailed
            }
            let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
                if inputDone || remaining <= 0 {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let count = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: count) else {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: count)
                } catch {
                    readError = error
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                remaining -= AVAudioFramePosition(inBuffer.frameLength)
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw DecodeError.unreadable("\(url.lastPathComponent): \(readError.localizedDescription)") }
            if status == .error { throw DecodeError.conversionFailed }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (inputDone && outBuffer.frameLength == 0) { break }
        }
        return output
    }
}
```

- [ ] **Step 4: Implement the builder** (`MeetAISyntheticSessionBuilder.swift`)

```swift
import AVFoundation
import CryptoKit
import Foundation

/// Builds FluidMeet sessions for audio MeetAI imports instead of captures (an audio file, or a
/// fork recording) and for transcript-only legacy meetings. See spec §6.6, §7 and §12.6.
nonisolated enum MeetAISyntheticSessionBuilder {
    static let chunkSeconds: Double = 60
    static let sampleRate: Double = 16_000
    static let importBundleIdentifier = "com.meetai.import"
    static let importDeviceID = "meetai-import"

    struct LegacySpeaker: Equatable, Sendable {
        let label: String
        let isLocalUser: Bool
    }

    struct LegacySegment: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let speakerLabel: String
        let text: String
    }

    struct TrackAudio: Sendable {
        let kind: MeetingAudioTrackKind
        let samples: [Float]
        /// Only used for microphone tracks.
        let echoProtection: MeetingMicrophoneEchoProtection
    }

    enum BuildError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            switch self { case let .writeFailed(detail): "Couldn't save the imported audio: \(detail)" }
        }
    }

    static let timebase = MeetingTimebaseMetadata(
        startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
    )

    static func configuration(title: String, languageCode: String, hasApplicationAudio: Bool) -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(
            mode: hasApplicationAudio ? .onlineCall : .inRoom,
            title: title,
            languageCode: languageCode,
            application: hasApplicationAudio
                ? MeetingApplicationIdentity(bundleIdentifier: self.importBundleIdentifier, displayName: "Imported recording")
                : nil,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: self.importDeviceID, displayName: "Imported audio")
        )
    }

    static func milliseconds(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1_000).rounded()), timescale: 1_000)
    }

    static func emptyTrack(kind: MeetingAudioTrackKind) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: kind == .microphone ? self.importDeviceID : self.importBundleIdentifier,
            sourceDisplayName: kind == .microphone ? "Imported audio" : "Imported recording",
            format: MeetingAudioFormat(codec: "lpcm-s16", sampleRate: self.sampleRate, channelCount: 1, bitRate: nil),
            timebase: self.timebase,
            health: MeetingTrackHealth(status: .stopped, lastPresentationTime: nil, lastSampleAt: nil, level: 0, droppedSampleCount: 0, detail: nil),
            chunks: [],
            captureMethod: kind == .microphone ? .avCaptureSession : .screenCaptureKit
        )
    }

    /// A session whose tracks have no chunks yet. State `.interrupted` means "audio captured, not
    /// processed", so upstream's recovery UI can retry it if MeetAI's own processing call fails.
    static func audioSessionShell(
        id: MeetingSessionID = UUID(),
        title: String,
        languageCode: String,
        startedAt: Date,
        duration: TimeInterval,
        trackKinds: [MeetingAudioTrackKind]
    ) -> MeetingSession {
        var session = MeetingSession(
            id: id,
            configuration: self.configuration(title: title, languageCode: languageCode, hasApplicationAudio: trackKinds.contains(.applicationAudio)),
            startedAt: startedAt,
            timebase: self.timebase
        )
        session.audioTracks = trackKinds.map { self.emptyTrack(kind: $0) }
        session.endedAt = startedAt.addingTimeInterval(duration)
        session.state = .interrupted
        session.updatedAt = Date()
        return session
    }

    /// Writes 16 kHz mono 16-bit WAV chunks of `chunkSeconds` at `tracks/<kind>/NNNNNN.wav`.
    static func writeChunks(samples: [Float], kind: MeetingAudioTrackKind, sessionDirectory: URL) throws -> [MeetingAudioChunk] {
        let chunkLength = Int(self.chunkSeconds * self.sampleRate)
        let folder = sessionDirectory.appendingPathComponent("tracks/\(kind.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false) else {
            throw BuildError.writeFailed("unsupported format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var chunks: [MeetingAudioChunk] = []
        var offset = 0
        var sequence = 0
        while offset < samples.count {
            let end = min(samples.count, offset + chunkLength)
            let relativePath = "tracks/\(kind.rawValue)/\(String(format: "%06d", sequence)).wav"
            let url = sessionDirectory.appendingPathComponent(relativePath)
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let frames = AVAudioFrameCount(end - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    throw BuildError.writeFailed("buffer allocation")
                }
                buffer.frameLength = frames
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: Int(frames))
                }
                try file.write(from: buffer)
                file.close()
            } catch let error as BuildError {
                throw error
            } catch {
                throw BuildError.writeFailed(error.localizedDescription)
            }
            let data = try Data(contentsOf: url)
            chunks.append(MeetingAudioChunk(
                id: UUID(),
                sequence: sequence,
                relativeFilePath: relativePath,
                presentationStart: self.milliseconds(Double(offset) / self.sampleRate),
                presentationEnd: self.milliseconds(Double(end) / self.sampleRate),
                discontinuities: [],
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                byteCount: Int64(data.count),
                finalizationState: .finalized
            ))
            offset = end
            sequence += 1
        }
        return chunks
    }

    static func attach(
        _ chunks: [MeetingAudioChunk],
        kind: MeetingAudioTrackKind,
        echoProtection: MeetingMicrophoneEchoProtection,
        to session: inout MeetingSession
    ) {
        guard let index = session.audioTracks.firstIndex(where: { $0.kind == kind }) else { return }
        session.audioTracks[index].chunks = chunks
        session.audioTracks[index].health.lastPresentationTime = chunks.last?.presentationEnd
        if kind == .microphone {
            session.audioTracks[index].captureEras = [MeetingCaptureEra(
                method: .avCaptureSession,
                deviceUID: self.importDeviceID,
                deviceName: "Imported audio",
                roleAtElection: .unknown,
                echoProtection: echoProtection,
                startSeconds: 0
            )]
        }
    }

    /// A completed session with a transcript and no audio (audio "deleted" at `audioDeletedAt`).
    static func transcriptOnlySession(
        id: MeetingSessionID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        speakers: [LegacySpeaker],
        segments: [LegacySegment],
        audioDeletedAt: Date
    ) -> MeetingSession {
        let hasRemote = speakers.contains { !$0.isLocalUser }
        var session = MeetingSession(
            id: id,
            configuration: self.configuration(title: title, languageCode: "en", hasApplicationAudio: hasRemote),
            startedAt: startedAt,
            timebase: self.timebase
        )
        let microphone = self.emptyTrack(kind: .microphone)
        let application = hasRemote ? self.emptyTrack(kind: .applicationAudio) : nil
        session.audioTracks = [microphone] + (application.map { [$0] } ?? [])
        var speakerIDs: [String: (id: SessionSpeakerID, isLocal: Bool)] = [:]
        session.speakers = speakers.map { speaker in
            let id = UUID()
            speakerIDs[speaker.label] = (id, speaker.isLocalUser)
            return MeetingSessionSpeaker(
                id: id,
                displayName: speaker.label,
                diarizationClusterID: nil,
                trackKind: speaker.isLocalUser ? .microphone : .applicationAudio,
                isLocalUser: speaker.isLocalUser,
                identityCandidates: []
            )
        }
        session.transcriptSegments = segments.compactMap { segment in
            guard let speaker = speakerIDs[segment.speakerLabel] else { return nil }
            return MeetingTranscriptSegment(
                id: UUID(),
                start: self.milliseconds(segment.start),
                end: self.milliseconds(segment.end),
                sourceTrackID: speaker.isLocal ? microphone.id : (application?.id ?? microphone.id),
                speakerID: speaker.id,
                text: segment.text,
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete,
                attributionState: .assigned
            )
        }
        session.state = .completed
        session.endedAt = endedAt
        session.transcriptIsComplete = true
        session.retention.audioDeletedAt = audioDeletedAt
        session.updatedAt = Date()
        return session
    }
}
```

- [ ] **Step 5: Implement the persistence helper** (`MeetAISessionImport.swift`)

```swift
import Foundation

@MainActor
enum MeetAISessionImport {
    /// Creates the session in `store`, writes each track's chunks into its directory and saves it.
    /// On any failure the half-written session is deleted.
    static func createAudioSession(
        store: any MeetingSessionStoring,
        id: MeetingSessionID = UUID(),
        title: String,
        languageCode: String,
        startedAt: Date,
        tracks: [MeetAISyntheticSessionBuilder.TrackAudio]
    ) async throws -> MeetingSession {
        let duration = (tracks.map { Double($0.samples.count) }.max() ?? 0) / MeetAISyntheticSessionBuilder.sampleRate
        var session = MeetAISyntheticSessionBuilder.audioSessionShell(
            id: id, title: title, languageCode: languageCode, startedAt: startedAt,
            duration: duration, trackKinds: tracks.map(\.kind)
        )
        try await store.create(session)
        do {
            let directory = try await store.sessionDirectory(for: session.id)
            for track in tracks {
                let chunks = try MeetAISyntheticSessionBuilder.writeChunks(samples: track.samples, kind: track.kind, sessionDirectory: directory)
                MeetAISyntheticSessionBuilder.attach(chunks, kind: track.kind, echoProtection: track.echoProtection, to: &session)
            }
            try await store.save(session)
            return session
        } catch {
            try? await store.delete(id: session.id)
            throw error
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the one-class command for `MeetAISyntheticSessionBuilderTests`. Expected: 6 PASS. If `store.create` rejects the shell, read `MeetingSessionStore.create` (`Sources/Fluid/Services/Meeting/MeetingSessionStore.swift:69`) for its validation and adjust the shell, not the store.

- [ ] **Step 7: Add the opt-in spike test** (append to the same file)

```swift
@MainActor
final class MeetAISpikeTests: XCTestCase {
    /// Opt-in: TEST_RUNNER_MEETAI_SPIKE_AUDIO=/path/to/multi-speaker.wav
    /// Builds an in-room session from real audio and runs upstream's full pipeline on it.
    func testSpikeRetryProcessingCompletesWithSpeakers() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEETAI_SPIKE_AUDIO"] else {
            throw XCTSkip("Set TEST_RUNNER_MEETAI_SPIKE_AUDIO to run the spike")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetai-spike-\(UUID().uuidString)", isDirectory: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let samples = try await MeetAIAudioDecoder.decode(url: URL(fileURLWithPath: path))
        let session = try await MeetAISessionImport.createAudioSession(
            store: store, title: "Spike", languageCode: "en", startedAt: Date(),
            tracks: [.init(kind: .microphone, samples: samples, echoProtection: .acousticallyClosed)]
        )
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: MeetingCaptureEngine(),
            processing: MeetingProcessingPipeline(
                asrServiceProvider: { AppServices.shared.asr },
                prepareDiarizationModel: { try await MeetingDiarizationModelStore.shared.ensureInstalled() }
            ),
            audioArbiter: AppServices.shared.meetingAudioActivityArbiter,
            preferredMicrophoneUID: { nil },
            validateRecordingModels: {}
        )
        let processed = try await coordinator.retryProcessing(sessionID: session.id)
        XCTAssertEqual(processed.state, .completed)
        XCTAssertFalse(processed.transcriptSegments.isEmpty)
        print("MEETAI-SPIKE speakers=\(processed.activeSpeakers.map(\.displayName)) segments=\(processed.transcriptSegments.count)")
        XCTAssertGreaterThanOrEqual(processed.activeSpeakers.count, 2, "expected the multi-speaker recording to diarize into ≥2 speakers")
    }
}
```

- [ ] **Step 8: Run the spike against a real fork recording** (local data, never committed)

```bash
TEST_RUNNER_MEETAI_SPIKE_AUDIO="$HOME/Library/Application Support/FluidVoice/MeetingRecordings/2026-10-15T06:00:44/system.wav" \
  xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -only-testing:FluidDictationIntegrationTests/MeetAISpikeTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "MEETAI-SPIKE|Test Case|error:" | tail -20
```

Expected: PASS and a `MEETAI-SPIKE speakers=[…]` line with ≥ 2 speakers. Diarization model downloads may happen on first run. If it fails with an admission/era error, try `echoProtection: .legacyUnclassified` and re-run once. If it still fails: STOP — record the error in spec §11 and ask the user (spec §6.6 / §7.4 fallbacks).

- [ ] **Step 9: Spike item 2 — check a transcript-only session renders in the app**

Build the dev app (`./build.sh`). Then write one transcript-only session into the shared meetings store (`~/Library/Application Support/FluidVoice/Meetings`, the same path the debug build reads) with this throwaway test method in `MeetAISpikeTests` — add it, run it once, then delete it:

```swift
    func testSpikeWriteTranscriptOnlySessionForManualCheck() async throws {
        guard ProcessInfo.processInfo.environment["MEETAI_SPIKE_WRITE_LEGACY"] == "1" else { throw XCTSkip("manual spike") }
        let started = Date()
        let session = MeetAISyntheticSessionBuilder.transcriptOnlySession(
            title: "MeetAI spike — delete me", startedAt: started, endedAt: started.addingTimeInterval(60),
            speakers: [.init(label: "Me", isLocalUser: true), .init(label: "Them 1", isLocalUser: false)],
            segments: [.init(start: 0, end: 5, speakerLabel: "Them 1", text: "Spike line one."), .init(start: 5, end: 9, speakerLabel: "Me", text: "Spike line two.")],
            audioDeletedAt: started.addingTimeInterval(60)
        )
        try await MeetingSessionStore.shared.create(session)
        print("MEETAI-SPIKE wrote \(session.id)")
    }
```

Run it with `TEST_RUNNER_MEETAI_SPIKE_WRITE_LEGACY=1`, launch `DerivedData/Build/Products/Debug/FluidVoice Debug.app`, open the meetings list, open "MeetAI spike — delete me", take a screenshot, confirm both lines show with speaker labels and no audio controls error, then delete the meeting in the app. Remove the throwaway method. If the session does not appear or errors: STOP and ask the user (Archive fallback, spec §7.4).

- [ ] **Step 10: Full suite, then commit**

```bash
git add Sources/Fluid/MeetAI/Import Tests/FluidDictationIntegrationTests/MeetAISyntheticSessionBuilderTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add the synthetic session builder for imports and migration

Writes FluidMeet sessions from decoded audio (16 kHz WAV chunks, ready
for retryProcessing) or from legacy transcripts. Spike: a real fork
recording processed end to end with upstream's pipeline.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: MeetAI foundation — paths, settings, sidecars, transcript helpers, hooks

**Files:**
- Create: `Sources/Fluid/MeetAI/MeetAIPaths.swift`, `MeetAISettings.swift`, `MeetAISidecarStore.swift`, `MeetAITranscript.swift`, `MeetAIHooks.swift`, `MeetAIBootstrap.swift`
- Modify: `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift` (H1 ~L1693, H6 in `performCorrection` ~L865)
- Modify: `Sources/Fluid/AppDelegate.swift` (H4, after `LocalAPIServer.shared.start()` ~L109)
- Test: `Tests/FluidDictationIntegrationTests/MeetAITestSupport.swift`, `Tests/FluidDictationIntegrationTests/MeetAIFoundationTests.swift`

**Interfaces:**
- Produces:
  - `MeetAIPaths(supportRoot: URL)`, `.standard()`, `.root`, `.profilesFile`, `.sessionsDirectory`, `.sessionDirectory(for:)`, `.migrationFile`, `.legacyMeetingsDirectory`, `.legacyProfilesFile`
  - `MeetAISettings(defaults:)`, `.shared`, `var autoSummarize/autoName/speakerMatching: Bool`, `let defaults: UserDefaults`
  - Records: `MeetAISummaryRecord`, `MeetAIQARecord`, `MeetAINameSource`, `MeetAISpeakerRecord { embedding: [Float]?; matchedProfileID: String?; nameSource: MeetAINameSource?; lastAppliedName: String? }`, `MeetAITitleSource`, `MeetAIMetaRecord { titleSource; lastLLMTitle }`
  - `actor MeetAISidecarStore(paths:)`: `summary(for:)`, `saveSummary(_:for:)`, `qa(for:)`, `saveQA(_:for:)`, `speakers(for:)`, `saveSpeakers(_:for:)`, `meta(for:)`, `saveMeta(_:for:)`, `removeAll(for:)`, `sweepOrphans(keeping:) -> [MeetingSessionID]`
  - `MeetAITranscript.text(for:)`, `.turns(for:)`, `.hash(for:)`, `.localUserLabel(in:)`, `.isDefaultSpeakerName(_:)`
  - `MeetAIHooks.sessionDidComplete`, `.sessionCorrected`, `.runSessionDidComplete(_:timeout:)`, `.notifySessionCorrected(_:)`
  - `MeetAIBootstrap.start()`
  - Test support: `MeetAIFixtures.tempDirectory(_:)`, `MeetAIFixtures.session(speakers:lines:title:)`

- [ ] **Step 1: Write test support** (`MeetAITestSupport.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

enum MeetAIFixtures {
    static func tempDirectory(_ test: XCTestCase, _ prefix: String = "meetai") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    struct Line {
        let speaker: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// A completed session. `speakers[i]` is (displayName, isLocalUser); lines reference speakers by index.
    static func session(
        speakers: [(String, Bool)],
        lines: [Line],
        title: String = "Fixture meeting",
        defaultTitle: Bool = true
    ) -> MeetingSession {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom, title: title,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic"),
                timestampDefaultTitle: defaultTitle
            ),
            startedAt: started,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic", format: nil,
            timebase: session.timebase, health: .waiting, chunks: []
        )
        session.audioTracks = [track]
        session.speakers = speakers.map { name, isLocal in
            MeetingSessionSpeaker(id: UUID(), displayName: name, diarizationClusterID: nil, trackKind: .microphone, isLocalUser: isLocal, identityCandidates: [])
        }
        session.transcriptSegments = lines.map { line in
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: Int64(line.start * 1_000), timescale: 1_000),
                end: MeetingMediaTime(value: Int64(line.end * 1_000), timescale: 1_000),
                sourceTrackID: track.id,
                speakerID: session.speakers[line.speaker].id,
                text: line.text,
                revision: 1,
                status: .final,
                overlap: .none,
                completeness: .complete,
                attributionState: .assigned
            )
        }
        session.state = .completed
        session.endedAt = started.addingTimeInterval((lines.map(\.end).max() ?? 0) + 1)
        session.transcriptIsComplete = true
        return session
    }
}
```

- [ ] **Step 2: Write the failing foundation tests** (`MeetAIFoundationTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIFoundationTests: XCTestCase {
    // MARK: Sidecar store

    func testSidecarRoundTripsEveryRecord() async throws {
        let paths = MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self))
        let store = MeetAISidecarStore(paths: paths)
        let id = UUID()
        let speakerID = UUID()
        let summary = MeetAISummaryRecord(style: "standard", transcriptHash: "abc", markdown: "## Overview", providerID: "openai", modelID: "gpt-6.1", createdAt: Date(timeIntervalSince1970: 1))
        try await store.saveSummary(summary, for: id)
        try await store.saveQA([MeetAIQARecord(id: UUID(), question: "Q", answer: "A", askedAt: Date(timeIntervalSince1970: 2))], for: id)
        try await store.saveSpeakers([speakerID: MeetAISpeakerRecord(embedding: [0.6, 0.8], matchedProfileID: "p1", nameSource: .profile, lastAppliedName: "Sam")], for: id)
        try await store.saveMeta(MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "Roadmap sync"), for: id)

        let reopened = MeetAISidecarStore(paths: paths)
        let loadedSummary = try await reopened.summary(for: id)
        let loadedQA = try await reopened.qa(for: id)
        let loadedSpeakers = try await reopened.speakers(for: id)
        let loadedMeta = try await reopened.meta(for: id)
        XCTAssertEqual(loadedSummary, summary)
        XCTAssertEqual(loadedQA.map(\.answer), ["A"])
        XCTAssertEqual(loadedSpeakers[speakerID]?.lastAppliedName, "Sam")
        XCTAssertEqual(loadedMeta.lastLLMTitle, "Roadmap sync")
    }

    func testSidecarDefaultsWhenMissing() async throws {
        let store = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let id = UUID()
        let summary = try await store.summary(for: id)
        let qa = try await store.qa(for: id)
        let speakers = try await store.speakers(for: id)
        let meta = try await store.meta(for: id)
        XCTAssertNil(summary)
        XCTAssertTrue(qa.isEmpty)
        XCTAssertTrue(speakers.isEmpty)
        XCTAssertEqual(meta, MeetAIMetaRecord())
    }

    func testSweepOrphansRemovesOnlyUnknownSessions() async throws {
        let paths = MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self))
        let store = MeetAISidecarStore(paths: paths)
        let kept = UUID(), orphan = UUID()
        try await store.saveMeta(MeetAIMetaRecord(), for: kept)
        try await store.saveMeta(MeetAIMetaRecord(), for: orphan)
        let removed = try await store.sweepOrphans(keeping: [kept])
        XCTAssertEqual(removed, [orphan])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: orphan).path))
    }

    // MARK: Transcript helpers

    func testDefaultSpeakerNames() {
        for name in ["Speaker 1", "Speaker 12", "Microphone Speaker 2", "Room Speaker", "Meeting audio", "Meeting Audio", "Microphone / Unknown", "Them", "Them 3"] {
            XCTAssertTrue(MeetAITranscript.isDefaultSpeakerName(name), name)
        }
        for name in ["Sam", "Speaker", "Speaker One", "Themis", "Me"] {
            XCTAssertFalse(MeetAITranscript.isDefaultSpeakerName(name), name)
        }
    }

    func testHashIgnoresTitleButTracksTextAndNames() throws {
        var session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [.init(speaker: 1, start: 0, end: 3, text: "Hello there"), .init(speaker: 0, start: 3, end: 5, text: "Hi")]
        )
        let original = MeetAITranscript.hash(for: session)
        session.title = "Renamed meeting"
        XCTAssertEqual(MeetAITranscript.hash(for: session), original)
        session.transcriptSegments[0].text = "Hello there!"
        let edited = MeetAITranscript.hash(for: session)
        XCTAssertNotEqual(edited, original)
        try session.renameSpeaker(id: session.speakers[1].id, to: "Sam")
        XCTAssertNotEqual(MeetAITranscript.hash(for: session), edited)
        XCTAssertEqual(MeetAITranscript.localUserLabel(in: session), "You")
    }

    // MARK: Hooks

    func testCompletionHookReturnsAfterTimeoutWhenHandlerHangs() async {
        let saved = MeetAIHooks.sessionDidComplete
        defer { MeetAIHooks.sessionDidComplete = saved }
        MeetAIHooks.sessionDidComplete = { _ in try? await Task.sleep(for: .seconds(5)) }
        let start = ContinuousClock.now
        await MeetAIHooks.runSessionDidComplete(MeetAIFixtures.session(speakers: [], lines: []), timeout: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testHooksAreNoOpsWhenUnset() async {
        let savedComplete = MeetAIHooks.sessionDidComplete, savedCorrected = MeetAIHooks.sessionCorrected
        defer { MeetAIHooks.sessionDidComplete = savedComplete; MeetAIHooks.sessionCorrected = savedCorrected }
        MeetAIHooks.sessionDidComplete = nil
        MeetAIHooks.sessionCorrected = nil
        await MeetAIHooks.runSessionDidComplete(MeetAIFixtures.session(speakers: [], lines: []))
        MeetAIHooks.notifySessionCorrected(MeetAIFixtures.session(speakers: [], lines: []))
    }
}
```

- [ ] **Step 3: Register both files and verify the tests fail**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAITestSupport.swift
python3 scripts/add_test_file_to_xcodeproj.py MeetAIFoundationTests.swift
```

Run `MeetAIFoundationTests`. Expected: build FAIL ("cannot find 'MeetAIPaths'").

- [ ] **Step 4: Implement `MeetAIPaths.swift`**

```swift
import Foundation

nonisolated struct MeetAIPaths: Equatable, Sendable {
    /// `~/Library/Application Support/FluidVoice` (shared with upstream and the fork's legacy data).
    let supportRoot: URL

    static func standard(fileManager: FileManager = .default) -> MeetAIPaths {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return MeetAIPaths(supportRoot: applicationSupport.appendingPathComponent("FluidVoice", isDirectory: true))
    }

    var root: URL { self.supportRoot.appendingPathComponent("MeetAI", isDirectory: true) }
    var profilesFile: URL { self.root.appendingPathComponent("SpeakerProfiles/profiles.json") }
    var sessionsDirectory: URL { self.root.appendingPathComponent("Sessions", isDirectory: true) }
    var migrationFile: URL { self.root.appendingPathComponent("migration.json") }
    var legacyMeetingsDirectory: URL { self.supportRoot.appendingPathComponent("MeetingRecordings", isDirectory: true) }
    var legacyProfilesFile: URL { self.supportRoot.appendingPathComponent("SpeakerProfiles/profiles.json") }

    func sessionDirectory(for id: MeetingSessionID) -> URL {
        self.sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
```

- [ ] **Step 5: Implement `MeetAISettings.swift`**

```swift
import Combine
import Foundation

@MainActor
final class MeetAISettings: ObservableObject {
    static let shared = MeetAISettings(defaults: .standard)

    enum Key {
        static let autoSummarize = "MeetAIAutoSummarize"
        static let summaryStyle = "MeetAISummaryStyle"
        static let autoName = "MeetAIAutoName"
        static let speakerMatching = "MeetAISpeakerMatching"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var autoSummarize: Bool {
        get { self.bool(Key.autoSummarize) }
        set { self.set(newValue, Key.autoSummarize) }
    }

    var autoName: Bool {
        get { self.bool(Key.autoName) }
        set { self.set(newValue, Key.autoName) }
    }

    var speakerMatching: Bool {
        get { self.bool(Key.speakerMatching) }
        set { self.set(newValue, Key.speakerMatching) }
    }

    private func bool(_ key: String) -> Bool {
        (self.defaults.object(forKey: key) as? Bool) ?? true
    }

    private func set(_ value: Bool, _ key: String) {
        self.objectWillChange.send()
        self.defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 6: Implement `MeetAISidecarStore.swift`**

```swift
import Foundation

nonisolated struct MeetAISummaryRecord: Codable, Equatable, Sendable {
    var style: String
    var transcriptHash: String
    var markdown: String
    var providerID: String
    var modelID: String
    var createdAt: Date
}

nonisolated struct MeetAIQARecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var question: String
    var answer: String
    var askedAt: Date
}

nonisolated enum MeetAINameSource: String, Codable, Sendable {
    case profile, llm, user
}

nonisolated struct MeetAISpeakerRecord: Codable, Equatable, Sendable {
    var embedding: [Float]?
    var matchedProfileID: String?
    var nameSource: MeetAINameSource?
    /// The display name MeetAI last applied or accepted. A different, non-default name means the user renamed.
    var lastAppliedName: String?

    init(embedding: [Float]? = nil, matchedProfileID: String? = nil, nameSource: MeetAINameSource? = nil, lastAppliedName: String? = nil) {
        self.embedding = embedding
        self.matchedProfileID = matchedProfileID
        self.nameSource = nameSource
        self.lastAppliedName = lastAppliedName
    }
}

nonisolated enum MeetAITitleSource: String, Codable, Sendable {
    case `default`, llm, user
}

nonisolated struct MeetAIMetaRecord: Codable, Equatable, Sendable {
    var titleSource: MeetAITitleSource = .default
    var lastLLMTitle: String?
}

/// Per-session MeetAI data, keyed by upstream `MeetingSessionID`.
actor MeetAISidecarStore {
    static let shared = MeetAISidecarStore(paths: .standard())

    private let paths: MeetAIPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: MeetAIPaths) {
        self.paths = paths
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func summary(for id: MeetingSessionID) throws -> MeetAISummaryRecord? {
        try self.read(MeetAISummaryRecord.self, id, "summary.json")
    }

    func saveSummary(_ record: MeetAISummaryRecord?, for id: MeetingSessionID) throws {
        try self.write(record, id, "summary.json")
    }

    func qa(for id: MeetingSessionID) throws -> [MeetAIQARecord] {
        try self.read([MeetAIQARecord].self, id, "qa.json") ?? []
    }

    func saveQA(_ records: [MeetAIQARecord], for id: MeetingSessionID) throws {
        try self.write(records.isEmpty ? nil : records, id, "qa.json")
    }

    func speakers(for id: MeetingSessionID) throws -> [SessionSpeakerID: MeetAISpeakerRecord] {
        let raw = try self.read([String: MeetAISpeakerRecord].self, id, "speakers.json") ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func saveSpeakers(_ records: [SessionSpeakerID: MeetAISpeakerRecord], for id: MeetingSessionID) throws {
        let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        try self.write(raw.isEmpty ? nil : raw, id, "speakers.json")
    }

    func meta(for id: MeetingSessionID) throws -> MeetAIMetaRecord {
        try self.read(MeetAIMetaRecord.self, id, "meta.json") ?? MeetAIMetaRecord()
    }

    func saveMeta(_ record: MeetAIMetaRecord, for id: MeetingSessionID) throws {
        try self.write(record, id, "meta.json")
    }

    func removeAll(for id: MeetingSessionID) throws {
        let directory = self.paths.sessionDirectory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes sidecar folders whose session is not in `keeping`. Returns the removed IDs.
    func sweepOrphans(keeping ids: Set<MeetingSessionID>) throws -> [MeetingSessionID] {
        let directory = self.paths.sessionsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var removed: [MeetingSessionID] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent), !ids.contains(id) else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(id)
        }
        return removed
    }

    private func url(_ id: MeetingSessionID, _ name: String) -> URL {
        self.paths.sessionDirectory(for: id).appendingPathComponent(name)
    }

    private func read<T: Decodable>(_ type: T.Type, _ id: MeetingSessionID, _ name: String) throws -> T? {
        let url = self.url(id, name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try self.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T?, _ id: MeetingSessionID, _ name: String) throws {
        let url = self.url(id, name)
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.encoder.encode(value).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 7: Implement `MeetAITranscript.swift`**

```swift
import Foundation

nonisolated enum MeetAITranscript {
    /// Prompt text: upstream's own rendering, so names and echo filtering match the UI.
    static func text(for session: MeetingSession) -> String {
        MeetingSummaryInput.transcript(for: session)
    }

    /// `Label: text` per non-echo turn, in time order. Excludes the title, so retitling does not
    /// make a summary stale.
    static func turns(for session: MeetingSession) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        return session.transcriptSegments
            .filter { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start.seconds < $1.start.seconds }
            .map { "\(MeetingTranscriptExporter.speakerLabel(for: $0, in: session, speakerNames: names)): \($0.text)" }
    }

    static func hash(for session: MeetingSession) -> String {
        MeetingSummaryInput.fingerprint(self.turns(for: session).joined(separator: "\n"))
    }

    static func localUserLabel(in session: MeetingSession) -> String {
        session.activeSpeakers.first(where: \.isLocalUser)?.displayName ?? "You"
    }

    /// Upstream's generated labels plus the fork's legacy "Them"/"Them N" (spec §12.4).
    private static let defaultNamePattern =
        #"^(Speaker \d+|Microphone Speaker \d+|Room Speaker( \d+)?|Meeting [Aa]udio|Microphone / Unknown|Them( \d+)?)$"#

    static func isDefaultSpeakerName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).range(of: self.defaultNamePattern, options: .regularExpression) != nil
    }
}
```

- [ ] **Step 8: Implement `MeetAIHooks.swift`**

```swift
import Foundation

/// The only entry points upstream code calls (H1, H6). Unset handlers are no-ops, so upstream
/// tests and builds without MeetAI wiring behave exactly as before.
@MainActor
enum MeetAIHooks {
    static var sessionDidComplete: (@MainActor (MeetingSession) async -> Void)?
    static var sessionCorrected: (@MainActor (MeetingSession) -> Void)?
    static let completionTimeout: Duration = .seconds(30)

    /// H1: awaited by the coordinator before its audio-retention sweep. Returns when the handler
    /// finishes or `timeout` elapses, whichever is first. Never throws.
    static func runSessionDidComplete(_ session: MeetingSession, timeout: Duration = completionTimeout) async {
        guard let handler = self.sessionDidComplete else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = OnceGate(continuation)
            Task { @MainActor in
                await handler(session)
                gate.fire()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !gate.fired { DebugLogger.shared.warning("MeetAI completion hook timed out", source: "MeetAI") }
                gate.fire()
            }
        }
    }

    /// H6: called after any transcript correction is saved. Must not mutate the session synchronously.
    static func notifySessionCorrected(_ session: MeetingSession) {
        self.sessionCorrected?(session)
    }

    @MainActor
    private final class OnceGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var fired = false

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func fire() {
            guard !self.fired else { return }
            self.fired = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}
```

- [ ] **Step 9: Implement `MeetAIBootstrap.swift`**

```swift
import Foundation

/// H4: launch wiring for the MeetAI layer.
@MainActor
enum MeetAIBootstrap {
    private static var started = false

    /// Tests run hosted in the debug app, which shares Application Support with the real app.
    /// Never touch real meeting data from a test process.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func start() {
        guard !self.started, !self.isTestHost else { return }
        self.started = true
        Task { await self.sweepOrphanedSidecars() }
    }

    static func sweepOrphanedSidecars() async {
        do {
            let ids = Set(try await MeetingSessionStore.shared.loadAll().map(\.id))
            let removed = try await MeetAISidecarStore.shared.sweepOrphans(keeping: ids)
            if !removed.isEmpty {
                DebugLogger.shared.info("Removed \(removed.count) orphaned MeetAI sidecars", source: "MeetAI")
            }
        } catch {
            DebugLogger.shared.warning("MeetAI sidecar sweep failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
}
```

- [ ] **Step 10: Add hook calls to upstream (H1, H6, H4)**

H1 — in `MeetingSessionCoordinator.swift`, in the completion path, immediately before the line `// afterTranscription policy deletes here; sweep failures are logged, never affect this result.` (~L1693) insert:

```swift
            // MeetAI H1: speaker embeddings need the audio before the retention sweep below.
            await MeetAIHooks.runSessionDidComplete(session)
```

H6 — in `private func performCorrection(...)`, after `self.refreshSlots(with: target)` and before `return target` insert:

```swift
        // MeetAI H6: diff-based; the handler only schedules work and never mutates synchronously.
        MeetAIHooks.notifySessionCorrected(target)
```

H4 — in `AppDelegate.swift`, after `LocalAPIServer.shared.start()` insert:

```swift
        MeetAIBootstrap.start()
```

- [ ] **Step 11: Run the tests to verify they pass**

Run `MeetAIFoundationTests`. Expected: 7 PASS.

- [ ] **Step 12: Full suite, then commit**

```bash
git add Sources/Fluid/MeetAI Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift Sources/Fluid/AppDelegate.swift Tests/FluidDictationIntegrationTests/MeetAITestSupport.swift Tests/FluidDictationIntegrationTests/MeetAIFoundationTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add the MeetAI foundation: sidecars, transcript helpers, hooks H1/H4/H6

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: MeetAILLM

**Files:**
- Create: `Sources/Fluid/MeetAI/LLM/EndpointClassifier.swift` (from `meetai-v2:Sources/Fluid/Networking/EndpointClassifier.swift`, unchanged)
- Create: `Sources/Fluid/MeetAI/LLM/MeetAILLM.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAILLMTests.swift`

**Interfaces:**
- Produces:
  - `EndpointClassifier.isLocal(_ urlString: String) -> Bool`
  - `MeetAILLMTurn(role: String, content: String)`, `MeetAIProviderDescriptor(providerID:modelID:)`, `MeetAILLMError(_ message: String)`
  - `@MainActor protocol MeetAILLMCompleting { complete(systemPrompt:turns:); completeAboutTranscript(transcript:turns:systemPrompt:); descriptor() }`
  - `@MainActor struct MeetAILLM: MeetAILLMCompleting` with `static resolveProvider(settings:) throws -> MeetAIResolvedProvider`, `static completeFittingContext(transcript:turns:systemPrompt:startingBudgetTokens:maxAttempts:complete:)`, `static trimmedTranscript(_:maxTokens:)`, `static approxTokens(_:)`, `static isContextOverflow(_:)`

- [ ] **Step 1: Copy the classifier**

```bash
mkdir -p Sources/Fluid/MeetAI/LLM
git show meetai-v2:Sources/Fluid/Networking/EndpointClassifier.swift > Sources/Fluid/MeetAI/LLM/EndpointClassifier.swift
```

- [ ] **Step 2: Write the failing tests** (`MeetAILLMTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAILLMTests: XCTestCase {
    func testIsLocal() {
        let local = ["http://localhost:11434/v1", "http://127.0.0.1:8080", "http://[::1]:1234/v1", "http://10.0.0.5:8000", "http://192.168.1.20:1234/v1", "http://172.16.0.1", "http://172.31.255.255:9000"]
        let remote = ["https://api.openai.com/v1", "https://api.anthropic.com/v1", "http://172.15.0.1", "http://172.32.0.1", "http://11.0.0.1", "not a url", ""]
        for url in local { XCTAssertTrue(EndpointClassifier.isLocal(url), url) }
        for url in remote { XCTAssertFalse(EndpointClassifier.isLocal(url), url) }
    }

    private struct FakeOverflow: LocalizedError {
        var errorDescription: String? { "This model's maximum context length is 4096 tokens" }
    }

    private func transcript(lines: Int) -> String {
        (0..<lines).map { "Speaker 1: line number \($0) of the meeting transcript" }.joined(separator: "\n")
    }

    func testFittingContextConvergesUnderSmallLocalWindow() async throws {
        let window = 4_096
        var attempts = 0
        let reply = try await MeetAILLM.completeFittingContext(
            transcript: self.transcript(lines: 5_000),
            turns: [MeetAILLMTurn(role: "user", content: "Summarise this meeting.")],
            systemPrompt: { "You summarise meetings.\n\($0)" },
            startingBudgetTokens: 1_000_000,
            maxAttempts: 20,
            complete: { prompt, _ in
                attempts += 1
                guard MeetAILLM.approxTokens(prompt) <= window - 1_024 else { throw FakeOverflow() }
                return "ok"
            }
        )
        XCTAssertEqual(reply, "ok")
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThanOrEqual(attempts, 20)
    }

    func testFittingContextRemoteAttemptCap() async {
        var attempts = 0
        do {
            _ = try await MeetAILLM.completeFittingContext(
                transcript: self.transcript(lines: 5_000), turns: [], systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000, maxAttempts: 4,
                complete: { _, _ in attempts += 1; throw FakeOverflow() }
            )
            XCTFail("expected the overflow to surface")
        } catch {
            XCTAssertTrue(MeetAILLM.isContextOverflow(error))
        }
        XCTAssertEqual(attempts, 4)
    }

    func testFittingContextDoesNotRetryOtherErrors() async {
        var attempts = 0
        do {
            _ = try await MeetAILLM.completeFittingContext(
                transcript: "You: hi", turns: [], systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000, maxAttempts: 20,
                complete: { _, _ in attempts += 1; throw URLError(.cannotConnectToHost) }
            )
            XCTFail("expected the connection error to surface")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    func testTrimmedTranscriptKeepsMostRecentLinesWithMarker() {
        let trimmed = MeetAILLM.trimmedTranscript(self.transcript(lines: 100), maxTokens: 50)
        XCTAssertTrue(trimmed.hasPrefix("[Earlier part of the meeting ("))
        XCTAssertTrue(trimmed.hasSuffix("line number 99 of the meeting transcript"))
    }
}
```

- [ ] **Step 3: Register and verify the tests fail**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAILLMTests.swift
```

Run `MeetAILLMTests`. Expected: build FAIL ("cannot find 'MeetAILLM'").

- [ ] **Step 4: Implement `MeetAILLM.swift`**

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `MeetAILLMTests`. Expected: 5 PASS.

- [ ] **Step 6: Full suite, then commit**

```bash
git add Sources/Fluid/MeetAI/LLM Tests/FluidDictationIntegrationTests/MeetAILLMTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add MeetAILLM: provider resolution and context-fit retry for meeting AI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Speaker profiles, clean turns and matching (pure)

**Files:**
- Create: `Sources/Fluid/MeetAI/Speakers/MeetAISpeakerMath.swift`, `MeetAISpeakerProfileStore.swift`, `MeetAICleanTurns.swift`, `MeetAIProfileMatching.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAISpeakerTests.swift`

**Interfaces:**
- Consumes: `MeetAIPaths`, `MeetAISpeakerRecord`, `MeetAITranscript.isDefaultSpeakerName`
- Produces:
  - `MeetAISpeakerMath.normalize(_:)`, `.dot(_:_:)`, `.centroid(_:) -> [Float]?`, `.updatedCentroid(_:count:adding:)`
  - `MeetAISpeakerProfile` (Codable, fork-compatible JSON: `id, name, embedding, sampleCount, createdAt, updatedAt`)
  - `@MainActor final class MeetAISpeakerProfileStore: ObservableObject` — `init(fileURL:)`, `.shared`, `matchThreshold = 0.7`, `profiles`, `enroll(name:embedding:) -> MeetAISpeakerProfile`, `rename(id:to:)`, `delete(id:)`, `copyLegacyProfilesIfNeeded(from:) -> Bool`
  - `MeetAICleanTurns.select(for:in:) -> [MeetingTranscriptSegment]`
  - `MeetAIProfileMatching.Decision { speakerID; profile; score }`, `MeetAIProfileMatching.decide(session:records:profiles:threshold:) -> [Decision]`

- [ ] **Step 1: Write the failing tests** (`MeetAISpeakerTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAISpeakerTests: XCTestCase {
    private func vector(_ seed: Float, dims: Int = 256) -> [Float] {
        MeetAISpeakerMath.normalize((0..<dims).map { sin(Float($0) * seed) })
    }

    // MARK: Math

    func testCentroidIsNormalisedMean() throws {
        let c = try XCTUnwrap(MeetAISpeakerMath.centroid([[1, 0], [0, 1]]))
        XCTAssertEqual(c[0], c[1], accuracy: 1e-5)
        XCTAssertEqual(MeetAISpeakerMath.dot(c, c), 1, accuracy: 1e-5)
        XCTAssertNil(MeetAISpeakerMath.centroid([]))
        XCTAssertEqual(MeetAISpeakerMath.dot([1, 0], [1, 0, 0]), -1)
    }

    // MARK: Profile store

    func testEnrollUpdatesByNameAndPersistsForkFormat() throws {
        let file = try MeetAIFixtures.tempDirectory(self).appendingPathComponent("SpeakerProfiles/profiles.json")
        let store = MeetAISpeakerProfileStore(fileURL: file)
        let first = store.enroll(name: "Sam", embedding: self.vector(0.1))
        let second = store.enroll(name: " sam ", embedding: self.vector(0.12))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].sampleCount, 2)
        let reloaded = MeetAISpeakerProfileStore(fileURL: file)
        XCTAssertEqual(reloaded.profiles, store.profiles)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"sampleCount\""))
    }

    func testCopyLegacyProfilesOnlyWhenMissing() throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let legacy = root.appendingPathComponent("legacy.json")
        let legacyStore = MeetAISpeakerProfileStore(fileURL: legacy)
        _ = legacyStore.enroll(name: "Girish", embedding: self.vector(0.3))
        let store = MeetAISpeakerProfileStore(fileURL: root.appendingPathComponent("MeetAI/profiles.json"))
        XCTAssertTrue(store.copyLegacyProfilesIfNeeded(from: legacy))
        XCTAssertEqual(store.profiles.map(\.name), ["Girish"])
        XCTAssertFalse(store.copyLegacyProfilesIfNeeded(from: legacy), "second copy must not overwrite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "legacy file is copied, not moved")
    }

    // MARK: Clean turns

    func testCleanTurnsPickLongestAdmissibleTurnsUpToThirtySeconds() {
        var session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [
                .init(speaker: 1, start: 0, end: 1, text: "too short"),
                .init(speaker: 1, start: 1, end: 13, text: "twelve"),
                .init(speaker: 1, start: 13, end: 33, text: "twenty"),
                .init(speaker: 1, start: 33, end: 41, text: "eight"),
                .init(speaker: 1, start: 41, end: 51, text: "echo"),
                .init(speaker: 0, start: 51, end: 70, text: "local"),
            ]
        )
        session.transcriptSegments[4].isLikelyEcho = true
        let picked = MeetAICleanTurns.select(for: session.speakers[1].id, in: session)
        XCTAssertEqual(picked.map(\.text), ["twenty", "twelve"])
    }

    func testCleanTurnsSkipSpeakerWithUnderThreeSeconds() {
        let session = MeetAIFixtures.session(
            speakers: [("Speaker 1", false)],
            lines: [.init(speaker: 0, start: 0, end: 2, text: "short")]
        )
        XCTAssertTrue(MeetAICleanTurns.select(for: session.speakers[0].id, in: session).isEmpty)
    }

    // MARK: Matching

    func testMatchRenamesOnlyDefaultLabelsAboveThreshold() {
        let session = MeetAIFixtures.session(speakers: [("You", true), ("Speaker 1", false), ("Speaker 2", false), ("Alex", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [
            session.speakers[1].id: .init(embedding: self.vector(0.1)),
            session.speakers[2].id: .init(embedding: self.vector(0.9)),
            session.speakers[3].id: .init(embedding: self.vector(0.1)),
            session.speakers[0].id: .init(embedding: self.vector(0.1)),
        ]
        let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam])
        XCTAssertEqual(decisions.map(\.speakerID), [session.speakers[1].id])
    }

    func testSameProfileGoesToBestSpeakerOnly() {
        let session = MeetAIFixtures.session(speakers: [("Speaker 1", false), ("Speaker 2", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [
            session.speakers[0].id: .init(embedding: self.vector(0.1)),
            session.speakers[1].id: .init(embedding: MeetAISpeakerMath.normalize(zip(self.vector(0.1), self.vector(0.11)).map { $0 + $1 })),
        ]
        let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam])
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.speakerID, session.speakers[0].id)
    }

    func testNoMatchWhenProfileNameAlreadyUsedInSession() {
        let session = MeetAIFixtures.session(speakers: [("Speaker 1", false), ("Sam", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [session.speakers[0].id: .init(embedding: self.vector(0.1))]
        XCTAssertTrue(MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam]).isEmpty)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAISpeakerTests.swift
```

Run `MeetAISpeakerTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAISpeakerMath.swift`**

```swift
import Foundation

nonisolated enum MeetAISpeakerMath {
    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return vector }
        return vector.map { $0 / norm }
    }

    /// Dot product, or -1 when dimensions differ.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let normalized = self.normalize(vector)
            for index in sum.indices { sum[index] += normalized[index] }
        }
        return self.normalize(sum)
    }

    /// Weighted running centroid (existing weight = `count`), renormalised.
    static func updatedCentroid(_ centroid: [Float], count: Int, adding sample: [Float]) -> [Float] {
        guard centroid.count == sample.count else { return self.normalize(sample) }
        let weight = Float(count)
        let normalizedSample = self.normalize(sample)
        return self.normalize(centroid.indices.map { centroid[$0] * weight + normalizedSample[$0] })
    }
}
```

- [ ] **Step 4: Implement `MeetAISpeakerProfileStore.swift`**

```swift
import Combine
import Foundation

/// Same JSON shape as the fork's `SpeakerProfile`, so the 27 existing profiles load unchanged.
nonisolated struct MeetAISpeakerProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// L2-normalised centroid of this person's WeSpeaker embedding.
    var embedding: [Float]
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, embedding: [Float], sampleCount: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = MeetAISpeakerMath.normalize(embedding)
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class MeetAISpeakerProfileStore: ObservableObject {
    static let shared = MeetAISpeakerProfileStore(fileURL: MeetAIPaths.standard().profilesFile)
    static let matchThreshold: Float = 0.7

    @Published private(set) var profiles: [MeetAISpeakerProfile] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.load()
    }

    @discardableResult
    func enroll(name: String, embedding: [Float]) -> MeetAISpeakerProfile {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = self.profiles.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            var profile = self.profiles[index]
            profile.embedding = MeetAISpeakerMath.updatedCentroid(profile.embedding, count: profile.sampleCount, adding: embedding)
            profile.sampleCount += 1
            profile.updatedAt = Date()
            self.profiles[index] = profile
            self.save()
            return profile
        }
        let profile = MeetAISpeakerProfile(name: clean, embedding: embedding)
        self.profiles.append(profile)
        self.save()
        return profile
    }

    func rename(id: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
        self.profiles[index].name = clean
        self.profiles[index].updatedAt = Date()
        self.save()
    }

    func delete(id: String) {
        self.profiles.removeAll { $0.id == id }
        self.save()
    }

    /// Copies the fork's profiles file when MeetAI has none yet. Never overwrites; never moves.
    @discardableResult
    func copyLegacyProfilesIfNeeded(from legacyFile: URL) -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: self.fileURL.path), manager.fileExists(atPath: legacyFile.path) else { return false }
        do {
            try manager.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: legacyFile, to: self.fileURL)
            self.load()
            return true
        } catch {
            DebugLogger.shared.warning("Copying legacy speaker profiles failed: \(error.localizedDescription)", source: "MeetAI")
            return false
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.profiles = (try? decoder.decode([MeetAISpeakerProfile].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self.profiles).write(to: self.fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.warning("Saving speaker profiles failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
}
```

- [ ] **Step 5: Implement `MeetAICleanTurns.swift`**

```swift
import Foundation

nonisolated enum MeetAICleanTurns {
    static let maximumSeconds: TimeInterval = 30
    static let minimumTurnSeconds: TimeInterval = 1.5
    static let minimumTotalSeconds: TimeInterval = 3

    /// The speaker's longest single-speaker, non-echo, non-overlapping turns, up to 30 s in total.
    /// Empty when less than 3 s qualifies.
    static func select(for speakerID: SessionSpeakerID, in session: MeetingSession) -> [MeetingTranscriptSegment] {
        func duration(_ segment: MeetingTranscriptSegment) -> TimeInterval { segment.end.seconds - segment.start.seconds }
        let candidates = session.transcriptSegments
            .filter {
                $0.speakerID == speakerID && !$0.isEcho && $0.overlap == .none
                    && ($0.attributionState ?? .assigned) == .assigned
                    && duration($0) >= self.minimumTurnSeconds
            }
            .sorted { duration($0) > duration($1) }
        var picked: [MeetingTranscriptSegment] = []
        var total: TimeInterval = 0
        for segment in candidates where total < self.maximumSeconds {
            picked.append(segment)
            total += duration(segment)
        }
        return total >= self.minimumTotalSeconds ? picked : []
    }
}
```

- [ ] **Step 6: Implement `MeetAIProfileMatching.swift`**

```swift
import Foundation

nonisolated enum MeetAIProfileMatching {
    struct Decision: Equatable, Sendable {
        let speakerID: SessionSpeakerID
        let profile: MeetAISpeakerProfile
        let score: Float
    }

    /// Default-labelled, non-local speakers whose embedding matches a profile at ≥ threshold.
    /// One profile goes to at most one speaker (the best score), and never to a name already in use.
    static func decide(
        session: MeetingSession,
        records: [SessionSpeakerID: MeetAISpeakerRecord],
        profiles: [MeetAISpeakerProfile],
        threshold: Float = 0.7
    ) -> [Decision] {
        let usedNames = Set(session.activeSpeakers.map { $0.displayName.lowercased() })
        var bestByProfile: [String: Decision] = [:]
        for speaker in session.activeSpeakers where !speaker.isLocalUser && MeetAITranscript.isDefaultSpeakerName(speaker.displayName) {
            guard let embedding = records[speaker.id]?.embedding else { continue }
            let query = MeetAISpeakerMath.normalize(embedding)
            var top: Decision?
            for profile in profiles where !usedNames.contains(profile.name.lowercased()) {
                let score = MeetAISpeakerMath.dot(query, profile.embedding)
                if score >= threshold, score > (top?.score ?? -1) {
                    top = Decision(speakerID: speaker.id, profile: profile, score: score)
                }
            }
            guard let top else { continue }
            if let existing = bestByProfile[top.profile.id], existing.score >= top.score { continue }
            bestByProfile[top.profile.id] = top
        }
        return bestByProfile.values.sorted { $0.speakerID.uuidString < $1.speakerID.uuidString }
    }
}
```

- [ ] **Step 7: Run tests, full suite, commit**

Run `MeetAISpeakerTests`. Expected: 7 PASS.

```bash
git add Sources/Fluid/MeetAI/Speakers Tests/FluidDictationIntegrationTests/MeetAISpeakerTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add persistent speaker profiles, clean-turn selection and profile matching

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Speaker embedder (FluidAudio)

**Files:**
- Create: `Sources/Fluid/MeetAI/Speakers/MeetAISpeakerEmbedder.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAIEmbedderTests.swift`

**Interfaces:**
- Consumes: `MeetAIAudioDecoder.load16kMono(url:start:end:)`, `MeetingSegmentPlaybackPlan.slices(session:segment:directory:)`, `MeetAISpeakerMath.centroid`
- Produces: `protocol MeetAISpeakerEmbedding: Sendable { func embedding(for:session:sessionDirectory:) async throws -> [Float]? }`, `struct MeetAIFluidAudioEmbedder: MeetAISpeakerEmbedding`, `MeetAIFluidAudioEmbedder.clips(from:) -> [[Float]]`, `MeetAIFluidAudioEmbedder.embed(clips:) async throws -> [[Float]]`

- [ ] **Step 1: Write the tests** (`MeetAIEmbedderTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIEmbedderTests: XCTestCase {
    func testClipsAreTenSecondWindowsAndDropShortTail() {
        let audio = [Float](repeating: 0.1, count: 16_000 * 25)
        let clips = MeetAIFluidAudioEmbedder.clips(from: audio)
        XCTAssertEqual(clips.map(\.count), [160_000, 160_000, 80_000])
        XCTAssertTrue(MeetAIFluidAudioEmbedder.clips(from: [Float](repeating: 0, count: 40_000)).isEmpty)
    }

    /// Opt-in (downloads/loads the diarizer embedding model): TEST_RUNNER_MEETAI_MODEL_TESTS=1
    func testSameVoiceMatchesAndDifferentVoicesDoNot() async throws {
        guard ProcessInfo.processInfo.environment["MEETAI_MODEL_TESTS"] == "1" else { throw XCTSkip("model test") }
        let directory = try MeetAIFixtures.tempDirectory(self)
        func say(_ voice: String, _ text: String, _ name: String) throws -> [Float] {
            let url = directory.appendingPathComponent("\(name).aiff")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-o", url.path, text]
            try process.run()
            process.waitUntilExit()
            return try MeetAIAudioDecoder.load16kMono(url: url)
        }
        let paragraph = "We reviewed the quarterly roadmap and agreed to ship the meeting features after the migration finishes and the tests pass."
        let samA1 = try say("Samantha", paragraph, "a1")
        let samA2 = try say("Samantha", paragraph + " Then we talked about the budget for next quarter.", "a2")
        let danB = try say("Daniel", paragraph, "b1")
        let embeddings = try await MeetAIFluidAudioEmbedder.embed(clips: [samA1, samA2, danB].map { Array($0.prefix(160_000)) })
        XCTAssertEqual(embeddings.count, 3)
        let same = MeetAISpeakerMath.dot(MeetAISpeakerMath.normalize(embeddings[0]), MeetAISpeakerMath.normalize(embeddings[1]))
        let different = MeetAISpeakerMath.dot(MeetAISpeakerMath.normalize(embeddings[0]), MeetAISpeakerMath.normalize(embeddings[2]))
        print("MEETAI-EMBED same=\(same) different=\(different)")
        XCTAssertGreaterThanOrEqual(same, MeetAISpeakerProfileStore.matchThreshold)
        XCTAssertLessThan(different, MeetAISpeakerProfileStore.matchThreshold)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAIEmbedderTests.swift
```

Run `MeetAIEmbedderTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAISpeakerEmbedder.swift`**

```swift
import CoreML
import FluidAudio
import Foundation

nonisolated protocol MeetAISpeakerEmbedding: Sendable {
    /// WeSpeaker centroid for `turns`, or nil when there is not enough decodable audio.
    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]?
}

nonisolated enum MeetAIEmbeddingError: LocalizedError {
    case unsupportedModel
    var errorDescription: String? { "The speaker voice model has an unsupported input format." }
}

/// Same model and calls as upstream's `MeetingProductionParakeetNemotronRuntime.speakerVoiceProfiles`
/// (spec §12.2), so embeddings are compatible with the fork's existing WeSpeaker profiles.
nonisolated struct MeetAIFluidAudioEmbedder: MeetAISpeakerEmbedding {
    static let clipSamples = 160_000 // 10 s
    static let minimumClipSamples = 48_000 // 3 s

    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        try await Self.compute(turns: turns, session: session, sessionDirectory: sessionDirectory)
    }

    /// Decoding and CoreML run off the caller's actor.
    @concurrent static func compute(turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        var audio: [Float] = []
        for turn in turns {
            try Task.checkCancellation()
            let slices = try MeetingSegmentPlaybackPlan.slices(session: session, segment: turn, directory: sessionDirectory)
            for slice in slices {
                audio += try MeetAIAudioDecoder.load16kMono(url: slice.url, start: slice.start, end: slice.end)
            }
        }
        let clips = self.clips(from: audio)
        guard !clips.isEmpty else { return nil }
        return MeetAISpeakerMath.centroid(try await self.embed(clips: clips))
    }

    static func clips(from audio: [Float]) -> [[Float]] {
        stride(from: 0, to: audio.count, by: self.clipSamples).compactMap { start in
            let clip = Array(audio[start..<min(audio.count, start + self.clipSamples)])
            return clip.count >= self.minimumClipSamples ? clip : nil
        }
    }

    @concurrent static func embed(clips: [[Float]]) async throws -> [[Float]] {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "meetai-speakers", modelID: ModelNames.Diarizer.embeddingFile) {
            let models = try await DownloadUtils.loadModels(
                .diarizer,
                modelNames: [ModelNames.Diarizer.embeddingFile],
                directory: DiarizerModels.defaultModelsDirectory().deletingLastPathComponent(),
                computeUnits: .cpuAndNeuralEngine
            )
            guard let model = models[ModelNames.Diarizer.embeddingFile],
                  let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue,
                  (1...4096).contains(maskFrames)
            else { throw MeetAIEmbeddingError.unsupportedModel }
            let extractor = EmbeddingExtractor(embeddingModel: model)
            let mask = [Float](repeating: 1, count: maskFrames)
            var embeddings: [[Float]] = []
            for clip in clips {
                try Task.checkCancellation()
                if let embedding = try extractor.getEmbeddings(audio: clip, masks: [mask]).first,
                   embedding.count == 256, embedding.allSatisfy(\.isFinite)
                {
                    embeddings.append(embedding)
                }
            }
            return embeddings
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run `MeetAIEmbedderTests` (clip test PASS, model test SKIP). Then run the model test:

```bash
TEST_RUNNER_MEETAI_MODEL_TESTS=1 xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -only-testing:FluidDictationIntegrationTests/MeetAIEmbedderTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "MEETAI-EMBED|Test Case|error:" | tail
```

Expected: PASS with a `MEETAI-EMBED same=… different=…` line. If synthetic voices fall on the wrong side of 0.7, record the printed scores in the commit message and spec §11. Do not change the threshold without asking the user: it must stay compatible with the 27 existing profiles.

- [ ] **Step 5: Full suite, commit**

```bash
git add Sources/Fluid/MeetAI/Speakers/MeetAISpeakerEmbedder.swift Tests/FluidDictationIntegrationTests/MeetAIEmbedderTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add the WeSpeaker speaker embedder for persistent speakers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Session processor — embeddings, profile matching, rename enrolment

**Files:**
- Create: `Sources/Fluid/MeetAI/MeetAISessionProcessor.swift`, `Sources/Fluid/MeetAI/Speakers/MeetAICorrectionDiff.swift`
- Modify: `Sources/Fluid/MeetAI/MeetAIBootstrap.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAISessionProcessorTests.swift`

**Interfaces:**
- Consumes: Tasks 4–7.
- Produces:
  - `@MainActor protocol MeetAISessionMutating: AnyObject` with `renameSpeakers(sessionID:names:)` and `renameSession(sessionID:to:)`; `extension MeetingSessionCoordinator: MeetAISessionMutating`
  - `MeetAICorrectionDiff.Result { records; enrolments: [(speakerID, name, embedding)]; renamedSpeakers: Bool; changed: Bool }`, `MeetAICorrectionDiff.apply(session:records:)`
  - `@MainActor final class MeetAISessionProcessor: ObservableObject` — `Dependencies`, `.shared`, `@Published busySessions: Set<MeetingSessionID>`, `@Published summaryErrors: [MeetingSessionID: String]`, `sessionDidComplete(_:) async`, `sessionCorrected(_:)`, `runAutomation(sessionID:) async`, `handleCorrection(sessionID:) async`, `enqueue(_:_:) -> Task<Void, Never>`, `mutate(_:)`, `load(_:)`
  - Test fakes in the test file: `FakeMutator`, `FakeEmbedder`, `FakeLLM`

- [ ] **Step 1: Write the failing tests** (`MeetAISessionProcessorTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FakeMutator: MeetAISessionMutating {
    var session: MeetingSession
    var busyFailures = 0
    var deleted = false
    var renameCalls: [[SessionSpeakerID: String]] = []
    var titleCalls: [String] = []

    init(_ session: MeetingSession) { self.session = session }

    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async throws -> MeetingSession {
        if self.deleted { throw MeetingCoordinatorError.noActiveMeeting }
        if self.busyFailures > 0 { self.busyFailures -= 1; throw MeetingCoordinatorError.activityInProgress }
        self.renameCalls.append(names)
        for (id, name) in names { try self.session.renameSpeaker(id: id, to: name) }
        return self.session
    }

    func renameSession(sessionID: MeetingSessionID, to title: String) async throws -> MeetingSession {
        if self.deleted { throw MeetingCoordinatorError.noActiveMeeting }
        self.titleCalls.append(title)
        self.session.title = title
        self.session.defaultTitleBase = nil
        return self.session
    }
}

nonisolated struct FakeEmbedder: MeetAISpeakerEmbedding {
    let bySpeakerText: [String: [Float]]
    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        turns.first.flatMap { self.bySpeakerText[$0.text] }
    }
}

@MainActor
final class FakeLLM: MeetAILLMCompleting {
    var replies: [String]
    var error: Error?
    private(set) var prompts: [String] = []

    init(replies: [String] = [], error: Error? = nil) {
        self.replies = replies
        self.error = error
    }

    func complete(systemPrompt: String, turns: [MeetAILLMTurn]) async throws -> String {
        self.prompts.append(systemPrompt + "\n" + turns.map(\.content).joined(separator: "\n"))
        if let error { throw error }
        return self.replies.isEmpty ? "" : self.replies.removeFirst()
    }

    func completeAboutTranscript(transcript: String, turns: [MeetAILLMTurn], systemPrompt: (String) -> String) async throws -> String {
        try await self.complete(systemPrompt: systemPrompt(transcript), turns: turns)
    }

    func descriptor() -> MeetAIProviderDescriptor { MeetAIProviderDescriptor(providerID: "fake", modelID: "fake-1") }
}

@MainActor
final class MeetAISessionProcessorTests: XCTestCase {
    private func vector(_ seed: Float) -> [Float] {
        MeetAISpeakerMath.normalize((0..<256).map { sin(Float($0) * seed) })
    }

    private struct Harness {
        let processor: MeetAISessionProcessor
        let mutator: FakeMutator
        let sidecars: MeetAISidecarStore
        let profiles: MeetAISpeakerProfileStore
        let settings: MeetAISettings
        let llm: FakeLLM
    }

    private func harness(session: MeetingSession, embeddings: [String: [Float]] = [:], llm: FakeLLM = FakeLLM()) throws -> Harness {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let profiles = MeetAISpeakerProfileStore(fileURL: paths.profilesFile)
        let defaults = UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!
        let settings = MeetAISettings(defaults: defaults)
        settings.autoName = false
        settings.autoSummarize = false
        let mutator = FakeMutator(session)
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars,
            profiles: profiles,
            settings: settings,
            embedder: FakeEmbedder(bySpeakerText: embeddings),
            llm: llm,
            mutator: { mutator },
            loadSession: { _ in mutator.deleted ? nil : mutator.session },
            sessionDirectory: { _ in root },
            retryDelay: .milliseconds(1)
        ))
        return Harness(processor: processor, mutator: mutator, sidecars: sidecars, profiles: profiles, settings: settings, llm: llm)
    }

    private func twoSpeakerSession() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false), ("Speaker 2", false)],
            lines: [
                .init(speaker: 1, start: 0, end: 10, text: "alpha"),
                .init(speaker: 2, start: 10, end: 20, text: "beta"),
                .init(speaker: 0, start: 20, end: 30, text: "gamma"),
            ]
        )
    }

    func testCompletionStoresEmbeddingsAndRenamesKnownVoice() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Sam")
        XCTAssertEqual(h.mutator.session.speakers[2].displayName, "Speaker 2")
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[1].id]?.nameSource, .profile)
        XCTAssertEqual(records[session.speakers[1].id]?.lastAppliedName, "Sam")
        XCTAssertNotNil(records[session.speakers[2].id]?.embedding)
        XCTAssertNil(records[session.speakers[0].id], "local user is never embedded")
    }

    func testProcessorRenameDoesNotEnrolButUserRenameDoes() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        // The processor's own rename comes back through H6: no new profile, Sam's count unchanged.
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(h.profiles.profiles.map(\.name), ["Sam"])
        XCTAssertEqual(h.profiles.profiles.first?.sampleCount, 1)
        // The user names Speaker 2: that enrols a new profile from the stored embedding.
        try h.mutator.session.renameSpeaker(id: session.speakers[2].id, to: "Priya")
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(Set(h.profiles.profiles.map(\.name)), ["Sam", "Priya"])
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[2].id]?.nameSource, .user)
    }

    func testMergeDropsSourceEmbedding() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        try h.mutator.session.mergeSpeakers(session.speakers[2].id, into: session.speakers[1].id)
        await h.processor.handleCorrection(sessionID: session.id)
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertNil(records[session.speakers[2].id]?.embedding)
        XCTAssertNotNil(records[session.speakers[1].id]?.embedding)
    }

    func testBusyCoordinatorIsRetriedThenGivesUp() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        h.mutator.busyFailures = 3
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Sam", "retried past 3 busy errors")

        let other = self.twoSpeakerSession()
        let h2 = try self.harness(session: other, embeddings: ["alpha": self.vector(0.1)])
        _ = h2.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        h2.mutator.busyFailures = 50
        await h2.processor.sessionDidComplete(other)
        await h2.processor.enqueue(other.id) { _ in }.value
        XCTAssertEqual(h2.mutator.session.speakers[1].displayName, "Speaker 1", "gives up after 10 retries")
    }

    func testMutationOnDeletedSessionIsSwallowed() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        h.mutator.deleted = true
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertTrue(h.mutator.renameCalls.isEmpty)
        await h.processor.handleCorrection(sessionID: session.id)
    }

    func testSpeakerMatchingToggleOffSkipsEverything() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        h.settings.speakerMatching = false
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertTrue(h.mutator.renameCalls.isEmpty)
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertTrue(records.isEmpty)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAISessionProcessorTests.swift
```

Run `MeetAISessionProcessorTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAICorrectionDiff.swift`**

```swift
import Foundation

/// Turns a saved correction into sidecar updates (spec §12.3). Pure.
nonisolated enum MeetAICorrectionDiff {
    struct Enrolment: Equatable, Sendable {
        let speakerID: SessionSpeakerID
        let name: String
        let embedding: [Float]
    }

    struct Result: Equatable, Sendable {
        var records: [SessionSpeakerID: MeetAISpeakerRecord]
        var enrolments: [Enrolment]
        var renamedSpeakers: Bool
        var changed: Bool
    }

    static func apply(session: MeetingSession, records: [SessionSpeakerID: MeetAISpeakerRecord]) -> Result {
        var result = Result(records: records, enrolments: [], renamedSpeakers: false, changed: false)
        for speaker in session.activeSpeakers where !speaker.isLocalUser {
            let name = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            var record = result.records[speaker.id] ?? MeetAISpeakerRecord()
            guard !MeetAITranscript.isDefaultSpeakerName(name), name != record.lastAppliedName else { continue }
            record.nameSource = .user
            record.lastAppliedName = name
            if let embedding = record.embedding {
                result.enrolments.append(Enrolment(speakerID: speaker.id, name: name, embedding: embedding))
            }
            result.records[speaker.id] = record
            result.renamedSpeakers = true
            result.changed = true
        }
        for speaker in session.speakers where speaker.mergedIntoSpeakerID != nil {
            guard result.records[speaker.id]?.embedding != nil else { continue }
            result.records[speaker.id]?.embedding = nil
            result.changed = true
        }
        return result
    }
}
```

- [ ] **Step 4: Implement `MeetAISessionProcessor.swift`**

```swift
import Combine
import Foundation

@MainActor
protocol MeetAISessionMutating: AnyObject {
    @discardableResult
    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async throws -> MeetingSession
    @discardableResult
    func renameSession(sessionID: MeetingSessionID, to title: String) async throws -> MeetingSession
}

extension MeetingSessionCoordinator: MeetAISessionMutating {}

/// Per-session MeetAI work, serialized per session: speakers → names → title → summary (spec §5.5).
@MainActor
final class MeetAISessionProcessor: ObservableObject {
    struct Dependencies {
        var sidecars: MeetAISidecarStore
        var profiles: MeetAISpeakerProfileStore
        var settings: MeetAISettings
        var embedder: any MeetAISpeakerEmbedding
        var llm: any MeetAILLMCompleting
        var mutator: @MainActor () -> any MeetAISessionMutating
        var loadSession: @MainActor (MeetingSessionID) async throws -> MeetingSession?
        var sessionDirectory: @MainActor (MeetingSessionID) async throws -> URL
        var retryDelay: Duration = .seconds(1)

        static func live() -> Dependencies {
            Dependencies(
                sidecars: .shared,
                profiles: .shared,
                settings: .shared,
                embedder: MeetAIFluidAudioEmbedder(),
                llm: MeetAILLM(),
                mutator: { AppServices.shared.meetingSessionCoordinator },
                loadSession: { try await MeetingSessionStore.shared.load(id: $0) },
                sessionDirectory: { try await MeetingSessionStore.shared.sessionDirectory(for: $0) }
            )
        }
    }

    static let shared = MeetAISessionProcessor(dependencies: .live())
    static let maximumMutationRetries = 10

    @Published private(set) var busySessions: Set<MeetingSessionID> = []
    @Published var summaryErrors: [MeetingSessionID: String] = [:]

    let deps: Dependencies
    private var chains: [MeetingSessionID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: Hook handlers

    /// H1. Awaited (bounded) by the coordinator: only the audio-dependent step runs inline.
    func sessionDidComplete(_ session: MeetingSession) async {
        if self.deps.settings.speakerMatching {
            await self.captureEmbeddings(session)
        }
        self.enqueue(session.id) { await $0.runAutomation(sessionID: session.id) }
    }

    /// H6. Never mutates synchronously: the coordinator still holds its mutation gate.
    func sessionCorrected(_ session: MeetingSession) {
        self.enqueue(session.id) { await $0.handleCorrection(sessionID: session.id) }
    }

    // MARK: Queue

    @discardableResult
    func enqueue(_ id: MeetingSessionID, _ work: @escaping @MainActor (MeetAISessionProcessor) async -> Void) -> Task<Void, Never> {
        let previous = self.chains[id]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.busySessions.insert(id)
            await work(self)
            if self.chains[id]?.token == token {
                self.chains[id] = nil
                self.busySessions.remove(id)
            }
        }
        self.chains[id] = (token, task)
        return task
    }

    // MARK: Pipeline

    func runAutomation(sessionID: MeetingSessionID) async {
        guard var session = await self.load(sessionID), session.state == .completed else { return }
        if self.deps.settings.speakerMatching, let updated = await self.applyProfileMatches(session) {
            session = updated
        }
    }

    func handleCorrection(sessionID: MeetingSessionID) async {
        guard let session = await self.load(sessionID) else { return }
        do {
            let result = MeetAICorrectionDiff.apply(session: session, records: try await self.deps.sidecars.speakers(for: sessionID))
            guard result.changed else { return }
            var records = result.records
            for enrolment in result.enrolments {
                let profile = self.deps.profiles.enroll(name: enrolment.name, embedding: enrolment.embedding)
                records[enrolment.speakerID]?.matchedProfileID = profile.id
            }
            try await self.deps.sidecars.saveSpeakers(records, for: sessionID)
        } catch {
            DebugLogger.shared.warning("MeetAI correction handling failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func captureEmbeddings(_ session: MeetingSession) async {
        do {
            let directory = try await self.deps.sessionDirectory(session.id)
            var records = try await self.deps.sidecars.speakers(for: session.id)
            for speaker in session.activeSpeakers where !speaker.isLocalUser {
                let turns = MeetAICleanTurns.select(for: speaker.id, in: session)
                guard !turns.isEmpty,
                      let embedding = try await self.deps.embedder.embedding(for: turns, session: session, sessionDirectory: directory)
                else { continue }
                records[speaker.id, default: MeetAISpeakerRecord()].embedding = embedding
            }
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
        } catch {
            DebugLogger.shared.warning("MeetAI speaker embeddings skipped: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func applyProfileMatches(_ session: MeetingSession) async -> MeetingSession? {
        do {
            var records = try await self.deps.sidecars.speakers(for: session.id)
            let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: self.deps.profiles.profiles)
            guard !decisions.isEmpty else { return nil }
            for decision in decisions {
                records[decision.speakerID, default: MeetAISpeakerRecord()].matchedProfileID = decision.profile.id
                records[decision.speakerID, default: MeetAISpeakerRecord()].nameSource = .profile
                records[decision.speakerID, default: MeetAISpeakerRecord()].lastAppliedName = decision.profile.name
            }
            // Saved before renaming so the H6 echo of this rename is recognised as MeetAI's own.
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
            let names = Dictionary(uniqueKeysWithValues: decisions.map { ($0.speakerID, $0.profile.name) })
            return try await self.mutate { try await $0.renameSpeakers(sessionID: session.id, names: names) }
        } catch {
            DebugLogger.shared.warning("MeetAI profile matching failed: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    // MARK: Helpers

    func load(_ id: MeetingSessionID) async -> MeetingSession? {
        do { return try await self.deps.loadSession(id) } catch { return nil }
    }

    /// Retries while the coordinator is busy; any other error (e.g. a deleted session) propagates.
    func mutate(_ body: @MainActor (any MeetAISessionMutating) async throws -> MeetingSession) async throws -> MeetingSession {
        var attempt = 0
        while true {
            do {
                return try await body(self.deps.mutator())
            } catch let error as MeetingCoordinatorError
                where (error == .activityInProgress || error == .maintenanceInProgress) && attempt < Self.maximumMutationRetries
            {
                attempt += 1
                try await Task.sleep(for: self.deps.retryDelay)
            }
        }
    }
}
```

- [ ] **Step 5: Wire the hooks and legacy profiles in `MeetAIBootstrap.start()`**

Replace the body of `start()` with:

```swift
    static func start() {
        guard !self.started, !self.isTestHost else { return }
        self.started = true
        let paths = MeetAIPaths.standard()
        MeetAISpeakerProfileStore.shared.copyLegacyProfilesIfNeeded(from: paths.legacyProfilesFile)
        MeetAIHooks.sessionDidComplete = { session in await MeetAISessionProcessor.shared.sessionDidComplete(session) }
        MeetAIHooks.sessionCorrected = { session in MeetAISessionProcessor.shared.sessionCorrected(session) }
        Task { await self.sweepOrphanedSidecars() }
    }
```

- [ ] **Step 6: Run tests, full suite, commit**

Run `MeetAISessionProcessorTests`. Expected: 6 PASS. Note: `testBusyCoordinatorIsRetriedThenGivesUp`'s give-up half exercises `mutate` throwing after 10 retries; `applyProfileMatches` catches it and returns nil.

```bash
git add Sources/Fluid/MeetAI Tests/FluidDictationIntegrationTests/MeetAISessionProcessorTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add the MeetAI session processor: persistent speaker matching and enrolment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: LLM speaker naming and titles

**Files:**
- Create: `Sources/Fluid/MeetAI/MeetAISpeakerNamer.swift`, `Sources/Fluid/MeetAI/MeetAITitler.swift`
- Modify: `Sources/Fluid/MeetAI/MeetAISessionProcessor.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAINamingTitleTests.swift`

**Interfaces:**
- Produces: `MeetAISpeakerNamer.systemPrompt(labels:localLabel:) -> (String) -> String`, `MeetAISpeakerNamer.parseNameMap(from:validLabels:) -> [String: String]`, `MeetAITitler.systemPrompt`, `MeetAITitler.clean(_:) -> String?`, `MeetAITitler.ownsTitle(session:meta:) -> Bool`, processor `applyLLMNames(_:)`, `applyTitle(_:)`, `refreshTitleAfterRename(sessionID:)`

- [ ] **Step 1: Write the failing tests** (`MeetAINamingTitleTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAINamingTitleTests: XCTestCase {
    func testParseNameMapToleratesFencesAndRejectsJunk() {
        let reply = "```json\n{\"Speaker 1\": \"Sarah\", \"Speaker 2\": null, \"Speaker 3\": \"Speaker 3\", \"Bogus\": \"X\", \"Speaker 4\": \" \"}\n```"
        let map = MeetAISpeakerNamer.parseNameMap(from: reply, validLabels: ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])
        XCTAssertEqual(map, ["Speaker 1": "Sarah"])
        XCTAssertTrue(MeetAISpeakerNamer.parseNameMap(from: "no json", validLabels: ["Speaker 1"]).isEmpty)
    }

    func testPromptCarriesDirectAddressRuleAndLocalLabel() {
        let prompt = MeetAISpeakerNamer.systemPrompt(labels: ["Speaker 1"], localLabel: "You")("TRANSCRIPT")
        XCTAssertTrue(prompt.contains("identifies the LISTENER"))
        XCTAssertTrue(prompt.contains("\"You\""))
        XCTAssertTrue(prompt.hasSuffix("TRANSCRIPT"))
    }

    func testTitleCleaning() {
        XCTAssertEqual(MeetAITitler.clean("\"Roadmap Sync.\"\nextra"), "Roadmap Sync")
        XCTAssertEqual(MeetAITitler.clean("## **Budget Review**"), "Budget Review")
        XCTAssertNil(MeetAITitler.clean("   \n  "))
        XCTAssertEqual(MeetAITitler.clean(String(repeating: "a", count: 100))?.count, 60)
    }

    func testTitleOwnership() {
        var session = MeetAIFixtures.session(speakers: [], lines: [], defaultTitle: true)
        XCTAssertTrue(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord()))
        session.defaultTitleBase = nil
        session.title = "LLM title"
        XCTAssertTrue(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "LLM title")))
        session.title = "User title"
        XCTAssertFalse(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "LLM title")))
    }

    private func harness(_ session: MeetingSession, llm: FakeLLM) throws -> (MeetAISessionProcessor, FakeMutator, MeetAISidecarStore) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let settings = MeetAISettings(defaults: UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!)
        settings.speakerMatching = false
        settings.autoSummarize = false
        let mutator = FakeMutator(session)
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars, profiles: MeetAISpeakerProfileStore(fileURL: paths.profilesFile), settings: settings,
            embedder: FakeEmbedder(bySpeakerText: [:]), llm: llm, mutator: { mutator },
            loadSession: { _ in mutator.session }, sessionDirectory: { _ in root }, retryDelay: .milliseconds(1)
        ))
        return (processor, mutator, sidecars)
    }

    func testAutomationNamesSpeakersThenTitlesWithoutEnrolling() async throws {
        let session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Hi, I'm Sarah from finance."), .init(speaker: 0, start: 4, end: 6, text: "Thanks Sarah.")]
        )
        let llm = FakeLLM(replies: ["{\"Speaker 1\": \"Sarah\"}", "Finance Check-in"])
        let (processor, mutator, sidecars) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.speakers[1].displayName, "Sarah")
        XCTAssertEqual(mutator.session.title, "Finance Check-in")
        let records = try await sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[1].id]?.nameSource, .llm)
        let meta = try await sidecars.meta(for: session.id)
        XCTAssertEqual(meta.lastLLMTitle, "Finance Check-in")
        await processor.handleCorrection(sessionID: session.id)
        let afterEcho = try await sidecars.speakers(for: session.id)
        XCTAssertEqual(afterEcho[session.speakers[1].id]?.nameSource, .llm, "MeetAI's own rename is not a user rename")
    }

    func testNamingSkipsWhenOnlyLocalUser() async throws {
        let session = MeetAIFixtures.session(speakers: [("You", true)], lines: [.init(speaker: 0, start: 0, end: 3, text: "Note to self.")])
        let llm = FakeLLM(replies: ["Personal Note"])
        let (processor, mutator, _) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(llm.prompts.count, 1, "only the title call, no naming call")
        XCTAssertEqual(mutator.session.title, "Personal Note")
    }

    func testUserTitleIsNeverReplaced() async throws {
        var session = MeetAIFixtures.session(speakers: [("You", true)], lines: [.init(speaker: 0, start: 0, end: 3, text: "Hello")])
        session.defaultTitleBase = nil
        session.title = "My own title"
        let llm = FakeLLM(replies: ["Should Not Apply"])
        let (processor, mutator, sidecars) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.title, "My own title")
        XCTAssertTrue(llm.prompts.isEmpty)
        let meta = try await sidecars.meta(for: session.id)
        XCTAssertEqual(meta.titleSource, .user)
    }

    func testDuplicateLLMNamesAreDropped() async throws {
        let session = MeetAIFixtures.session(
            speakers: [("Speaker 1", false), ("Speaker 2", false)],
            lines: [.init(speaker: 0, start: 0, end: 3, text: "a"), .init(speaker: 1, start: 3, end: 6, text: "b")]
        )
        let llm = FakeLLM(replies: ["{\"Speaker 1\": \"Sam\", \"Speaker 2\": \"Sam\"}", "Title"])
        let (processor, mutator, _) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.speakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAINamingTitleTests.swift
```

Run `MeetAINamingTitleTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAISpeakerNamer.swift`** (prompt and parser ported from the fork's `MeetingSpeakerNamer`, generalised from "Me"/"Them N" to upstream labels)

```swift
import Foundation

nonisolated enum MeetAISpeakerNamer {
    static func systemPrompt(labels: [String], localLabel: String) -> (String) -> String {
        let labelList = labels.joined(separator: ", ")
        return { transcript in
            """
            You identify speakers in a meeting transcript. The local user is labelled "\(localLabel)". \
            The other speakers have provisional labels: \(labelList).

            Determine the real first name of each provisional label ONLY when the transcript \
            clearly evidences it — for example the speaker introduces themselves ("I'm Sarah", \
            "this is John speaking"). IMPORTANT: a name a speaker uses while talking TO someone \
            (direct address, e.g. "thanks, Sam" or "what do you think, Sam?") identifies the \
            LISTENER, not the speaker — never assign such a name to the speaker's own label. \
            Since "\(localLabel)" is usually the person being addressed by the others, names they use in \
            direct address most likely belong to "\(localLabel)" and must NOT be assigned to any label. \
            Do NOT guess, and do NOT infer a name from topic or context. If a label's name is \
            not clearly evidenced, use null.

            Respond with ONLY a JSON object mapping each provisional label to a name string or null, e.g.:
            {"\(labels.first ?? "Speaker 1")": "Sarah"}

            Transcript:
            \(transcript)
            """
        }
    }

    /// `{label: name}` from the model's reply, keeping only valid labels with real names.
    static func parseNameMap(from response: String, validLabels: Set<String>) -> [String: String] {
        guard let range = self.firstJSONObjectRange(in: response),
              let data = String(response[range]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (label, value) in raw {
            guard validLabels.contains(label), let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "null", trimmed != label,
                  !MeetAITranscript.isDefaultSpeakerName(trimmed)
            else { continue }
            map[label] = trimmed
        }
        return map
    }

    private static func firstJSONObjectRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
```

- [ ] **Step 4: Implement `MeetAITitler.swift`**

```swift
import Foundation

nonisolated enum MeetAITitler {
    static let systemPrompt = """
    You title meetings. Reply with ONLY a concise, descriptive 3-8 word title for the meeting \
    described below. No quotes, no dates, no trailing punctuation.
    """

    /// First non-empty line, stripped of quotes/markdown/trailing punctuation, max 60 characters.
    static func clean(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`#*. "))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60))
    }

    /// MeetAI may (re)title while upstream's default title stands or its own last title stands (spec §12.5).
    static func ownsTitle(session: MeetingSession, meta: MeetAIMetaRecord) -> Bool {
        session.defaultTitleBase != nil || (meta.lastLLMTitle != nil && session.title == meta.lastLLMTitle)
    }
}
```

- [ ] **Step 5: Extend the processor**

In `runAutomation`, after the profile-matching `if` block add:

```swift
        if self.deps.settings.autoName, let updated = await self.applyLLMNames(session) {
            session = updated
        }
        if let updated = await self.applyTitle(session) {
            session = updated
        }
```

In `handleCorrection`, after `try await self.deps.sidecars.saveSpeakers(records, for: sessionID)` add:

```swift
            if result.renamedSpeakers {
                await self.refreshTitleAfterRename(sessionID: sessionID)
            }
```

Add these methods to the `// MARK: Pipeline` section:

```swift
    func applyLLMNames(_ session: MeetingSession) async -> MeetingSession? {
        let candidates = session.activeSpeakers.filter { !$0.isLocalUser && MeetAITranscript.isDefaultSpeakerName($0.displayName) }
        guard !candidates.isEmpty, !MeetAITranscript.turns(for: session).isEmpty else { return nil }
        let labels = Set(candidates.map(\.displayName))
        let taken = Set(session.activeSpeakers.filter { !labels.contains($0.displayName) }.map { $0.displayName.lowercased() })
        do {
            let reply = try await self.deps.llm.completeAboutTranscript(
                transcript: MeetAITranscript.text(for: session),
                turns: [MeetAILLMTurn(role: "user", content: "Return the speaker-name JSON.")],
                systemPrompt: MeetAISpeakerNamer.systemPrompt(labels: labels.sorted(), localLabel: MeetAITranscript.localUserLabel(in: session))
            )
            let parsed = MeetAISpeakerNamer.parseNameMap(from: reply, validLabels: labels)
            let counts = Dictionary(grouping: parsed.values, by: { $0.lowercased() }).mapValues(\.count)
            let map = parsed.filter { counts[$0.value.lowercased()] == 1 && !taken.contains($0.value.lowercased()) }
            guard !map.isEmpty else { return nil }
            var records = try await self.deps.sidecars.speakers(for: session.id)
            var names: [SessionSpeakerID: String] = [:]
            for speaker in candidates {
                guard let name = map[speaker.displayName] else { continue }
                names[speaker.id] = name
                records[speaker.id, default: MeetAISpeakerRecord()].nameSource = .llm
                records[speaker.id, default: MeetAISpeakerRecord()].lastAppliedName = name
            }
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
            return try await self.mutate { try await $0.renameSpeakers(sessionID: session.id, names: names) }
        } catch {
            DebugLogger.shared.warning("MeetAI speaker naming skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    func applyTitle(_ session: MeetingSession) async -> MeetingSession? {
        do {
            var meta = try await self.deps.sidecars.meta(for: session.id)
            guard MeetAITitler.ownsTitle(session: session, meta: meta) else {
                if meta.titleSource != .user {
                    meta.titleSource = .user
                    try await self.deps.sidecars.saveMeta(meta, for: session.id)
                }
                return nil
            }
            guard !MeetAITranscript.turns(for: session).isEmpty else { return nil }
            let context = String(MeetAITranscript.text(for: session).prefix(4_000))
            let raw = try await self.deps.llm.complete(systemPrompt: MeetAITitler.systemPrompt, turns: [MeetAILLMTurn(role: "user", content: context)])
            guard let title = MeetAITitler.clean(raw), title != session.title else { return nil }
            meta.titleSource = .llm
            meta.lastLLMTitle = title
            try await self.deps.sidecars.saveMeta(meta, for: session.id)
            return try await self.mutate { try await $0.renameSession(sessionID: session.id, to: title) }
        } catch {
            DebugLogger.shared.warning("MeetAI title skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    func refreshTitleAfterRename(sessionID: MeetingSessionID) async {
        guard let session = await self.load(sessionID) else { return }
        _ = await self.applyTitle(session)
    }
```

- [ ] **Step 6: Run tests, full suite, commit**

Run `MeetAINamingTitleTests` and `MeetAISessionProcessorTests`. Expected: all PASS.

```bash
git add Sources/Fluid/MeetAI Tests/FluidDictationIntegrationTests/MeetAINamingTitleTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add LLM speaker naming and meeting titles

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Summaries and the Summary tab (H2a)

**Files:**
- Create: `Sources/Fluid/MeetAI/MeetAISummaryStyle.swift`, `Sources/Fluid/MeetAI/MeetAISummarizer.swift`, `Sources/Fluid/UI/MeetAI/MeetAISummaryView.swift`
- Modify: `Sources/Fluid/MeetAI/MeetAISessionProcessor.swift`, `Sources/Fluid/UI/MeetingSessionCanvases.swift` (~L441)
- Test: `Tests/FluidDictationIntegrationTests/MeetAISummaryTests.swift`

**Interfaces:**
- Produces: `MeetAISummaryStyle` (`standard`, `keyTakeaways`, `whatByWhenPerSpeaker`, `whatByWhenBroad`; `displayName`, `userPrompt`, `formatInstructions(localLabel:)`), `extension MeetAISettings { var summaryStyle }`, `MeetAISummarizer.systemPrompt(style:localLabel:)`, `MeetAISummarizer.generate(session:style:llm:) async throws -> MeetAISummaryRecord`, processor `generateSummaryIfMissing(_:)`, `regenerateSummary(sessionID:style:) async`, `MeetAISummaryView(session:)`

- [ ] **Step 1: Write the failing tests** (`MeetAISummaryTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAISummaryTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Sam", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Ship it Friday."), .init(speaker: 0, start: 4, end: 6, text: "Agreed.")]
        )
    }

    func testGenerateRecordsStyleHashAndProvider() async throws {
        let llm = FakeLLM(replies: ["  ## Overview\nShip Friday.  "])
        let record = try await MeetAISummarizer.generate(session: self.session(), style: .keyTakeaways, llm: llm)
        XCTAssertEqual(record.markdown, "## Overview\nShip Friday.")
        XCTAssertEqual(record.style, "keyTakeaways")
        XCTAssertEqual(record.transcriptHash, MeetAITranscript.hash(for: self.session()))
        XCTAssertEqual(record.providerID, "fake")
        XCTAssertTrue(llm.prompts[0].contains("## Key takeaways"))
        XCTAssertTrue(llm.prompts[0].contains("Ship it Friday."))
    }

    func testPerSpeakerStyleNamesTheLocalUser() {
        XCTAssertTrue(MeetAISummaryStyle.whatByWhenPerSpeaker.formatInstructions(localLabel: "You").contains("(\"You\") first"))
    }

    func testSummaryOfEmptyTranscriptFailsCleanly() async {
        let empty = MeetAIFixtures.session(speakers: [("You", true)], lines: [])
        let llm = FakeLLM(replies: ["should not be called"])
        do {
            _ = try await MeetAISummarizer.generate(session: empty, style: .standard, llm: llm)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no transcript"))
        }
        XCTAssertTrue(llm.prompts.isEmpty)
    }

    private func processor(session: MeetingSession, llm: FakeLLM) throws -> (MeetAISessionProcessor, MeetAISidecarStore) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let settings = MeetAISettings(defaults: UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!)
        settings.speakerMatching = false
        settings.autoName = false
        let mutator = FakeMutator(session)
        mutator.session.defaultTitleBase = nil
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars, profiles: MeetAISpeakerProfileStore(fileURL: paths.profilesFile), settings: settings,
            embedder: FakeEmbedder(bySpeakerText: [:]), llm: llm, mutator: { mutator },
            loadSession: { _ in mutator.session }, sessionDirectory: { _ in root }, retryDelay: .milliseconds(1)
        ))
        return (processor, sidecars)
    }

    func testAutomationSummarisesOnceWithDefaultStyle() async throws {
        let session = self.session()
        let llm = FakeLLM(replies: ["Summary one", "Summary two"])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        await processor.runAutomation(sessionID: session.id)
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertEqual(summary?.markdown, "Summary one")
        XCTAssertEqual(summary?.style, "standard")
    }

    func testSummaryErrorIsRecordedNotThrown() async throws {
        let session = self.session()
        let llm = FakeLLM(error: MeetAILLMError("Missing API key for openai. Add it under AI Enhancement."))
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(processor.summaryErrors[session.id], "Missing API key for openai. Add it under AI Enhancement.")
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertNil(summary)
        llm.error = nil
        llm.replies = ["Recovered"]
        await processor.regenerateSummary(sessionID: session.id, style: .standard)
        XCTAssertNil(processor.summaryErrors[session.id])
        let recovered = try await sidecars.summary(for: session.id)
        XCTAssertEqual(recovered?.markdown, "Recovered")
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAISummaryTests.swift
```

Run `MeetAISummaryTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAISummaryStyle.swift`** (ported from the fork's `MeetingSummaryStyle`)

```swift
import Foundation

nonisolated enum MeetAISummaryStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case keyTakeaways
    case whatByWhenPerSpeaker
    case whatByWhenBroad

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .keyTakeaways: "Key Takeaways and Summary of Topics"
        case .whatByWhenPerSpeaker: "What by When and Why (per speaker)"
        case .whatByWhenBroad: "What by When and Why (broad)"
        }
    }

    /// Small local models follow the user turn over the system prompt, so it restates the ask.
    var userPrompt: String {
        switch self {
        case .standard: "Summarise this meeting."
        case .keyTakeaways: "Give the key takeaways and a topic-by-topic summary of this meeting, in the format described."
        case .whatByWhenPerSpeaker: "List the action items for each speaker in this meeting on a \"What by When and Why\" basis, in the format described."
        case .whatByWhenBroad: "Describe what we are collectively trying to achieve in this meeting on a \"What by When and Why\" basis, in the format described."
        }
    }

    func formatInstructions(localLabel: String) -> String {
        switch self {
        case .standard:
            """
            Write a concise summary in Markdown with these sections, omitting any section with nothing to say:

            ## Overview — 1-3 sentences on what the meeting was about.
            ## Key points — bullet list of the substantive points discussed.
            ## Decisions — bullet list of decisions reached.
            ## Action items — bullet list; note who owns each when clear.
            ## Open questions — bullet list of unresolved items.
            """
        case .keyTakeaways:
            """
            Write a summary in Markdown with exactly these sections:

            ## Key takeaways
            ### Core points
            A bullet list of the essential points of the meeting, most important first.

            ## Summary
            One top-level bullet per topic discussed, in the order the topics came up, each followed \
            by indented sub-bullets describing what was discussed about that topic:
            - Topic discussed
              - What was discussed
            """
        case .whatByWhenPerSpeaker:
            """
            Create a list of action items for each speaker based on the transcript, answering on a \
            "What by When and Why" basis:
            — What exactly do you need from me?
            — When exactly do you need each of those things by?
            — Why exactly do you need each of those things to be done?

            Write Markdown with one "## <speaker>" section per speaker who has action items, each \
            section a bullet list where every action item states **What** exactly they need to do, \
            **When** exactly it is needed by (quote the deadline discussed, or note that none was \
            mentioned), and **Why** exactly it needs to be done. Put the section for the user \
            ("\(localLabel)") first and make it the most thorough and detailed. Omit speakers with no action items.
            """
        case .whatByWhenBroad:
            """
            Describe what the participants are collectively trying to achieve, answering on a \
            "What by When and Why" basis:
            — What exactly do we have to do?
            — When exactly do we need each of those things by?
            — Why exactly do we need each of those things to be done?

            Write Markdown with these sections:

            ## What
            Bullet list of what exactly has to be done.
            ## When
            Bullet list of when exactly each of those things is needed by (quote deadlines \
            discussed; note where none was mentioned).
            ## Why
            Bullet list of why exactly each of those things needs to be done.
            """
        }
    }
}

extension MeetAISettings {
    var summaryStyle: MeetAISummaryStyle {
        get { self.defaults.string(forKey: Key.summaryStyle).flatMap(MeetAISummaryStyle.init(rawValue:)) ?? .standard }
        set {
            self.objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Key.summaryStyle)
        }
    }
}
```

- [ ] **Step 4: Implement `MeetAISummarizer.swift`**

```swift
import Foundation

@MainActor
enum MeetAISummarizer {
    static func systemPrompt(style: MeetAISummaryStyle, localLabel: String) -> (String) -> String {
        { transcript in
            """
            You summarise meetings. Below is a machine-generated transcript of a meeting. The user is \
            labelled "\(localLabel)"; other participants are labelled by name or as "Speaker N". The \
            transcription may contain recognition errors — infer the intended meaning where obvious. \
            \(style.formatInstructions(localLabel: localLabel))

            Transcript:
            \(transcript)
            """
        }
    }

    static func generate(session: MeetingSession, style: MeetAISummaryStyle, llm: any MeetAILLMCompleting) async throws -> MeetAISummaryRecord {
        guard !MeetAITranscript.turns(for: session).isEmpty else {
            throw MeetAILLMError("This meeting has no transcript to summarise.")
        }
        let reply = try await llm.completeAboutTranscript(
            transcript: MeetAITranscript.text(for: session),
            turns: [MeetAILLMTurn(role: "user", content: style.userPrompt)],
            systemPrompt: self.systemPrompt(style: style, localLabel: MeetAITranscript.localUserLabel(in: session))
        )
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MeetAILLMError("The AI provider returned an empty summary.") }
        let descriptor = llm.descriptor()
        return MeetAISummaryRecord(
            style: style.rawValue,
            transcriptHash: MeetAITranscript.hash(for: session),
            markdown: body,
            providerID: descriptor.providerID,
            modelID: descriptor.modelID,
            createdAt: Date()
        )
    }
}
```

- [ ] **Step 5: Extend the processor**

In `runAutomation`, after the title block add:

```swift
        if self.deps.settings.autoSummarize {
            await self.generateSummaryIfMissing(session)
        }
```

Add to `// MARK: Pipeline`:

```swift
    func generateSummaryIfMissing(_ session: MeetingSession) async {
        do {
            guard try await self.deps.sidecars.summary(for: session.id) == nil else { return }
        } catch {
            return
        }
        await self.writeSummary(session, style: self.deps.settings.summaryStyle)
    }

    /// Summary tab's Generate/Regenerate. Runs in the session's queue.
    func regenerateSummary(sessionID: MeetingSessionID, style: MeetAISummaryStyle) async {
        await self.enqueue(sessionID) { processor in
            guard let session = await processor.load(sessionID) else { return }
            await processor.writeSummary(session, style: style)
        }.value
    }

    private func writeSummary(_ session: MeetingSession, style: MeetAISummaryStyle) async {
        do {
            let record = try await MeetAISummarizer.generate(session: session, style: style, llm: self.deps.llm)
            try await self.deps.sidecars.saveSummary(record, for: session.id)
            self.summaryErrors[session.id] = nil
        } catch {
            self.summaryErrors[session.id] = error.localizedDescription
            DebugLogger.shared.warning("MeetAI summary failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
```

- [ ] **Step 6: Implement `MeetAISummaryView.swift`**

```swift
import AppKit
import SwiftUI

struct MeetAISummaryView: View {
    let session: MeetingSession

    @ObservedObject private var processor = MeetAISessionProcessor.shared
    @Environment(\.theme) private var theme
    @State private var record: MeetAISummaryRecord?
    @State private var style: MeetAISummaryStyle = MeetAISettings.shared.summaryStyle

    private var isBusy: Bool { self.processor.busySessions.contains(self.session.id) }
    private var isStale: Bool { self.record.map { $0.transcriptHash != MeetAITranscript.hash(for: self.session) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Picker("Style", selection: self.$style) {
                    ForEach(MeetAISummaryStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 320)
                Button(self.record == nil ? "Generate" : "Regenerate") { self.regenerate() }
                    .disabled(self.isBusy)
                if let record {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.markdown, forType: .string)
                    }
                }
                Spacer(minLength: 0)
            }

            if self.isBusy {
                ProgressView("Working on this meeting…").controlSize(.small)
            }

            if let error = self.processor.summaryErrors[self.session.id] {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                    Button("Retry") { self.regenerate() }.disabled(self.isBusy)
                }
            }

            if self.isStale {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label("The transcript changed since this summary was written.", systemImage: "arrow.triangle.2.circlepath")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button("Regenerate") { self.regenerate() }.disabled(self.isBusy)
                }
            }

            if let record {
                if MeetAISummaryStyle(rawValue: record.style) == nil {
                    Text("Summary from the previous MeetAI version")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                MarkdownText(markdown: record.markdown)
                    .textSelection(.enabled)
            } else if !self.isBusy {
                Text("No summary yet.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .task(id: self.session.updatedAt) { await self.reload() }
        .onChange(of: self.processor.busySessions) { _, _ in Task { await self.reload() } }
    }

    private func reload() async {
        self.record = try? await MeetAISidecarStore.shared.summary(for: self.session.id)
        if let saved = self.record.flatMap({ MeetAISummaryStyle(rawValue: $0.style) }) { self.style = saved }
    }

    private func regenerate() {
        MeetAISettings.shared.summaryStyle = self.style
        Task {
            await self.processor.regenerateSummary(sessionID: self.session.id, style: self.style)
            await self.reload()
        }
    }
}
```

- [ ] **Step 7: H2a — swap the Summary tab**

In `Sources/Fluid/UI/MeetingSessionCanvases.swift` (~L441) replace

```swift
                    MeetingSummaryView(session: self.session, asrService: self.summaryASRService, isQuiescent: self.isQuiescent)
```

with

```swift
                    // MeetAI H2: summaries through the user's AI provider (spec §6.4).
                    MeetAISummaryView(session: self.session)
```

Keep the following `.id(...)` modifier unchanged.

- [ ] **Step 8: Run tests, build the app, full suite, commit**

Run `MeetAISummaryTests`. Expected: 5 PASS. Then `./build.sh` (signed dev build, debug bundle ID) must succeed.

```bash
git add Sources/Fluid/MeetAI Sources/Fluid/UI/MeetAI Sources/Fluid/UI/MeetingSessionCanvases.swift Tests/FluidDictationIntegrationTests/MeetAISummaryTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add meeting summaries through the user's AI provider (Summary tab, H2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Q&A and the Ask tab (H2b)

**Files:**
- Create: `Sources/Fluid/MeetAI/MeetAIQAService.swift`, `Sources/Fluid/UI/MeetAI/MeetAIQAPanel.swift`
- Modify: `Sources/Fluid/UI/MeetingWorkspaceComponents.swift` (`MeetingDocumentSection`, `MeetingDocumentTabs`), `Sources/Fluid/UI/MeetingSessionCanvases.swift` (~L437–441)
- Test: `Tests/FluidDictationIntegrationTests/MeetAIQATests.swift`

**Interfaces:**
- Produces: `@MainActor final class MeetAIQAService: ObservableObject` — `init(sessionID:sidecars:llm:)`, `@Published records`, `isThinking`, `error`, `load() async`, `ask(_ question:, session:) async`, `clear() async`; `MeetAIQAService.systemPrompt(localLabel:) -> (String) -> String`; `MeetAIQAPanel(session:)`; `MeetingDocumentSection.ask`; `MeetingDocumentTabs(showsAsk:)`

- [ ] **Step 1: Write the failing tests** (`MeetAIQATests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIQATests: XCTestCase {
    private func session() -> MeetingSession {
        MeetAIFixtures.session(speakers: [("You", true), ("Sam", false)], lines: [.init(speaker: 1, start: 0, end: 4, text: "The launch is on Friday.")])
    }

    func testAskUsesThisSessionsTranscriptAndPersistsHistory() async throws {
        let session = self.session()
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let llm = FakeLLM(replies: ["Friday.", "Sam said it."])
        let service = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: llm)
        await service.ask("When is the launch?", session: session)
        await service.ask("Who said that?", session: session)
        XCTAssertEqual(service.records.map(\.answer), ["Friday.", "Sam said it."])
        XCTAssertTrue(llm.prompts[0].contains("The launch is on Friday."))
        XCTAssertTrue(llm.prompts[1].contains("When is the launch?"), "earlier turns go with follow-ups")

        let reopened = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: llm)
        await reopened.load()
        XCTAssertEqual(reopened.records.count, 2)
        await reopened.clear()
        let afterClear = try await sidecars.qa(for: session.id)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testAskSurfacesProviderErrorWithoutRecording() async throws {
        let session = self.session()
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let service = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: FakeLLM(error: MeetAILLMError("No AI provider is selected.")))
        await service.ask("Anything?", session: session)
        XCTAssertEqual(service.error, "No AI provider is selected.")
        XCTAssertTrue(service.records.isEmpty)
        XCTAssertFalse(service.isThinking)
    }

    func testBlankQuestionIsIgnored() async throws {
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let llm = FakeLLM(replies: ["x"])
        let service = MeetAIQAService(sessionID: UUID(), sidecars: sidecars, llm: llm)
        await service.ask("   ", session: self.session())
        XCTAssertTrue(llm.prompts.isEmpty)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAIQATests.swift
```

Run `MeetAIQATests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAIQAService.swift`**

```swift
import Combine
import Foundation

@MainActor
final class MeetAIQAService: ObservableObject {
    @Published private(set) var records: [MeetAIQARecord] = []
    @Published private(set) var isThinking = false
    @Published var error: String?

    private let sessionID: MeetingSessionID
    private let sidecars: MeetAISidecarStore
    private let llm: any MeetAILLMCompleting

    init(sessionID: MeetingSessionID, sidecars: MeetAISidecarStore = .shared, llm: any MeetAILLMCompleting = MeetAILLM()) {
        self.sessionID = sessionID
        self.sidecars = sidecars
        self.llm = llm
    }

    static func systemPrompt(localLabel: String) -> (String) -> String {
        { transcript in
            """
            You are a meeting assistant. Below is the machine-generated transcript of a finished meeting. \
            The user is labelled "\(localLabel)"; other participants are labelled by name or as "Speaker N". \
            The transcription may contain recognition errors; infer the intended meaning where it is obvious. \
            Answer the user's questions about this meeting concisely and factually. If the transcript does \
            not contain the answer, say so plainly.

            Transcript:
            \(transcript.isEmpty ? "(no speech was transcribed)" : transcript)
            """
        }
    }

    func load() async {
        self.records = (try? await self.sidecars.qa(for: self.sessionID)) ?? []
    }

    func ask(_ question: String, session: MeetingSession) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !self.isThinking else { return }
        self.error = nil
        self.isThinking = true
        defer { self.isThinking = false }
        var turns: [MeetAILLMTurn] = []
        for record in self.records.suffix(4) {
            turns.append(MeetAILLMTurn(role: "user", content: record.question))
            turns.append(MeetAILLMTurn(role: "assistant", content: record.answer))
        }
        turns.append(MeetAILLMTurn(role: "user", content: question))
        do {
            let answer = try await self.llm.completeAboutTranscript(
                transcript: MeetAITranscript.text(for: session),
                turns: turns,
                systemPrompt: Self.systemPrompt(localLabel: MeetAITranscript.localUserLabel(in: session))
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw MeetAILLMError("The AI provider returned an empty response.") }
            self.records.append(MeetAIQARecord(id: UUID(), question: question, answer: answer, askedAt: Date()))
            try await self.sidecars.saveQA(self.records, for: self.sessionID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() async {
        self.records = []
        self.error = nil
        try? await self.sidecars.saveQA([], for: self.sessionID)
    }
}
```

- [ ] **Step 4: Implement `MeetAIQAPanel.swift`**

```swift
import SwiftUI

struct MeetAIQAPanel: View {
    let session: MeetingSession

    @StateObject private var service: MeetAIQAService
    @State private var question = ""
    @Environment(\.theme) private var theme

    init(session: MeetingSession) {
        self.session = session
        self._service = StateObject(wrappedValue: MeetAIQAService(sessionID: session.id))
    }

    private var isAvailable: Bool { self.session.state == .completed }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            if !self.isAvailable {
                Text("Ask is available once this meeting has finished processing.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.service.records) { record in
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text(record.question)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    MarkdownText(markdown: record.answer)
                        .textSelection(.enabled)
                }
            }
            if self.service.isThinking {
                ProgressView("Thinking…").controlSize(.small)
            }
            if let error = self.service.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
            HStack(spacing: self.theme.metrics.spacing.sm) {
                TextField("Ask about this meeting", text: self.$question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.send() }
                Button("Ask") { self.send() }
                    .disabled(!self.isAvailable || self.service.isThinking || self.question.trimmingCharacters(in: .whitespaces).isEmpty)
                if !self.service.records.isEmpty {
                    Button("Clear") { Task { await self.service.clear() } }
                }
            }
            .disabled(!self.isAvailable)
        }
        .task { await self.service.load() }
    }

    private func send() {
        let text = self.question
        self.question = ""
        Task { await self.service.ask(text, session: self.session) }
    }
}
```

- [ ] **Step 5: H2b — add the Ask tab**

In `Sources/Fluid/UI/MeetingWorkspaceComponents.swift`:

```swift
enum MeetingDocumentSection: Hashable {
    case transcript
    case summary
    /// MeetAI H2: Q&A over a finished meeting.
    case ask
}
```

In `struct MeetingDocumentTabs`, add a property after `var isEnabled = true`:

```swift
    var showsAsk = false
```

and in its `body`, after `self.tab("Meet Summary", section: .summary, icon: "sparkles")` add:

```swift
            if self.showsAsk {
                self.tab("Ask", section: .ask, icon: "bubble.left.and.text.bubble.right")
            }
```

In `Sources/Fluid/UI/MeetingSessionCanvases.swift` (~L437) change

```swift
                    MeetingDocumentTabs(selection: self.$documentSection, isEnabled: self.summaryActivity.selectionLock == nil)
```

to

```swift
                    MeetingDocumentTabs(selection: self.$documentSection, isEnabled: self.summaryActivity.selectionLock == nil, showsAsk: true)
```

and change the section branch so it reads:

```swift
                if self.documentSection == .summary {
                    // MeetAI H2: summaries through the user's AI provider (spec §6.4).
                    MeetAISummaryView(session: self.session)
                        .id("\(self.session.id)-\(self.session.updatedAt)")
                } else if self.documentSection == .ask {
                    MeetAIQAPanel(session: self.session)
                        .id(self.session.id)
                } else {
```

(the existing `else {` transcript body stays as is).

- [ ] **Step 6: Run tests, build, full suite, commit**

Run `MeetAIQATests`. Expected: 3 PASS. `./build.sh` must succeed.

```bash
git add Sources/Fluid/MeetAI Sources/Fluid/UI/MeetAI Sources/Fluid/UI/MeetingWorkspaceComponents.swift Sources/Fluid/UI/MeetingSessionCanvases.swift Tests/FluidDictationIntegrationTests/MeetAIQATests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Add per-meeting Q&A in an Ask tab (H2)

Q&A now uses the open meeting's transcript, fixing the fork bug where it
always used the newest meeting.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: MeetAI settings sheet, known speakers, home actions (H3)

**Files:**
- Create: `Sources/Fluid/UI/MeetAI/MeetAIKnownSpeakersView.swift`, `MeetAISettingsSheet.swift`, `MeetAIHomeActions.swift`
- Modify: `Sources/Fluid/UI/MeetingTranscriptionView.swift` (`MeetingSetupCanvas.body`, ~L2096)

**Interfaces:**
- Produces: `MeetAIKnownSpeakersView()`, `MeetAISettingsSheet()`, `MeetAIHomeActions()`

This task is UI only; the logic it calls is covered by earlier tests. Verification is a build plus a manual check.

- [ ] **Step 1: `MeetAIKnownSpeakersView.swift`**

```swift
import SwiftUI

struct MeetAIKnownSpeakersView: View {
    @ObservedObject private var store = MeetAISpeakerProfileStore.shared
    @State private var pendingDelete: MeetAISpeakerProfile?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            if self.store.profiles.isEmpty {
                Text("No saved voices yet. Rename a speaker in a meeting to save their voice.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.store.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { profile in
                HStack(spacing: self.theme.metrics.spacing.md) {
                    ProfileNameField(profile: profile) { self.store.rename(id: profile.id, to: $0) }
                    Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button(role: .destructive) { self.pendingDelete = profile } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(profile.name)")
                }
            }
        }
        .confirmationDialog(
            "Delete \(self.pendingDelete?.name ?? "")'s saved voice?",
            isPresented: Binding(get: { self.pendingDelete != nil }, set: { if !$0 { self.pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = self.pendingDelete { self.store.delete(id: profile.id) }
                self.pendingDelete = nil
            }
        } message: {
            Text("Future meetings won't recognise this voice. Past meetings keep their names.")
        }
    }

    private struct ProfileNameField: View {
        let profile: MeetAISpeakerProfile
        let commit: (String) -> Void
        @State private var name = ""

        var body: some View {
            TextField("Name", text: self.$name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onAppear { self.name = self.profile.name }
                .onSubmit { self.commit(self.name) }
        }
    }
}
```

- [ ] **Step 2: `MeetAISettingsSheet.swift`**

```swift
import SwiftUI

struct MeetAISettingsSheet: View {
    @ObservedObject private var settings = MeetAISettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            Text("MeetAI")
                .font(self.theme.typography.bodyStrong)
            Form {
                Section("After each meeting") {
                    Toggle("Recognise saved voices", isOn: Binding(get: { self.settings.speakerMatching }, set: { self.settings.speakerMatching = $0 }))
                    Toggle("Name speakers from the conversation", isOn: Binding(get: { self.settings.autoName }, set: { self.settings.autoName = $0 }))
                    Toggle("Write a summary", isOn: Binding(get: { self.settings.autoSummarize }, set: { self.settings.autoSummarize = $0 }))
                    Picker("Summary style", selection: Binding(get: { self.settings.summaryStyle }, set: { self.settings.summaryStyle = $0 })) {
                        ForEach(MeetAISummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("Names, titles, summaries and answers use the provider chosen under AI Enhancement.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Section("Known speakers") {
                    MeetAIKnownSpeakersView()
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { self.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(self.theme.metrics.spacing.xl)
        .frame(minWidth: 520, minHeight: 480)
    }
}
```

- [ ] **Step 3: `MeetAIHomeActions.swift`**

```swift
import SwiftUI

struct MeetAIHomeActions: View {
    @State private var showsSettings = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Button {
                self.showsSettings = true
            } label: {
                Label("MeetAI settings…", systemImage: "gearshape")
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: self.$showsSettings) { MeetAISettingsSheet() }
    }
}
```

- [ ] **Step 4: H3 — place the actions on the meeting home**

In `MeetingSetupCanvas.body` (`Sources/Fluid/UI/MeetingTranscriptionView.swift` ~L2096) replace

```swift
            } else {
                self.recordingSetup
            }
```

with

```swift
            } else {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    self.recordingSetup
                    // MeetAI H3: import and MeetAI settings.
                    MeetAIHomeActions()
                }
            }
```

- [ ] **Step 5: Build and check by hand**

```bash
./build.sh
```

Launch `DerivedData/Build/Products/Debug/FluidVoice Debug.app`, open the meeting home, click "MeetAI settings…", toggle each switch, close and reopen the sheet (toggles persist), and take a screenshot of the sheet. Expected: sheet shows the four controls and the Known speakers section.

- [ ] **Step 6: Full suite, commit**

```bash
git add Sources/Fluid/UI/MeetAI Sources/Fluid/UI/MeetingTranscriptionView.swift
git commit -m "Add the MeetAI settings sheet and known-speakers list on the meeting home (H3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Import audio as a meeting

**Files:**
- Create: `Sources/Fluid/MeetAI/Import/MeetAIAudioImporter.swift`
- Modify: `Sources/Fluid/UI/MeetAI/MeetAIHomeActions.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAIImporterTests.swift`

**Interfaces:**
- Consumes: `MeetAIAudioDecoder.decode(url:)`, `MeetAISessionImport.createAudioSession`
- Produces: `@MainActor final class MeetAIAudioImporter: ObservableObject` — `.shared`, `enum Status { idle, working(String), failed(String), done(String) }`, `init(store:retry:)`, `importFile(_ url: URL) async`

- [ ] **Step 1: Write the failing tests** (`MeetAIImporterTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIImporterTests: XCTestCase {
    func testUndecodableFileLeavesNoSession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        var retried: [MeetingSessionID] = []
        let importer = MeetAIAudioImporter(store: store, retry: { retried.append($0) })
        let bogus = root.appendingPathComponent("voice-note.wav")
        try Data("definitely not audio".utf8).write(to: bogus)
        await importer.importFile(bogus)
        guard case let .failed(message) = importer.status else { return XCTFail("expected failure, got \(importer.status)") }
        XCTAssertTrue(message.contains("voice-note.wav"))
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(retried.isEmpty)
    }

    func testImportCreatesTitledSessionAndStartsProcessing() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(
            samples: (0..<(16_000 * 3)).map { 0.2 * sin(Float($0) / 10) }, kind: .microphone, sessionDirectory: chunkDirectory
        )
        let source = root.appendingPathComponent("Team Sync.wav")
        try FileManager.default.copyItem(at: chunks[0].fileURL(relativeTo: chunkDirectory), to: source)
        var retried: [MeetingSessionID] = []
        let importer = MeetAIAudioImporter(store: store, retry: { retried.append($0) })
        await importer.importFile(source)
        let sessions = try await store.loadAll()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Team Sync")
        XCTAssertEqual(retried, sessions.map(\.id))
        guard case .done = importer.status else { return XCTFail("expected done, got \(importer.status)") }
    }

    func testTooShortAudioIsRejected() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(samples: [Float](repeating: 0.1, count: 8_000), kind: .microphone, sessionDirectory: chunkDirectory)
        let importer = MeetAIAudioImporter(store: store, retry: { _ in })
        await importer.importFile(chunks[0].fileURL(relativeTo: chunkDirectory))
        guard case .failed = importer.status else { return XCTFail("expected failure") }
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAIImporterTests.swift
```

Run `MeetAIImporterTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAIAudioImporter.swift`**

```swift
import Combine
import Foundation

@MainActor
final class MeetAIAudioImporter: ObservableObject {
    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done(String)
    }

    static let shared = MeetAIAudioImporter(
        store: MeetingSessionStore.shared,
        retry: { try await AppServices.shared.meetingSessionCoordinator.retryProcessing(sessionID: $0) }
    )

    @Published private(set) var status: Status = .idle

    private let store: any MeetingSessionStoring
    private let retry: @MainActor (MeetingSessionID) async throws -> Void

    init(store: any MeetingSessionStoring, retry: @escaping @MainActor (MeetingSessionID) async throws -> Void) {
        self.store = store
        self.retry = retry
    }

    func importFile(_ url: URL) async {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        self.status = .working("Reading \(name)…")
        let samples: [Float]
        do {
            samples = try await MeetAIAudioDecoder.decode(url: url)
        } catch {
            self.status = .failed(error.localizedDescription)
            return
        }
        guard samples.count >= Int(MeetAISyntheticSessionBuilder.sampleRate) else {
            self.status = .failed("\(name) is shorter than one second.")
            return
        }

        let title = url.deletingPathExtension().lastPathComponent
        let startedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let session: MeetingSession
        do {
            session = try await MeetAISessionImport.createAudioSession(
                store: self.store,
                title: title,
                languageCode: SettingsStore.shared.meetingRecordingDefaults.languageCode ?? "en",
                startedAt: startedAt,
                tracks: [.init(kind: .microphone, samples: samples, echoProtection: .acousticallyClosed)]
            )
        } catch {
            self.status = .failed(error.localizedDescription)
            return
        }

        self.status = .working("Transcribing \(title)…")
        do {
            try await self.retry(session.id)
            self.status = .done("Imported \(title).")
        } catch {
            // The session stays saved and retryable from the meeting's own recovery controls.
            self.status = .failed("Saved \(title), but processing failed: \(error.localizedDescription) You can retry from the meeting.")
        }
    }
}
```

- [ ] **Step 4: Add the import button** — replace `MeetAIHomeActions.swift` with:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct MeetAIHomeActions: View {
    @ObservedObject private var importer = MeetAIAudioImporter.shared
    @State private var showsSettings = false
    @State private var showsImporter = false
    @Environment(\.theme) private var theme

    private var isWorking: Bool {
        if case .working = self.importer.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Button {
                    self.showsImporter = true
                } label: {
                    Label("Import audio as meeting…", systemImage: "square.and.arrow.down")
                }
                .disabled(self.isWorking)
                Button {
                    self.showsSettings = true
                } label: {
                    Label("MeetAI settings…", systemImage: "gearshape")
                }
                Spacer(minLength: 0)
            }
            switch self.importer.status {
            case .idle:
                EmptyView()
            case let .working(message):
                ProgressView(message).controlSize(.small)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            case let .done(message):
                Label(message, systemImage: "checkmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .sheet(isPresented: self.$showsSettings) { MeetAISettingsSheet() }
        .fileImporter(isPresented: self.$showsImporter, allowedContentTypes: [.audio, .movie]) { result in
            guard case let .success(url) = result else { return }
            Task { await self.importer.importFile(url) }
        }
    }
}
```

- [ ] **Step 5: Run tests, build, manual check, full suite, commit**

Run `MeetAIImporterTests`. Expected: 3 PASS. `./build.sh`, launch the debug app, import a short `.m4a` (e.g. a Voice Memo), and confirm a meeting titled with the file name appears and finishes processing with a transcript.

```bash
git add Sources/Fluid/MeetAI/Import Sources/Fluid/UI/MeetAI/MeetAIHomeActions.swift Tests/FluidDictationIntegrationTests/MeetAIImporterTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Import an audio file as a FluidMeet meeting

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Migration Tier 1 — transcript-only import of old meetings

**Files:**
- Create: `Sources/Fluid/MeetAI/Migration/MeetAILegacyTranscriptParser.swift`, `Sources/Fluid/MeetAI/Migration/MeetAIMigrator.swift`
- Modify: `Sources/Fluid/MeetAI/MeetAIBootstrap.swift`, `Sources/Fluid/UI/MeetAI/MeetAISettingsSheet.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAIMigrationTests.swift`

**Interfaces:**
- Produces:
  - `MeetAILegacyTranscriptParser.Parsed { speakers: [LegacySpeaker]; segments: [LegacySegment]; duration: TimeInterval? }`, `.parse(_:) -> Parsed`, `.stripTitleSuffix(_:) -> String`
  - `MeetAIMigrationEntry { status: Status (done|skipped|failed); sessionID; reason; migratedAt; reprocessedAt }`
  - `@MainActor final class MeetAIMigrator: ObservableObject` — `init(paths:store:sidecars:)`, `.shared`, `@Published entries: [String: MeetAIMigrationEntry]`, `@Published isRunning`, `loadEntries()`, `run(retryFailed:) async`, `static sessionID(forFolder:) -> MeetingSessionID`

- [ ] **Step 1: Write the failing tests** (`MeetAIMigrationTests.swift`)

```swift
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIMigrationTests: XCTestCase {
    private let sampleTranscript = """
    # Meeting 2026-10-15T06:00:44

    - Started: 15 Oct 2026 at 4:30 pm
    - Duration: 03:23

    **[00:00] Girish:** But I'm thinking

    **[00:01] Girish:** Can we get other frontier models as well

    **[00:04] Me:** Sure, Girish.

    **[61:05] Them 2:** Late point
    with a wrapped line
    """

    func testParserReadsSpeakersSegmentsAndDuration() {
        let parsed = MeetAILegacyTranscriptParser.parse(self.sampleTranscript)
        XCTAssertEqual(parsed.duration, 203)
        XCTAssertEqual(parsed.speakers.map(\.label), ["Girish", "Me", "Them 2"])
        XCTAssertEqual(parsed.speakers.first { $0.label == "Me" }?.isLocalUser, true)
        XCTAssertEqual(parsed.segments.map(\.start), [0, 1, 4, 3_665])
        XCTAssertEqual(parsed.segments[0].end, 1)
        XCTAssertEqual(parsed.segments.last?.text, "Late point\nwith a wrapped line")
    }

    func testParserHandlesOddLines() {
        let parsed = MeetAILegacyTranscriptParser.parse("""
        Some header without format

        **[00:05] Dr: Lee:** Colon in the name
        **[00:05] Sam:** Same timestamp
        **[1:02:03] Sam:** Hours format

        """)
        XCTAssertEqual(parsed.segments.map(\.speakerLabel), ["Dr: Lee", "Sam", "Sam"])
        XCTAssertEqual(parsed.segments.map(\.text), ["Colon in the name", "Same timestamp", "Hours format"])
        XCTAssertEqual(parsed.segments[2].start, 3_723)
        XCTAssertTrue(parsed.segments.allSatisfy { $0.end > $0.start })
        XCTAssertNil(parsed.duration)
    }

    func testTitleSuffixIsStripped() {
        XCTAssertEqual(MeetAILegacyTranscriptParser.stripTitleSuffix("Comparison of Frontier Models (Thu, 15 Oct at 4:30 pm)"), "Comparison of Frontier Models")
        XCTAssertEqual(MeetAILegacyTranscriptParser.stripTitleSuffix("Plain title"), "Plain title")
    }

    private func makeLegacyFolder(_ root: URL, name: String, transcript: String?, summary: String? = nil, title: String? = nil, speakers: [String: [Float]]? = nil) throws {
        let folder = root.appendingPathComponent("MeetingRecordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let transcript { try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        if let summary { try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        if let title { try title.write(to: folder.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8) }
        if let speakers { try JSONEncoder().encode(speakers).write(to: folder.appendingPathComponent("speakers.json")) }
        let session = """
        {"startedAt":"\(name)Z","endedAt":"\(name.prefix(17))59Z"}
        """
        try session.write(to: folder.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    }

    func testMigratorImportsSkipsAndIsIdempotent() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        try self.makeLegacyFolder(root, name: "2026-10-15T06:00:44", transcript: self.sampleTranscript,
                                  summary: "# Meeting summary — x\n\n## Overview\nModels.", title: "Frontier Models (Thu, 15 Oct at 4:30 pm)",
                                  speakers: ["Girish": [0.6, 0.8]])
        try self.makeLegacyFolder(root, name: "2026-07-13T00:22:00", transcript: nil)
        let before = try Data(contentsOf: paths.legacyMeetingsDirectory.appendingPathComponent("2026-10-15T06:00:44/transcript.md"))

        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: paths)
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await migrator.run()

        XCTAssertEqual(migrator.entries["2026-10-15T06:00:44"]?.status, .done)
        XCTAssertEqual(migrator.entries["2026-07-13T00:22:00"]?.status, .skipped)
        let id = MeetAIMigrator.sessionID(forFolder: "2026-10-15T06:00:44")
        let session = try await XCTUnwrapAsync(await store.load(id: id))
        XCTAssertEqual(session.title, "Frontier Models")
        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.transcriptSegments.count, 4)
        let summary = try await sidecars.summary(for: id)
        XCTAssertEqual(summary?.markdown, "## Overview\nModels.")
        XCTAssertEqual(summary?.style, "migrated")
        XCTAssertEqual(summary?.transcriptHash, MeetAITranscript.hash(for: session))
        let girish = try XCTUnwrap(session.speakers.first { $0.displayName == "Girish" })
        let records = try await sidecars.speakers(for: id)
        XCTAssertEqual(records[girish.id]?.nameSource, .user)
        XCTAssertEqual(records[girish.id]?.lastAppliedName, "Girish")
        XCTAssertNotNil(records[girish.id]?.embedding)
        let meta = try await sidecars.meta(for: id)
        XCTAssertEqual(meta.lastLLMTitle, "Frontier Models")

        let second = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await second.run()
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1, "re-running never duplicates")
        let after = try Data(contentsOf: paths.legacyMeetingsDirectory.appendingPathComponent("2026-10-15T06:00:44/transcript.md"))
        XCTAssertEqual(before, after, "legacy files are read only")
    }

    /// Opt-in dry run on a COPY of real data: TEST_RUNNER_MEETAI_LEGACY_ROOT="$HOME/Library/Application Support/FluidVoice"
    func testDryRunOnCopyOfRealData() async throws {
        guard let source = ProcessInfo.processInfo.environment["MEETAI_LEGACY_ROOT"] else { throw XCTSkip("dry run") }
        let root = try MeetAIFixtures.tempDirectory(self, "meetai-dryrun")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("MeetingRecordings"), to: root.appendingPathComponent("MeetingRecordings"))
        let paths = MeetAIPaths(supportRoot: root)
        let migrator = MeetAIMigrator(paths: paths, store: MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings")), sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        let byStatus = Dictionary(grouping: migrator.entries.values, by: \.status)
        let folders = try FileManager.default.contentsOfDirectory(atPath: paths.legacyMeetingsDirectory.path).filter { !$0.hasPrefix(".") }
        print("MEETAI-DRYRUN folders=\(folders.count) done=\(byStatus[.done]?.count ?? 0) skipped=\(byStatus[.skipped]?.count ?? 0) failed=\(byStatus[.failed]?.count ?? 0)")
        for (folder, entry) in migrator.entries.sorted(by: { $0.key < $1.key }) where entry.status != .done {
            print("MEETAI-DRYRUN \(entry.status.rawValue) \(folder): \(entry.reason ?? "")")
        }
        XCTAssertEqual(byStatus[.failed]?.count ?? 0, 0)
        XCTAssertEqual(migrator.entries.count, folders.count)
    }
}
```

- [ ] **Step 2: Register and verify failure**

```bash
python3 scripts/add_test_file_to_xcodeproj.py MeetAIMigrationTests.swift
```

Run `MeetAIMigrationTests`. Expected: build FAIL.

- [ ] **Step 3: Implement `MeetAILegacyTranscriptParser.swift`**

```swift
import Foundation

/// Parses the fork's `transcript.md` (`**[MM:SS] Speaker:** text`; minutes may exceed 59; H:MM:SS also accepted).
nonisolated enum MeetAILegacyTranscriptParser {
    struct Parsed: Equatable, Sendable {
        var speakers: [MeetAISyntheticSessionBuilder.LegacySpeaker]
        var segments: [MeetAISyntheticSessionBuilder.LegacySegment]
        var duration: TimeInterval?
    }

    static let localLabel = "Me"
    static let minimumSegmentSeconds: TimeInterval = 0.5
    static let lastSegmentFallbackSeconds: TimeInterval = 5

    private static let linePattern = try! NSRegularExpression(pattern: #"^\*\*\[(\d+):(\d{2})(?::(\d{2}))?\] (.+?):\*\* ?(.*)$"#)
    private static let durationPattern = try! NSRegularExpression(pattern: #"^- Duration: (\d+):(\d{2})(?::(\d{2}))?\s*$"#)

    static func parse(_ markdown: String) -> Parsed {
        var starts: [(start: TimeInterval, label: String, text: String)] = []
        var duration: TimeInterval?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = self.match(self.linePattern, line) {
                starts.append((self.seconds(match, 1, 2, 3), match[4], match[5]))
            } else if let match = self.match(self.durationPattern, line) {
                duration = self.seconds(match, 1, 2, 3)
            } else if !line.isEmpty, !starts.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("- ") {
                starts[starts.count - 1].text += "\n" + line
            }
        }
        var speakers: [MeetAISyntheticSessionBuilder.LegacySpeaker] = []
        var seen = Set<String>()
        var segments: [MeetAISyntheticSessionBuilder.LegacySegment] = []
        for (index, entry) in starts.enumerated() {
            if seen.insert(entry.label).inserted {
                speakers.append(.init(label: entry.label, isLocalUser: entry.label == self.localLabel))
            }
            let next = index + 1 < starts.count ? starts[index + 1].start : (duration ?? entry.start + self.lastSegmentFallbackSeconds)
            segments.append(.init(
                start: entry.start,
                end: max(next, entry.start + self.minimumSegmentSeconds),
                speakerLabel: entry.label,
                text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return Parsed(speakers: speakers, segments: segments, duration: duration)
    }

    /// "Short title (Thu, 15 Oct at 4:30 pm)" → "Short title".
    static func stripTitleSuffix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? trimmed : stripped
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let result = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Groups (a, b, c): "a:b" = minutes:seconds, "a:b:c" = hours:minutes:seconds.
    private static func seconds(_ match: [String], _ a: Int, _ b: Int, _ c: Int) -> TimeInterval {
        let first = Double(match[a]) ?? 0, second = Double(match[b]) ?? 0
        if !match[c].isEmpty { return first * 3_600 + second * 60 + (Double(match[c]) ?? 0) }
        return first * 60 + second
    }
}
```

- [ ] **Step 4: Implement `MeetAIMigrator.swift`**

```swift
import Combine
import CryptoKit
import Foundation

nonisolated struct MeetAIMigrationEntry: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case done, skipped, failed }
    var status: Status
    var sessionID: MeetingSessionID?
    var reason: String?
    var migratedAt: Date
    var reprocessedAt: Date?
}

/// Spec §7: imports the fork's MeetingRecordings into FluidMeet. Reads legacy files only.
@MainActor
final class MeetAIMigrator: ObservableObject {
    static let shared = MeetAIMigrator(paths: .standard(), store: MeetingSessionStore.shared, sidecars: .shared)

    @Published private(set) var entries: [String: MeetAIMigrationEntry] = [:]
    @Published private(set) var isRunning = false

    let paths: MeetAIPaths
    let store: any MeetingSessionStoring
    let sidecars: MeetAISidecarStore

    init(paths: MeetAIPaths, store: any MeetingSessionStoring, sidecars: MeetAISidecarStore) {
        self.paths = paths
        self.store = store
        self.sidecars = sidecars
    }

    /// Deterministic per folder so an interrupted run never duplicates (spec §12.7).
    static func sessionID(forFolder folder: String) -> MeetingSessionID {
        var bytes = Array(SHA256.hash(data: Data("meetai-legacy:\(folder)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func loadEntries() {
        guard let data = try? Data(contentsOf: self.paths.migrationFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.entries = (try? decoder.decode([String: MeetAIMigrationEntry].self, from: data)) ?? [:]
    }

    private func saveEntries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: self.paths.migrationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self.entries).write(to: self.paths.migrationFile, options: .atomic)
        } catch {
            DebugLogger.shared.warning("Saving MeetAI migration state failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func run(retryFailed: Bool = false) async {
        guard !self.isRunning else { return }
        self.isRunning = true
        defer { self.isRunning = false }
        self.loadEntries()
        let directory = self.paths.legacyMeetingsDirectory
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for folder in folders.filter({ !$0.hasPrefix(".") }).sorted() {
            if let entry = self.entries[folder] {
                if entry.status == .done || entry.status == .skipped { continue }
                if entry.status == .failed, !retryFailed { continue }
            }
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            do {
                if let id = try await self.migrate(folder: folder, url: url) {
                    self.entries[folder] = MeetAIMigrationEntry(status: .done, sessionID: id, reason: nil, migratedAt: Date())
                }
            } catch let skip as SkipReason {
                self.entries[folder] = MeetAIMigrationEntry(status: .skipped, sessionID: nil, reason: skip.message, migratedAt: Date())
            } catch {
                self.entries[folder] = MeetAIMigrationEntry(status: .failed, sessionID: nil, reason: error.localizedDescription, migratedAt: Date())
            }
            self.saveEntries()
        }
    }

    struct SkipReason: Error {
        let message: String
    }

    private func migrate(folder: String, url: URL) async throws -> MeetingSessionID? {
        let id = Self.sessionID(forFolder: folder)
        if try await self.store.load(id: id) != nil { return id }
        guard let markdown = try? String(contentsOf: url.appendingPathComponent("transcript.md"), encoding: .utf8) else {
            throw SkipReason(message: "No transcript.md")
        }
        let parsed = MeetAILegacyTranscriptParser.parse(markdown)
        guard !parsed.segments.isEmpty else { throw SkipReason(message: "Transcript has no lines") }

        let manifest = Self.readManifest(url.appendingPathComponent("session.json"))
        let startedAt = manifest.startedAt ?? Self.folderDate(folder) ?? Date()
        let endedAt = manifest.endedAt
            ?? parsed.duration.map { startedAt.addingTimeInterval($0) }
            ?? startedAt.addingTimeInterval(parsed.segments.last?.end ?? 0)
        let rawTitle = (try? String(contentsOf: url.appendingPathComponent("title.txt"), encoding: .utf8)) ?? ""
        let title = rawTitle.isEmpty
            ? "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))"
            : MeetAILegacyTranscriptParser.stripTitleSuffix(rawTitle)

        let session = MeetAISyntheticSessionBuilder.transcriptOnlySession(
            id: id, title: title, startedAt: startedAt, endedAt: endedAt,
            speakers: parsed.speakers, segments: parsed.segments, audioDeletedAt: endedAt
        )
        try await self.store.create(session)

        if let summary = try? String(contentsOf: url.appendingPathComponent("summary.md"), encoding: .utf8) {
            let body = summary.components(separatedBy: "\n")
                .drop { $0.hasPrefix("# Meeting summary") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let modified = (try? url.appendingPathComponent("summary.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? endedAt
                try await self.sidecars.saveSummary(MeetAISummaryRecord(
                    style: "migrated", transcriptHash: MeetAITranscript.hash(for: session), markdown: body,
                    providerID: "migrated", modelID: "migrated", createdAt: modified
                ), for: id)
            }
        }

        let centroids = (try? JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: url.appendingPathComponent("speakers.json")))) ?? [:]
        var records: [SessionSpeakerID: MeetAISpeakerRecord] = [:]
        for speaker in session.speakers where !speaker.isLocalUser {
            let isNamed = !MeetAITranscript.isDefaultSpeakerName(speaker.displayName)
            records[speaker.id] = MeetAISpeakerRecord(
                embedding: centroids[speaker.displayName].map(MeetAISpeakerMath.normalize),
                matchedProfileID: nil,
                nameSource: isNamed ? .user : nil,
                lastAppliedName: isNamed ? speaker.displayName : nil
            )
        }
        try await self.sidecars.saveSpeakers(records, for: id)
        try await self.sidecars.saveMeta(MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: title), for: id)
        return id
    }

    private static func readManifest(_ url: URL) -> (startedAt: Date?, endedAt: Date?) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let formatter = ISO8601DateFormatter()
        return ((json["startedAt"] as? String).flatMap(formatter.date(from:)), (json["endedAt"] as? String).flatMap(formatter.date(from:)))
    }

    /// Folder names are UTC ISO-8601 timestamps without the zone, e.g. 2026-10-15T06:00:44.
    private static func folderDate(_ folder: String) -> Date? {
        ISO8601DateFormatter().date(from: folder + "Z")
    }
}
```

- [ ] **Step 5: Run migration at launch** — in `MeetAIBootstrap.start()`, replace `Task { await self.sweepOrphanedSidecars() }` with:

```swift
        Task {
            await self.sweepOrphanedSidecars()
            await MeetAIMigrator.shared.run()
        }
```

(The sweep runs first so it cannot delete sidecars that migration is about to write: migrated sessions are created in the store before their sidecars.)

- [ ] **Step 6: Migration section in the settings sheet** — in `MeetAISettingsSheet`, add `@ObservedObject private var migrator = MeetAIMigrator.shared` and, after the "Known speakers" section, add:

```swift
                Section("Meetings from the previous MeetAI version") {
                    Text("Imported \(self.count(.done)) · skipped \(self.count(.skipped)) · failed \(self.count(.failed))")
                    ForEach(self.folders { $0.status != .done }, id: \.self) { folder in
                        Text("\(self.migrator.entries[folder]?.status.rawValue.capitalized ?? ""): \(folder) — \(self.migrator.entries[folder]?.reason ?? "")")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Button(self.migrator.isRunning ? "Importing…" : "Re-run migration") {
                        Task { await self.migrator.run(retryFailed: true) }
                    }
                    .disabled(self.migrator.isRunning)
                }
```

add `.task { self.migrator.loadEntries() }` to the sheet's outer `VStack`, and add these helpers to `MeetAISettingsSheet` (dictionary tuples are not used directly in `ForEach`):

```swift
    private func count(_ status: MeetAIMigrationEntry.Status) -> Int {
        self.migrator.entries.values.filter { $0.status == status }.count
    }

    private func folders(where predicate: (MeetAIMigrationEntry) -> Bool) -> [String] {
        self.migrator.entries.filter { predicate($0.value) }.map(\.key).sorted()
    }
```

- [ ] **Step 7: Run tests, then the dry run on a copy of the real data**

Run `MeetAIMigrationTests`. Expected: 4 PASS, 1 SKIP. Then:

```bash
TEST_RUNNER_MEETAI_LEGACY_ROOT="$HOME/Library/Application Support/FluidVoice" xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -only-testing:FluidDictationIntegrationTests/MeetAIMigrationTests/testDryRunOnCopyOfRealData CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "MEETAI-DRYRUN|Test Case|error:"
```

Expected (inventory of 2026-10-16): `folders=113 done=109 skipped=4 failed=0`, with the 4 skipped folders listed. Record the printed lines in the commit message; they go into the PR description in Task 16.

- [ ] **Step 8: Full suite, commit**

```bash
git add Sources/Fluid/MeetAI Sources/Fluid/UI/MeetAI/MeetAISettingsSheet.swift Tests/FluidDictationIntegrationTests/MeetAIMigrationTests.swift Fluid.xcodeproj/project.pbxproj
git commit -m "Migrate old MeetAI meetings into FluidMeet (transcript-only, Tier 1)

Dry run on a copy of real data: <paste MEETAI-DRYRUN lines here>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Migration Tier 2 — re-process old meetings that still have audio

**Files:**
- Modify: `Sources/Fluid/MeetAI/Migration/MeetAIMigrator.swift`, `Sources/Fluid/UI/MeetAI/MeetAISettingsSheet.swift`
- Test: `Tests/FluidDictationIntegrationTests/MeetAIMigrationTests.swift` (append)

**Interfaces:**
- Produces: `MeetAIMigrator.hasLegacyAudio(folder:) -> Bool`, `MeetAIMigrator.reprocess(folder:retry:) async throws -> MeetingSessionID`

- [ ] **Step 1: Write the failing tests** (append to `MeetAIMigrationTests`)

```swift
    private func writeWAV(_ url: URL, seconds: Double, frequency: Float) throws {
        let directory = url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(
            samples: (0..<Int(seconds * 16_000)).map { 0.2 * sin(2 * .pi * frequency * Float($0) / 16_000) },
            kind: .microphone, sessionDirectory: directory
        )
        try FileManager.default.moveItem(at: chunks[0].fileURL(relativeTo: directory), to: url)
        try FileManager.default.removeItem(at: directory)
    }

    func testReprocessReplacesTranscriptOnlySession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript, title: "Frontier Models (Thu, 15 Oct at 4:30 pm)")
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        XCTAssertTrue(migrator.hasLegacyAudio(folder: folderName))
        let oldID = try XCTUnwrap(migrator.entries[folderName]?.sessionID)

        var retried: [MeetingSessionID] = []
        let newID = try await migrator.reprocess(folder: folderName, retry: { retried.append($0) })
        XCTAssertEqual(retried, [newID])
        let oldSession = try await store.load(id: oldID)
        XCTAssertNil(oldSession, "old transcript-only session removed")
        let replacement = try await XCTUnwrapAsync(await store.load(id: newID))
        XCTAssertEqual(replacement.mode, .onlineCall)
        XCTAssertEqual(replacement.title, "Frontier Models")
        XCTAssertEqual(migrator.entries[folderName]?.sessionID, newID)
        XCTAssertNotNil(migrator.entries[folderName]?.reprocessedAt)
    }

    func testReprocessFailureKeepsOldSession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript)
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        let oldID = try XCTUnwrap(migrator.entries[folderName]?.sessionID)
        do {
            _ = try await migrator.reprocess(folder: folderName, retry: { _ in throw MeetingCoordinatorError.activityInProgress })
            XCTFail("expected failure")
        } catch {}
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [oldID], "new session deleted, old kept")
        XCTAssertEqual(migrator.entries[folderName]?.sessionID, oldID)
    }
```

- [ ] **Step 2: Verify failure**

Run `MeetAIMigrationTests`. Expected: build FAIL ("value of type 'MeetAIMigrator' has no member 'reprocess'").

- [ ] **Step 3: Implement** — add to `MeetAIMigrator`:

```swift
    func hasLegacyAudio(folder: String) -> Bool {
        let url = self.paths.legacyMeetingsDirectory.appendingPathComponent(folder, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("system.wav").path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("mic.wav").path)
    }

    /// Tier 2 (spec §7.2, §12.8): rebuild the meeting from the fork's two WAVs and run FluidMeet's
    /// pipeline. On success the transcript-only session is replaced; on failure the new one is deleted.
    func reprocess(folder: String, retry: @MainActor (MeetingSessionID) async throws -> Void) async throws -> MeetingSessionID {
        guard let entry = self.entries[folder], entry.status == .done, let oldID = entry.sessionID else {
            throw MeetAILLMError("This meeting hasn't been imported yet.")
        }
        guard self.hasLegacyAudio(folder: folder) else { throw MeetAILLMError("The original audio for this meeting is gone.") }
        let url = self.paths.legacyMeetingsDirectory.appendingPathComponent(folder, isDirectory: true)
        let old = try await self.store.load(id: oldID)
        let system = try await MeetAIAudioDecoder.decode(url: url.appendingPathComponent("system.wav"))
        let microphone = try await MeetAIAudioDecoder.decode(url: url.appendingPathComponent("mic.wav"))
        let session = try await MeetAISessionImport.createAudioSession(
            store: self.store,
            title: old?.title ?? folder,
            languageCode: old?.languageCode ?? "en",
            startedAt: old?.startedAt ?? Date(),
            tracks: [
                .init(kind: .applicationAudio, samples: system, echoProtection: .unprotected),
                .init(kind: .microphone, samples: microphone, echoProtection: .legacyUnclassified),
            ]
        )
        do {
            try await retry(session.id)
        } catch {
            try? await self.store.delete(id: session.id)
            try? await self.sidecars.removeAll(for: session.id)
            throw error
        }
        try? await self.store.delete(id: oldID)
        try? await self.sidecars.removeAll(for: oldID)
        self.entries[folder]?.sessionID = session.id
        self.entries[folder]?.reprocessedAt = Date()
        self.saveEntries()
        return session.id
    }
```

Note: the in-app retry goes through `AppServices.shared.meetingSessionCoordinator.retryProcessing`, which fires H1 for the new session, so speakers are matched to saved voices as for a live meeting.

- [ ] **Step 4: UI** — in the settings sheet's migration section, after the counts `Text`, add a list of re-processable meetings with a confirmation:

```swift
                    ForEach(self.folders { $0.status == .done }.filter { self.migrator.hasLegacyAudio(folder: $0) }, id: \.self) { folder in
                        HStack {
                            Text(folder).font(self.theme.typography.caption)
                            if self.migrator.entries[folder]?.reprocessedAt != nil {
                                Text("re-processed").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                            }
                            Spacer()
                            Button("Re-process…") { self.pendingReprocess = folder }
                                .disabled(self.reprocessing != nil)
                        }
                    }
                    if let message = self.reprocessMessage {
                        Text(message).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    }
```

Add state and the dialog to `MeetAISettingsSheet`:

```swift
    @State private var pendingReprocess: String?
    @State private var reprocessing: String?
    @State private var reprocessMessage: String?
```

```swift
        .confirmationDialog(
            "Re-process this meeting with FluidMeet?",
            isPresented: Binding(get: { self.pendingReprocess != nil }, set: { if !$0 { self.pendingReprocess = nil } })
        ) {
            Button("Re-process") {
                guard let folder = self.pendingReprocess else { return }
                self.pendingReprocess = nil
                self.reprocessing = folder
                self.reprocessMessage = "Re-processing \(folder)…"
                Task {
                    do {
                        _ = try await self.migrator.reprocess(folder: folder, retry: {
                            try await AppServices.shared.meetingSessionCoordinator.retryProcessing(sessionID: $0)
                        })
                        self.reprocessMessage = "Re-processed \(folder)."
                    } catch {
                        self.reprocessMessage = "Couldn't re-process \(folder): \(error.localizedDescription)"
                    }
                    self.reprocessing = nil
                }
            }
        } message: {
            Text("The transcript will be replaced with a new one from the original audio. Speaker names come back where voices match saved speakers. This can take several minutes.")
        }
```

- [ ] **Step 5: Run tests, full suite, commit**

Run `MeetAIMigrationTests`. Expected: 6 PASS, 1 SKIP.

```bash
git add Sources/Fluid/MeetAI/Migration Sources/Fluid/UI/MeetAI/MeetAISettingsSheet.swift Tests/FluidDictationIntegrationTests/MeetAIMigrationTests.swift
git commit -m "Re-process old meetings that still have audio with FluidMeet (Tier 2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Docs, install, and end-to-end verification

**Files:**
- Create: `docs/MEETAI.md`
- Modify: spec §11 (verification results)

- [ ] **Step 1: Write `docs/MEETAI.md`**

```markdown
# MeetAI layer

MeetAI adds meeting features to upstream FluidVoice's FluidMeet without changing how FluidMeet records or transcribes.

## What it adds
- Persistent speakers: voices you name are recognised in later meetings (cosine ≥ 0.7, WeSpeaker embeddings).
- LLM speaker naming from introductions, LLM titles, summaries in four styles, and per-meeting Q&A, all through the AI Enhancement provider.
- Import an audio file as a meeting.
- One-time migration of meetings recorded by the previous MeetAI version, plus optional re-processing of the ones that still have audio.

## Where things live
- Code: `Sources/Fluid/MeetAI/`, `Sources/Fluid/UI/MeetAI/`.
- Data: `~/Library/Application Support/FluidVoice/MeetAI/` (`SpeakerProfiles/profiles.json`, `Sessions/<id>/{summary,qa,speakers,meta}.json`, `migration.json`).
- Settings: UserDefaults `MeetAIAutoSummarize`, `MeetAISummaryStyle`, `MeetAIAutoName`, `MeetAISpeakerMatching`.

## Hook points in upstream files (check these when merging upstream)
| # | File | What |
|---|---|---|
| H1 | `Services/Meeting/MeetingSessionCoordinator.swift` (completion, before `sweepExpiredAudio`) | `await MeetAIHooks.runSessionDidComplete(session)` |
| H2 | `UI/MeetingSessionCanvases.swift`, `UI/MeetingWorkspaceComponents.swift` | Summary tab → `MeetAISummaryView`; `MeetingDocumentSection.ask` + `MeetingDocumentTabs(showsAsk:)` → `MeetAIQAPanel` |
| H3 | `UI/MeetingTranscriptionView.swift` (`MeetingSetupCanvas.body`) | `MeetAIHomeActions()` |
| H4 | `AppDelegate.swift` | `MeetAIBootstrap.start()`; updater guarded by `MeetAIBuildFlags.updaterEnabled` |
| H5 | `Services/SimpleUpdater.swift` | updater entry points return when disabled |
| H6 | `Services/Meeting/MeetingSessionCoordinator.swift` (`performCorrection`) | `MeetAIHooks.notifySessionCorrected(target)` |
| — | `build.sh` | `install` profile with the release bundle ID |

## Updating from upstream
Merge the new upstream tag into the fork's `main`, then into the MeetAI branch; resolve conflicts only at the hook points above; run the full suite and compare the failing set with the previous baseline.
```

- [ ] **Step 2: Full suite** — run the full-suite command. Expected: the failing set is the spec §11 baseline (or a subset). Record the executed/failed counts.

- [ ] **Step 3: Back up user data before the first real install** — ask the user before running this step (it replaces their installed app):

```bash
ditto "$HOME/Library/Application Support/FluidVoice" "$HOME/FluidVoice-backup-$(date +%Y%m%d)"
defaults export com.FluidApp.app "$HOME/FluidVoice-backup-$(date +%Y%m%d)/com.FluidApp.app.plist"
```

- [ ] **Step 4: Install** (with the user's go-ahead)

```bash
./build.sh install
```

Expected: `Installed /Applications/FluidVoice.app (com.FluidApp.app)`. Relaunch the app. The first launch of this signed build may re-prompt for Microphone, Accessibility and Screen & System Audio permissions; that's expected once.

- [ ] **Step 5: Manual checklist** (drive what can be driven; list what needs the user)

1. Meetings list shows migrated meetings (expect 109) with transcripts and Summary; Ask answers about the open meeting.
2. Record a short real call with a known person: the speaker is auto-named from the saved voice, an unknown speaker who introduces themselves is LLM-named, a title is set, and the summary appears.
3. Rename an unknown speaker; record again with them; they are recognised.
4. With retention "After transcription", audio is still deleted after H1 completes.
5. Import an audio file as a meeting.
6. Re-process one migrated meeting that still has audio (Tier 2).
7. Dictation sanity: one hotkey dictation into a text field.

- [ ] **Step 6: Record results and commit**

Append to spec §11 a "Verification (date)" block with: full-suite counts and failing set, dry-run lines, which checklist items passed, and which need the user.

```bash
git add -f docs/MEETAI.md docs/superpowers/specs/2026-10-16-meetai-v3-upstream-intake-design.md
git commit -m "Document the MeetAI layer and record verification results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Hand back for push/PR** — do not push. Report to the user: commits on `meetai-v3`, verification layers (suite / installed app / committed / not pushed), and the pending actions from spec §4 (fast-forward fork `main` to `v1.6.11`, push `meetai-v3`, open the PR into `main`, close Satpat/FluidVoice#1), each needing their go-ahead.

# MeetAI v3: take in upstream v1.6.11, port fork meeting features onto FluidMeet

Date: 2026-10-16
Branch: `meetai-v3` (cut from upstream tag `v1.6.11`, `9bf99b4`)
Worktree: `.claude/worktrees/meetai-v3` (git-ignored via `.git/info/exclude`)
Supersedes: fork branch `meetai-v2` (frozen, kept on the remote for reference)

## 1. Context

The fork `Satpat/FluidVoice` branched from upstream `altic-dev/FluidVoice` at `dc57029` (2026-07-06). Since then:

- The fork added 49 commits on `meetai-v2`: its own meeting subsystem in `Services/MeetingRecording/` (two-track capture, Parakeet transcription, FluidAudio diarization, persistent voice profiles, LLM speaker naming, summaries, titles, Q&A, upload import), a `DictationCoordinator` / `DictationAIProcessor` refactor, LLM plumbing consolidation, a disabled updater, and a GPT-5+ reasoning-model fix.
- Upstream shipped 545 commits up to `v1.6.11`, including **FluidMeet**: a much larger meeting subsystem in `Services/Meeting/` (74 files, ~1.9 MB Swift) with AEC3/VPIO echo handling, crash and interruption recovery, meeting auto-detection, live captions, segment playback, transcript editing, speaker rename/merge/reassign, retention policy, and a local meeting API.
- A dry-run merge of `v1.6.11` into `meetai-v2` conflicts in 15 files, dominated by `ContentView.swift` (fork refactor 4450→2511 lines vs upstream growth 4450→6282).

What upstream FluidMeet does **not** have, and the fork does:

| Fork feature | Upstream v1.6.11 |
|---|---|
| Q&A over a meeting | None |
| Persistent cross-meeting speaker identities | None. `MeetingSpeakerVoiceMatcher` is per-attempt and never persisted |
| LLM speaker auto-naming from the transcript | None |
| LLM meeting titles | None (default titles only) |
| Summaries via the user's AI provider | `MeetingSummaryController` exists but runs only on an on-device Private AI model and the UI shows `MeetingSummaryComingSoon` |
| Import an audio file as a meeting | None |

## 2. Goal and decisions

Goal: run upstream v1.6.11 (including FluidMeet) as the base, and keep the fork's meeting features by re-implementing them as a thin layer on top of FluidMeet, so future upstream releases merge cheaply.

Decisions made during brainstorming:

1. **Approach A**: fresh branch from `v1.6.11` plus a MeetAI extension layer. Not a merge of `v1.6.11` into `meetai-v2` (B), and not keeping the fork's meeting stack (C).
2. **Old meetings migrate into FluidMeet** (not a read-only archive, not discarded).
3. **The `DictationCoordinator` refactor and LLM consolidation are redone later** as a separate project against upstream's code. Not part of this work.
4. **Meeting AI features use the user's AI Enhancement provider** (cloud or local LLM server), not upstream's Private AI model.
5. **Live Q&A during recording is cut.** Q&A is for completed meetings.
6. **LLM-guessed speaker names do not enrol voice profiles.** Only names the user sets or keeps (by renaming) enrol. Change from fork behaviour.

## 3. Non-goals

- Redoing the dictation refactor, LLM consolidation, or other fork architecture work (`docs/ARCHITECTURE.md` roadmap items).
- Changing upstream FluidMeet capture, transcription, diarization, or UI beyond the hook points in §5.2.
- Live Q&A while recording.
- Re-enabling upstream's Private AI meeting summaries or `MeetingPostProcessingRegistry` (nothing calls it in v1.6.11).
- Deleting the fork's old `MeetingRecordings/` data.

## 4. Branch and git mechanics

- **Fork `main`**: fast-forward to `v1.6.11`. It is at `dc57029`, an ancestor of the tag, so no merge commit. Push only on the user's go-ahead.
- **`meetai-v3`**: created from `v1.6.11` in the worktree above. All work for this spec lands here.
- **`meetai-v2`**: frozen. PR [Satpat/FluidVoice#1](https://github.com/Satpat/FluidVoice/pull/1) is closed unmerged with a note pointing to the v3 PR, on the user's go-ahead.
- **PR**: `meetai-v3` → fork `main`, opened only after all commits are pushed.

### 4.1 What carries over from `meetai-v2`

| Category | Item | Treatment |
|---|---|---|
| Re-apply | `MeetAIBuildFlags.updaterEnabled = false` and its guards in `AppDelegate` and `SimpleUpdater` | Re-written by hand: upstream rewrote `SimpleUpdater` (+786 lines), so the commit does not cherry-pick |
| Re-apply | `./build.sh install` profile (build + install to `/Applications`) | Re-added to upstream's new `build.sh`. Upstream now handles signing and framework embedding, so the fork's build-script fixes are dropped |
| Cherry-pick | `UI/MarkdownText.swift` + `MarkdownTextTests`, `scripts/add_test_file_to_xcodeproj.py` | New files, no conflicts |
| Port as tests | `FluidAudioSmokeTests`; the `isReasoningModel` cases from `90234f5` | Run against upstream's FluidAudio pin (`eb1e662`) and upstream's `isReasoningModel` (which already covers `gpt-6` and provider prefixes) |
| Copy docs | `docs/superpowers/specs/2026-10-15-dictation-coordinator-design.md`, `docs/superpowers/plans/2026-10-15-dictation-coordinator.md` | Reference for the later refactor redo |
| Re-implement | Q&A, persistent speakers, auto-naming, titles, summaries, upload import | New code, §6 |
| Drop | Fork recorder, `MeetingTranscriptPipeline`, live transcriber, leak gate/AEC, PostHog removal (upstream already dropped PostHog), FluidAudio and mediaremote-adapter bumps (take upstream pins), the fork's `docs/ARCHITECTURE.md` | Not carried. A short `docs/MEETAI.md` describes the layer instead |

## 5. Architecture

### 5.1 Principle

Fork code lives in `Sources/Fluid/MeetAI/` (services) and `Sources/Fluid/UI/MeetAI/` (views). It reaches FluidMeet only through upstream's public `MeetingSessionCoordinator` API and model types:

- Read: `MeetingSession` (speakers, segments, audio tracks/assets), `latestCompletedSession`, `MeetingSessionStore.load/loadAll`.
- Write: `renameSpeakers`, `renameSession`, `retryProcessing(sessionID:)`, `MeetingSessionStore.create`.
- Reuse: `MeetingSummaryInput.transcript(for:)` to render a session as text (consistent speaker names, echo segments excluded).

The only place MeetAI builds upstream session files itself is the synthetic session builder (§6.6, §7), and it does so through `MeetingSessionStore.create`.

### 5.2 Hook points (the only upstream edits)

| # | File | Edit | Why |
|---|---|---|---|
| H1 | `Services/Meeting/MeetingSessionCoordinator.swift`, completion path (~L1693) | `await MeetAIHooks.sessionDidComplete(session)` immediately before the `sweepExpiredAudio()` Task. The awaited part is the audio-dependent speaker step only; LLM work is detached. Hard timeout 30 s; errors are logged and swallowed | The "After transcription" retention policy deletes audio in that sweep. Speaker embeddings need the audio first |
| H2 | `UI/MeetingSessionCanvases.swift` (~L440) and `MeetingDocumentTabs` | Summary tab renders `MeetAISummaryView` instead of `MeetingSummaryView`. Add an **Ask** tab rendering `MeetAIQAPanel` | Replace the parked Private AI summary; add Q&A |
| H3 | Meeting home in `UI/MeetingTranscriptionView.swift` | "Import audio as meeting…" button and a "MeetAI" settings gear | Entry points for import and settings |
| H4 | `AppDelegate.swift` | `MeetAIBootstrap.start()` at launch; updater guard | Install hooks, run migration, sweep orphans |
| H5 | `Services/SimpleUpdater.swift` | `guard MeetAIBuildFlags.updaterEnabled` | Stop the updater installing upstream builds over the fork |
| H6 | `MeetingSessionCoordinator.swift`, after `renameSpeaker`, `renameSpeakers`, `mergeSpeakers` succeed | `MeetAIHooks.speakersChanged(session, change)` (fire-and-forget) | User renames enrol voice profiles; merges drop the merged speaker's embedding |

`MeetAIHooks` is a small `@MainActor` enum with static closures that `MeetAIBootstrap` sets. If unset, the hooks are no-ops, so upstream tests run unchanged.

### 5.3 Storage

MeetAI-owned data lives under `~/Library/Application Support/FluidVoice/MeetAI/`:

```
MeetAI/
├── SpeakerProfiles/profiles.json        persistent voices (copied from the fork's SpeakerProfiles/)
├── Sessions/<MeetingSessionID>/
│   ├── summary.json      { style, transcriptHash, markdown, providerID, modelID, createdAt }
│   ├── qa.json           [{ question, answer, askedAt }]
│   ├── speakers.json     { SessionSpeakerID: { embedding: [Float], matchedProfileID?, nameSource } }
│   └── meta.json         { titleSource: default|llm|user, lastLLMTitle? }
└── migration.json        { folderName: { sessionID?, status, reason? } }
```

Rules:

- Sidecars are keyed by upstream session ID. At launch, `MeetAIBootstrap` deletes `Sessions/<id>/` folders whose session no longer exists in `MeetingSessionStore` (this covers deletion through upstream's UI).
- `transcriptHash` is SHA-256 of `MeetingSummaryInput.transcript(for:)`. If the current hash differs from the stored one, the summary view shows a "transcript changed — regenerate?" banner. Summaries are never silently stale.
- `nameSource` per speaker: `profile`, `llm`, `user`. MeetAI never overwrites a `user` name or the local user's speaker.
- Settings are `MeetAI*` UserDefaults keys (`MeetAIAutoSummarize` default true, `MeetAISummaryStyle` default `standard`, `MeetAIAutoName` default true, `MeetAISpeakerMatching` default true). Upstream's `SettingsStore` is not touched.

### 5.4 LLM access

`MeetAILLM` wraps upstream's `LLMClient` and resolves the provider the same way AI Enhancement does. It carries over from the fork's `MeetingAIClient`:

- Context-budget handling: on "context / too long / maximum length / token limit" errors, halve the input budget based on what was actually sent and retry (up to 20 attempts for local endpoints, 4 for remote).
- Wait for a local endpoint (Ollama / LM Studio / llama-server) to come up, ~40 s.
- 180 s per-request timeout set on a MeetAI-owned `URLSession`. Upstream's shared `LLMClient` session timeouts are not changed.
- Apple Intelligence provider: 4096-token budget, as in the fork.

### 5.5 Concurrency and failure rules

- MeetAI services are actors or `nonisolated` async functions. UI types are `@MainActor`. No file or audio decoding on the main actor.
- Speaker embedding runs FluidAudio CoreML off main and takes upstream's `MeetingModelResidencyCoordinator` lease so it never overlaps meeting ASR.
- Per session, MeetAI work is serialized: speakers → naming → title → summary.
- A MeetAI failure never blocks or alters upstream completion. Summary, naming and title failures show inline with a Retry action.

## 6. Ported features

### 6.1 Persistent speakers

At H1, for each non-local `SessionSpeaker` (`isLocalUser == false`, not merged):

1. Select up to 30 s of that speaker's cleanest turns: segments with `attributionState == .assigned`, `isLikelyEcho != true`, `overlap == .none`, duration ≥ 1.5 s, longest first.
2. Read those ranges from the session's `captureAnalysis` audio assets at 16 kHz mono.
3. Embed with FluidAudio `EmbeddingExtractor` (WeSpeaker, the model behind the fork's existing 27 profiles, so they stay valid). L2-normalise and average into a centroid. Store it in `speakers.json`.
4. Match against `profiles.json` by cosine similarity. At ≥ 0.7 (the fork's threshold), rename the speaker to the profile name via `renameSpeakers`, only if its current name is upstream's default label. Record `nameSource = profile`.

Speakers with too little clean audio (< 3 s total) are skipped and left for LLM naming.

Enrolment (H6):

- **Rename** to a non-default name: enrol a new profile or update the matching one (running weighted centroid, as in the fork's `SpeakerProfileStore`) from the stored embedding. `nameSource = user`. Works after audio deletion because the embedding is stored.
- **Merge**: drop the source speaker's embedding; keep the target's.
- LLM-assigned names never enrol.

UI: a "Known speakers" sheet (port of the fork's `KnownSpeakersPanel`) inside MeetAI settings to rename or delete profiles.

### 6.2 LLM speaker auto-naming

Runs after §6.1, if `MeetAIAutoName` is on, for speakers still on default labels. It ports `MeetingSpeakerNamer`'s prompt and rules:

- Assign a name only when the transcript clearly evidences it: a self-introduction, or the speaker being unambiguously addressed by name.
- Includes the fork's direct-address inversion fix: "Thanks, Sam" spoken by speaker A names the *other* party, not A.
- Never rename the local user's speaker.
- JSON response `{label: name}`; unparseable or empty responses change nothing.

Applied via `renameSpeakers` with `nameSource = llm`.

### 6.3 Titles

If `meta.json` `titleSource` is `default` (or absent and the session title equals upstream's default title), ask the LLM for a short title (≤ 8 words, no date) and apply it via `renameSession`, setting `titleSource = llm`.

After a speaker rename (H6), regenerate the title only if `titleSource == llm`. A title the user edits in upstream's UI (detected as a session title that differs from `lastLLMTitle`) becomes `titleSource = user` and is never touched again.

### 6.4 Summaries

- Auto-run after completion when `MeetAIAutoSummarize` is on, using `MeetAISummaryStyle`.
- Styles, ported from the fork's `MeetingSummaryStyle`: `standard`, `keyTakeaways`, `whatByWhenPerSpeaker`, `whatByWhenBroad`. Migrated summaries use a read-only `migrated` style label.
- Input: `MeetingSummaryInput.transcript(for:)`, sent through `MeetAILLM` with the context-trim retry.
- `MeetAISummaryView` (H2): style menu, Regenerate, Copy, markdown rendered with `MarkdownText`, stale banner (§5.3), inline error with Retry, progress state while generating.

### 6.5 Q&A

- **Ask** tab (H2) on completed sessions. Disabled with an explanation while a session is recording or processing.
- Ports `MeetingQAService`'s system prompt. Transcript input is the same as summaries, for *that* session. This fixes the fork bug where Q&A used the newest meeting.
- History persisted per session in `qa.json`, shown oldest first. Clear button.

### 6.6 Upload import

"Import audio as meeting…" (H3):

1. User picks a file. Formats: whatever upstream File Transcription accepts.
2. Off main: decode, downmix and resample into upstream's capture chunk format.
3. **Synthetic session builder** creates an `inRoom` `MeetingSession` with one `microphone` track whose chunks match upstream's on-disk format and ledger, via `MeetingSessionStore.create`. Title = original filename without extension; `startedAt` = file creation date.
4. Call `retryProcessing(sessionID:)`. Upstream runs its full pipeline; H1 fires as for a live meeting.

This depends on upstream's chunk/ledger format, not a public API, so it is the riskiest piece. It is gated by the opening spike (§8.2).

**Fallback** if the spike fails: import through upstream File Transcription and offer summary and Q&A only, with no diarization. Stop and confirm with the user before switching to the fallback.

### 6.7 MeetAI settings sheet

Opened from the H3 gear:

- Auto-summarize on/off, default style.
- Auto-name speakers on/off.
- Speaker matching on/off.
- Known speakers (§6.1).
- Migration status: counts, skipped/failed folders with reasons, "Re-run migration" (§7).

## 7. Migrating old meetings

Source data, read-only: `~/Library/Application Support/FluidVoice/MeetingRecordings/` (113 folders on 2026-10-16: 109 with `transcript.md`, 20 with audio, 4 without a transcript) and `SpeakerProfiles/profiles.json` (27 profiles).

### 7.1 Tier 1: automatic transcript-only import (all folders with `transcript.md`)

`MeetAIMigrator` runs once in the background from `MeetAIBootstrap`, oldest folder first.

| Fork source | FluidMeet / MeetAI target |
|---|---|
| Folder name (ISO-8601 timestamp), `session.json` | `startedAt`; `endedAt` from `session.json`, else `startedAt` + the transcript's `Duration:` line |
| Distinct speaker labels | One `MeetingSessionSpeaker` per label. `Me` → `isLocalUser = true`, `trackKind = .microphone`. Others → `.applicationAudio`. `mode = .onlineCall` if any non-`Me` label exists, else `.inRoom` |
| — | One `MeetingAudioTrack` per track kind used, with no chunks and health `.unavailable`, so every segment has a valid `sourceTrackID`. `retention.audioDeletedAt` = `endedAt` |
| `transcript.md` lines `**[MM:SS] Speaker:** text` (minutes may exceed 59) | `MeetingTranscriptSegment`s: `start` from the timestamp, `end` = next segment's start (last = duration), `status = .final`, `completeness = .complete`, `overlap = .none`, `attributionState = .assigned`, `revision = 0` |
| `title.txt` | `title`, with the fork's trailing `(Day D Mon, h:mm am)` suffix stripped. `titleSource = llm` |
| `summary.md` | `summary.json`, `style = migrated`, `transcriptHash` computed after import |
| `speakers.json` (label → centroid) | `speakers.json` keyed by the new `SessionSpeakerID`, `nameSource = user` for non-`Them N` labels |
| `session.state` | `.completed` |

Written via `MeetingSessionStore.create`.

### 7.2 Tier 2: opt-in re-processing (folders that still have `system.wav` / `mic.wav`)

A "Re-process with FluidMeet" action on migrated sessions whose source folder still has audio. It uses the §6.6 builder in two-track `onlineCall` mode (`system.wav` → `applicationAudio`, `mic.wav` → `microphone`), then `retryProcessing`. A confirmation explains that the transcript will be replaced. Names come back through §6.1 matching. Never automatic.

### 7.3 Rules

- **Idempotent**: `migration.json` records each folder's status. Re-runs skip `done` folders. "Re-run migration" retries `failed` ones.
- **Non-destructive**: `MeetingRecordings/` and `SpeakerProfiles/` are only read. Profiles are copied. Old `FileTranscriptionHistoryEntries` "Meeting …" entries in UserDefaults are left alone. Deleting old data is the user's call.
- **Skipped** (no `transcript.md`, empty folder) and **failed** (parse or store error) folders are recorded with a reason and shown in settings.
- Migration only writes completed sessions, never blocks the UI, and does not interact with an active recording.

### 7.4 Fallback

If the spike (§8.2) shows upstream rejects or misrenders audio-less sessions, fall back to a read-only "Archive" list in the MeetAI settings sheet that shows old meetings with Summary and Ask outside FluidMeet. Confirm with the user before switching.

## 8. Testing and verification

### 8.1 Baseline gate

On `meetai-v3` before any change, run upstream's CI command:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS,arch=arm64' -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

plus `Tests/run_*` scripts. Record pass/fail counts. Every later commit keeps upstream's results unchanged and adds MeetAI tests. Upstream tests already failing at the tag are recorded, not fixed.

### 8.2 Opening spike (gates §6.6 and §7)

1. Build a synthetic `inRoom` session from a short two-speaker fixture WAV → `MeetingSessionStore.create` → `retryProcessing` → session reaches `.completed` with ≥ 2 speakers.
2. Build a transcript-only session from a fixture `transcript.md` → `load` round-trips equal → open it in the built app and capture a screenshot.

Spike code stays labelled spike until both pass. Then it becomes the builder plus a kept integration test.

### 8.3 Unit tests (no models, stubbed LLM)

| Area | Cases |
|---|---|
| `transcript.md` parser | `Me` + named + `Them N` labels; timestamps past 59 min; missing `Duration:`; empty file; multi-line text |
| Migrator | field mapping; idempotency (second run is a no-op); skipped and failed reporting; profiles copied, not moved; source folder bytes unchanged (hash before/after) |
| Speakers | clean-turn selection; cosine match around the 0.7 threshold; enrol and update on rename; merge drops source; never overwrite a `user` name or the local speaker |
| Naming / titles | response parsing; local-user guard; title regenerated only while `titleSource == llm` |
| Summaries / Q&A | prompt building; context-trim retry (port of the fork's `LLMHelpersTests`); `transcriptHash` staleness; per-session Q&A history |
| Sidecar store | write/read; orphan sweep after upstream `deleteSession` |
| Hooks | upstream completion succeeds and H1 returns within 30 s when the MeetAI hook throws or hangs; hooks unset → no-ops |

### 8.4 Ported and model-backed tests

- `MarkdownTextTests`, `FluidAudioSmokeTests` (against upstream's FluidAudio pin), `isReasoningModel` cases from `90234f5`.
- Opt-in model-backed test: `EmbeddingExtractor` on fixture clips. Same speaker across two clips scores ≥ 0.7; different speakers score < 0.7. Confirms the threshold under upstream's FluidAudio pin.

### 8.5 Migration dry run on a copy of real data

Run the migrator in a test harness against a temporary copy of `MeetingRecordings/` and `SpeakerProfiles/`, with the store root injected. Expected: 109 imported, 4 skipped with reasons, 27 profiles copied. The report goes in the PR.

### 8.6 Before the first real launch of the v3 build

Upstream v1.6.11 also migrates settings on first run, so back up first:

```bash
ditto "$HOME/Library/Application Support/FluidVoice" "$HOME/FluidVoice-backup-$(date +%Y%m%d)"
```

plus `defaults export` of the app's defaults domain. Restore steps go in the PR description.

### 8.7 Manual checklist (installed via `./build.sh install`)

1. Record a short real call: known voices auto-named, unknown voices LLM-named, title set, summary appears, Ask answers about that meeting.
2. Rename a speaker; a second recording matches them by voice.
3. With retention "After transcription", audio is still deleted after H1 finishes.
4. Import an audio file as a meeting.
5. A migrated meeting opens with transcript, summary and Ask. Tier 2 re-process on one migrated meeting.
6. Dictation sanity check: one hotkey dictation into a text field.

### 8.8 Evidence

Each report states which layer was checked: tested in the suite, run in the installed app, committed, pushed. Pushes only on the user's go-ahead.

## 9. Commit sequence

1. Spec (this document), with the §8.1 baseline results appended in §11 once the run finishes.
2. Updater flag + H4/H5 guards; `build.sh install`.
3. Cherry-picks: `MarkdownText`, test helper script; copied coordinator docs.
4. Ported tests: FluidAudio smoke, `isReasoningModel` cases.
5. Spike → synthetic session builder + integration test.
6. `MeetAI` skeleton: `MeetAIHooks`, `MeetAIBootstrap`, sidecar store, orphan sweep, settings keys; H1/H6 hook calls.
7. `MeetAILLM`.
8. Persistent speakers (§6.1) + Known speakers sheet.
9. Auto-naming (§6.2) and titles (§6.3).
10. Summaries (§6.4) + H2 Summary tab.
11. Q&A (§6.5) + H2 Ask tab.
12. Upload import (§6.6) + H3.
13. Migration Tier 1 (§7.1) + dry run report.
14. Migration Tier 2 (§7.2).
15. MeetAI settings sheet (§6.7) and `docs/MEETAI.md`.

Each commit builds and keeps the test suite green before the next one starts.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Synthetic sessions depend on upstream's internal chunk/ledger format | Opening spike; integration test pins the format so an upstream change fails loudly; documented fallbacks (§6.6, §7.4) |
| Upstream rejects or misrenders sessions with no audio | Spike item 2; Archive fallback |
| WeSpeaker threshold behaves differently on upstream-segmented turns | Model-backed threshold test; matching can be switched off in settings |
| Future upstream releases change hook-point code | Hooks are six one-line edits listed in §5.2 and in `docs/MEETAI.md`, so conflicts are small and findable |
| Upstream's first-run settings migration changes user settings | Backup before first launch (§8.6) |
| H1 delays upstream's audio sweep | 30 s timeout; only the embedding step is awaited |

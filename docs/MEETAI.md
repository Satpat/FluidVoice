# MeetAI layer

MeetAI adds meeting features to upstream FluidVoice's FluidMeet without changing how FluidMeet records or transcribes.

## What it adds
- Persistent speakers: voices you name are recognised in later meetings (cosine >= 0.7, WeSpeaker embeddings). A speaker whose second-best profile also clears 0.7 within 0.1 of the best is not auto-named by voice; LLM naming handles it instead. An AI-assigned name can be confirmed from the Summary tab ("Save this voice as <name>"), which saves the voice like a rename would.
- LLM speaker naming from introductions, LLM titles, and per-meeting Q&A, all through the AI Enhancement provider.
- Summaries: since upstream 1.6.12 the Summary tab uses upstream's summary (on-device or your AI provider, custom prompt; also what `fv-serve meet summary` reads). MeetAI no longer writes summaries. Below it, MeetAI shows the "Save this voice as <name>" prompts and, collapsed, any earlier MeetAI summary (`summary.json`, kept read-only, e.g. from migration). Upstream's summary reads the original-language transcript; for Indian-language meetings pick Custom prompt and ask for English.
- English translation of Indian-language segments, shown under the original and in Text/Markdown exports. Editing a segment's text hides its translation until the next MeetAI run (translations are keyed by a hash of the source text).
- Import an audio file as a meeting; the file name is a placeholder title that MeetAI's title step replaces unless you edit it first. The synthetic session stores PCM-first CAF Float32 chunks (`tracks/<kind>/NNNNNN.caf`, audioSchemaVersion 2, ready `captureAnalysisAsset` of kind `linearPCMFloat32CAFV1`) so upstream's analysis attributes speakers.
- One-time migration of meetings recorded by the previous MeetAI version (transcript-only; meetings whose transcript has no lines, e.g. "No speech detected", are skipped), plus optional Tier 2 re-processing of the ones that still have audio. Migration status and the re-process action live in the MeetAI settings sheet, which lists re-processable meetings by title and date.

## Where things live
- Code: `Sources/Fluid/MeetAI/`, `Sources/Fluid/UI/MeetAI/`.
- Data: `~/Library/Application Support/FluidVoice/MeetAI/` (`SpeakerProfiles/profiles.json`, `Sessions/<id>/{summary,qa,speakers,meta}.json`, `migration.json`).
- Settings: UserDefaults `MeetAIAutoName`, `MeetAISpeakerMatching`, `MeetAITranslateIndicSpeech` (`MeetAIAutoSummarize`/`MeetAISummaryStyle` are no longer read).

## Hook points in upstream files (check these when merging upstream)
| # | File | What |
|---|---|---|
| H1 | `Services/Meeting/MeetingSessionCoordinator.swift` (completion, before `sweepExpiredAudio`) | `await MeetAIHooks.runSessionDidComplete(session)` |
| H2 | `UI/MeetingSessionCanvases.swift`, `UI/MeetingWorkspaceComponents.swift` | Summary tab -> upstream `MeetingSummaryView` then `MeetAISummaryView` (voice confirmations, earlier summary); `MeetingDocumentSection.ask` + `MeetingDocumentTabs(showsAsk:)` -> `MeetAIQAPanel`; segment row `englishText:` + translations `.task` |
| H3 | `UI/MeetingTranscriptionView.swift` (`MeetingSetupCanvas.body`) | `MeetAIHomeActions()` |
| H4 | `AppDelegate.swift` | `MeetAIBootstrap.start()`; updater started only if `MeetAIBuildFlags.updaterEnabled` |
| H5 | `Services/SimpleUpdater.swift` | guards in the updater entry points; `MeetAIBuildFlags.updaterEnabled` is false in the app and true only under XCTest, so updater tests still run |
| H6 | `Services/Meeting/MeetingSessionCoordinator.swift` (`performCorrection`) | `MeetAIHooks.notifySessionCorrected(target)` |
| - | `build.sh` | `install` profile with the release bundle ID |
| - | `Services/Meeting/MeetingTranscriptExporter.swift` | `translations:` on `text` and `markdown` |

## Known overlaps with upstream
- Edit speakers → Merge (1.6.12) leaves the merged-away speaker's record in MeetAI's `speakers.json`. Harmless: nothing reads records for speakers absent from the session.
- `fv-serve` (coding-agent meeting reader) sees upstream summaries only, not MeetAI's earlier `summary.json`.

## Testing note
Test runs are signed with the user's personal team (`DEVELOPMENT_TEAM=BVA3X42BK9`): unsigned test hosts hang on a keychain prompt.

## Updating from upstream
Merge the new upstream tag into the fork's `main`, then into the MeetAI branch; resolve conflicts only at the hook points above; run the full suite and compare the failing set with the previous baseline (spec section 11).

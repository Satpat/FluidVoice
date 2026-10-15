# MeetAI layer

MeetAI adds meeting features to upstream FluidVoice's FluidMeet without changing how FluidMeet records or transcribes.

## What it adds
- Persistent speakers: voices you name are recognised in later meetings (cosine >= 0.7, WeSpeaker embeddings).
- LLM speaker naming from introductions, LLM titles, summaries in four styles, and per-meeting Q&A, all through the AI Enhancement provider.
- Import an audio file as a meeting. The synthetic session stores PCM-first CAF Float32 chunks (`tracks/<kind>/NNNNNN.caf`, audioSchemaVersion 2, ready `captureAnalysisAsset` of kind `linearPCMFloat32CAFV1`) so upstream's analysis attributes speakers.
- One-time migration of meetings recorded by the previous MeetAI version (transcript-only; meetings whose transcript has no lines, e.g. "No speech detected", are skipped), plus optional Tier 2 re-processing of the ones that still have audio. Migration status and the re-process action live in the MeetAI settings sheet.

## Where things live
- Code: `Sources/Fluid/MeetAI/`, `Sources/Fluid/UI/MeetAI/`.
- Data: `~/Library/Application Support/FluidVoice/MeetAI/` (`SpeakerProfiles/profiles.json`, `Sessions/<id>/{summary,qa,speakers,meta}.json`, `migration.json`).
- Settings: UserDefaults `MeetAIAutoSummarize`, `MeetAISummaryStyle`, `MeetAIAutoName`, `MeetAISpeakerMatching`.

## Hook points in upstream files (check these when merging upstream)
| # | File | What |
|---|---|---|
| H1 | `Services/Meeting/MeetingSessionCoordinator.swift` (completion, before `sweepExpiredAudio`) | `await MeetAIHooks.runSessionDidComplete(session)` |
| H2 | `UI/MeetingSessionCanvases.swift`, `UI/MeetingWorkspaceComponents.swift` | Summary tab -> `MeetAISummaryView`; `MeetingDocumentSection.ask` + `MeetingDocumentTabs(showsAsk:)` -> `MeetAIQAPanel` |
| H3 | `UI/MeetingTranscriptionView.swift` (`MeetingSetupCanvas.body`) | `MeetAIHomeActions()` |
| H4 | `AppDelegate.swift` | `MeetAIBootstrap.start()`; updater started only if `MeetAIBuildFlags.updaterEnabled` |
| H5 | `Services/SimpleUpdater.swift` | guards in the updater entry points; `MeetAIBuildFlags.updaterEnabled` is false in the app and true only under XCTest, so updater tests still run |
| H6 | `Services/Meeting/MeetingSessionCoordinator.swift` (`performCorrection`) | `MeetAIHooks.notifySessionCorrected(target)` |
| - | `build.sh` | `install` profile with the release bundle ID |

## Testing note
Test runs are signed with the user's personal team (`DEVELOPMENT_TEAM=BVA3X42BK9`): unsigned test hosts hang on a keychain prompt.

## Updating from upstream
Merge the new upstream tag into the fork's `main`, then into the MeetAI branch; resolve conflicts only at the hook points above; run the full suite and compare the failing set with the previous baseline (spec section 11).

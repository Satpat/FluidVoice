// MeetAI v2 native two-track meeting transcription.
//
// Transcribes mic.wav ("Me") and system.wav ("Them") separately with the
// active ASR provider, using silence-based utterance splitting so both
// tracks can be interleaved by timestamp into one speaker-labelled
// transcript. Writes transcript.md, summary.md, title.txt and speakers.json
// next to the recordings and registers the meeting in the file-transcription
// history.
//
// This class is the @MainActor coordinator: it publishes progress and owns
// the steps that need main-actor state (ASR provider, voice profiles,
// history store, AI calls). CPU-heavy stages — decode, VAD, diarization,
// echo suppression, rendering — run off the main actor in
// MeetingProcessingEngine.

import Combine
import Foundation

nonisolated struct MeetingSegment: Sendable, Identifiable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
    let text: String
}

/// What a completed `MeetingTranscriptPipeline.process` produced.
struct MeetingProcessingResult {
    let transcriptURL: URL
    /// FileTranscriptionHistoryStore entry for this meeting; nil when the
    /// transcript is empty (the store doesn't keep empty entries).
    let historyEntryID: UUID?
    /// Plain "[MM:SS] Speaker: text" transcript; empty when no speech was found.
    let mergedText: String
    let title: String
    let summaryError: String?
}

@MainActor
final class MeetingTranscriptPipeline: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var error: String?
    @Published var transcriptURL: URL?
    @Published var summary: String?
    @Published var summaryError: String?
    @Published var meetingTitle: String?

    /// Session-folder name of the recording currently being processed by
    /// this instance (nil when idle). Lets views tie progress UI to a
    /// specific meeting row.
    @Published var processingFolderName: String?

    /// Long-lived pipelines whose progress must survive SwiftUI view
    /// recreation (sidebar navigation recreates MeetingsView and the
    /// recorder card, and with them any @StateObject).
    enum Role {
        /// Transcribes a just-stopped live recording (MeetingRecorderCard).
        case recorder
        /// Re-transcribes meetings from the Meetings history.
        case reprocessor
    }

    private static var sharedInstances: [Role: MeetingTranscriptPipeline] = [:]
    static func shared(_ role: Role, asrService: ASRService) -> MeetingTranscriptPipeline {
        if let existing = sharedInstances[role] { return existing }
        let created = MeetingTranscriptPipeline(asrService: asrService)
        sharedInstances[role] = created
        return created
    }

    private let asrService: ASRService

    static let micSpeakerLabel = MeetingProcessingEngine.micSpeakerLabel
    static let systemSpeakerLabel = MeetingProcessingEngine.systemSpeakerLabel

    /// Consecutive per-utterance ASR failures after which the provider is
    /// treated as broken rather than the audio as unusable.
    private static let maxConsecutiveUtteranceFailures = 5

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    // MARK: - Entry point

    /// Transcribe both tracks of a recording and write transcript.md (plus
    /// summary, title and speaker embeddings) into the session folder.
    @discardableResult
    func process(_ artifacts: MeetingRecordingArtifacts) async throws -> MeetingProcessingResult {
        let folderName = artifacts.folder.lastPathComponent
        guard MeetingFolderActivity.shared.begin(folderName, .transcribing) else {
            throw MeetingRecordingError("This meeting is already being processed.")
        }

        self.isProcessing = true
        self.processingFolderName = folderName
        self.error = nil
        self.summary = nil
        self.summaryError = nil
        self.meetingTitle = nil
        self.progress = 0.0
        let startTime = Date()

        // Progress is deliberately not reset here: observers (e.g. the
        // upload view) read the final 1.0 after the run completes.
        defer {
            MeetingFolderActivity.shared.end(folderName)
            isProcessing = false
            processingFolderName = nil
        }

        do {
            if !self.asrService.isAsrReady {
                self.currentStatus = "Preparing ASR models..."
                try await self.asrService.ensureAsrReady()
            }
            let provider = self.asrService.fileTranscriptionProvider
            guard provider.isReady else {
                throw MeetingRecordingError("Transcription provider not ready")
            }

            // One track in memory at a time: the mic track's samples are
            // released before the system track is decoded.
            self.currentStatus = "Transcribing your microphone track..."
            let micSegments = try await self.transcribeTrack(
                url: artifacts.microphone,
                speaker: Self.micSpeakerLabel,
                provider: provider,
                progressRange: 0.05...0.4
            ).segments

            self.currentStatus = "Transcribing the system-audio track..."
            var embeddingByLabel: [String: [Float]] = [:]
            var systemSegments: [MeetingSegment]
            do {
                let track = try await self.transcribeTrack(
                    url: artifacts.systemAudio,
                    speaker: Self.systemSpeakerLabel,
                    provider: provider,
                    progressRange: 0.4...0.75
                )
                systemSegments = track.segments
                if track.diarizable, !systemSegments.isEmpty {
                    self.currentStatus = "Identifying speakers..."
                    self.progress = 0.8
                    let resolution = await Self.resolveSpeakers(to: systemSegments, samples: track.samples)
                    systemSegments = resolution.segments
                    embeddingByLabel = resolution.embeddingByLabel
                }
            }

            self.currentStatus = "Merging tracks..."
            self.progress = 0.92
            // Echo backstop: when recording with speakers + mic, the far-end
            // voice bleeds into the mic and duplicates onto the "Me" track.
            // Drop any mic segment that echoes a near-simultaneous system
            // segment so leaked audio never appears attributed to the user.
            let mergeResult = await MeetingProcessingEngine.mergeSuppressingEcho(mic: micSegments, system: systemSegments)
            var merged = mergeResult.segments
            if mergeResult.droppedEchoes > 0 {
                DebugLogger.shared.info(
                    "Echo suppression removed \(mergeResult.droppedEchoes) leaked mic segment(s)",
                    source: "MeetingTranscriptPipeline"
                )
            }

            // Replace remaining "Them N" labels with real names when the
            // transcript reveals them (self-introductions, direct address).
            var appliedNameMap: [String: String] = [:]
            if !systemSegments.isEmpty {
                self.currentStatus = "Naming speakers..."
                self.progress = 0.94
                let namingResult = await MeetingSpeakerNamer.nameSpeakers(in: merged)
                merged = namingResult.segments
                appliedNameMap = namingResult.appliedMap
            }

            // Persist voice identities: enrol every speaker that ended up with
            // a real name (recognised from a profile, or discovered from the
            // transcript) so the same voice is recognised in future meetings.
            Self.enrollProfiles(embeddingByLabel: embeddingByLabel, appliedNameMap: appliedNameMap)
            Self.writeSpeakerEmbeddings(embeddingByLabel, folder: artifacts.folder)

            let rendered = await MeetingProcessingEngine.render(segments: merged, artifacts: artifacts)
            let transcriptURL = artifacts.folder.appendingPathComponent("transcript.md")
            try rendered.markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let mergedText = rendered.mergedText
            let fileName = "Meeting \(artifacts.displayName)"
            // Replace any prior transcript for this same recording so
            // re-transcribing updates in place instead of duplicating.
            for existing in FileTranscriptionHistoryStore.shared.entries where existing.fileName == fileName {
                FileTranscriptionHistoryStore.shared.deleteEntry(id: existing.id)
            }
            let historyEntryID = FileTranscriptionHistoryStore.shared.addEntry(TranscriptionResult(
                text: mergedText,
                confidence: 1.0,
                duration: artifacts.duration,
                processingTime: Date().timeIntervalSince(startTime),
                fileName: fileName
            ))

            let titleLine: String
            if mergedText.isEmpty {
                // Nothing to summarise or title; keep the audio regardless of
                // the delete setting so the user can retry.
                titleLine = "Meeting (\(Self.friendlyDate(artifacts.startedAt)))"
            } else {
                self.currentStatus = "Summarizing..."
                self.progress = 0.96
                await self.summarize(mergedText: mergedText, artifacts: artifacts)

                // Friendly meeting name: short generated title + readable date,
                // shown in place of the raw folder timestamp everywhere.
                self.currentStatus = "Naming meeting..."
                self.progress = 0.98
                titleLine = await Self.generateTitleLine(
                    context: self.summary ?? mergedText,
                    startedAt: artifacts.startedAt
                )

                // Only once both the transcript and the summary exist: deleting
                // audio after a failed summary (e.g. local LLM not running)
                // would leave nothing to retry from but the transcript.
                if self.summary != nil, self.summaryError == nil {
                    Self.deleteAudioIfConfigured(artifacts)
                }
            }
            Self.writeTitle(titleLine, folder: artifacts.folder)
            self.meetingTitle = titleLine

            self.currentStatus = "Complete!"
            self.progress = 1.0
            self.transcriptURL = transcriptURL
            return MeetingProcessingResult(
                transcriptURL: transcriptURL,
                historyEntryID: historyEntryID,
                mergedText: mergedText,
                title: titleLine,
                summaryError: self.summaryError
            )
        } catch {
            self.error = error.localizedDescription
            self.progress = 0.0
            throw error
        }
    }

    /// Delete a meeting's raw audio once it's been transcribed and summarised,
    /// if the user has opted in. The transcript and summary are kept; only
    /// system.wav/mic.wav go. Best-effort: a failed delete doesn't fail the
    /// pipeline. This makes Re-transcribe unavailable for the meeting going
    /// forward (see MeetingReprocessor.artifacts, which checks the files
    /// still exist).
    private static func deleteAudioIfConfigured(_ artifacts: MeetingRecordingArtifacts) {
        guard SettingsStore.shared.deleteMeetingAudioAfterTranscription else { return }
        for url in [artifacts.systemAudio, artifacts.microphone] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Summary

    /// Generate a meeting summary with the configured AI provider and write
    /// summary.md next to the transcript. Failures are surfaced but never
    /// fail the transcription itself.
    private func summarize(mergedText: String, artifacts: MeetingRecordingArtifacts) async {
        self.summary = nil
        self.summaryError = nil
        guard !mergedText.isEmpty else { return }

        do {
            let body = try await Self.generateSummaryBody(mergedText: mergedText)
            try Self.writeSummary(body: body, displayName: artifacts.displayName, folder: artifacts.folder)
            self.summary = body
        } catch {
            self.summaryError = error.localizedDescription
            DebugLogger.shared.warning(
                "Meeting summary failed: \(error.localizedDescription)",
                source: "MeetingTranscriptPipeline"
            )
        }
    }

    /// Generate the summary body (Markdown) from a merged transcript. Reused
    /// by the pipeline, in-place relabelling, and summary-only regeneration.
    static func generateSummaryBody(
        mergedText: String,
        style: MeetingSummaryStyle = .current
    ) async throws -> String {
        func systemPrompt(_ transcript: String) -> String {
            """
            You summarise meetings. Below is a machine-generated transcript of a meeting between \
            the user (labelled "Me") and the other participants (labelled "Them", or named/"Them 1"/\
            "Them 2"/... when individual speakers were distinguished); timestamps are \
            minutes:seconds from the start and the transcription may contain recognition errors — \
            infer the intended meaning where obvious. \(style.formatInstructions)

            Transcript:
            \(transcript)
            """
        }
        let result = try await MeetingAIClient.completeAboutTranscript(
            transcript: mergedText,
            turns: [MeetingAIClient.Turn(role: "user", content: style.userPrompt)],
            systemPrompt: systemPrompt
        )
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingRecordingError("The AI provider returned an empty summary.")
        }
        return trimmed
    }

    static func writeSummary(body: String, displayName: String, folder: URL) throws {
        let summaryURL = folder.appendingPathComponent("summary.md")
        let document = "# Meeting summary — \(displayName)\n\n\(body)\n"
        try document.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    /// Regenerate summary.md for an already-processed meeting from its
    /// transcript.md, without re-running transcription or diarization.
    static func regenerateSummary(folder: URL, style: MeetingSummaryStyle = .current) async throws {
        let folderName = folder.lastPathComponent
        guard MeetingFolderActivity.shared.begin(folderName, .summarizing) else {
            throw MeetingRecordingError("This meeting is already being processed.")
        }
        defer { MeetingFolderActivity.shared.end(folderName) }

        let transcriptURL = folder.appendingPathComponent("transcript.md")
        guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw MeetingRecordingError("No transcript found for this meeting.")
        }
        let plain = MeetingProcessingEngine.plainTranscript(markdown)
        guard !plain.isEmpty else {
            throw MeetingRecordingError("The transcript for this meeting is empty.")
        }
        let body = try await Self.generateSummaryBody(mergedText: plain, style: style)
        try Self.writeSummary(body: body, displayName: folder.lastPathComponent, folder: folder)
    }

    // MARK: - Meeting title

    /// "Short generated title (friendly date)". Best-effort: falls back to
    /// plain "Meeting (date)" if the AI provider is unavailable.
    static func generateTitleLine(context: String, startedAt: Date) async -> String {
        var title = "Meeting"
        do {
            let raw = try await MeetingAIClient.complete(
                systemPrompt: """
                You title meetings. Reply with ONLY a concise, descriptive 3-6 word title \
                for the meeting described below. No quotes, no trailing punctuation.
                """,
                turns: [MeetingAIClient.Turn(role: "user", content: String(context.prefix(4000)))]
            )
            let line = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`#*.")).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                title = String(cleaned.prefix(60))
            }
        } catch {
            DebugLogger.shared.warning(
                "Meeting title generation failed: \(error.localizedDescription)",
                source: "MeetingTranscriptPipeline"
            )
        }
        return "\(title) (\(Self.friendlyDate(startedAt)))"
    }

    static func friendlyDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func writeTitle(_ title: String, folder: URL) {
        let url = folder.appendingPathComponent("title.txt")
        try? title.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Per-track transcription

    private struct TrackTranscription {
        let segments: [MeetingSegment]
        /// 16 kHz mono samples, kept for diarization.
        let samples: [Float]
        /// False when the track was transcribed as one block by the
        /// provider's native file path, so there are no per-utterance
        /// timestamps to diarize against.
        let diarizable: Bool
    }

    /// Decode a track off the main actor, then transcribe it utterance by
    /// utterance. If utterance-level ASR fails outright and the provider has
    /// its own whole-file path (Cohere/Nemotron), fall back to that as a
    /// single segment rather than losing the track.
    private func transcribeTrack(
        url: URL,
        speaker: String,
        provider: TranscriptionProvider,
        progressRange: ClosedRange<Double>
    ) async throws -> TrackTranscription {
        let track = try await MeetingProcessingEngine.decodeAndSplit(url: url)
        do {
            let segments = try await self.transcribeUtterances(
                track: track,
                speaker: speaker,
                provider: provider,
                progressRange: progressRange
            )
            return TrackTranscription(segments: segments, samples: track.samples, diarizable: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch where provider.prefersNativeFileTranscription {
            DebugLogger.shared.warning(
                "Utterance ASR failed for \(url.lastPathComponent) (\(error.localizedDescription)); "
                    + "falling back to \(provider.name) native file transcription",
                source: "MeetingTranscriptPipeline"
            )
            let result = try await provider.transcribeFile(at: url)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = text.isEmpty
                ? []
                : [MeetingSegment(start: 0, end: track.duration, speaker: speaker, text: text)]
            self.progress = progressRange.upperBound
            return TrackTranscription(segments: segments, samples: track.samples, diarizable: false)
        }
    }

    /// Transcribe each utterance. A single bad utterance is skipped, but a
    /// run of failures (or every utterance failing) means the provider is
    /// broken and must fail the pipeline instead of producing an empty
    /// transcript that looks like success. Cancellation always propagates.
    private func transcribeUtterances(
        track: MeetingProcessingEngine.DecodedTrack,
        speaker: String,
        provider: TranscriptionProvider,
        progressRange: ClosedRange<Double>
    ) async throws -> [MeetingSegment] {
        let utterances = track.utterances
        var segments: [MeetingSegment] = []
        var failures = 0
        var consecutiveFailures = 0

        for (index, utterance) in utterances.enumerated() {
            try Task.checkCancellation()
            let slice = Array(track.samples[utterance.startSample..<utterance.endSample])
            let result: ASRTranscriptionResult
            do {
                result = try await provider.transcribe(slice)
                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                consecutiveFailures += 1
                DebugLogger.shared.warning(
                    "Skipping unusable utterance (\(slice.count) samples): \(error.localizedDescription)",
                    source: "MeetingTranscriptPipeline"
                )
                if consecutiveFailures >= Self.maxConsecutiveUtteranceFailures || failures == utterances.count {
                    throw MeetingRecordingError(
                        "Speech recognition failed on \(failures) of \(utterances.count) utterances: \(error.localizedDescription)"
                    )
                }
                continue
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(MeetingSegment(
                    start: TimeInterval(utterance.startSample) / TimeInterval(MeetingProcessingEngine.sampleRate),
                    end: TimeInterval(utterance.endSample) / TimeInterval(MeetingProcessingEngine.sampleRate),
                    speaker: speaker,
                    text: text
                ))
            }
            let fraction = Double(index + 1) / Double(max(utterances.count, 1))
            self.progress = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * fraction
        }
        return segments
    }

    // MARK: - Speaker diarization + identity ("Them" track)

    /// Diarize the system track (off the main actor), match each speaker's
    /// voice against saved profiles, and relabel each segment by its
    /// dominant speaker. Best-effort: any diarizer failure keeps the plain
    /// "Them" labels and no embeddings.
    static func resolveSpeakers(
        to segments: [MeetingSegment],
        samples: [Float]
    ) async -> MeetingProcessingEngine.SpeakerResolution {
        let diarization: MeetingProcessingEngine.Diarization
        do {
            diarization = try await MeetingProcessingEngine.diarize(samples: samples)
        } catch {
            DebugLogger.shared.warning(
                "Diarization skipped: \(error.localizedDescription)",
                source: "MeetingTranscriptPipeline"
            )
            return MeetingProcessingEngine.SpeakerResolution(segments: segments, embeddingByLabel: [:])
        }

        var matchedNames: [String: String] = [:]
        for (id, centroid) in diarization.centroids {
            if let name = SpeakerProfileStore.shared.bestMatchName(for: centroid) {
                matchedNames[id] = name
            }
        }
        return MeetingProcessingEngine.assignSpeakers(to: segments, diarization: diarization, matchedNames: matchedNames)
    }

    /// True for a real person's name, i.e. not "Me" and not a provisional
    /// "Them"/"Them N" placeholder.
    static func isRealSpeakerName(_ label: String) -> Bool {
        if label == Self.micSpeakerLabel || label == Self.systemSpeakerLabel { return false }
        if label.hasPrefix("\(Self.systemSpeakerLabel) "),
           Int(label.dropFirst(Self.systemSpeakerLabel.count + 1)) != nil {
            return false
        }
        return true
    }

    /// Enrol/update a voice profile for each speaker that resolved to a real
    /// name. `embeddingByLabel` is keyed by the *diarization* label; the
    /// transcript namer may have renamed some of those, so consult its map.
    private static func enrollProfiles(
        embeddingByLabel: [String: [Float]],
        appliedNameMap: [String: String]
    ) {
        for (label, embedding) in embeddingByLabel {
            let finalName = appliedNameMap[label] ?? label
            guard Self.isRealSpeakerName(finalName) else { continue }
            SpeakerProfileStore.shared.enroll(name: finalName, embedding: embedding)
        }
    }

    /// Persist per-meeting speaker centroids so a speaker can be named
    /// manually later (which enrols the voice for future recognition).
    private static func writeSpeakerEmbeddings(_ embeddingByLabel: [String: [Float]], folder: URL) {
        guard !embeddingByLabel.isEmpty else { return }
        let url = folder.appendingPathComponent("speakers.json")
        if let data = try? JSONSerialization.data(withJSONObject: embeddingByLabel, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func timestamp(_ interval: TimeInterval) -> String {
        MeetingProcessingEngine.timestamp(interval)
    }
}

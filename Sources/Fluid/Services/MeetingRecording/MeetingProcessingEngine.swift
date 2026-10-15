// CPU-heavy, actor-free stages of meeting processing: audio decode, VAD
// utterance splitting, diarization, speaker assignment, echo suppression and
// transcript rendering.
//
// The app target uses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so any
// unannotated code — including `nonisolated` *synchronous* functions called
// from the main actor — runs on the main thread. Everything here is
// `nonisolated`, and the expensive entry points are `@concurrent`, so
// MeetingTranscriptPipeline (the @MainActor coordinator that publishes
// progress) can `await` them without blocking the UI. Pure functions take
// and return value types only, which also makes them unit-testable.

import AVFoundation
import FluidAudio
import Foundation

nonisolated enum MeetingProcessingEngine {
    static let sampleRate = 16_000

    /// Speaker label for the microphone track. The mic is provably the local
    /// user, which is the whole point of recording two tracks.
    static let micSpeakerLabel = "Me"
    static let systemSpeakerLabel = "Them"

    // MARK: - Decode + split

    struct Utterance: Sendable, Equatable {
        let startSample: Int
        let endSample: Int
    }

    struct DecodedTrack: Sendable {
        let samples: [Float]
        let utterances: [Utterance]

        var duration: TimeInterval { TimeInterval(self.samples.count) / TimeInterval(MeetingProcessingEngine.sampleRate) }
    }

    /// Decode a track to 16 kHz mono and split it into utterances, off the
    /// main actor.
    @concurrent
    static func decodeAndSplit(url: URL) async throws -> DecodedTrack {
        let samples = try Self.loadSamples16kMono(url: url)
        return DecodedTrack(samples: samples, utterances: Self.splitOnSilence(samples: samples, sampleRate: Self.sampleRate))
    }

    /// Stream a whole audio file as 16 kHz mono Float32 chunks (about one
    /// minute each), so callers that only need to transform or copy the audio
    /// never hold the full recording in memory.
    static func forEach16kMonoChunk(url: URL, _ body: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw MeetingRecordingError("Invalid audio file (sample rate 0): \(url.lastPathComponent)")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false
        ) else {
            throw MeetingRecordingError("Failed to build 16k mono format.")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw MeetingRecordingError("Failed to create audio converter for \(url.lastPathComponent)")
        }

        let chunkFrames = AVAudioFrameCount(sourceFormat.sampleRate * 60) // 1 minute per read
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let toRead = min(chunkFrames, remaining)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: toRead) else {
                throw MeetingRecordingError("Failed to allocate read buffer")
            }
            try file.read(into: inBuffer, frameCount: toRead)

            let ratio = Double(Self.sampleRate) / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw MeetingRecordingError("Failed to allocate conversion buffer")
            }

            var consumed = false
            var conversionError: NSError?
            converter.convert(to: outBuffer, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw conversionError
            }
            if let channel = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                try body(Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength))))
            }
        }

        // The sample-rate converter holds back its filter latency between
        // calls (`.noDataNow`); signal end of stream and drain it, or the
        // file's last ~100 ms never comes out.
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                throw MeetingRecordingError("Failed to allocate conversion buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw conversionError
            }
            if let channel = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                try body(Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength))))
            }
            if status != .haveData || outBuffer.frameLength == 0 { break }
        }
    }

    /// Read a whole audio file as 16 kHz mono Float32 samples.
    static func loadSamples16kMono(url: URL) throws -> [Float] {
        var output: [Float] = []
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            output.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * Double(Self.sampleRate)) + 1024)
        }
        try Self.forEach16kMonoChunk(url: url) { output.append(contentsOf: $0) }
        return output
    }

    /// Split audio into utterances at silences, giving each a start/end
    /// timestamp so the two tracks can be interleaved. Energy-threshold VAD:
    /// crude but adequate for turn boundaries; a model-based VAD can replace
    /// it later without changing the pipeline shape.
    static func splitOnSilence(
        samples: [Float],
        sampleRate: Int,
        minSilence: TimeInterval = 0.45,
        minUtterance: TimeInterval = 1.0,
        maxUtterance: TimeInterval = 30.0
    ) -> [Utterance] {
        guard !samples.isEmpty else { return [] }

        let window = sampleRate / 33 // ~30 ms
        let windowCount = (samples.count + window - 1) / window

        var rms = [Float](repeating: 0, count: windowCount)
        for w in 0..<windowCount {
            let start = w * window
            let end = min(start + window, samples.count)
            var sum: Float = 0
            for i in start..<end {
                sum += samples[i] * samples[i]
            }
            rms[w] = (sum / Float(end - start)).squareRoot()
        }
        // Threshold from the track's noise floor rather than its mean: long
        // silent stretches (padded system audio, quiet mic) drag the mean
        // down and a mean-relative threshold with it. p20 approximates the
        // noise floor, p90 the speech level; cut a bit above the floor.
        let sorted = rms.sorted()
        let noiseFloor = sorted[windowCount / 5]
        let speechLevel = sorted[min(windowCount - 1, windowCount * 9 / 10)]
        let threshold = max(0.004, noiseFloor + (speechLevel - noiseFloor) * 0.18)

        let minSilenceWindows = max(1, Int(minSilence * Double(sampleRate)) / window)
        let minUtteranceSamples = Int(minUtterance * Double(sampleRate))
        let maxUtteranceSamples = Int(maxUtterance * Double(sampleRate))

        var utterances: [Utterance] = []
        var utteranceStart: Int? = nil
        var silentWindows = 0

        func close(at endSample: Int) {
            guard let start = utteranceStart else { return }
            let paddedEnd = min(endSample, samples.count)
            if paddedEnd - start >= minUtteranceSamples {
                // Hard-cap long utterances so single segments stay within
                // provider limits (Whisper-style models window at 30 s).
                // Split into equal chunks rather than max-size chunks plus a
                // remainder: every chunk is then <= maxUtterance and, when a
                // split happens at all, >= maxUtterance / 2 — never a sub-1s
                // tail the ASR provider rejects.
                let length = paddedEnd - start
                let chunkCount = (length + maxUtteranceSamples - 1) / maxUtteranceSamples
                let chunkLength = length / chunkCount
                var chunkStart = start
                for index in 0..<chunkCount {
                    let chunkEnd = index == chunkCount - 1 ? paddedEnd : chunkStart + chunkLength
                    utterances.append(Utterance(startSample: chunkStart, endSample: chunkEnd))
                    chunkStart = chunkEnd
                }
            }
            utteranceStart = nil
            silentWindows = 0
        }

        for w in 0..<windowCount {
            let isVoiced = rms[w] >= threshold
            if isVoiced {
                if utteranceStart == nil {
                    // Back up half a window so onsets aren't clipped.
                    utteranceStart = max(0, w * window - window / 2)
                }
                silentWindows = 0
            } else if utteranceStart != nil {
                silentWindows += 1
                if silentWindows >= minSilenceWindows {
                    close(at: (w - silentWindows + 1) * window + window)
                }
            }
        }
        close(at: samples.count)
        return utterances
    }

    // MARK: - Echo suppression (speaker -> mic bleed)

    /// Merge both tracks by start time, then remove "Me" (mic) segments that
    /// duplicate a near-simultaneous system segment — the acoustic bleed of
    /// the far-end voice through the speakers. Runs off the main actor: it is
    /// O(mic × system) token-set comparisons, which adds up on long meetings.
    @concurrent
    static func mergeSuppressingEcho(
        mic: [MeetingSegment],
        system: [MeetingSegment]
    ) async -> (segments: [MeetingSegment], droppedEchoes: Int) {
        let merged = (mic + system).sorted { $0.start < $1.start }
        let kept = Self.suppressEcho(in: merged)
        return (kept, merged.count - kept.count)
    }

    /// System audio never contains the mic, so a shared utterance is always
    /// leak on the mic side; keep the system copy, drop the mic echo.
    static func suppressEcho(in segments: [MeetingSegment]) -> [MeetingSegment] {
        let micLabel = Self.micSpeakerLabel
        let systemSegments = segments.filter { $0.speaker != micLabel }
        guard !systemSegments.isEmpty else { return segments }

        let systemTokens = systemSegments.map { (seg: $0, tokens: Self.tokenSet($0.text)) }
        let windowSeconds = 5.0

        return segments.filter { segment in
            guard segment.speaker == micLabel else { return true }
            let tokens = Self.tokenSet(segment.text)
            guard !tokens.isEmpty else { return true }
            let isEcho = systemTokens.contains { candidate in
                guard abs(candidate.seg.start - segment.start) <= windowSeconds
                    || Self.overlaps(segment, candidate.seg) else { return false }
                return Self.tokenSimilarity(tokens, candidate.tokens) >= 0.6
            }
            return !isEcho
        }
    }

    private static func overlaps(_ a: MeetingSegment, _ b: MeetingSegment) -> Bool {
        min(a.end, b.end) - max(a.start, b.start) > 0
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let cleaned = lowered.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        return Set(String(cleaned).split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    /// Symmetric token overlap: |A∩B| / |smaller set|, so a short echoed
    /// phrase still matches a longer system segment that contains it.
    private static func tokenSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        return Double(intersection) / Double(min(a.count, b.count))
    }

    // MARK: - Diarization ("Them" track)

    struct SpeakerSpan: Sendable, Equatable {
        let speakerId: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Diarization: Sendable {
        /// Spans of speakers that survived the short-cluster filter.
        let spans: [SpeakerSpan]
        /// Diarizer speaker id -> L2-normalised voice centroid.
        let centroids: [String: [Float]]
    }

    struct SpeakerResolution: Sendable {
        var segments: [MeetingSegment]
        /// Final label -> L2-normalised voice centroid, for enrolment and for
        /// persisting per-meeting so speakers can be named manually later.
        var embeddingByLabel: [String: [Float]]
    }

    /// Run the FluidAudio diarizer over the system track, off the main actor.
    /// The manager is created and torn down here so no CoreML state crosses
    /// actors.
    @concurrent
    static func diarize(
        samples: [Float],
        clusteringThreshold: Float = 0.75,
        minSpeakerDuration: TimeInterval = 2.0
    ) async throws -> Diarization {
        // The offline (pyannote community-1) pipeline was tried here as a
        // fix for cross-talk fragmenting one speaker into duplicate labels,
        // since it clusters globally and excludes overlapping-speech
        // frames from embedding extraction. Measured on an actual noisy
        // single-mic room recording it was worse, not better: at every
        // clustering threshold from 0.3 to 0.9 it collapsed the entire
        // 38-minute, ~6-person conversation into one speaker. The
        // streaming clusterer at least partially separates people; a
        // slightly higher threshold (0.75 vs. the library default 0.7)
        // measurably drops the smallest spurious clusters without yet
        // triggering the same collapse (which starts around 0.8 on this
        // recording).
        let config = DiarizerConfig(clusteringThreshold: clusteringThreshold)
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager(config: config)
        diarizer.initialize(models: models)
        defer { diarizer.cleanup() }
        let result = try diarizer.performCompleteDiarization(samples, sampleRate: Self.sampleRate)

        let allSpans = result.segments.map {
            SpeakerSpan(speakerId: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
        let spans = Self.dropShortSpeakers(allSpans, minDuration: minSpeakerDuration)
        let keptIds = Set(spans.map(\.speakerId))

        // Centroid embedding per diarized speaker: prefer the diarizer's own
        // speaker database, else average that speaker's segment embeddings.
        var centroids: [String: [Float]] = [:]
        for id in keptIds {
            if let dbEmbedding = result.speakerDatabase?[id] {
                centroids[id] = Self.normalize(dbEmbedding)
            } else {
                let embeddings = result.segments.filter { $0.speakerId == id }.map(\.embedding).filter { !$0.isEmpty }
                if let averaged = Self.averageEmbedding(embeddings) {
                    centroids[id] = averaged
                }
            }
        }
        return Diarization(spans: spans, centroids: centroids)
    }

    /// Drop clusters that are almost certainly noise/cross-talk blips rather
    /// than a real speaker: on a real recording these consistently show up as
    /// one- or two-segment clusters totalling only a couple of seconds,
    /// regardless of clustering threshold. Left in, they mint a "Them N"
    /// identity that never actually gets assigned to any transcribed line, so
    /// they only clutter speakers.json and the naming UI.
    static func dropShortSpeakers(_ spans: [SpeakerSpan], minDuration: TimeInterval) -> [SpeakerSpan] {
        var durationById: [String: TimeInterval] = [:]
        for span in spans {
            durationById[span.speakerId, default: 0] += span.end - span.start
        }
        return spans.filter { (durationById[$0.speakerId] ?? 0) >= minDuration }
    }

    /// Relabel each segment by its dominant diarized speaker. A speaker whose
    /// voice matched a saved profile (`matchedNames`) takes that name;
    /// otherwise it becomes "Them N" in order of first appearance, or plain
    /// "Them" when it is the only, unmatched speaker. Segments that overlap no
    /// speaker span keep their label.
    static func assignSpeakers(
        to segments: [MeetingSegment],
        diarization: Diarization,
        matchedNames: [String: String]
    ) -> SpeakerResolution {
        let spans = diarization.spans
        let distinctSpeakers = Set(spans.map(\.speakerId))
        guard !distinctSpeakers.isEmpty else {
            return SpeakerResolution(segments: segments, embeddingByLabel: [:])
        }

        var provisionalNumber: [String: Int] = [:]
        let singleUnmatched = distinctSpeakers.count == 1 && matchedNames[distinctSpeakers.first!] == nil
        for id in spans.sorted(by: { $0.start < $1.start }).map(\.speakerId) {
            guard provisionalNumber[id] == nil, matchedNames[id] == nil else { continue }
            provisionalNumber[id] = provisionalNumber.count + 1
        }

        func label(for id: String) -> String {
            if let matched = matchedNames[id] { return matched }
            if singleUnmatched { return Self.systemSpeakerLabel }
            return "\(Self.systemSpeakerLabel) \(provisionalNumber[id] ?? 1)"
        }

        var embeddingByLabel: [String: [Float]] = [:]
        for (id, centroid) in diarization.centroids where distinctSpeakers.contains(id) {
            embeddingByLabel[label(for: id)] = centroid
        }

        let relabelled = segments.map { segment -> MeetingSegment in
            var overlapBySpeaker: [String: Double] = [:]
            for span in spans {
                let overlap = min(segment.end, span.end) - max(segment.start, span.start)
                if overlap > 0 {
                    overlapBySpeaker[span.speakerId, default: 0] += overlap
                }
            }
            guard let dominant = overlapBySpeaker.max(by: { $0.value < $1.value })?.key else {
                return segment
            }
            return MeetingSegment(start: segment.start, end: segment.end, speaker: label(for: dominant), text: segment.text)
        }

        return SpeakerResolution(segments: relabelled, embeddingByLabel: embeddingByLabel)
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func averageEmbedding(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == first.count {
            let normalized = Self.normalize(embedding)
            for i in sum.indices { sum[i] += normalized[i] }
        }
        return Self.normalize(sum)
    }

    // MARK: - Rendering

    struct RenderedTranscript: Sendable {
        /// transcript.md contents.
        let markdown: String
        /// Plain "[MM:SS] Speaker: text" lines for history, summary and Q&A.
        let mergedText: String
    }

    @concurrent
    static func render(segments: [MeetingSegment], artifacts: MeetingRecordingArtifacts) async -> RenderedTranscript {
        RenderedTranscript(
            markdown: Self.renderMarkdown(segments: segments, artifacts: artifacts),
            mergedText: Self.mergedText(segments)
        )
    }

    static func renderMarkdown(segments: [MeetingSegment], artifacts: MeetingRecordingArtifacts) -> String {
        var lines: [String] = []
        lines.append("# Meeting \(artifacts.displayName)")
        lines.append("")
        if let source = artifacts.sourceFileName {
            lines.append("- Source: \(source)")
        }
        lines.append("- Started: \(artifacts.startedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("- Duration: \(Self.timestamp(artifacts.duration))")
        lines.append("")

        if segments.isEmpty {
            lines.append("_No speech detected on either track._")
        }
        for segment in segments {
            lines.append("**[\(Self.timestamp(segment.start))] \(segment.speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func mergedText(_ segments: [MeetingSegment]) -> String {
        segments
            .map { "[\(Self.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Strip Markdown header/bold from transcript.md so the summary model
    /// sees plain "[MM:SS] Speaker: ..." lines.
    static func plainTranscript(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { $0.contains("]") && $0.contains(":") }
            .map { $0.replacingOccurrences(of: "**", with: "") }
            .joined(separator: "\n")
    }

    static func timestamp(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

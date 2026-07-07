// MeetAI v2 native two-track meeting transcription.
//
// Transcribes mic.wav ("Me") and system.wav ("Them") separately with the
// active ASR provider, using silence-based utterance splitting so both
// tracks can be interleaved by timestamp into one speaker-labelled
// transcript. Output is written next to the recordings and registered in
// the file-transcription history.

import AVFoundation
import Combine
import Foundation

struct MeetingSegment: Sendable, Identifiable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
    let text: String
}

@MainActor
final class MeetingTranscriptPipeline: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var error: String?
    @Published var transcriptURL: URL?

    private let asrService: ASRService

    /// Speaker label for the microphone track. The mic is provably the local
    /// user, which is the whole point of recording two tracks.
    static let micSpeakerLabel = "Me"
    static let systemSpeakerLabel = "Them"

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    // MARK: - Entry point

    /// Transcribe both tracks of a recording and write transcript.md/.json
    /// into the session folder.
    @discardableResult
    func process(_ artifacts: MeetingRecordingArtifacts) async throws -> URL {
        self.isProcessing = true
        self.error = nil
        self.progress = 0.0
        let startTime = Date()

        defer {
            isProcessing = false
            progress = 0.0
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

            self.currentStatus = "Transcribing your microphone track..."
            let micSegments = try await self.transcribeTrack(
                url: artifacts.microphone,
                speaker: Self.micSpeakerLabel,
                provider: provider,
                progressRange: 0.05...0.45
            )

            self.currentStatus = "Transcribing the system-audio track..."
            let systemSegments = try await self.transcribeTrack(
                url: artifacts.systemAudio,
                speaker: Self.systemSpeakerLabel,
                provider: provider,
                progressRange: 0.45...0.9
            )

            self.currentStatus = "Merging tracks..."
            self.progress = 0.92
            let merged = (micSegments + systemSegments).sorted { $0.start < $1.start }

            let markdown = Self.renderMarkdown(segments: merged, artifacts: artifacts)
            let transcriptURL = artifacts.folder.appendingPathComponent("transcript.md")
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let mergedText = merged
                .map { "[\(Self.timestamp($0.start))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
            let historyEntry = TranscriptionResult(
                text: mergedText,
                confidence: 1.0,
                duration: artifacts.duration,
                processingTime: Date().timeIntervalSince(startTime),
                fileName: "Meeting \(artifacts.displayName)"
            )
            FileTranscriptionHistoryStore.shared.addEntry(historyEntry)

            self.currentStatus = "Complete!"
            self.progress = 1.0
            self.transcriptURL = transcriptURL
            return transcriptURL
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: - Per-track transcription

    private func transcribeTrack(
        url: URL,
        speaker: String,
        provider: TranscriptionProvider,
        progressRange: ClosedRange<Double>
    ) async throws -> [MeetingSegment] {
        let samples = try Self.loadSamples16kMono(url: url)
        let utterances = Self.splitOnSilence(samples: samples, sampleRate: 16_000)
        var segments: [MeetingSegment] = []

        for (index, utterance) in utterances.enumerated() {
            let slice = Array(samples[utterance.startSample..<utterance.endSample])
            let result = try await provider.transcribe(slice)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(MeetingSegment(
                    start: TimeInterval(utterance.startSample) / 16_000,
                    end: TimeInterval(utterance.endSample) / 16_000,
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

    // MARK: - Audio loading

    /// Read a whole audio file as 16 kHz mono Float32 samples, converting in
    /// chunks so multi-hour recordings don't require the file's native-rate
    /// audio in memory all at once.
    nonisolated static func loadSamples16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw MeetingRecordingError("Invalid audio file (sample rate 0): \(url.lastPathComponent)")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw MeetingRecordingError("Failed to build 16k mono format.")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw MeetingRecordingError("Failed to create audio converter for \(url.lastPathComponent)")
        }

        let chunkFrames = AVAudioFrameCount(sourceFormat.sampleRate * 60) // 1 minute per read
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) / sourceFormat.sampleRate * 16_000) + 1024)

        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let toRead = min(chunkFrames, remaining)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: toRead) else {
                throw MeetingRecordingError("Failed to allocate read buffer")
            }
            try file.read(into: inBuffer, frameCount: toRead)

            let ratio = 16_000 / sourceFormat.sampleRate
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
            if let channel = outBuffer.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
            }
        }
        return output
    }

    // MARK: - Silence-based utterance splitting

    struct Utterance {
        let startSample: Int
        let endSample: Int
    }

    /// Split audio into utterances at silences, giving each a start/end
    /// timestamp so the two tracks can be interleaved. Energy-threshold VAD:
    /// crude but adequate for turn boundaries; a model-based VAD can replace
    /// it later without changing the pipeline shape.
    nonisolated static func splitOnSilence(
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
                // Hard-cap long utterances so single segments stay well under
                // provider limits.
                var chunkStart = start
                while paddedEnd - chunkStart > maxUtteranceSamples {
                    utterances.append(Utterance(startSample: chunkStart, endSample: chunkStart + maxUtteranceSamples))
                    chunkStart += maxUtteranceSamples
                }
                utterances.append(Utterance(startSample: chunkStart, endSample: paddedEnd))
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

    // MARK: - Rendering

    nonisolated static func renderMarkdown(
        segments: [MeetingSegment],
        artifacts: MeetingRecordingArtifacts
    ) -> String {
        var lines: [String] = []
        lines.append("# Meeting \(artifacts.displayName)")
        lines.append("")
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

    nonisolated static func timestamp(_ interval: TimeInterval) -> String {
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

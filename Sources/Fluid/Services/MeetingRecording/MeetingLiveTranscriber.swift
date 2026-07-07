// MeetAI v2 live meeting transcription.
//
// Consumes the 16 kHz mono sample tees from both recorders and transcribes
// newly arrived audio on a rolling cadence, cutting chunks at silences so
// words aren't split. Segments accumulate with wall-clock timestamps and can
// be rendered live or handed to the meeting Q&A prompt.

import Combine
import Foundation

/// Thread-safe queue of samples with a running base offset, so timestamps
/// survive draining. Appended from audio threads, drained on the main actor.
final class LiveSampleQueue: @unchecked Sendable {
    private var samples: [Float] = []
    private var baseOffset: Int = 0
    private let lock = NSLock()

    func append(_ new: [Float]) {
        self.lock.lock()
        defer { lock.unlock() }
        self.samples.append(contentsOf: new)
    }

    /// Current pending samples and the absolute offset of their first sample.
    func snapshot() -> (offset: Int, samples: [Float]) {
        self.lock.lock()
        defer { lock.unlock() }
        return (self.baseOffset, self.samples)
    }

    /// Drop `count` samples from the front, advancing the base offset.
    func consume(_ count: Int) {
        self.lock.lock()
        defer { lock.unlock() }
        let safe = min(count, self.samples.count)
        self.samples.removeFirst(safe)
        self.baseOffset += safe
    }

    func reset() {
        self.lock.lock()
        defer { lock.unlock() }
        self.samples.removeAll()
        self.baseOffset = 0
    }
}

@MainActor
final class MeetingLiveTranscriber: ObservableObject {
    /// Shared so a live session survives sidebar navigation, like
    /// MeetingRecordingSession.shared.
    static let shared = MeetingLiveTranscriber()

    @Published private(set) var segments: [MeetingSegment] = []
    @Published private(set) var isRunning = false

    let micQueue = LiveSampleQueue()
    let systemQueue = LiveSampleQueue()

    private var asrService: ASRService?
    private var loopTask: Task<Void, Never>?

    /// Cadence between transcription passes.
    static let tickInterval: TimeInterval = 10
    /// Don't transcribe a chunk shorter than this; wait for the next tick.
    private static let minChunkSeconds: Double = 2
    /// Force a cut when this much audio is pending even without a silence.
    private static let maxChunkSeconds: Double = 25
    private static let sampleRate = 16_000

    func start(asrService: ASRService) {
        guard !self.isRunning else { return }
        self.asrService = asrService
        self.segments = []
        self.micQueue.reset()
        self.systemQueue.reset()
        self.isRunning = true

        self.loopTask = Task { [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                guard self.isRunning else { break }
                await self.tick(force: false)
            }
        }
    }

    /// Stop the loop and transcribe whatever is still pending.
    func finish() async {
        guard self.isRunning else { return }
        self.isRunning = false
        self.loopTask?.cancel()
        self.loopTask = nil
        await self.tick(force: true)
    }

    func reset() {
        self.loopTask?.cancel()
        self.loopTask = nil
        self.isRunning = false
        self.segments = []
        self.micQueue.reset()
        self.systemQueue.reset()
    }

    /// Merged transcript so far, for the live pane and the Q&A prompt.
    var transcriptText: String {
        self.segments
            .map { "[\(MeetingTranscriptPipeline.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Transcription pass

    private func tick(force: Bool) async {
        guard let asrService else { return }
        let provider = asrService.fileTranscriptionProvider
        guard provider.isReady else { return } // model still loading; next tick catches up

        var newSegments: [MeetingSegment] = []
        newSegments += await self.drainAndTranscribe(
            queue: self.micQueue,
            speaker: MeetingTranscriptPipeline.micSpeakerLabel,
            provider: provider,
            force: force
        )
        newSegments += await self.drainAndTranscribe(
            queue: self.systemQueue,
            speaker: MeetingTranscriptPipeline.systemSpeakerLabel,
            provider: provider,
            force: force
        )
        guard !newSegments.isEmpty else { return }
        self.segments = (self.segments + newSegments).sorted { $0.start < $1.start }
    }

    private func drainAndTranscribe(
        queue: LiveSampleQueue,
        speaker: String,
        provider: TranscriptionProvider,
        force: Bool
    ) async -> [MeetingSegment] {
        let (offset, pending) = queue.snapshot()
        let minSamples = Int(Self.minChunkSeconds) * Self.sampleRate
        guard pending.count >= minSamples else {
            if force { queue.consume(pending.count) }
            return []
        }

        // Cut at the last silence so we don't split a word mid-utterance; if
        // none is found, only proceed when forced or the backlog is too big.
        var cut = Self.lastSilenceCut(in: pending, sampleRate: Self.sampleRate)
        if cut < minSamples {
            let maxSamples = Int(Self.maxChunkSeconds) * Self.sampleRate
            if force || pending.count >= maxSamples {
                cut = pending.count
            } else {
                return []
            }
        }

        let chunk = Array(pending[0..<cut])
        queue.consume(cut)

        // Skip all-silence chunks (e.g. padded system audio while nobody talks).
        let utterances = MeetingTranscriptPipeline.splitOnSilence(samples: chunk, sampleRate: Self.sampleRate)
        var results: [MeetingSegment] = []
        for utterance in utterances {
            let slice = Array(chunk[utterance.startSample..<utterance.endSample])
            guard let result = try? await provider.transcribe(slice) else { continue }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            results.append(MeetingSegment(
                start: TimeInterval(offset + utterance.startSample) / TimeInterval(Self.sampleRate),
                end: TimeInterval(offset + utterance.endSample) / TimeInterval(Self.sampleRate),
                speaker: speaker,
                text: text
            ))
        }
        return results
    }

    /// Index just past the last ≥0.3 s quiet stretch, scanning backwards, so
    /// chunks end on a pause. Returns 0 if the tail has no usable silence.
    private static func lastSilenceCut(in samples: [Float], sampleRate: Int) -> Int {
        let window = sampleRate / 33 // ~30 ms
        let quietWindowsNeeded = max(1, Int(0.3 * Double(sampleRate)) / window)
        let windowCount = samples.count / window
        guard windowCount > quietWindowsNeeded else { return 0 }

        var quiet = 0
        var w = windowCount - 1
        while w >= 0 {
            let start = w * window
            var sum: Float = 0
            for i in start..<(start + window) {
                sum += samples[i] * samples[i]
            }
            let rms = (sum / Float(window)).squareRoot()
            if rms < 0.004 {
                quiet += 1
                if quiet >= quietWindowsNeeded {
                    return (w + quietWindowsNeeded) * window
                }
            } else {
                quiet = 0
            }
            w -= 1
        }
        return 0
    }
}

@testable import FluidVoice_Debug
import XCTest

// Unit tests for the pure stages of the meeting pipeline: utterance
// splitting, echo suppression, transcript flattening and speaker relabelling.
// None of these need models, audio files or an AI provider.

@MainActor
final class MeetingPipelineTests: XCTestCase {
    private let sampleRate = 16_000

    // MARK: - Helpers

    /// `seconds` of a 220 Hz sine at amplitude 0.3 (clearly "voiced").
    private func tone(_ seconds: Double) -> [Float] {
        let count = Int(seconds * Double(self.sampleRate))
        return (0..<count).map { 0.3 * sin(2 * .pi * 220 * Float($0) / Float(self.sampleRate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(self.sampleRate)))
    }

    private func segment(_ start: TimeInterval, _ speaker: String, _ text: String) -> MeetingSegment {
        MeetingSegment(start: start, end: start + 2, speaker: speaker, text: text)
    }

    // MARK: - splitOnSilence

    func testSplitOnSilence_cutsAtSilences() {
        let samples = self.silence(1) + self.tone(2) + self.silence(1) + self.tone(3) + self.silence(1)
        let utterances = MeetingTranscriptPipeline.splitOnSilence(samples: samples, sampleRate: self.sampleRate)

        XCTAssertEqual(utterances.count, 2)
        guard utterances.count == 2 else { return }
        XCTAssertEqual(Double(utterances[0].startSample) / 16_000, 1.0, accuracy: 0.05)
        XCTAssertEqual(Double(utterances[1].startSample) / 16_000, 4.0, accuracy: 0.05)
        XCTAssertGreaterThan(utterances[1].endSample - utterances[1].startSample, 3 * self.sampleRate - 1_000)
    }

    func testSplitOnSilence_dropsBlipsShorterThanMinimum() {
        let samples = self.silence(1) + self.tone(0.3) + self.silence(2) + self.tone(2) + self.silence(1)
        let utterances = MeetingTranscriptPipeline.splitOnSilence(samples: samples, sampleRate: self.sampleRate)

        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(Double(utterances.first?.startSample ?? 0) / 16_000, 3.3, accuracy: 0.05)
    }

    func testSplitOnSilence_longUtteranceSplitsEvenlyUnderCap() {
        for (seconds, expectedChunks) in [(31.0, 2), (60.5, 3), (89.0, 3), (29.0, 1)] {
            let samples = self.silence(1) + self.tone(seconds) + self.silence(1)
            let utterances = MeetingTranscriptPipeline.splitOnSilence(samples: samples, sampleRate: self.sampleRate)
            XCTAssertEqual(utterances.count, expectedChunks, "\(seconds)s utterance")
            for utterance in utterances {
                let length = utterance.endSample - utterance.startSample
                XCTAssertLessThanOrEqual(length, 30 * self.sampleRate, "\(seconds)s: chunk over the 30 s cap")
                if expectedChunks > 1 {
                    XCTAssertGreaterThanOrEqual(length, 15 * self.sampleRate - 1, "\(seconds)s: chunk too short")
                }
            }
            for (a, b) in zip(utterances, utterances.dropFirst()) {
                XCTAssertEqual(a.endSample, b.startSample, "chunks must be contiguous")
            }
        }
    }

    func testSplitOnSilence_emptyInput() {
        XCTAssertTrue(MeetingTranscriptPipeline.splitOnSilence(samples: [], sampleRate: self.sampleRate).isEmpty)
    }

    // MARK: - suppressEcho

    func testSuppressEcho_dropsMicLineThatEchoesNearbySystemLine() {
        let segments = [
            self.segment(10, "Them", "Let's ship the release on Friday afternoon"),
            self.segment(11, "Me", "ship the release on Friday"),
        ]
        let kept = MeetingTranscriptPipeline.suppressEcho(in: segments)
        XCTAssertEqual(kept.map(\.speaker), ["Them"])
    }

    func testSuppressEcho_keepsDistinctMicLine() {
        let segments = [
            self.segment(10, "Them", "Let's ship the release on Friday afternoon"),
            self.segment(11, "Me", "Sounds good, I'll update the changelog"),
        ]
        XCTAssertEqual(MeetingTranscriptPipeline.suppressEcho(in: segments).count, 2)
    }

    func testSuppressEcho_keepsSameTextOutsideWindow() {
        let segments = [
            self.segment(10, "Them", "ship the release on Friday"),
            self.segment(60, "Me", "ship the release on Friday"),
        ]
        XCTAssertEqual(MeetingTranscriptPipeline.suppressEcho(in: segments).count, 2)
    }

    // MARK: - plainTranscript

    func testPlainTranscript_stripsHeaderAndBold() {
        let markdown = """
        # Meeting 2026-07-09T10-00-00Z

        - Started: 9 Jul 2026 at 10:00 am
        - Duration: 01:00

        **[00:01] Me:** Hello there

        **[00:04] Them 1:** Hi, ready to start?
        """
        XCTAssertEqual(
            MeetingTranscriptPipeline.plainTranscript(markdown),
            "[00:01] Me: Hello there\n[00:04] Them 1: Hi, ready to start?"
        )
    }

    // MARK: - MeetingRelabeler

    func testApplyToTranscript_matchesLongestLabelFirst() {
        let text = "**[00:01] Them:** hi\n**[00:04] Them 1:** hello Them"
        let updated = MeetingRelabeler.applyToTranscript(text, map: ["Them": "Alex", "Them 1": "Sam"])
        XCTAssertEqual(updated, "**[00:01] Alex:** hi\n**[00:04] Sam:** hello Them")
    }

    func testApplyToTranscript_plainLines() {
        let updated = MeetingRelabeler.applyToTranscript("[00:01] Them 2: ok", map: ["Them 2": "Priya"])
        XCTAssertEqual(updated, "[00:01] Priya: ok")
    }
}

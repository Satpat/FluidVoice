@testable import FluidVoice_Debug
import AVFoundation
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
        let utterances = MeetingProcessingEngine.splitOnSilence(samples: samples, sampleRate: self.sampleRate)

        XCTAssertEqual(utterances.count, 2)
        guard utterances.count == 2 else { return }
        XCTAssertEqual(Double(utterances[0].startSample) / 16_000, 1.0, accuracy: 0.05)
        XCTAssertEqual(Double(utterances[1].startSample) / 16_000, 4.0, accuracy: 0.05)
        XCTAssertGreaterThan(utterances[1].endSample - utterances[1].startSample, 3 * self.sampleRate - 1_000)
    }

    func testSplitOnSilence_dropsBlipsShorterThanMinimum() {
        let samples = self.silence(1) + self.tone(0.3) + self.silence(2) + self.tone(2) + self.silence(1)
        let utterances = MeetingProcessingEngine.splitOnSilence(samples: samples, sampleRate: self.sampleRate)

        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(Double(utterances.first?.startSample ?? 0) / 16_000, 3.3, accuracy: 0.05)
    }

    func testSplitOnSilence_longUtteranceSplitsEvenlyUnderCap() {
        for (seconds, expectedChunks) in [(31.0, 2), (60.5, 3), (89.0, 3), (29.0, 1)] {
            let samples = self.silence(1) + self.tone(seconds) + self.silence(1)
            let utterances = MeetingProcessingEngine.splitOnSilence(samples: samples, sampleRate: self.sampleRate)
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
        XCTAssertTrue(MeetingProcessingEngine.splitOnSilence(samples: [], sampleRate: self.sampleRate).isEmpty)
    }

    // MARK: - suppressEcho

    func testSuppressEcho_dropsMicLineThatEchoesNearbySystemLine() {
        let segments = [
            self.segment(10, "Them", "Let's ship the release on Friday afternoon"),
            self.segment(11, "Me", "ship the release on Friday"),
        ]
        let kept = MeetingProcessingEngine.suppressEcho(in: segments)
        XCTAssertEqual(kept.map(\.speaker), ["Them"])
    }

    func testSuppressEcho_keepsDistinctMicLine() {
        let segments = [
            self.segment(10, "Them", "Let's ship the release on Friday afternoon"),
            self.segment(11, "Me", "Sounds good, I'll update the changelog"),
        ]
        XCTAssertEqual(MeetingProcessingEngine.suppressEcho(in: segments).count, 2)
    }

    func testSuppressEcho_keepsSameTextOutsideWindow() {
        let segments = [
            self.segment(10, "Them", "ship the release on Friday"),
            self.segment(60, "Me", "ship the release on Friday"),
        ]
        XCTAssertEqual(MeetingProcessingEngine.suppressEcho(in: segments).count, 2)
    }

    func testMergeSuppressingEcho_sortsAndCountsDrops() async {
        let mic = [self.segment(11, "Me", "ship the release on Friday"), self.segment(30, "Me", "agreed")]
        let system = [self.segment(10, "Them", "Let's ship the release on Friday afternoon")]
        let result = await MeetingProcessingEngine.mergeSuppressingEcho(mic: mic, system: system)
        XCTAssertEqual(result.segments.map(\.text), ["Let's ship the release on Friday afternoon", "agreed"])
        XCTAssertEqual(result.droppedEchoes, 1)
    }

    // MARK: - Speaker assignment

    private func span(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> MeetingProcessingEngine.SpeakerSpan {
        MeetingProcessingEngine.SpeakerSpan(speakerId: id, start: start, end: end)
    }

    func testDropShortSpeakers_removesBlipClusters() {
        let spans = [self.span("A", 0, 5), self.span("B", 5, 6), self.span("B", 7, 7.5), self.span("C", 8, 10)]
        let kept = MeetingProcessingEngine.dropShortSpeakers(spans, minDuration: 2.0)
        XCTAssertEqual(Set(kept.map(\.speakerId)), ["A", "C"])
    }

    func testAssignSpeakers_dominantOverlapAndNumbering() {
        let diarization = MeetingProcessingEngine.Diarization(
            spans: [self.span("s2", 0, 4), self.span("s1", 4, 12), self.span("s2", 12, 20)],
            centroids: ["s1": [1, 0], "s2": [0, 1]]
        )
        let segments = [
            MeetingSegment(start: 0, end: 5, speaker: "Them", text: "a"), // mostly s2
            MeetingSegment(start: 5, end: 11, speaker: "Them", text: "b"), // s1
            MeetingSegment(start: 30, end: 31, speaker: "Them", text: "c"), // no overlap -> unchanged
        ]
        let resolution = MeetingProcessingEngine.assignSpeakers(to: segments, diarization: diarization, matchedNames: [:])
        // Numbered by first appearance: s2 speaks first.
        XCTAssertEqual(resolution.segments.map(\.speaker), ["Them 1", "Them 2", "Them"])
        XCTAssertEqual(resolution.embeddingByLabel["Them 1"], [0, 1])
        XCTAssertEqual(resolution.embeddingByLabel["Them 2"], [1, 0])
    }

    func testAssignSpeakers_profileMatchAndSingleUnmatchedSpeaker() {
        let one = MeetingProcessingEngine.Diarization(spans: [self.span("s1", 0, 10)], centroids: ["s1": [1, 0]])
        let segments = [MeetingSegment(start: 1, end: 3, speaker: "Them", text: "hi")]

        let unmatched = MeetingProcessingEngine.assignSpeakers(to: segments, diarization: one, matchedNames: [:])
        XCTAssertEqual(unmatched.segments.first?.speaker, "Them")

        let matched = MeetingProcessingEngine.assignSpeakers(to: segments, diarization: one, matchedNames: ["s1": "Priya"])
        XCTAssertEqual(matched.segments.first?.speaker, "Priya")
        XCTAssertEqual(matched.embeddingByLabel["Priya"], [1, 0])
    }

    // MARK: - Rendering

    func testRenderMarkdown_includesSourceForUploads() {
        let folder = URL(fileURLWithPath: "/tmp/2026-07-09T10-00-00")
        let artifacts = MeetingRecordingArtifacts(
            folder: folder,
            systemAudio: folder.appendingPathComponent("system.wav"),
            microphone: folder.appendingPathComponent("mic.wav"),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 65),
            sourceFileName: "interview.m4a"
        )
        let markdown = MeetingProcessingEngine.renderMarkdown(
            segments: [MeetingSegment(start: 3, end: 5, speaker: "Them", text: "hello")],
            artifacts: artifacts
        )
        XCTAssertTrue(markdown.contains("- Source: interview.m4a"))
        XCTAssertTrue(markdown.contains("- Duration: 01:05"))
        XCTAssertTrue(markdown.contains("**[00:03] Them:** hello"))
        // The source line must not leak into the summary model's transcript.
        XCTAssertEqual(MeetingProcessingEngine.plainTranscript(markdown), "[00:03] Them: hello")
    }

    // MARK: - Upload import

    func testImportArtifacts_streamsTo16kAndWritesManifest() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // 2.5 s of 44.1 kHz stereo — exercises resampling and downmix.
        let sourceURL = temp.appendingPathComponent("upload source.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = AVAudioFrameCount(44_100 * 2.5)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = 0.3 * sin(2 * .pi * 220 * Float(i) / 44_100)
            }
        }
        try AVAudioFile(forWriting: sourceURL, settings: format.settings).write(from: buffer)

        let base = temp.appendingPathComponent("MeetingRecordings", isDirectory: true)
        let artifacts = try await MeetingUploadImporter.importArtifacts(from: sourceURL, baseDirectory: base)

        XCTAssertEqual(artifacts.sourceFileName, "upload source.wav")
        XCTAssertEqual(artifacts.duration, 2.5, accuracy: 0.05)
        let system = try MeetingProcessingEngine.loadSamples16kMono(url: artifacts.systemAudio)
        XCTAssertEqual(Double(system.count), 2.5 * 16_000, accuracy: 1_600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.microphone.path))

        let reloaded = try XCTUnwrap(MeetingReprocessor.artifacts(inFolder: artifacts.folder))
        XCTAssertEqual(reloaded.sourceFileName, "upload source.wav")
    }

    func testImportArtifacts_rejectsSilentFileAndCleansUp() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = temp.appendingPathComponent("empty.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        _ = try AVAudioFile(forWriting: sourceURL, settings: format.settings) // zero frames

        let base = temp.appendingPathComponent("MeetingRecordings", isDirectory: true)
        do {
            _ = try await MeetingUploadImporter.importArtifacts(from: sourceURL, baseDirectory: base)
            XCTFail("expected an error for an empty file")
        } catch {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "failed import must not leave a session folder")
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
            MeetingProcessingEngine.plainTranscript(markdown),
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

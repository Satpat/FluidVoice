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

    private func assertSame(_ a: MeetingSession, _ b: MeetingSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.id, b.id, file: file, line: line)
        XCTAssertEqual(a.mode, b.mode, file: file, line: line)
        XCTAssertEqual(a.state, b.state, file: file, line: line)
        XCTAssertEqual(a.title, b.title, file: file, line: line)
        XCTAssertEqual(a.audioTracks, b.audioTracks, file: file, line: line)
        XCTAssertEqual(a.speakers, b.speakers, file: file, line: line)
        XCTAssertEqual(a.transcriptSegments, b.transcriptSegments, file: file, line: line)
        XCTAssertEqual(a.endedAt?.timeIntervalSince1970 ?? 0, b.endedAt?.timeIntervalSince1970 ?? 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(a.hasRetryableAudio, b.hasRetryableAudio, file: file, line: line)
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
            XCTAssertEqual(chunk.audioSchemaVersion, 2)
            XCTAssertEqual(chunk.captureAnalysisAsset?.encoding, .linearPCMFloat32CAFV1)
            XCTAssertEqual(chunk.captureAnalysisAsset?.validationIssues().isEmpty, true)
            XCTAssertEqual(chunk.captureAnalysisAsset?.sha256, chunk.sha256)
            XCTAssertEqual(chunk.relativeFilePath, "tracks/microphone/\(String(format: "%06d", chunk.sequence)).caf")
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
        self.assertSame(loaded, session)
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
        self.assertSame(loaded, session)
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

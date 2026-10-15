@testable import FluidVoice_Debug
import XCTest

// Smoke tests for the FluidAudio dependency: Parakeet ASR (dictation and
// meetings) and the speaker diarizer (meetings). They use models already in
// the local FluidAudio cache and skip when those aren't present, so they
// never trigger a multi-hundred-MB download. Run them after bumping
// FluidAudio to catch API or behaviour regressions.

@MainActor
final class FluidAudioSmokeTests: XCTestCase {
    private static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private func requireCachedModel(_ name: String) throws {
        let path = Self.modelsDirectory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("FluidAudio model \(name) is not cached at \(path)")
        }
    }

    func testParakeetV2TranscribesFixture() async throws {
        #if arch(arm64)
        try self.requireCachedModel("parakeet-tdt-0.6b-v2-coreml")

        let provider = FluidAudioProvider(modelOverride: .parakeetTDTv2, configureWordBoosting: false)
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribeFinal(samples)

        let text = result.text.lowercased()
        XCTAssertTrue(text.contains("hello"), "Got: \(result.text)")
        XCTAssertTrue(text.contains("fluid"), "Got: \(result.text)")
        #else
        throw XCTSkip("FluidAudio providers are arm64-only")
        #endif
    }

    func testDiarizerRunsOnFixture() async throws {
        try self.requireCachedModel("speaker-diarization-coreml")

        let fixture = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        // Pad to a meeting-like length so the diarizer has full windows.
        let samples = fixture + [Float](repeating: 0, count: 16_000 * 5) + fixture
        let diarization = try await MeetingProcessingEngine.diarize(samples: samples, minSpeakerDuration: 0)

        XCTAssertFalse(diarization.spans.isEmpty, "Expected at least one speaker span on speech audio")
        let ids = Set(diarization.spans.map(\.speakerId))
        XCTAssertTrue(Set(diarization.centroids.keys).isSubset(of: ids))
        for centroid in diarization.centroids.values {
            let norm = centroid.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(norm, 1, accuracy: 0.01, "centroids must be L2-normalised")
        }
    }
}

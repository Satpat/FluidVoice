@testable import FluidVoice_Debug
import XCTest

// Smoke test for the FluidAudio dependency at upstream's pin. Uses a model already in the
// local FluidAudio cache and skips otherwise, so it never triggers a large download.
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
}

@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIEmbedderTests: XCTestCase {
    func testClipsAreTenSecondWindowsAndDropShortTail() {
        let audio = [Float](repeating: 0.1, count: 16_000 * 25)
        let clips = MeetAIFluidAudioEmbedder.clips(from: audio)
        XCTAssertEqual(clips.map(\.count), [160_000, 160_000, 80_000])
        XCTAssertTrue(MeetAIFluidAudioEmbedder.clips(from: [Float](repeating: 0, count: 40_000)).isEmpty)
    }

    /// Opt-in (downloads/loads the diarizer embedding model): TEST_RUNNER_MEETAI_MODEL_TESTS=1
    func testSameVoiceMatchesAndDifferentVoicesDoNot() async throws {
        guard ProcessInfo.processInfo.environment["MEETAI_MODEL_TESTS"] == "1" else { throw XCTSkip("model test") }
        let directory = try MeetAIFixtures.tempDirectory(self)
        func say(_ voice: String, _ text: String, _ name: String) throws -> [Float] {
            let url = directory.appendingPathComponent("\(name).aiff")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-o", url.path, text]
            try process.run()
            process.waitUntilExit()
            return try MeetAIAudioDecoder.load16kMono(url: url)
        }
        let paragraph = "We reviewed the quarterly roadmap and agreed to ship the meeting features after the migration finishes and the tests pass."
        let samA1 = try say("Samantha", paragraph, "a1")
        let samA2 = try say("Samantha", paragraph + " Then we talked about the budget for next quarter.", "a2")
        let danB = try say("Daniel", paragraph, "b1")
        let embeddings = try await MeetAIFluidAudioEmbedder.embed(clips: [samA1, samA2, danB].map { Array($0.prefix(160_000)) })
        XCTAssertEqual(embeddings.count, 3)
        let same = MeetAISpeakerMath.dot(MeetAISpeakerMath.normalize(embeddings[0]), MeetAISpeakerMath.normalize(embeddings[1]))
        let different = MeetAISpeakerMath.dot(MeetAISpeakerMath.normalize(embeddings[0]), MeetAISpeakerMath.normalize(embeddings[2]))
        print("MEETAI-EMBED same=\(same) different=\(different)")
        XCTAssertGreaterThanOrEqual(same, MeetAISpeakerProfileStore.matchThreshold)
        XCTAssertLessThan(different, MeetAISpeakerProfileStore.matchThreshold)
    }
}

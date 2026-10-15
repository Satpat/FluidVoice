@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIQATests: XCTestCase {
    private func session() -> MeetingSession {
        MeetAIFixtures.session(speakers: [("You", true), ("Sam", false)], lines: [.init(speaker: 1, start: 0, end: 4, text: "The launch is on Friday.")])
    }

    func testAskUsesThisSessionsTranscriptAndPersistsHistory() async throws {
        let session = self.session()
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let llm = FakeLLM(replies: ["Friday.", "Sam said it."])
        let service = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: llm)
        await service.ask("When is the launch?", session: session)
        await service.ask("Who said that?", session: session)
        XCTAssertEqual(service.records.map(\.answer), ["Friday.", "Sam said it."])
        XCTAssertTrue(llm.prompts[0].contains("The launch is on Friday."))
        XCTAssertTrue(llm.prompts[1].contains("When is the launch?"), "earlier turns go with follow-ups")

        let reopened = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: llm)
        await reopened.load()
        XCTAssertEqual(reopened.records.count, 2)
        await reopened.clear()
        let afterClear = try await sidecars.qa(for: session.id)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testAskSurfacesProviderErrorWithoutRecording() async throws {
        let session = self.session()
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let service = MeetAIQAService(sessionID: session.id, sidecars: sidecars, llm: FakeLLM(error: MeetAILLMError("No AI provider is selected.")))
        await service.ask("Anything?", session: session)
        XCTAssertEqual(service.error, "No AI provider is selected.")
        XCTAssertTrue(service.records.isEmpty)
        XCTAssertFalse(service.isThinking)
    }

    func testBlankQuestionIsIgnored() async throws {
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let llm = FakeLLM(replies: ["x"])
        let service = MeetAIQAService(sessionID: UUID(), sidecars: sidecars, llm: llm)
        await service.ask("   ", session: self.session())
        XCTAssertTrue(llm.prompts.isEmpty)
    }
}

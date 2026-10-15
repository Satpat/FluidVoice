@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAISummaryTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Sam", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Ship it Friday."), .init(speaker: 0, start: 4, end: 6, text: "Agreed.")]
        )
    }

    func testGenerateRecordsStyleHashAndProvider() async throws {
        let llm = FakeLLM(replies: ["  ## Overview\nShip Friday.  "])
        let record = try await MeetAISummarizer.generate(session: self.session(), style: .keyTakeaways, llm: llm)
        XCTAssertEqual(record.markdown, "## Overview\nShip Friday.")
        XCTAssertEqual(record.style, "keyTakeaways")
        XCTAssertEqual(record.transcriptHash, MeetAITranscript.hash(for: self.session()))
        XCTAssertEqual(record.providerID, "fake")
        XCTAssertTrue(llm.prompts[0].contains("## Key takeaways"))
        XCTAssertTrue(llm.prompts[0].contains("Ship it Friday."))
    }

    func testPerSpeakerStyleNamesTheLocalUser() {
        XCTAssertTrue(MeetAISummaryStyle.whatByWhenPerSpeaker.formatInstructions(localLabel: "You").contains("(\"You\") first"))
    }

    func testSummaryOfEmptyTranscriptFailsCleanly() async {
        let empty = MeetAIFixtures.session(speakers: [("You", true)], lines: [])
        let llm = FakeLLM(replies: ["should not be called"])
        do {
            _ = try await MeetAISummarizer.generate(session: empty, style: .standard, llm: llm)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no transcript"))
        }
        XCTAssertTrue(llm.prompts.isEmpty)
    }

    private func processor(session: MeetingSession, llm: FakeLLM) throws -> (MeetAISessionProcessor, MeetAISidecarStore) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let settings = MeetAISettings(defaults: UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!)
        settings.speakerMatching = false
        settings.autoName = false
        let mutator = FakeMutator(session)
        mutator.session.defaultTitleBase = nil
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars, profiles: MeetAISpeakerProfileStore(fileURL: paths.profilesFile), settings: settings,
            embedder: FakeEmbedder(bySpeakerText: [:]), llm: llm, mutator: { mutator },
            loadSession: { _ in mutator.session }, sessionDirectory: { _ in root }, retryDelay: .milliseconds(1)
        ))
        return (processor, sidecars)
    }

    func testAutomationSummarisesOnceWithDefaultStyle() async throws {
        let session = self.session()
        let llm = FakeLLM(replies: ["Summary one", "Summary two"])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        await processor.runAutomation(sessionID: session.id)
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertEqual(summary?.markdown, "Summary one")
        XCTAssertEqual(summary?.style, "standard")
    }

    func testSummaryErrorIsRecordedNotThrown() async throws {
        let session = self.session()
        let llm = FakeLLM(error: MeetAILLMError("Missing API key for openai. Add it under AI Enhancement."))
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(processor.summaryErrors[session.id], "Missing API key for openai. Add it under AI Enhancement.")
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertNil(summary)
        llm.error = nil
        llm.replies = ["Recovered"]
        await processor.regenerateSummary(sessionID: session.id, style: .standard)
        XCTAssertNil(processor.summaryErrors[session.id])
        let recovered = try await sidecars.summary(for: session.id)
        XCTAssertEqual(recovered?.markdown, "Recovered")
    }
}

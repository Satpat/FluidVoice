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

    private func processor(
        session: MeetingSession,
        llm: FakeLLM,
        configure: (MeetAISettings) -> Void = { _ in }
    ) throws -> (MeetAISessionProcessor, MeetAISidecarStore) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let settings = MeetAISettings(defaults: UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!)
        settings.speakerMatching = false
        settings.autoName = false
        configure(settings)
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

    private let bengali = "আমি কাল অফিসে যাব"

    private func mixedSession() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Sam", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Ship it Friday."), .init(speaker: 0, start: 4, end: 6, text: self.bengali)]
        )
    }

    func testAutomationTranslatesFirstAndSummaryReadsEnglishButHashesOriginal() async throws {
        let session = self.mixedSession()
        let segment = try XCTUnwrap(session.transcriptSegments.first { $0.text == self.bengali })
        let reply = "[{\"id\": \"\(segment.id.uuidString)\", \"english\": \"I will go to the office tomorrow\"}]"
        let llm = FakeLLM(replies: [reply, "Summary"])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)

        XCTAssertEqual(llm.prompts.count, 2, "one translation call, then the summary")
        XCTAssertTrue(llm.prompts[0].contains(self.bengali))
        XCTAssertTrue(llm.prompts[1].contains("I will go to the office tomorrow"))
        XCTAssertFalse(llm.prompts[1].contains(self.bengali), "the summary reads the English")
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertEqual(summary?.markdown, "Summary")
        XCTAssertEqual(summary?.transcriptHash, MeetAITranscript.hash(for: session), "staleness stays on the original text")
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertEqual(translations[segment.id.uuidString]?.english, "I will go to the office tomorrow")
    }

    func testEnglishOnlyMeetingNeverCallsTheTranslator() async throws {
        let session = self.session()
        let llm = FakeLLM(replies: ["Summary"])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(llm.prompts.count, 1)
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
    }

    func testTranslationFailureDoesNotBlockTheSummaryStep() async throws {
        let session = self.mixedSession()
        let llm = FakeLLM(error: MeetAILLMError("Missing API key"))
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(processor.summaryErrors[session.id], "Missing API key", "the summary step still ran")
        XCTAssertEqual(llm.prompts.count, 2, "translation attempt, then summary attempt")
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
    }

    func testTurningTranslationOffSkipsIt() async throws {
        let session = self.mixedSession()
        let llm = FakeLLM(replies: ["Summary"])
        let (processor, sidecars) = try self.processor(session: session, llm: llm) { $0.translateIndicSpeech = false }
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(llm.prompts.count, 1)
        XCTAssertTrue(llm.prompts[0].contains(self.bengali), "the summary sees the original text")
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
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

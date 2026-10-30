@testable import FluidVoice_Debug
import XCTest

@MainActor
/// MeetAI's after-meeting automation: Indian-language translation ahead of naming and titling.
final class MeetAIAutomationTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Sam", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Ship it Friday."), .init(speaker: 0, start: 4, end: 6, text: "Agreed.")]
        )
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

    private let bengali = "আমি কাল অফিসে যাব"

    private func mixedSession() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Sam", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Ship it Friday."), .init(speaker: 0, start: 4, end: 6, text: self.bengali)]
        )
    }

    func testAutomationTranslatesIndicSegmentsWithoutWritingASummary() async throws {
        let session = self.mixedSession()
        let segment = try XCTUnwrap(session.transcriptSegments.first { $0.text == self.bengali })
        let reply = "[{\"id\": \"\(segment.id.uuidString)\", \"english\": \"I will go to the office tomorrow\"}]"
        let llm = FakeLLM(replies: [reply])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)

        XCTAssertEqual(llm.prompts.count, 1, "one translation call; summaries are upstream's now")
        XCTAssertTrue(llm.prompts[0].contains(self.bengali))
        let summary = try await sidecars.summary(for: session.id)
        XCTAssertNil(summary)
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertEqual(translations[segment.id.uuidString]?.english, "I will go to the office tomorrow")
    }

    func testEnglishOnlyMeetingNeverCallsTheTranslator() async throws {
        let session = self.session()
        let llm = FakeLLM(replies: [])
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertTrue(llm.prompts.isEmpty)
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
    }

    func testTranslationFailureLeavesNoTranslations() async throws {
        let session = self.mixedSession()
        let llm = FakeLLM(error: MeetAILLMError("Missing API key"))
        let (processor, sidecars) = try self.processor(session: session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(llm.prompts.count, 1, "one translation attempt")
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
    }

    func testTurningTranslationOffSkipsIt() async throws {
        let session = self.mixedSession()
        let llm = FakeLLM(replies: [])
        let (processor, sidecars) = try self.processor(session: session, llm: llm) { $0.translateIndicSpeech = false }
        await processor.runAutomation(sessionID: session.id)
        XCTAssertTrue(llm.prompts.isEmpty)
        let translations = try await sidecars.translations(for: session.id)
        XCTAssertTrue(translations.isEmpty)
    }
}

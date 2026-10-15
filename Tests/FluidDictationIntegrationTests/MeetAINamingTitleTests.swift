@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAINamingTitleTests: XCTestCase {
    func testParseNameMapToleratesFencesAndRejectsJunk() {
        let reply = "```json\n{\"Speaker 1\": \"Sarah\", \"Speaker 2\": null, \"Speaker 3\": \"Speaker 3\", \"Bogus\": \"X\", \"Speaker 4\": \" \"}\n```"
        let map = MeetAISpeakerNamer.parseNameMap(from: reply, validLabels: ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])
        XCTAssertEqual(map, ["Speaker 1": "Sarah"])
        XCTAssertTrue(MeetAISpeakerNamer.parseNameMap(from: "no json", validLabels: ["Speaker 1"]).isEmpty)
    }

    func testPromptCarriesDirectAddressRuleAndLocalLabel() {
        let prompt = MeetAISpeakerNamer.systemPrompt(labels: ["Speaker 1"], localLabel: "You")("TRANSCRIPT")
        XCTAssertTrue(prompt.contains("identifies the LISTENER"))
        XCTAssertTrue(prompt.contains("\"You\""))
        XCTAssertTrue(prompt.hasSuffix("TRANSCRIPT"))
    }

    func testTitleCleaning() {
        XCTAssertEqual(MeetAITitler.clean("\"Roadmap Sync.\"\nextra"), "Roadmap Sync")
        XCTAssertEqual(MeetAITitler.clean("## **Budget Review**"), "Budget Review")
        XCTAssertNil(MeetAITitler.clean("   \n  "))
        XCTAssertEqual(MeetAITitler.clean(String(repeating: "a", count: 100))?.count, 60)
    }

    func testTitleOwnership() {
        var session = MeetAIFixtures.session(speakers: [], lines: [], defaultTitle: true)
        XCTAssertTrue(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord()))
        session.defaultTitleBase = nil
        session.title = "LLM title"
        XCTAssertTrue(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "LLM title")))
        session.title = "User title"
        XCTAssertFalse(MeetAITitler.ownsTitle(session: session, meta: MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "LLM title")))
    }

    private func harness(_ session: MeetingSession, llm: FakeLLM) throws -> (MeetAISessionProcessor, FakeMutator, MeetAISidecarStore) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let settings = MeetAISettings(defaults: UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!)
        settings.speakerMatching = false
        settings.autoSummarize = false
        let mutator = FakeMutator(session)
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars, profiles: MeetAISpeakerProfileStore(fileURL: paths.profilesFile), settings: settings,
            embedder: FakeEmbedder(bySpeakerText: [:]), llm: llm, mutator: { mutator },
            loadSession: { _ in mutator.session }, sessionDirectory: { _ in root }, retryDelay: .milliseconds(1)
        ))
        return (processor, mutator, sidecars)
    }

    func testAutomationNamesSpeakersThenTitlesWithoutEnrolling() async throws {
        let session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [.init(speaker: 1, start: 0, end: 4, text: "Hi, I'm Sarah from finance."), .init(speaker: 0, start: 4, end: 6, text: "Thanks Sarah.")]
        )
        let llm = FakeLLM(replies: ["{\"Speaker 1\": \"Sarah\"}", "Finance Check-in"])
        let (processor, mutator, sidecars) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.speakers[1].displayName, "Sarah")
        XCTAssertEqual(mutator.session.title, "Finance Check-in")
        let records = try await sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[1].id]?.nameSource, .llm)
        let meta = try await sidecars.meta(for: session.id)
        XCTAssertEqual(meta.lastLLMTitle, "Finance Check-in")
        await processor.handleCorrection(sessionID: session.id)
        let afterEcho = try await sidecars.speakers(for: session.id)
        XCTAssertEqual(afterEcho[session.speakers[1].id]?.nameSource, .llm, "MeetAI's own rename is not a user rename")
    }

    func testNamingSkipsWhenOnlyLocalUser() async throws {
        let session = MeetAIFixtures.session(speakers: [("You", true)], lines: [.init(speaker: 0, start: 0, end: 3, text: "Note to self.")])
        let llm = FakeLLM(replies: ["Personal Note"])
        let (processor, mutator, _) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(llm.prompts.count, 1, "only the title call, no naming call")
        XCTAssertEqual(mutator.session.title, "Personal Note")
    }

    func testUserTitleIsNeverReplaced() async throws {
        var session = MeetAIFixtures.session(speakers: [("You", true)], lines: [.init(speaker: 0, start: 0, end: 3, text: "Hello")])
        session.defaultTitleBase = nil
        session.title = "My own title"
        let llm = FakeLLM(replies: ["Should Not Apply"])
        let (processor, mutator, sidecars) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.title, "My own title")
        XCTAssertTrue(llm.prompts.isEmpty)
        let meta = try await sidecars.meta(for: session.id)
        XCTAssertEqual(meta.titleSource, .user)
    }

    func testDuplicateLLMNamesAreDropped() async throws {
        let session = MeetAIFixtures.session(
            speakers: [("Speaker 1", false), ("Speaker 2", false)],
            lines: [.init(speaker: 0, start: 0, end: 3, text: "a"), .init(speaker: 1, start: 3, end: 6, text: "b")]
        )
        let llm = FakeLLM(replies: ["{\"Speaker 1\": \"Sam\", \"Speaker 2\": \"Sam\"}", "Title"])
        let (processor, mutator, _) = try self.harness(session, llm: llm)
        await processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(mutator.session.speakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
    }
}

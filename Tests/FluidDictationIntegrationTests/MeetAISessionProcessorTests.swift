@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FakeMutator: MeetAISessionMutating {
    var session: MeetingSession
    var busyFailures = 0
    var deleted = false
    var renameCalls: [[SessionSpeakerID: String]] = []
    var titleCalls: [String] = []

    init(_ session: MeetingSession) { self.session = session }

    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async throws -> MeetingSession {
        if self.deleted { throw MeetingCoordinatorError.noActiveMeeting }
        if self.busyFailures > 0 { self.busyFailures -= 1; throw MeetingCoordinatorError.activityInProgress }
        self.renameCalls.append(names)
        for (id, name) in names { try self.session.renameSpeaker(id: id, to: name) }
        return self.session
    }

    func renameSession(sessionID: MeetingSessionID, to title: String) async throws -> MeetingSession {
        if self.deleted { throw MeetingCoordinatorError.noActiveMeeting }
        self.titleCalls.append(title)
        self.session.title = title
        self.session.defaultTitleBase = nil
        return self.session
    }
}

nonisolated struct FakeEmbedder: MeetAISpeakerEmbedding {
    let bySpeakerText: [String: [Float]]
    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        turns.first.flatMap { self.bySpeakerText[$0.text] }
    }
}

@MainActor
final class FakeLLM: MeetAILLMCompleting {
    var replies: [String]
    var error: Error?
    private(set) var prompts: [String] = []

    init(replies: [String] = [], error: Error? = nil) {
        self.replies = replies
        self.error = error
    }

    func complete(systemPrompt: String, turns: [MeetAILLMTurn]) async throws -> String {
        self.prompts.append(systemPrompt + "\n" + turns.map(\.content).joined(separator: "\n"))
        if let error { throw error }
        return self.replies.isEmpty ? "" : self.replies.removeFirst()
    }

    func completeAboutTranscript(transcript: String, turns: [MeetAILLMTurn], systemPrompt: (String) -> String) async throws -> String {
        try await self.complete(systemPrompt: systemPrompt(transcript), turns: turns)
    }

    func descriptor() -> MeetAIProviderDescriptor { MeetAIProviderDescriptor(providerID: "fake", modelID: "fake-1") }
}

@MainActor
final class MeetAISessionProcessorTests: XCTestCase {
    private func vector(_ seed: Float) -> [Float] {
        MeetAISpeakerMath.normalize((0..<256).map { sin(Float($0) * seed) })
    }

    private struct Harness {
        let processor: MeetAISessionProcessor
        let mutator: FakeMutator
        let sidecars: MeetAISidecarStore
        let profiles: MeetAISpeakerProfileStore
        let settings: MeetAISettings
        let llm: FakeLLM
    }

    private func harness(session: MeetingSession, embeddings: [String: [Float]] = [:], llm providedLLM: FakeLLM? = nil) throws -> Harness {
        let llm = providedLLM ?? FakeLLM()
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        let profiles = MeetAISpeakerProfileStore(fileURL: paths.profilesFile)
        let defaults = UserDefaults(suiteName: "meetai-tests-\(UUID().uuidString)")!
        let settings = MeetAISettings(defaults: defaults)
        settings.autoName = false
        settings.autoSummarize = false
        let mutator = FakeMutator(session)
        let processor = MeetAISessionProcessor(dependencies: .init(
            sidecars: sidecars,
            profiles: profiles,
            settings: settings,
            embedder: FakeEmbedder(bySpeakerText: embeddings),
            llm: llm,
            mutator: { mutator },
            loadSession: { _ in mutator.deleted ? nil : mutator.session },
            sessionDirectory: { _ in root },
            retryDelay: .milliseconds(1)
        ))
        return Harness(processor: processor, mutator: mutator, sidecars: sidecars, profiles: profiles, settings: settings, llm: llm)
    }

    private func twoSpeakerSession() -> MeetingSession {
        MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false), ("Speaker 2", false)],
            lines: [
                .init(speaker: 1, start: 0, end: 10, text: "alpha"),
                .init(speaker: 2, start: 10, end: 20, text: "beta"),
                .init(speaker: 0, start: 20, end: 30, text: "gamma"),
            ]
        )
    }

    func testCompletionStoresEmbeddingsAndRenamesKnownVoice() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Sam")
        XCTAssertEqual(h.mutator.session.speakers[2].displayName, "Speaker 2")
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[1].id]?.nameSource, .profile)
        XCTAssertEqual(records[session.speakers[1].id]?.lastAppliedName, "Sam")
        XCTAssertNotNil(records[session.speakers[2].id]?.embedding)
        XCTAssertNil(records[session.speakers[0].id], "local user is never embedded")
    }

    func testProcessorRenameDoesNotEnrolButUserRenameDoes() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        // The processor's own rename comes back through H6: no new profile, Sam's count unchanged.
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(h.profiles.profiles.map(\.name), ["Sam"])
        XCTAssertEqual(h.profiles.profiles.first?.sampleCount, 1)
        // The user names Speaker 2: that enrols a new profile from the stored embedding.
        try h.mutator.session.renameSpeaker(id: session.speakers[2].id, to: "Priya")
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(Set(h.profiles.profiles.map(\.name)), ["Sam", "Priya"])
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[2].id]?.nameSource, .user)
    }

    func testMergeDropsSourceEmbedding() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1), "beta": self.vector(0.9)])
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        try h.mutator.session.mergeSpeakers(session.speakers[2].id, into: session.speakers[1].id)
        await h.processor.handleCorrection(sessionID: session.id)
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertNil(records[session.speakers[2].id]?.embedding)
        XCTAssertNotNil(records[session.speakers[1].id]?.embedding)
    }

    func testBusyCoordinatorIsRetriedThenGivesUp() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        h.mutator.busyFailures = 3
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Sam", "retried past 3 busy errors")

        let other = self.twoSpeakerSession()
        let h2 = try self.harness(session: other, embeddings: ["alpha": self.vector(0.1)])
        _ = h2.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        h2.mutator.busyFailures = 50
        await h2.processor.sessionDidComplete(other)
        await h2.processor.enqueue(other.id) { _ in }.value
        XCTAssertEqual(h2.mutator.session.speakers[1].displayName, "Speaker 1", "gives up after 10 retries")
    }

    func testMutationOnDeletedSessionIsSwallowed() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        h.mutator.deleted = true
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertTrue(h.mutator.renameCalls.isEmpty)
        await h.processor.handleCorrection(sessionID: session.id)
    }

    func testSpeakerMatchingToggleOffSkipsEverything() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        h.settings.speakerMatching = false
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertTrue(h.mutator.renameCalls.isEmpty)
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertTrue(records.isEmpty)
    }
}

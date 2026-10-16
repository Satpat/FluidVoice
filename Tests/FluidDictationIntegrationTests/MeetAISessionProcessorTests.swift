@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FakeMutator: MeetAISessionMutating {
    var session: MeetingSession
    var busyFailures = 0
    var deleted = false
    var renameCalls: [[SessionSpeakerID: String]] = []
    var titleCalls: [String] = []
    var titleError: Error?

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
        if let titleError { throw titleError }
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

/// Runs `beforeReply` once (the user acting while the LLM call is in flight), then replies in order.
@MainActor
final class HookLLM: MeetAILLMCompleting {
    var replies: [String]
    var beforeReply: (@MainActor () throws -> Void)?

    init(replies: [String], beforeReply: (@MainActor () throws -> Void)? = nil) {
        self.replies = replies
        self.beforeReply = beforeReply
    }

    func complete(systemPrompt: String, turns: [MeetAILLMTurn]) async throws -> String {
        let hook = self.beforeReply
        self.beforeReply = nil
        try hook?()
        return self.replies.isEmpty ? "" : self.replies.removeFirst()
    }

    func completeAboutTranscript(transcript: String, turns: [MeetAILLMTurn], systemPrompt: (String) -> String) async throws -> String {
        try await self.complete(systemPrompt: systemPrompt(transcript), turns: turns)
    }

    func descriptor() -> MeetAIProviderDescriptor { MeetAIProviderDescriptor(providerID: "fake", modelID: "fake-1") }
}

nonisolated struct SlowEmbedder: MeetAISpeakerEmbedding {
    let vector: [Float]
    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        try await Task.sleep(for: .milliseconds(150))
        return self.vector
    }
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
        let llm: any MeetAILLMCompleting
    }

    private func harness(
        session: MeetingSession,
        embeddings: [String: [Float]] = [:],
        llm providedLLM: (any MeetAILLMCompleting)? = nil,
        embedder: (any MeetAISpeakerEmbedding)? = nil,
        seedProfiles: [MeetAISpeakerProfile] = []
    ) throws -> Harness {
        let llm: any MeetAILLMCompleting = providedLLM ?? FakeLLM()
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let sidecars = MeetAISidecarStore(paths: paths)
        if !seedProfiles.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: paths.profilesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(seedProfiles).write(to: paths.profilesFile)
        }
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
            embedder: embedder ?? FakeEmbedder(bySpeakerText: embeddings),
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

    func testCorrectionDuringEmbeddingCaptureIsNotOverwritten() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embedder: SlowEmbedder(vector: self.vector(0.1)))
        let completion = Task { await h.processor.sessionDidComplete(session) }
        try await Task.sleep(for: .milliseconds(30))
        try h.mutator.session.renameSpeaker(id: session.speakers[2].id, to: "Priya")
        h.processor.sessionCorrected(h.mutator.session)
        await completion.value
        await h.processor.enqueue(session.id) { _ in }.value
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[2].id]?.nameSource, .user)
        XCTAssertEqual(records[session.speakers[2].id]?.lastAppliedName, "Priya")
        XCTAssertNotNil(records[session.speakers[2].id]?.embedding)
    }

    // MARK: F1 — never overwrite a user edit made during a MeetAI LLM call

    func testUserRenameDuringNamingCallIsKeptAndEnrolled() async throws {
        let session = self.twoSpeakerSession()
        let speaker1 = session.speakers[1].id
        var mutatorRef: FakeMutator?
        let llm = HookLLM(replies: ["{\"Speaker 1\": \"Bob\"}", ""]) {
            try mutatorRef?.session.renameSpeaker(id: speaker1, to: "Alice")
        }
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)], llm: llm)
        mutatorRef = h.mutator
        h.settings.autoName = true
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Alice", "user rename survives the LLM reply")
        XCTAssertTrue(h.mutator.renameCalls.isEmpty)
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertNotEqual(records[speaker1]?.nameSource, .llm)
        XCTAssertNotEqual(records[speaker1]?.lastAppliedName, "Bob")
        // The user's queued H6 correction now sees a user rename and enrols the voice.
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(h.profiles.profiles.map(\.name), ["Alice"])
        let after = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(after[speaker1]?.nameSource, .user)
    }

    private func llmNamedSession() async throws -> (Harness, MeetingSession) {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)], llm: FakeLLM(replies: ["{\"Speaker 1\": \"Bob\"}", ""]))
        h.settings.autoName = true
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        // Echo of the LLM rename through H6 changes nothing.
        await h.processor.handleCorrection(sessionID: session.id)
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Bob")
        XCTAssertTrue(h.profiles.profiles.isEmpty)
        return (h, session)
    }

    func testConfirmableSpeakersAreLLMNamedWithAVoice() async throws {
        let (h, session) = try await self.llmNamedSession()
        let candidates = await h.processor.confirmableSpeakers(sessionID: session.id)
        XCTAssertEqual(candidates, [.init(speakerID: session.speakers[1].id, name: "Bob")])
    }

    func testConfirmSpeakerNameEnrolsVoiceAndMarksUser() async throws {
        let (h, session) = try await self.llmNamedSession()
        let speaker = session.speakers[1].id
        let saved = await h.processor.confirmSpeakerName(sessionID: session.id, speakerID: speaker)
        XCTAssertTrue(saved)
        XCTAssertEqual(h.profiles.profiles.map(\.name), ["Bob"])
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[speaker]?.nameSource, .user)
        XCTAssertEqual(records[speaker]?.matchedProfileID, h.profiles.profiles.first?.id)
        XCTAssertTrue(h.mutator.renameCalls.count == 1, "no rename: the name stays as it is")
        let after = await h.processor.confirmableSpeakers(sessionID: session.id)
        XCTAssertTrue(after.isEmpty)
        // A second confirm is a no-op: no extra sample.
        let again = await h.processor.confirmSpeakerName(sessionID: session.id, speakerID: speaker)
        XCTAssertFalse(again)
        XCTAssertEqual(h.profiles.profiles.first?.sampleCount, 1)
    }

    func testConfirmIsRefusedWhenNameChangedOrVoiceMissing() async throws {
        let (h, session) = try await self.llmNamedSession()
        try h.mutator.session.renameSpeaker(id: session.speakers[1].id, to: "Robert")
        let renamed = await h.processor.confirmSpeakerName(sessionID: session.id, speakerID: session.speakers[1].id)
        XCTAssertFalse(renamed, "the shown name is stale; the user's rename is handled by H6")
        XCTAssertTrue(h.profiles.profiles.isEmpty)

        var records = try await h.sidecars.speakers(for: session.id)
        records[session.speakers[2].id] = MeetAISpeakerRecord(nameSource: .llm, lastAppliedName: "Carol")
        try await h.sidecars.saveSpeakers(records, for: session.id)
        try h.mutator.session.renameSpeaker(id: session.speakers[2].id, to: "Carol")
        let noVoice = await h.processor.confirmSpeakerName(sessionID: session.id, speakerID: session.speakers[2].id)
        XCTAssertFalse(noVoice)
        let candidates = await h.processor.confirmableSpeakers(sessionID: session.id)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUserTitleEditDuringTitleCallIsKept() async throws {
        let session = self.twoSpeakerSession()
        var mutatorRef: FakeMutator?
        let llm = HookLLM(replies: ["LLM Title"]) {
            mutatorRef?.session.title = "User title"
            mutatorRef?.session.defaultTitleBase = nil
        }
        let h = try self.harness(session: session, llm: llm)
        mutatorRef = h.mutator
        h.settings.speakerMatching = false
        await h.processor.runAutomation(sessionID: session.id)
        XCTAssertEqual(h.mutator.session.title, "User title")
        XCTAssertTrue(h.mutator.titleCalls.isEmpty)
        let meta = try await h.sidecars.meta(for: session.id)
        XCTAssertEqual(meta.titleSource, .user)
        XCTAssertNil(meta.lastLLMTitle)
    }

    func testFailedProfileRenameRollsBackRecords() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, embeddings: ["alpha": self.vector(0.1)])
        _ = h.profiles.enroll(name: "Sam", embedding: self.vector(0.1))
        h.mutator.busyFailures = 50
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.session.speakers[1].displayName, "Speaker 1")
        let records = try await h.sidecars.speakers(for: session.id)
        let record = try XCTUnwrap(records[session.speakers[1].id])
        XCTAssertNil(record.nameSource)
        XCTAssertNil(record.lastAppliedName)
        XCTAssertNil(record.matchedProfileID)
        XCTAssertNotNil(record.embedding, "rollback keeps the captured embedding")
    }

    func testFailedTitleRenameRollsBackMeta() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(session: session, llm: FakeLLM(replies: ["LLM Title"]))
        h.settings.speakerMatching = false
        h.mutator.titleError = MeetingCoordinatorError.noActiveMeeting
        await h.processor.runAutomation(sessionID: session.id)
        XCTAssertTrue(h.mutator.titleCalls.isEmpty)
        let meta = try await h.sidecars.meta(for: session.id)
        XCTAssertEqual(meta, MeetAIMetaRecord())
    }

    // MARK: F8 — profile names are trimmed before they are applied

    func testProfileNameIsTrimmedBeforeApplying() async throws {
        let session = self.twoSpeakerSession()
        let h = try self.harness(
            session: session,
            embeddings: ["alpha": self.vector(0.1)],
            seedProfiles: [MeetAISpeakerProfile(name: "  Sam \n", embedding: self.vector(0.1))]
        )
        XCTAssertEqual(h.profiles.profiles.first?.name, "  Sam \n")
        await h.processor.sessionDidComplete(session)
        await h.processor.enqueue(session.id) { _ in }.value
        XCTAssertEqual(h.mutator.renameCalls.first?[session.speakers[1].id], "Sam")
        let records = try await h.sidecars.speakers(for: session.id)
        XCTAssertEqual(records[session.speakers[1].id]?.lastAppliedName, "Sam")
    }
}

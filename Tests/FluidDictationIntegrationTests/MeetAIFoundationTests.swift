@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIFoundationTests: XCTestCase {
    // MARK: Sidecar store

    func testSidecarRoundTripsEveryRecord() async throws {
        let paths = MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self))
        let store = MeetAISidecarStore(paths: paths)
        let id = UUID()
        let speakerID = UUID()
        let summary = MeetAISummaryRecord(style: "standard", transcriptHash: "abc", markdown: "## Overview", providerID: "openai", modelID: "gpt-6.1", createdAt: Date(timeIntervalSince1970: 1))
        try await store.saveSummary(summary, for: id)
        try await store.saveQA([MeetAIQARecord(id: UUID(), question: "Q", answer: "A", askedAt: Date(timeIntervalSince1970: 2))], for: id)
        try await store.saveSpeakers([speakerID: MeetAISpeakerRecord(embedding: [0.6, 0.8], matchedProfileID: "p1", nameSource: .profile, lastAppliedName: "Sam")], for: id)
        try await store.saveMeta(MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "Roadmap sync"), for: id)

        let reopened = MeetAISidecarStore(paths: paths)
        let loadedSummary = try await reopened.summary(for: id)
        let loadedQA = try await reopened.qa(for: id)
        let loadedSpeakers = try await reopened.speakers(for: id)
        let loadedMeta = try await reopened.meta(for: id)
        XCTAssertEqual(loadedSummary, summary)
        XCTAssertEqual(loadedQA.map(\.answer), ["A"])
        XCTAssertEqual(loadedSpeakers[speakerID]?.lastAppliedName, "Sam")
        XCTAssertEqual(loadedMeta.lastLLMTitle, "Roadmap sync")
    }

    func testSidecarDefaultsWhenMissing() async throws {
        let store = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self)))
        let id = UUID()
        let summary = try await store.summary(for: id)
        let qa = try await store.qa(for: id)
        let speakers = try await store.speakers(for: id)
        let meta = try await store.meta(for: id)
        XCTAssertNil(summary)
        XCTAssertTrue(qa.isEmpty)
        XCTAssertTrue(speakers.isEmpty)
        XCTAssertEqual(meta, MeetAIMetaRecord())
    }

    func testSweepOrphansRemovesOnlyUnknownSessions() async throws {
        let paths = MeetAIPaths(supportRoot: try MeetAIFixtures.tempDirectory(self))
        let store = MeetAISidecarStore(paths: paths)
        let kept = UUID(), orphan = UUID()
        try await store.saveMeta(MeetAIMetaRecord(), for: kept)
        try await store.saveMeta(MeetAIMetaRecord(), for: orphan)
        let unreadable = UUID(), throwing = UUID()
        try await store.saveMeta(MeetAIMetaRecord(), for: unreadable)
        try await store.saveMeta(MeetAIMetaRecord(), for: throwing)
        let strayFolder = paths.sessionsDirectory.appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: true)
        let strayFile = paths.sessionsDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: strayFile)
        // `kept` is loaded; `unreadable` fails to load but its directory exists; `throwing` is treated as live.
        let removed = try await store.sweepOrphans { id in id == kept || id == unreadable || id == throwing }
        XCTAssertEqual(removed, [orphan])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: unreadable).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory(for: throwing).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFile.path))
    }

    // MARK: Transcript helpers

    func testDefaultSpeakerNames() {
        for name in ["Speaker 1", "Speaker 12", "Microphone Speaker 2", "Room Speaker", "Meeting audio", "Meeting Audio", "Microphone / Unknown", "Them", "Them 3"] {
            XCTAssertTrue(MeetAITranscript.isDefaultSpeakerName(name), name)
        }
        for name in ["Sam", "Speaker", "Speaker One", "Themis", "Me"] {
            XCTAssertFalse(MeetAITranscript.isDefaultSpeakerName(name), name)
        }
    }

    func testHashIgnoresTitleButTracksTextAndNames() throws {
        var session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [.init(speaker: 1, start: 0, end: 3, text: "Hello there"), .init(speaker: 0, start: 3, end: 5, text: "Hi")]
        )
        let original = MeetAITranscript.hash(for: session)
        session.title = "Renamed meeting"
        XCTAssertEqual(MeetAITranscript.hash(for: session), original)
        session.transcriptSegments[0].text = "Hello there!"
        let edited = MeetAITranscript.hash(for: session)
        XCTAssertNotEqual(edited, original)
        try session.renameSpeaker(id: session.speakers[1].id, to: "Sam")
        XCTAssertNotEqual(MeetAITranscript.hash(for: session), edited)
        XCTAssertEqual(MeetAITranscript.localUserLabel(in: session), "You")
    }

    // MARK: Hooks

    func testCompletionHookReturnsAfterTimeoutWhenHandlerHangs() async {
        let saved = MeetAIHooks.sessionDidComplete
        defer { MeetAIHooks.sessionDidComplete = saved }
        MeetAIHooks.sessionDidComplete = { _ in try? await Task.sleep(for: .seconds(5)) }
        let start = ContinuousClock.now
        await MeetAIHooks.runSessionDidComplete(MeetAIFixtures.session(speakers: [], lines: []), timeout: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testHooksAreNoOpsWhenUnset() async {
        let savedComplete = MeetAIHooks.sessionDidComplete, savedCorrected = MeetAIHooks.sessionCorrected
        defer { MeetAIHooks.sessionDidComplete = savedComplete; MeetAIHooks.sessionCorrected = savedCorrected }
        MeetAIHooks.sessionDidComplete = nil
        MeetAIHooks.sessionCorrected = nil
        await MeetAIHooks.runSessionDidComplete(MeetAIFixtures.session(speakers: [], lines: []))
        MeetAIHooks.notifySessionCorrected(MeetAIFixtures.session(speakers: [], lines: []))
    }
}

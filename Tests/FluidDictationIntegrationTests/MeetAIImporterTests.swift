@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIImporterTests: XCTestCase {
    func testUndecodableFileLeavesNoSession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        var retried: [MeetingSessionID] = []
        let importer = MeetAIAudioImporter(store: store, sidecars: MeetAISidecarStore(paths: MeetAIPaths(supportRoot: root)), retry: { retried.append($0) })
        let bogus = root.appendingPathComponent("voice-note.wav")
        try Data("definitely not audio".utf8).write(to: bogus)
        await importer.importFile(bogus)
        guard case let .failed(message) = importer.status else { return XCTFail("expected failure, got \(importer.status)") }
        XCTAssertTrue(message.contains("voice-note.wav"))
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(retried.isEmpty)
    }

    func testImportCreatesTitledSessionAndStartsProcessing() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(
            samples: (0..<(16_000 * 3)).map { 0.2 * sin(Float($0) / 10) }, kind: .microphone, sessionDirectory: chunkDirectory
        )
        let source = root.appendingPathComponent("Team Sync.caf")
        try FileManager.default.copyItem(at: chunks[0].fileURL(relativeTo: chunkDirectory), to: source)
        var retried: [MeetingSessionID] = []
        let importer = MeetAIAudioImporter(store: store, sidecars: MeetAISidecarStore(paths: MeetAIPaths(supportRoot: root)), retry: { retried.append($0) })
        await importer.importFile(source)
        let sessions = try await store.loadAll()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Team Sync")
        XCTAssertEqual(retried, sessions.map(\.id))
        guard case .done = importer.status else { return XCTFail("expected done, got \(importer.status)") }
    }

    func testImportedFileNameTitleIsMeetAIOwnedBeforeProcessingStarts() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: MeetAIPaths(supportRoot: root))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(
            samples: (0..<(16_000 * 3)).map { 0.2 * sin(Float($0) / 10) }, kind: .microphone, sessionDirectory: chunkDirectory
        )
        let source = root.appendingPathComponent("New Recording 73.caf")
        try FileManager.default.copyItem(at: chunks[0].fileURL(relativeTo: chunkDirectory), to: source)
        var metaAtRetry: MeetAIMetaRecord?
        let importer = MeetAIAudioImporter(store: store, sidecars: sidecars, retry: { metaAtRetry = try await sidecars.meta(for: $0) })
        await importer.importFile(source)

        let sessions = try await store.loadAll()
        let session = try XCTUnwrap(sessions.first)
        let expected = MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: "New Recording 73")
        XCTAssertEqual(metaAtRetry, expected, "recorded before processing so H1's title step sees it")
        XCTAssertTrue(MeetAITitler.ownsTitle(session: session, meta: expected))
        var renamed = session
        renamed.title = "Budget review"
        XCTAssertFalse(MeetAITitler.ownsTitle(session: renamed, meta: expected), "a user edit still wins")
    }

    func testTooShortAudioIsRejected() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(samples: [Float](repeating: 0.1, count: 8_000), kind: .microphone, sessionDirectory: chunkDirectory)
        let importer = MeetAIAudioImporter(store: store, sidecars: MeetAISidecarStore(paths: MeetAIPaths(supportRoot: root)), retry: { _ in })
        await importer.importFile(chunks[0].fileURL(relativeTo: chunkDirectory))
        guard case .failed = importer.status else { return XCTFail("expected failure") }
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }
}

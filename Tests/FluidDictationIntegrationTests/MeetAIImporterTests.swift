@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIImporterTests: XCTestCase {
    func testUndecodableFileLeavesNoSession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        var retried: [MeetingSessionID] = []
        let importer = MeetAIAudioImporter(store: store, retry: { retried.append($0) })
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
        let importer = MeetAIAudioImporter(store: store, retry: { retried.append($0) })
        await importer.importFile(source)
        let sessions = try await store.loadAll()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Team Sync")
        XCTAssertEqual(retried, sessions.map(\.id))
        guard case .done = importer.status else { return XCTFail("expected done, got \(importer.status)") }
    }

    func testTooShortAudioIsRejected() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let chunkDirectory = root.appendingPathComponent("src")
        let chunks = try MeetAISyntheticSessionBuilder.writeChunks(samples: [Float](repeating: 0.1, count: 8_000), kind: .microphone, sessionDirectory: chunkDirectory)
        let importer = MeetAIAudioImporter(store: store, retry: { _ in })
        await importer.importFile(chunks[0].fileURL(relativeTo: chunkDirectory))
        guard case .failed = importer.status else { return XCTFail("expected failure") }
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }
}

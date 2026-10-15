@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAIMigrationTests: XCTestCase {
    private let sampleTranscript = """
    # Meeting 2026-10-15T06:00:44

    - Started: 15 Oct 2026 at 4:30 pm
    - Duration: 03:23

    **[00:00] Girish:** But I'm thinking

    **[00:01] Girish:** Can we get other frontier models as well

    **[00:04] Me:** Sure, Girish.

    **[61:05] Them 2:** Late point
    with a wrapped line
    """

    func testParserReadsSpeakersSegmentsAndDuration() {
        let parsed = MeetAILegacyTranscriptParser.parse(self.sampleTranscript)
        XCTAssertEqual(parsed.duration, 203)
        XCTAssertEqual(parsed.speakers.map(\.label), ["Girish", "Me", "Them 2"])
        XCTAssertEqual(parsed.speakers.first { $0.label == "Me" }?.isLocalUser, true)
        XCTAssertEqual(parsed.segments.map(\.start), [0, 1, 4, 3_665])
        XCTAssertEqual(parsed.segments[0].end, 1)
        XCTAssertEqual(parsed.segments.last?.text, "Late point\nwith a wrapped line")
    }

    func testParserHandlesOddLines() {
        let parsed = MeetAILegacyTranscriptParser.parse("""
        Some header without format

        **[00:05] Dr: Lee:** Colon in the name
        **[00:05] Sam:** Same timestamp
        **[1:02:03] Sam:** Hours format

        """)
        XCTAssertEqual(parsed.segments.map(\.speakerLabel), ["Dr: Lee", "Sam", "Sam"])
        XCTAssertEqual(parsed.segments.map(\.text), ["Colon in the name", "Same timestamp", "Hours format"])
        XCTAssertEqual(parsed.segments[2].start, 3_723)
        XCTAssertTrue(parsed.segments.allSatisfy { $0.end > $0.start })
        XCTAssertNil(parsed.duration)
    }

    func testEmptySpeakerLabelBecomesThem() {
        let parsed = MeetAILegacyTranscriptParser.parse("**[00:00] :** Unlabelled line\n\n**[00:10] Me:** Reply")
        XCTAssertEqual(parsed.segments.map(\.speakerLabel), ["Them", "Me"])
        XCTAssertEqual(parsed.speakers.map(\.label), ["Them", "Me"])
    }

    func testTitleSuffixIsStripped() {
        XCTAssertEqual(MeetAILegacyTranscriptParser.stripTitleSuffix("Comparison of Frontier Models (Thu, 15 Oct at 4:30 pm)"), "Comparison of Frontier Models")
        XCTAssertEqual(MeetAILegacyTranscriptParser.stripTitleSuffix("Plain title"), "Plain title")
    }

    private func makeLegacyFolder(_ root: URL, name: String, transcript: String?, summary: String? = nil, title: String? = nil, speakers: [String: [Float]]? = nil) throws {
        let folder = root.appendingPathComponent("MeetingRecordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let transcript { try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        if let summary { try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        if let title { try title.write(to: folder.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8) }
        if let speakers { try JSONEncoder().encode(speakers).write(to: folder.appendingPathComponent("speakers.json")) }
        let session = """
        {"startedAt":"\(name)Z","endedAt":"\(name.prefix(17))59Z"}
        """
        try session.write(to: folder.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    }

    func testMigratorImportsSkipsAndIsIdempotent() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        try self.makeLegacyFolder(root, name: "2026-10-15T06:00:44", transcript: self.sampleTranscript,
                                  summary: "# Meeting summary — x\n\n## Overview\nModels.", title: "Frontier Models (Thu, 15 Oct at 4:30 pm)",
                                  speakers: ["Girish": [0.6, 0.8]])
        try self.makeLegacyFolder(root, name: "2026-07-13T00:22:00", transcript: nil)
        let before = try Data(contentsOf: paths.legacyMeetingsDirectory.appendingPathComponent("2026-10-15T06:00:44/transcript.md"))

        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: paths)
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await migrator.run()

        XCTAssertEqual(migrator.entries["2026-10-15T06:00:44"]?.status, .done)
        XCTAssertEqual(migrator.entries["2026-07-13T00:22:00"]?.status, .skipped)
        let id = MeetAIMigrator.sessionID(forFolder: "2026-10-15T06:00:44")
        let session = try await XCTUnwrapAsync(await store.load(id: id))
        XCTAssertEqual(session.title, "Frontier Models")
        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.transcriptSegments.count, 4)
        let summary = try await sidecars.summary(for: id)
        XCTAssertEqual(summary?.markdown, "## Overview\nModels.")
        XCTAssertEqual(summary?.style, "migrated")
        XCTAssertEqual(summary?.transcriptHash, MeetAITranscript.hash(for: session))
        let girish = try XCTUnwrap(session.speakers.first { $0.displayName == "Girish" })
        let records = try await sidecars.speakers(for: id)
        XCTAssertEqual(records[girish.id]?.nameSource, .user)
        XCTAssertEqual(records[girish.id]?.lastAppliedName, "Girish")
        XCTAssertNotNil(records[girish.id]?.embedding)
        let meta = try await sidecars.meta(for: id)
        XCTAssertEqual(meta.lastLLMTitle, "Frontier Models")

        let second = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await second.run()
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1, "re-running never duplicates")
        let after = try Data(contentsOf: paths.legacyMeetingsDirectory.appendingPathComponent("2026-10-15T06:00:44/transcript.md"))
        XCTAssertEqual(before, after, "legacy files are read only")
    }

    func testSidecarFailureIsRetriedAndReconciled() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        try self.makeLegacyFolder(root, name: "2026-10-15T06:00:44", transcript: self.sampleTranscript,
                                  summary: "# Meeting summary — x\n\n## Overview\nModels.", title: "Frontier Models",
                                  speakers: ["Girish": [0.6, 0.8]])
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: paths)
        let id = MeetAIMigrator.sessionID(forFolder: "2026-10-15T06:00:44")
        // A regular file where the sidecar directory must go makes the first sidecar write throw.
        try FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.sessionDirectory(for: id))

        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await migrator.run()
        XCTAssertEqual(migrator.entries["2026-10-15T06:00:44"]?.status, .failed)

        try FileManager.default.removeItem(at: paths.sessionDirectory(for: id))
        await migrator.run(retryFailed: true)
        XCTAssertEqual(migrator.entries["2026-10-15T06:00:44"]?.status, .done)
        let summary = try await sidecars.summary(for: id)
        XCTAssertEqual(summary?.markdown, "## Overview\nModels.")
        let speakers = try await sidecars.speakers(for: id)
        XCTAssertFalse(speakers.isEmpty)
        let meta = try await sidecars.meta(for: id)
        XCTAssertEqual(meta.lastLLMTitle, "Frontier Models")
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
    }

    func testRerunNeverOverwritesExistingSidecars() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        try self.makeLegacyFolder(root, name: "2026-10-15T06:00:44", transcript: self.sampleTranscript,
                                  summary: "# Meeting summary — x\n\n## Overview\nModels.", title: "Frontier Models")
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: paths)
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await migrator.run()
        let id = MeetAIMigrator.sessionID(forFolder: "2026-10-15T06:00:44")
        var summary = try await XCTUnwrapAsync(await sidecars.summary(for: id))
        summary.markdown = "Regenerated by the user"
        try await sidecars.saveSummary(summary, for: id)
        try await sidecars.saveMeta(MeetAIMetaRecord(titleSource: .user, lastLLMTitle: "Frontier Models"), for: id)

        let again = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await again.run()
        // Force the folder through migrate again, as after an interrupted run.
        try FileManager.default.removeItem(at: paths.migrationFile)
        let third = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await third.run()
        XCTAssertEqual(third.entries["2026-10-15T06:00:44"]?.status, .done)
        let kept = try await sidecars.summary(for: id)
        XCTAssertEqual(kept?.markdown, "Regenerated by the user")
        let meta = try await sidecars.meta(for: id)
        XCTAssertEqual(meta.titleSource, .user)
    }

    /// Opt-in dry run on a COPY of real data: TEST_RUNNER_MEETAI_LEGACY_ROOT="$HOME/Library/Application Support/FluidVoice"
    func testDryRunOnCopyOfRealData() async throws {
        guard let source = ProcessInfo.processInfo.environment["MEETAI_LEGACY_ROOT"] else { throw XCTSkip("dry run") }
        let root = try MeetAIFixtures.tempDirectory(self, "meetai-dryrun")
        try Self.copyTree(from: URL(fileURLWithPath: source).appendingPathComponent("MeetingRecordings"), to: root.appendingPathComponent("MeetingRecordings"))
        let paths = MeetAIPaths(supportRoot: root)
        let migrator = MeetAIMigrator(paths: paths, store: MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings")), sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        let byStatus = Dictionary(grouping: migrator.entries.values, by: \.status)
        let folders = try FileManager.default.contentsOfDirectory(atPath: paths.legacyMeetingsDirectory.path).filter { !$0.hasPrefix(".") }
        print("MEETAI-DRYRUN folders=\(folders.count) done=\(byStatus[.done]?.count ?? 0) skipped=\(byStatus[.skipped]?.count ?? 0) failed=\(byStatus[.failed]?.count ?? 0)")
        for (folder, entry) in migrator.entries.sorted(by: { $0.key < $1.key }) where entry.status != .done {
            print("MEETAI-DRYRUN \(entry.status.rawValue) \(folder): \(entry.reason ?? "")")
        }
        XCTAssertEqual(byStatus[.failed]?.count ?? 0, 0)
        XCTAssertEqual(migrator.entries.count, folders.count)
    }

    /// Recursive copy that skips audio (`.wav`): Tier 1 reads only the text/json files.
    private static func copyTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            if item.pathExtension.lowercased() == "wav" { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if (try item.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try self.copyTree(from: item, to: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}

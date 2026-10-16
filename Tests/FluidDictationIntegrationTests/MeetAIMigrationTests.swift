@testable import FluidVoice_Debug
import AVFoundation
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

    /// Real 16 kHz mono Int16 WAV, like the fork wrote.
    private func writeWAV(_ url: URL, seconds: Double, frequency: Float) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { channel[i] = 0.2 * sin(2 * .pi * frequency * Float(i) / 16_000) }
        try file.write(from: buffer)
    }

    func testReprocessReplacesTranscriptOnlySession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript, title: "Frontier Models (Thu, 15 Oct at 4:30 pm)")
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        XCTAssertTrue(migrator.hasLegacyAudio(folder: folderName))
        let oldID = try XCTUnwrap(migrator.entries[folderName]?.sessionID)

        var retried: [MeetingSessionID] = []
        let result = try await migrator.reprocess(folder: folderName, retry: { retried.append($0) })
        let newID = result.sessionID
        XCTAssertNil(result.oldCopyRemovalError)
        XCTAssertEqual(retried, [newID])
        let oldSession = try await store.load(id: oldID)
        XCTAssertNil(oldSession, "old transcript-only session removed")
        let replacement = try await XCTUnwrapAsync(await store.load(id: newID))
        XCTAssertEqual(replacement.mode, .onlineCall)
        XCTAssertEqual(replacement.title, "Frontier Models")
        XCTAssertEqual(migrator.entries[folderName]?.sessionID, newID)
        XCTAssertNotNil(migrator.entries[folderName]?.reprocessedAt)
    }

    func testReprocessFailureKeepsOldSession() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript)
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()
        let oldID = try XCTUnwrap(migrator.entries[folderName]?.sessionID)
        do {
            _ = try await migrator.reprocess(folder: folderName, retry: { _ in throw MeetingCoordinatorError.activityInProgress })
            XCTFail("expected failure")
        } catch {}
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [oldID], "new session deleted, old kept")
        XCTAssertEqual(migrator.entries[folderName]?.sessionID, oldID)
    }

    private func reprocessFixture() async throws -> (MeetAIMigrator, MeetingSessionStore, MeetAISidecarStore, String, MeetingSessionID) {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript, summary: "# Meeting summary — x\n\n## Overview\nModels.")
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let sidecars = MeetAISidecarStore(paths: paths)
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: sidecars)
        await migrator.run()
        return (migrator, store, sidecars, folderName, try XCTUnwrap(migrator.entries[folderName]?.sessionID))
    }

    func testReprocessCandidatesShowSessionTitleAndDateWithFolderAsSecondary() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        let folderName = "2026-10-15T06:00:44"
        try self.makeLegacyFolder(root, name: folderName, transcript: self.sampleTranscript, title: "Frontier Models (Thu, 15 Oct at 4:30 pm)")
        let folder = paths.legacyMeetingsDirectory.appendingPathComponent(folderName)
        try self.writeWAV(folder.appendingPathComponent("system.wav"), seconds: 3, frequency: 220)
        try self.writeWAV(folder.appendingPathComponent("mic.wav"), seconds: 3, frequency: 330)
        try self.makeLegacyFolder(root, name: "2026-10-14T01:00:00", transcript: self.sampleTranscript, title: "No Audio Here")
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await migrator.run()

        let candidates = await migrator.reprocessCandidates()
        XCTAssertEqual(candidates.map(\.folder), [folderName], "only meetings that still have audio")
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.title, "Frontier Models")
        XCTAssertEqual(candidate.startedAt, ISO8601DateFormatter().date(from: folderName + "Z"))
        XCTAssertFalse(candidate.reprocessed)

        _ = try await migrator.reprocess(folder: folderName, retry: { _ in })
        let after = await migrator.reprocessCandidates()
        XCTAssertEqual(after.first?.title, "Frontier Models", "title read from the re-processed session")
        XCTAssertEqual(after.first?.reprocessed, true)
    }

    func testReprocessCandidateFallsBackToFolderWhenSessionIsGone() async throws {
        let (migrator, store, _, folder, oldID) = try await reprocessFixture()
        try await store.delete(id: oldID)
        let candidates = await migrator.reprocessCandidates()
        XCTAssertEqual(candidates.first?.title, folder)
        XCTAssertEqual(candidates.first?.startedAt, ISO8601DateFormatter().date(from: folder + "Z"))
    }

    func testReprocessThenRunLeavesOneSessionAndNoOldSidecars() async throws {
        let (migrator, store, sidecars, folder, oldID) = try await reprocessFixture()
        let before = try await sidecars.summary(for: oldID)
        XCTAssertNotNil(before)
        let result = try await migrator.reprocess(folder: folder, retry: { _ in })
        await migrator.run()
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [result.sessionID])
        let after = try await sidecars.summary(for: oldID)
        XCTAssertNil(after)
    }

    func testReprocessFailureDiscardsNewSessionAndSidecarsViaClosure() async throws {
        let (migrator, store, sidecars, folder, oldID) = try await reprocessFixture()
        var discarded: [MeetingSessionID] = []
        var failedID: MeetingSessionID?
        do {
            _ = try await migrator.reprocess(
                folder: folder,
                retry: { id in
                    failedID = id
                    try await sidecars.saveSummary(MeetAISummaryRecord(style: "s", transcriptHash: "h", markdown: "x", providerID: "p", modelID: "m", createdAt: Date()), for: id)
                    throw MeetingCoordinatorError.activityInProgress
                },
                discard: { id in discarded.append(id); try await store.delete(id: id) }
            )
            XCTFail("expected failure")
        } catch {}
        let newID = try XCTUnwrap(failedID)
        XCTAssertEqual(discarded, [newID])
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [oldID])
        let leftover = try await sidecars.summary(for: newID)
        XCTAssertNil(leftover)
    }

    func testReprocessOldCopyRemovalFailureIsReportedNotThrown() async throws {
        let (fixture, inner, sidecars, folder, oldID) = try await reprocessFixture()
        // Both the injected discard and the store.delete fallback fail for the old copy.
        let store = DeleteFailingStore(inner: inner, failing: [oldID])
        let migrator = MeetAIMigrator(paths: fixture.paths, store: store, sidecars: sidecars)
        migrator.loadEntries()
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let result = try await migrator.reprocess(
            folder: folder, retry: { _ in },
            discard: { id in
                if id == oldID { throw Boom() }
                try await store.delete(id: id)
            }
        )
        XCTAssertEqual(result.oldCopyRemovalError, "store delete failed")
        XCTAssertEqual(migrator.entries[folder]?.sessionID, result.sessionID)
    }

    // MARK: F7 — a failing coordinator discard falls back to store.delete

    func testReprocessDiscardFailureFallsBackToStoreDelete() async throws {
        let (migrator, store, sidecars, folder, oldID) = try await reprocessFixture()
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let result = try await migrator.reprocess(folder: folder, retry: { _ in }, discard: { _ in throw Boom() })
        XCTAssertNil(result.oldCopyRemovalError, "fallback removed the old copy")
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [result.sessionID])
        let oldSummary = try await sidecars.summary(for: oldID)
        XCTAssertNil(oldSummary)
    }

    func testReprocessFailureWithFailingDiscardStillDeletesNewSession() async throws {
        let (migrator, store, sidecars, folder, oldID) = try await reprocessFixture()
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        var failedID: MeetingSessionID?
        do {
            _ = try await migrator.reprocess(
                folder: folder,
                retry: { id in
                    failedID = id
                    try await sidecars.saveSummary(MeetAISummaryRecord(style: "s", transcriptHash: "h", markdown: "x", providerID: "p", modelID: "m", createdAt: Date()), for: id)
                    throw MeetingCoordinatorError.activityInProgress
                },
                discard: { _ in throw Boom() }
            )
            XCTFail("expected failure")
        } catch {}
        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.id), [oldID])
        let leftover = try await sidecars.summary(for: try XCTUnwrap(failedID))
        XCTAssertNil(leftover)
    }

    // MARK: F4 — an unreadable migration.json is moved aside and never silently re-migrated

    func testUnreadableMigrationStateIsMovedAsideAndBlocksAutomaticRun() async throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let paths = MeetAIPaths(supportRoot: root)
        try self.makeLegacyFolder(root, name: "2026-10-15T06:00:44", transcript: self.sampleTranscript)
        try FileManager.default.createDirectory(at: paths.migrationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: paths.migrationFile)
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let migrator = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))

        await migrator.run()
        let asideName = try XCTUnwrap(migrator.unreadableStateFile)
        XCTAssertTrue(asideName.hasPrefix("migration.json.unreadable-"))
        let aside = paths.migrationFile.deletingLastPathComponent().appendingPathComponent(asideName)
        XCTAssertEqual(try Data(contentsOf: aside), Data("{ not json".utf8), "original kept, moved aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.migrationFile.path))
        XCTAssertTrue(migrator.entries.isEmpty)
        var all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty, "automatic run did not migrate")

        // A later launch's automatic run stays blocked until the user rebuilds.
        let relaunch = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await relaunch.run()
        XCTAssertNotNil(relaunch.unreadableStateFile)
        all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty)

        // "Re-run migration" rebuilds.
        await relaunch.run(retryFailed: true)
        XCTAssertNil(relaunch.unreadableStateFile)
        XCTAssertEqual(relaunch.entries["2026-10-15T06:00:44"]?.status, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.migrationFile.path))
        let afterRebuild = MeetAIMigrator(paths: paths, store: store, sidecars: MeetAISidecarStore(paths: paths))
        await afterRebuild.run()
        XCTAssertNil(afterRebuild.unreadableStateFile)
        all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
    }
}

/// Forwards to a real store; `delete` throws for the listed IDs.
nonisolated private final class DeleteFailingStore: MeetingSessionStoring {
    struct Failure: LocalizedError { var errorDescription: String? { "store delete failed" } }
    let inner: MeetingSessionStore
    let failing: Set<MeetingSessionID>

    init(inner: MeetingSessionStore, failing: Set<MeetingSessionID>) {
        self.inner = inner
        self.failing = failing
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.inner.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? { try await self.inner.existingSessionDirectory(for: id) }
    func delete(id: MeetingSessionID) async throws {
        if self.failing.contains(id) { throw Failure() }
        try await self.inner.delete(id: id)
    }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
}

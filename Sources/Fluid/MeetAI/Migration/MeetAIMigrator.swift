import Combine
import CryptoKit
import Foundation

nonisolated struct MeetAIMigrationEntry: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case done, skipped, failed }
    var status: Status
    var sessionID: MeetingSessionID?
    var reason: String?
    var migratedAt: Date
    var reprocessedAt: Date?
}

/// Spec §7: imports the fork's MeetingRecordings into FluidMeet. Reads legacy files only.
@MainActor
final class MeetAIMigrator: ObservableObject {
    static let shared = MeetAIMigrator(paths: .standard(), store: MeetingSessionStore.shared, sidecars: .shared)

    @Published private(set) var entries: [String: MeetAIMigrationEntry] = [:]
    @Published private(set) var isRunning = false

    let paths: MeetAIPaths
    let store: any MeetingSessionStoring
    let sidecars: MeetAISidecarStore

    init(paths: MeetAIPaths, store: any MeetingSessionStoring, sidecars: MeetAISidecarStore) {
        self.paths = paths
        self.store = store
        self.sidecars = sidecars
    }

    /// Deterministic per folder so an interrupted run never duplicates (spec §12.7).
    static func sessionID(forFolder folder: String) -> MeetingSessionID {
        var bytes = Array(SHA256.hash(data: Data("meetai-legacy:\(folder)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func loadEntries() {
        guard let data = try? Data(contentsOf: self.paths.migrationFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.entries = (try? decoder.decode([String: MeetAIMigrationEntry].self, from: data)) ?? [:]
    }

    private func saveEntries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: self.paths.migrationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self.entries).write(to: self.paths.migrationFile, options: .atomic)
        } catch {
            DebugLogger.shared.warning("Saving MeetAI migration state failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func run(retryFailed: Bool = false) async {
        guard !self.isRunning else { return }
        self.isRunning = true
        defer { self.isRunning = false }
        self.loadEntries()
        let directory = self.paths.legacyMeetingsDirectory
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for folder in folders.filter({ !$0.hasPrefix(".") }).sorted() {
            if let entry = self.entries[folder] {
                if entry.status == .done || entry.status == .skipped { continue }
                if entry.status == .failed, !retryFailed { continue }
            }
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            do {
                if let id = try await self.migrate(folder: folder, url: url) {
                    self.entries[folder] = MeetAIMigrationEntry(status: .done, sessionID: id, reason: nil, migratedAt: Date())
                }
            } catch let skip as SkipReason {
                self.entries[folder] = MeetAIMigrationEntry(status: .skipped, sessionID: nil, reason: skip.message, migratedAt: Date())
            } catch {
                self.entries[folder] = MeetAIMigrationEntry(status: .failed, sessionID: nil, reason: error.localizedDescription, migratedAt: Date())
            }
            self.saveEntries()
        }
    }

    struct SkipReason: Error {
        let message: String
    }

    private func migrate(folder: String, url: URL) async throws -> MeetingSessionID? {
        let id = Self.sessionID(forFolder: folder)
        guard let markdown = try? String(contentsOf: url.appendingPathComponent("transcript.md"), encoding: .utf8) else {
            throw SkipReason(message: "No transcript.md")
        }
        let parsed = MeetAILegacyTranscriptParser.parse(markdown)
        guard !parsed.segments.isEmpty else { throw SkipReason(message: "Transcript has no lines") }

        let manifest = Self.readManifest(url.appendingPathComponent("session.json"))
        let startedAt = manifest.startedAt ?? Self.folderDate(folder) ?? Date()
        let endedAt = manifest.endedAt
            ?? parsed.duration.map { startedAt.addingTimeInterval($0) }
            ?? startedAt.addingTimeInterval(parsed.segments.last?.end ?? 0)
        let rawTitle = (try? String(contentsOf: url.appendingPathComponent("title.txt"), encoding: .utf8)) ?? ""
        let title = rawTitle.isEmpty
            ? "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))"
            : MeetAILegacyTranscriptParser.stripTitleSuffix(rawTitle)

        // Sidecars are reconciled whether the session is new or left over from an interrupted or failed run.
        let session: MeetingSession
        if let existing = try await self.store.load(id: id) {
            session = existing
        } else {
            session = MeetAISyntheticSessionBuilder.transcriptOnlySession(
                id: id, title: title, startedAt: startedAt, endedAt: endedAt,
                speakers: parsed.speakers, segments: parsed.segments, audioDeletedAt: endedAt
            )
            try await self.store.create(session)
        }

        if try await self.sidecars.summary(for: id) == nil,
           let summary = try? String(contentsOf: url.appendingPathComponent("summary.md"), encoding: .utf8) {
            let body = summary.components(separatedBy: "\n")
                .drop { $0.hasPrefix("# Meeting summary") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let modified = (try? url.appendingPathComponent("summary.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? endedAt
                try await self.sidecars.saveSummary(MeetAISummaryRecord(
                    style: "migrated", transcriptHash: MeetAITranscript.hash(for: session), markdown: body,
                    providerID: "migrated", modelID: "migrated", createdAt: modified
                ), for: id)
            }
        }

        let centroids = (try? JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: url.appendingPathComponent("speakers.json")))) ?? [:]
        var records: [SessionSpeakerID: MeetAISpeakerRecord] = [:]
        for speaker in session.speakers where !speaker.isLocalUser {
            let isNamed = !MeetAITranscript.isDefaultSpeakerName(speaker.displayName)
            records[speaker.id] = MeetAISpeakerRecord(
                embedding: centroids[speaker.displayName].map(MeetAISpeakerMath.normalize),
                matchedProfileID: nil,
                nameSource: isNamed ? .user : nil,
                lastAppliedName: isNamed ? speaker.displayName : nil
            )
        }
        if try await self.sidecars.speakers(for: id).isEmpty {
            try await self.sidecars.saveSpeakers(records, for: id)
        }
        if try await self.sidecars.meta(for: id) == MeetAIMetaRecord() {
            try await self.sidecars.saveMeta(MeetAIMetaRecord(titleSource: .llm, lastLLMTitle: title), for: id)
        }
        return id
    }

    private static func readManifest(_ url: URL) -> (startedAt: Date?, endedAt: Date?) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let formatter = ISO8601DateFormatter()
        return ((json["startedAt"] as? String).flatMap(formatter.date(from:)), (json["endedAt"] as? String).flatMap(formatter.date(from:)))
    }

    /// Folder names are UTC ISO-8601 timestamps without the zone, e.g. 2026-10-15T06:00:44.
    private static func folderDate(_ folder: String) -> Date? {
        ISO8601DateFormatter().date(from: folder + "Z")
    }
}

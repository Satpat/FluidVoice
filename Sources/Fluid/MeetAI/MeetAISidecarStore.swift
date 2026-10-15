import Foundation

nonisolated struct MeetAISummaryRecord: Codable, Equatable, Sendable {
    var style: String
    var transcriptHash: String
    var markdown: String
    var providerID: String
    var modelID: String
    var createdAt: Date
}

nonisolated struct MeetAIQARecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var question: String
    var answer: String
    var askedAt: Date
}

nonisolated enum MeetAINameSource: String, Codable, Sendable {
    case profile, llm, user
}

nonisolated struct MeetAISpeakerRecord: Codable, Equatable, Sendable {
    var embedding: [Float]?
    var matchedProfileID: String?
    var nameSource: MeetAINameSource?
    /// The display name MeetAI last applied or accepted. A different, non-default name means the user renamed.
    var lastAppliedName: String?

    init(embedding: [Float]? = nil, matchedProfileID: String? = nil, nameSource: MeetAINameSource? = nil, lastAppliedName: String? = nil) {
        self.embedding = embedding
        self.matchedProfileID = matchedProfileID
        self.nameSource = nameSource
        self.lastAppliedName = lastAppliedName
    }
}

nonisolated enum MeetAITitleSource: String, Codable, Sendable {
    case `default`, llm, user
}

nonisolated struct MeetAIMetaRecord: Codable, Equatable, Sendable {
    var titleSource: MeetAITitleSource = .default
    var lastLLMTitle: String?
}

/// Per-session MeetAI data, keyed by upstream `MeetingSessionID`.
actor MeetAISidecarStore {
    static let shared = MeetAISidecarStore(paths: .standard())

    private let paths: MeetAIPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: MeetAIPaths) {
        self.paths = paths
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func summary(for id: MeetingSessionID) throws -> MeetAISummaryRecord? {
        try self.read(MeetAISummaryRecord.self, id, "summary.json")
    }

    func saveSummary(_ record: MeetAISummaryRecord?, for id: MeetingSessionID) throws {
        try self.write(record, id, "summary.json")
    }

    func qa(for id: MeetingSessionID) throws -> [MeetAIQARecord] {
        try self.read([MeetAIQARecord].self, id, "qa.json") ?? []
    }

    func saveQA(_ records: [MeetAIQARecord], for id: MeetingSessionID) throws {
        try self.write(records.isEmpty ? nil : records, id, "qa.json")
    }

    func speakers(for id: MeetingSessionID) throws -> [SessionSpeakerID: MeetAISpeakerRecord] {
        let raw = try self.read([String: MeetAISpeakerRecord].self, id, "speakers.json") ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func saveSpeakers(_ records: [SessionSpeakerID: MeetAISpeakerRecord], for id: MeetingSessionID) throws {
        let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        try self.write(raw.isEmpty ? nil : raw, id, "speakers.json")
    }

    func meta(for id: MeetingSessionID) throws -> MeetAIMetaRecord {
        try self.read(MeetAIMetaRecord.self, id, "meta.json") ?? MeetAIMetaRecord()
    }

    func saveMeta(_ record: MeetAIMetaRecord, for id: MeetingSessionID) throws {
        try self.write(record, id, "meta.json")
    }

    func removeAll(for id: MeetingSessionID) throws {
        let directory = self.paths.sessionDirectory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes sidecar folders whose session is not live. Returns the removed IDs. Entries that are
    /// not UUID-named directories are never touched.
    func sweepOrphans(isLive: @Sendable (MeetingSessionID) async -> Bool) async throws -> [MeetingSessionID] {
        let directory = self.paths.sessionsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var removed: [MeetingSessionID] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  await !isLive(id) else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(id)
        }
        return removed
    }

    private func url(_ id: MeetingSessionID, _ name: String) -> URL {
        self.paths.sessionDirectory(for: id).appendingPathComponent(name)
    }

    private func read<T: Decodable>(_ type: T.Type, _ id: MeetingSessionID, _ name: String) throws -> T? {
        let url = self.url(id, name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try self.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T?, _ id: MeetingSessionID, _ name: String) throws {
        let url = self.url(id, name)
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.encoder.encode(value).write(to: url, options: .atomic)
    }
}

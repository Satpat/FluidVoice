import Combine
import Foundation

/// Same JSON shape as the fork's `SpeakerProfile`, so the 27 existing profiles load unchanged.
nonisolated struct MeetAISpeakerProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// L2-normalised centroid of this person's WeSpeaker embedding.
    var embedding: [Float]
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, embedding: [Float], sampleCount: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = MeetAISpeakerMath.normalize(embedding)
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class MeetAISpeakerProfileStore: ObservableObject {
    static let shared = MeetAISpeakerProfileStore(fileURL: MeetAIPaths.standard().profilesFile)
    static let matchThreshold: Float = 0.7
    static let embeddingDimensions = 256

    @Published private(set) var profiles: [MeetAISpeakerProfile] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.load()
    }

    @discardableResult
    func enroll(name: String, embedding: [Float]) -> MeetAISpeakerProfile? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              embedding.count == Self.embeddingDimensions,
              embedding.allSatisfy({ $0.isFinite }) else { return nil }
        if let index = self.profiles.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            guard self.profiles[index].embedding.count == embedding.count else { return nil }
            var profile = self.profiles[index]
            profile.embedding = MeetAISpeakerMath.updatedCentroid(profile.embedding, count: profile.sampleCount, adding: embedding)
            profile.sampleCount += 1
            profile.updatedAt = Self.now()
            self.profiles[index] = profile
            self.save()
            return profile
        }
        let now = Self.now()
        let profile = MeetAISpeakerProfile(name: clean, embedding: embedding, createdAt: now, updatedAt: now)
        self.profiles.append(profile)
        self.save()
        return profile
    }

    func rename(id: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
        self.profiles[index].name = clean
        self.profiles[index].updatedAt = Self.now()
        self.save()
    }

    func delete(id: String) {
        self.profiles.removeAll { $0.id == id }
        self.save()
    }

    /// Copies the fork's profiles file when MeetAI has none yet. Never overwrites; never moves.
    @discardableResult
    func copyLegacyProfilesIfNeeded(from legacyFile: URL) -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: self.fileURL.path), manager.fileExists(atPath: legacyFile.path) else { return false }
        do {
            try manager.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: legacyFile, to: self.fileURL)
            self.load()
            return true
        } catch {
            DebugLogger.shared.warning("Copying legacy speaker profiles failed: \(error.localizedDescription)", source: "MeetAI")
            return false
        }
    }

    /// Whole seconds: the ISO-8601 file format drops fractions, so memory must match what reload yields.
    private static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            self.profiles = try decoder.decode([MeetAISpeakerProfile].self, from: data)
        } catch {
            self.profiles = []
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let aside = self.fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(self.fileURL.lastPathComponent).unreadable-\(formatter.string(from: Date()))")
            DebugLogger.shared.warning("Speaker profiles unreadable (\(error.localizedDescription)); moving to \(aside.lastPathComponent)", source: "MeetAI")
            do {
                try FileManager.default.moveItem(at: self.fileURL, to: aside)
            } catch {
                DebugLogger.shared.warning("Moving unreadable speaker profiles aside failed: \(error.localizedDescription)", source: "MeetAI")
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self.profiles).write(to: self.fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.warning("Saving speaker profiles failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
}

// Persistent speaker identities across meetings.
//
// Inspired by MeetAI's SpeakerProfileStore: store a voice embedding per named
// person, then match each meeting's diarized speakers against them by cosine
// similarity so the same person is recognised in future meetings. Embeddings
// come from FluidAudio's diarizer (no separate encoder needed).

import Combine
import Foundation

struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// L2-normalised centroid of this speaker's voice embedding.
    var embedding: [Float]
    /// Number of enrolments averaged into the centroid (for running updates).
    var sampleCount: Int
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, embedding: [Float], sampleCount: Int = 1,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class SpeakerProfileStore: ObservableObject {
    static let shared = SpeakerProfileStore()

    /// Cosine-similarity threshold for treating a meeting speaker as a known
    /// profile. Matches FluidAudio's intra-meeting clustering threshold (0.7)
    /// so cross-meeting identity is about as strict as same-meeting merging.
    static let matchThreshold: Float = 0.7

    @Published private(set) var profiles: [SpeakerProfile] = []

    private let fileURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FluidVoice/SpeakerProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        self.load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.profiles = (try? decoder.decode([SpeakerProfile].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self.profiles) {
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    // MARK: - Matching

    /// Best-matching profile name for an embedding, or nil below threshold.
    func bestMatchName(for embedding: [Float]) -> String? {
        let query = Self.normalize(embedding)
        var bestName: String?
        var bestScore: Float = -1
        for profile in self.profiles {
            let score = Self.dot(query, profile.embedding)
            if score > bestScore {
                bestScore = score
                bestName = profile.name
            }
        }
        return bestScore >= Self.matchThreshold ? bestName : nil
    }

    // MARK: - Enrolment

    /// Create or update the profile for `name`, folding `embedding` into its
    /// running centroid. Matching is by case-insensitive name.
    func enroll(name: String, embedding: [Float]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !embedding.isEmpty else { return }
        let normalized = Self.normalize(embedding)

        if let index = self.profiles.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            var profile = self.profiles[index]
            profile.embedding = Self.updatedCentroid(profile.embedding, count: profile.sampleCount, adding: normalized)
            profile.sampleCount += 1
            profile.updatedAt = Date()
            self.profiles[index] = profile
        } else {
            self.profiles.append(SpeakerProfile(name: clean, embedding: normalized))
        }
        self.save()
    }

    func rename(id: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
        self.profiles[index].name = clean
        self.profiles[index].updatedAt = Date()
        self.save()
    }

    func delete(id: String) {
        self.profiles.removeAll { $0.id == id }
        self.save()
    }

    // MARK: - Vector math

    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// Weighted average of the existing centroid (weight = count) and a new
    /// normalised sample, renormalised.
    private static func updatedCentroid(_ centroid: [Float], count: Int, adding sample: [Float]) -> [Float] {
        guard centroid.count == sample.count else { return sample }
        let weight = Float(count)
        var combined = [Float](repeating: 0, count: centroid.count)
        for i in centroid.indices {
            combined[i] = centroid[i] * weight + sample[i]
        }
        return normalize(combined)
    }
}

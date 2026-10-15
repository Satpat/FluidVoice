import Foundation

nonisolated enum MeetAIProfileMatching {
    struct Decision: Equatable, Sendable {
        let speakerID: SessionSpeakerID
        let profile: MeetAISpeakerProfile
        let score: Float
    }

    /// Default-labelled, non-local speakers whose embedding matches a profile at ≥ threshold.
    /// One profile goes to at most one speaker (the best score), and never to a name already in use.
    static func decide(
        session: MeetingSession,
        records: [SessionSpeakerID: MeetAISpeakerRecord],
        profiles: [MeetAISpeakerProfile],
        threshold: Float = 0.7
    ) -> [Decision] {
        let usedNames = Set(session.activeSpeakers.map { $0.displayName.lowercased() })
        var bestByProfile: [String: Decision] = [:]
        for speaker in session.activeSpeakers where !speaker.isLocalUser && MeetAITranscript.isDefaultSpeakerName(speaker.displayName) {
            guard let embedding = records[speaker.id]?.embedding else { continue }
            let query = MeetAISpeakerMath.normalize(embedding)
            var top: Decision?
            for profile in profiles where !usedNames.contains(profile.name.lowercased()) {
                let score = MeetAISpeakerMath.dot(query, profile.embedding)
                if score >= threshold, score > (top?.score ?? -1) {
                    top = Decision(speakerID: speaker.id, profile: profile, score: score)
                }
            }
            guard let top else { continue }
            if let existing = bestByProfile[top.profile.id], existing.score >= top.score { continue }
            bestByProfile[top.profile.id] = top
        }
        return bestByProfile.values.sorted { $0.speakerID.uuidString < $1.speakerID.uuidString }
    }
}

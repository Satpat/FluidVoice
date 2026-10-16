import Foundation

nonisolated enum MeetAIProfileMatching {
    struct Decision: Equatable, Sendable {
        let speakerID: SessionSpeakerID
        let profile: MeetAISpeakerProfile
        let score: Float
    }

    /// A runner-up profile scoring within this much of the best one makes the match ambiguous.
    /// Real data: one speaker scored Girish 0.894 vs Stephen 0.841 (gap 0.053); those two profiles
    /// are 0.887 alike while the next most alike pair of 27 is 0.5. 0.1 covers that gap with
    /// headroom and still names clear winners (same voice ≈ 0.98, different voices ≈ 0.1).
    static let ambiguityMargin: Float = 0.1

    /// Default-labelled, non-local speakers whose embedding matches a profile at ≥ threshold.
    /// One profile goes to at most one speaker (the best score), and never to a name already in use.
    /// A speaker whose runner-up also clears the threshold within `margin` is left for LLM naming.
    static func decide(
        session: MeetingSession,
        records: [SessionSpeakerID: MeetAISpeakerRecord],
        profiles: [MeetAISpeakerProfile],
        threshold: Float = 0.7,
        margin: Float = ambiguityMargin
    ) -> [Decision] {
        let usedNames = Set(session.activeSpeakers.map { $0.displayName.lowercased() })
        var bestByProfile: [String: Decision] = [:]
        for speaker in session.activeSpeakers where !speaker.isLocalUser && MeetAITranscript.isDefaultSpeakerName(speaker.displayName) {
            guard let embedding = records[speaker.id]?.embedding else { continue }
            let query = MeetAISpeakerMath.normalize(embedding)
            var top: Decision?
            var runnerUp: Float?
            for profile in profiles where !usedNames.contains(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                let score = MeetAISpeakerMath.dot(query, profile.embedding)
                guard score >= threshold else { continue }
                if score > (top?.score ?? -1) {
                    runnerUp = top?.score
                    top = Decision(speakerID: speaker.id, profile: profile, score: score)
                } else if score > (runnerUp ?? -1) {
                    runnerUp = score
                }
            }
            guard let top else { continue }
            if let runnerUp, top.score - runnerUp < margin { continue }
            if let existing = bestByProfile[top.profile.id], existing.score >= top.score { continue }
            bestByProfile[top.profile.id] = top
        }
        return bestByProfile.values.sorted { $0.speakerID.uuidString < $1.speakerID.uuidString }
    }
}

import Foundation

/// Turns a saved correction into sidecar updates (spec §12.3). Pure.
nonisolated enum MeetAICorrectionDiff {
    struct Enrolment: Equatable, Sendable {
        let speakerID: SessionSpeakerID
        let name: String
        let embedding: [Float]
    }

    struct Result: Equatable, Sendable {
        var records: [SessionSpeakerID: MeetAISpeakerRecord]
        var enrolments: [Enrolment]
        var renamedSpeakers: Bool
        var changed: Bool
    }

    static func apply(session: MeetingSession, records: [SessionSpeakerID: MeetAISpeakerRecord]) -> Result {
        var result = Result(records: records, enrolments: [], renamedSpeakers: false, changed: false)
        for speaker in session.activeSpeakers where !speaker.isLocalUser {
            let name = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            var record = result.records[speaker.id] ?? MeetAISpeakerRecord()
            guard !MeetAITranscript.isDefaultSpeakerName(name), name != record.lastAppliedName else { continue }
            record.nameSource = .user
            record.lastAppliedName = name
            if let embedding = record.embedding {
                result.enrolments.append(Enrolment(speakerID: speaker.id, name: name, embedding: embedding))
            }
            result.records[speaker.id] = record
            result.renamedSpeakers = true
            result.changed = true
        }
        for speaker in session.speakers where speaker.mergedIntoSpeakerID != nil {
            guard result.records[speaker.id]?.embedding != nil else { continue }
            result.records[speaker.id]?.embedding = nil
            result.changed = true
        }
        return result
    }
}

import Foundation

nonisolated enum MeetAITranscript {
    /// Prompt text: upstream's own rendering, so names and echo filtering match the UI.
    static func text(for session: MeetingSession) -> String {
        MeetingSummaryInput.transcript(for: session)
    }

    /// `Label: text` per non-echo turn, in time order. Excludes the title, so retitling does not
    /// make a summary stale.
    static func turns(for session: MeetingSession) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        return session.transcriptSegments
            .filter { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start.seconds < $1.start.seconds }
            .map { "\(MeetingTranscriptExporter.speakerLabel(for: $0, in: session, speakerNames: names)): \($0.text)" }
    }

    static func hash(for session: MeetingSession) -> String {
        MeetingSummaryInput.fingerprint(self.turns(for: session).joined(separator: "\n"))
    }

    static func localUserLabel(in session: MeetingSession) -> String {
        session.activeSpeakers.first(where: \.isLocalUser)?.displayName ?? "You"
    }

    /// Upstream's generated labels plus the fork's legacy "Them"/"Them N" (spec §12.4).
    private static let defaultNamePattern =
        #"^(Speaker \d+|Microphone Speaker \d+|Room Speaker( \d+)?|Meeting [Aa]udio|Microphone / Unknown|Them( \d+)?)$"#

    static func isDefaultSpeakerName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).range(of: self.defaultNamePattern, options: .regularExpression) != nil
    }
}

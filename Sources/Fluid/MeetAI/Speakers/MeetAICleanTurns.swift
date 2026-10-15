import Foundation

nonisolated enum MeetAICleanTurns {
    static let maximumSeconds: TimeInterval = 30
    static let minimumTurnSeconds: TimeInterval = 1.5
    static let minimumTotalSeconds: TimeInterval = 3

    /// The speaker's longest single-speaker, non-echo, non-overlapping turns, up to 30 s in total.
    /// Empty when less than 3 s qualifies.
    static func select(for speakerID: SessionSpeakerID, in session: MeetingSession) -> [MeetingTranscriptSegment] {
        func duration(_ segment: MeetingTranscriptSegment) -> TimeInterval { segment.end.seconds - segment.start.seconds }
        let candidates = session.transcriptSegments
            .filter {
                $0.speakerID == speakerID && !$0.isEcho && $0.overlap == .none
                    && ($0.attributionState ?? .assigned) == .assigned
                    && duration($0) >= self.minimumTurnSeconds
            }
            .sorted { duration($0) > duration($1) }
        var picked: [MeetingTranscriptSegment] = []
        var total: TimeInterval = 0
        for segment in candidates where total < self.maximumSeconds {
            picked.append(segment)
            total += duration(segment)
        }
        return total >= self.minimumTotalSeconds ? picked : []
    }
}

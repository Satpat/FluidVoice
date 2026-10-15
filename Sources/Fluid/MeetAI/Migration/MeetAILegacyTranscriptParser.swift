import Foundation

/// Parses the fork's `transcript.md` (`**[MM:SS] Speaker:** text`; minutes may exceed 59; H:MM:SS also accepted).
nonisolated enum MeetAILegacyTranscriptParser {
    struct Parsed: Equatable, Sendable {
        var speakers: [MeetAISyntheticSessionBuilder.LegacySpeaker]
        var segments: [MeetAISyntheticSessionBuilder.LegacySegment]
        var duration: TimeInterval?
    }

    static let localLabel = "Me"
    /// The fork wrote an empty label for unattributed remote speech; its speakers.json keys these as "Them".
    static let unlabeledRemote = "Them"
    static let minimumSegmentSeconds: TimeInterval = 0.5
    static let lastSegmentFallbackSeconds: TimeInterval = 5

    private static let linePattern = try! NSRegularExpression(pattern: #"^\*\*\[(\d+):(\d{2})(?::(\d{2}))?\] (.*?):\*\* ?(.*)$"#)
    private static let durationPattern = try! NSRegularExpression(pattern: #"^- Duration: (\d+):(\d{2})(?::(\d{2}))?\s*$"#)

    static func parse(_ markdown: String) -> Parsed {
        var starts: [(start: TimeInterval, label: String, text: String)] = []
        var duration: TimeInterval?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = self.match(self.linePattern, line) {
                starts.append((self.seconds(match, 1, 2, 3), match[4].isEmpty ? self.unlabeledRemote : match[4], match[5]))
            } else if let match = self.match(self.durationPattern, line) {
                duration = self.seconds(match, 1, 2, 3)
            } else if !line.isEmpty, !starts.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("- ") {
                starts[starts.count - 1].text += "\n" + line
            }
        }
        var speakers: [MeetAISyntheticSessionBuilder.LegacySpeaker] = []
        var seen = Set<String>()
        var segments: [MeetAISyntheticSessionBuilder.LegacySegment] = []
        for (index, entry) in starts.enumerated() {
            if seen.insert(entry.label).inserted {
                speakers.append(.init(label: entry.label, isLocalUser: entry.label == self.localLabel))
            }
            let next = index + 1 < starts.count ? starts[index + 1].start : (duration ?? entry.start + self.lastSegmentFallbackSeconds)
            segments.append(.init(
                start: entry.start,
                end: max(next, entry.start + self.minimumSegmentSeconds),
                speakerLabel: entry.label,
                text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return Parsed(speakers: speakers, segments: segments, duration: duration)
    }

    /// "Short title (Thu, 15 Oct at 4:30 pm)" → "Short title".
    static func stripTitleSuffix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? trimmed : stripped
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let result = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Groups (a, b, c): "a:b" = minutes:seconds, "a:b:c" = hours:minutes:seconds.
    private static func seconds(_ match: [String], _ a: Int, _ b: Int, _ c: Int) -> TimeInterval {
        let first = Double(match[a]) ?? 0, second = Double(match[b]) ?? 0
        if !match[c].isEmpty { return first * 3_600 + second * 60 + (Double(match[c]) ?? 0) }
        return first * 60 + second
    }
}

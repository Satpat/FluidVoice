import Foundation

nonisolated struct MeetAITranslationRecord: Codable, Equatable, Sendable {
    var english: String
    /// Fingerprint of the segment text that was translated; an edited segment no longer matches.
    var sourceHash: String
}

/// Finds segments spoken in Indian languages and translates them to English through the user's AI
/// provider. The transcript keeps the original text; translations live in a sidecar keyed by
/// segment ID.
nonisolated enum MeetAITranslator {
    /// Rough prompt budget per request so a long meeting is translated in several small calls.
    static let maximumBatchCharacters = 3_000

    static let systemPrompt = """
    You translate meeting transcript segments into English. The user message is a JSON array of \
    {"id", "text"} objects. Parts may be in Bengali, Hindi or another Indian language, often mixed \
    with English. Translate faithfully and naturally; keep any English as it is, keep names, and \
    add no commentary. Reply with ONLY a JSON array of {"id", "english"} objects, one per input id.
    """

    // Devanagari through Malayalam: Hindi, Marathi, Bengali, Gurmukhi, Gujarati, Odia, Tamil, Telugu, Kannada.
    private static let indicScalars: ClosedRange<UInt32> = 0x0900...0x0D7F

    /// True when enough of the letters are Indic script. Mixed English/Indic turns qualify; a single
    /// stray character or Latin-only text does not.
    static func isIndic(_ text: String) -> Bool {
        var indic = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                if self.indicScalars.contains(scalar.value) { indic += 1 } else { other += 1 }
            case .nonspacingMark, .spacingMark:
                if self.indicScalars.contains(scalar.value) { indic += 1 }
            default:
                break
            }
        }
        return indic >= 3 && Double(indic) / Double(indic + other) >= 0.3
    }

    static func hash(_ text: String) -> String {
        MeetingSummaryInput.fingerprint(text)
    }

    /// Non-echo segments worth translating, in time order.
    static func candidates(in session: MeetingSession) -> [MeetingTranscriptSegment] {
        session.transcriptSegments
            .filter { !$0.isEcho && self.isIndic($0.text) }
            .sorted { $0.start.seconds < $1.start.seconds }
    }

    /// The English for a segment, or nil when it has none or the segment was edited since.
    static func english(for segment: MeetingTranscriptSegment, in records: [String: MeetAITranslationRecord]) -> String? {
        guard let record = records[segment.id.uuidString], record.sourceHash == self.hash(segment.text) else { return nil }
        return record.english
    }

    /// Translates segments that have no current translation. Throws only when the provider call
    /// itself fails; an unusable reply just leaves those segments untranslated.
    @MainActor
    static func translate(
        session: MeetingSession,
        existing: [String: MeetAITranslationRecord],
        llm: any MeetAILLMCompleting
    ) async throws -> [String: MeetAITranslationRecord] {
        let wanted = self.candidates(in: session)
        var result: [String: MeetAITranslationRecord] = [:]
        var pending: [MeetingTranscriptSegment] = []
        for segment in wanted {
            if self.english(for: segment, in: existing) != nil {
                result[segment.id.uuidString] = existing[segment.id.uuidString]
            } else {
                pending.append(segment)
            }
        }
        for batch in self.batches(pending) {
            let reply = try await llm.complete(
                systemPrompt: self.systemPrompt,
                turns: [MeetAILLMTurn(role: "user", content: self.prompt(for: batch))]
            )
            let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id.uuidString, $0) })
            for (id, english) in self.parse(reply, expectedIDs: Set(byID.keys)) {
                guard let segment = byID[id] else { continue }
                result[id] = MeetAITranslationRecord(english: english, sourceHash: self.hash(segment.text))
            }
        }
        return result
    }

    static func batches(_ segments: [MeetingTranscriptSegment]) -> [[MeetingTranscriptSegment]] {
        var batches: [[MeetingTranscriptSegment]] = []
        var current: [MeetingTranscriptSegment] = []
        var size = 0
        for segment in segments {
            if !current.isEmpty, size + segment.text.count > self.maximumBatchCharacters {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(segment)
            size += segment.text.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func prompt(for batch: [MeetingTranscriptSegment]) -> String {
        let items = batch.map { ["id": $0.id.uuidString, "text": $0.text] }
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private struct Reply: Decodable {
        let id: String
        let english: String
    }

    /// Tolerates code fences and chatter around the JSON array; ignores unknown ids and empty text.
    static func parse(_ reply: String, expectedIDs: Set<String>) -> [String: String] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let items = try? JSONDecoder().decode([Reply].self, from: Data(reply[start...end].utf8))
        else { return [:] }
        var parsed: [String: String] = [:]
        for item in items where expectedIDs.contains(item.id) {
            let english = item.english.trimmingCharacters(in: .whitespacesAndNewlines)
            if !english.isEmpty { parsed[item.id] = english }
        }
        return parsed
    }
}

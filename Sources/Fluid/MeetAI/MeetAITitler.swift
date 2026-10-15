import Foundation

nonisolated enum MeetAITitler {
    static let systemPrompt = """
    You title meetings. Reply with ONLY a concise, descriptive 3-8 word title for the meeting \
    described below. No quotes, no dates, no trailing punctuation.
    """

    /// First non-empty line, stripped of quotes/markdown/trailing punctuation, max 60 characters.
    static func clean(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`#*. "))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60))
    }

    /// MeetAI may (re)title while upstream's default title stands or its own last title stands (spec §12.5).
    static func ownsTitle(session: MeetingSession, meta: MeetAIMetaRecord) -> Bool {
        session.defaultTitleBase != nil || (meta.lastLLMTitle != nil && session.title == meta.lastLLMTitle)
    }
}

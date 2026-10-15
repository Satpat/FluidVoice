// Selectable formats for generated meeting summaries. A style only changes
// the format instructions appended to the shared transcript preamble (see
// MeetingTranscriptPipeline.generateSummaryBody); the transcript handling,
// provider resolution, and summary.md output are the same for every style.

import Foundation

enum MeetingSummaryStyle: String, CaseIterable, Identifiable {
    case standard
    case keyTakeaways
    case whatByWhenPerSpeaker
    case whatByWhenBroad

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .keyTakeaways:
            return "Key Takeaways and Summary of Topics"
        case .whatByWhenPerSpeaker:
            return "What by When and Why (per speaker)"
        case .whatByWhenBroad:
            return "What by When and Why (broad)"
        }
    }

    /// The user-turn request paired with `formatInstructions`. Small local
    /// models tend to follow the user message over the system prompt, so the
    /// request must restate what the style asks for rather than a generic
    /// "summarise this".
    var userPrompt: String {
        switch self {
        case .standard:
            return "Summarise this meeting."
        case .keyTakeaways:
            return "Give the key takeaways and a topic-by-topic summary of this meeting, in the format described."
        case .whatByWhenPerSpeaker:
            return "List the action items for each speaker in this meeting on a \"What by When and Why\" basis, in the format described."
        case .whatByWhenBroad:
            return "Describe what we are collectively trying to achieve in this meeting on a \"What by When and Why\" basis, in the format described."
        }
    }

    /// What the model is asked to produce, appended to the shared preamble.
    var formatInstructions: String {
        switch self {
        case .standard:
            return """
            Write a concise summary in Markdown with these sections, omitting any section with nothing to say:

            ## Overview — 1-3 sentences on what the meeting was about.
            ## Key points — bullet list of the substantive points discussed.
            ## Decisions — bullet list of decisions reached.
            ## Action items — bullet list; note who owns each when clear.
            ## Open questions — bullet list of unresolved items.
            """
        case .keyTakeaways:
            return """
            Write a summary in Markdown with exactly these sections:

            ## Key takeaways
            ### Core points
            A bullet list of the essential points of the meeting, most important first.

            ## Summary
            One top-level bullet per topic discussed, in the order the topics came up, each followed \
            by indented sub-bullets describing what was discussed about that topic:
            - Topic discussed
              - What was discussed
            """
        case .whatByWhenPerSpeaker:
            return """
            Create a list of action items for each speaker based on the transcript, answering on a \
            "What by When and Why" basis:
            — What exactly do you need from me?
            — When exactly do you need each of those things by?
            — Why exactly do you need each of those things to be done?

            Write Markdown with one "## <speaker>" section per speaker who has action items, each \
            section a bullet list where every action item states **What** exactly they need to do, \
            **When** exactly it is needed by (quote the deadline discussed, or note that none was \
            mentioned), and **Why** exactly it needs to be done. Put the section for the user \
            ("Me") first and make it the most thorough and detailed. Omit speakers with no action items.
            """
        case .whatByWhenBroad:
            return """
            Describe what the participants are collectively trying to achieve, answering on a \
            "What by When and Why" basis:
            — What exactly do we have to do?
            — When exactly do we need each of those things by?
            — Why exactly do we need each of those things to be done?

            Write Markdown with these sections:

            ## What
            Bullet list of what exactly has to be done.
            ## When
            Bullet list of when exactly each of those things is needed by (quote deadlines \
            discussed; note where none was mentioned).
            ## Why
            Bullet list of why exactly each of those things needs to be done.
            """
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "MeetingSummaryStyle"

    /// The style used for newly generated summaries, persisted across runs.
    static var current: MeetingSummaryStyle {
        get {
            UserDefaults.standard.string(forKey: Self.defaultsKey)
                .flatMap(MeetingSummaryStyle.init(rawValue:)) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey) }
    }
}

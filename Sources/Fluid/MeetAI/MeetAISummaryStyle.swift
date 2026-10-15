import Combine
import Foundation

nonisolated enum MeetAISummaryStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case keyTakeaways
    case whatByWhenPerSpeaker
    case whatByWhenBroad

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .keyTakeaways: "Key Takeaways and Summary of Topics"
        case .whatByWhenPerSpeaker: "What by When and Why (per speaker)"
        case .whatByWhenBroad: "What by When and Why (broad)"
        }
    }

    /// Small local models follow the user turn over the system prompt, so it restates the ask.
    var userPrompt: String {
        switch self {
        case .standard: "Summarise this meeting."
        case .keyTakeaways: "Give the key takeaways and a topic-by-topic summary of this meeting, in the format described."
        case .whatByWhenPerSpeaker: "List the action items for each speaker in this meeting on a \"What by When and Why\" basis, in the format described."
        case .whatByWhenBroad: "Describe what we are collectively trying to achieve in this meeting on a \"What by When and Why\" basis, in the format described."
        }
    }

    func formatInstructions(localLabel: String) -> String {
        switch self {
        case .standard:
            """
            Write a concise summary in Markdown with these sections, omitting any section with nothing to say:

            ## Overview — 1-3 sentences on what the meeting was about.
            ## Key points — bullet list of the substantive points discussed.
            ## Decisions — bullet list of decisions reached.
            ## Action items — bullet list; note who owns each when clear.
            ## Open questions — bullet list of unresolved items.
            """
        case .keyTakeaways:
            """
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
            """
            Create a list of action items for each speaker based on the transcript, answering on a \
            "What by When and Why" basis:
            — What exactly do you need from me?
            — When exactly do you need each of those things by?
            — Why exactly do you need each of those things to be done?

            Write Markdown with one "## <speaker>" section per speaker who has action items, each \
            section a bullet list where every action item states **What** exactly they need to do, \
            **When** exactly it is needed by (quote the deadline discussed, or note that none was \
            mentioned), and **Why** exactly it needs to be done. Put the section for the user \
            ("\(localLabel)") first and make it the most thorough and detailed. Omit speakers with no action items.
            """
        case .whatByWhenBroad:
            """
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
}

extension MeetAISettings {
    var summaryStyle: MeetAISummaryStyle {
        get { self.defaults.string(forKey: Key.summaryStyle).flatMap(MeetAISummaryStyle.init(rawValue:)) ?? .standard }
        set {
            self.objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Key.summaryStyle)
        }
    }
}

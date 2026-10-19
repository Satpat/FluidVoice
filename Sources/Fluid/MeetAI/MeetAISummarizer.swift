import Foundation

@MainActor
enum MeetAISummarizer {
    static func systemPrompt(style: MeetAISummaryStyle, localLabel: String) -> (String) -> String {
        { transcript in
            """
            You summarise meetings. Below is a machine-generated transcript of a meeting. The user is \
            labelled "\(localLabel)"; other participants are labelled by name or as "Speaker N". The \
            transcription may contain recognition errors — infer the intended meaning where obvious. \
            \(style.formatInstructions(localLabel: localLabel))

            Transcript:
            \(transcript)
            """
        }
    }

    static func generate(
        session: MeetingSession,
        style: MeetAISummaryStyle,
        llm: any MeetAILLMCompleting,
        translations: [String: MeetAITranslationRecord] = [:]
    ) async throws -> MeetAISummaryRecord {
        guard !MeetAITranscript.turns(for: session).isEmpty else {
            throw MeetAILLMError("This meeting has no transcript to summarise.")
        }
        let reply = try await llm.completeAboutTranscript(
            transcript: MeetAITranscript.text(for: session, translations: translations),
            turns: [MeetAILLMTurn(role: "user", content: style.userPrompt)],
            systemPrompt: self.systemPrompt(style: style, localLabel: MeetAITranscript.localUserLabel(in: session))
        )
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MeetAILLMError("The AI provider returned an empty summary.") }
        let descriptor = llm.descriptor()
        return MeetAISummaryRecord(
            style: style.rawValue,
            transcriptHash: MeetAITranscript.hash(for: session),
            markdown: body,
            providerID: descriptor.providerID,
            modelID: descriptor.modelID,
            createdAt: Date()
        )
    }
}

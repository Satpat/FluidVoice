import Combine
import Foundation

@MainActor
final class MeetAIQAService: ObservableObject {
    @Published private(set) var records: [MeetAIQARecord] = []
    @Published private(set) var isThinking = false
    @Published var error: String?

    private let sessionID: MeetingSessionID
    private let sidecars: MeetAISidecarStore
    private let llm: any MeetAILLMCompleting

    init(sessionID: MeetingSessionID, sidecars: MeetAISidecarStore = .shared, llm: (any MeetAILLMCompleting)? = nil) {
        self.sessionID = sessionID
        self.sidecars = sidecars
        self.llm = llm ?? MeetAILLM()
    }

    static func systemPrompt(localLabel: String) -> (String) -> String {
        { transcript in
            """
            You are a meeting assistant. Below is the machine-generated transcript of a finished meeting. \
            The user is labelled "\(localLabel)"; other participants are labelled by name or as "Speaker N". \
            The transcription may contain recognition errors; infer the intended meaning where it is obvious. \
            Answer the user's questions about this meeting concisely and factually. If the transcript does \
            not contain the answer, say so plainly.

            Transcript:
            \(transcript.isEmpty ? "(no speech was transcribed)" : transcript)
            """
        }
    }

    func load() async {
        self.records = (try? await self.sidecars.qa(for: self.sessionID)) ?? []
    }

    func ask(_ question: String, session: MeetingSession) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !self.isThinking else { return }
        self.error = nil
        self.isThinking = true
        defer { self.isThinking = false }
        var turns: [MeetAILLMTurn] = []
        for record in self.records.suffix(4) {
            turns.append(MeetAILLMTurn(role: "user", content: record.question))
            turns.append(MeetAILLMTurn(role: "assistant", content: record.answer))
        }
        turns.append(MeetAILLMTurn(role: "user", content: question))
        do {
            let answer = try await self.llm.completeAboutTranscript(
                transcript: MeetAITranscript.text(for: session),
                turns: turns,
                systemPrompt: Self.systemPrompt(localLabel: MeetAITranscript.localUserLabel(in: session))
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw MeetAILLMError("The AI provider returned an empty response.") }
            self.records.append(MeetAIQARecord(id: UUID(), question: question, answer: answer, askedAt: Date()))
            try await self.sidecars.saveQA(self.records, for: self.sessionID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() async {
        self.records = []
        self.error = nil
        try? await self.sidecars.saveQA([], for: self.sessionID)
    }
}

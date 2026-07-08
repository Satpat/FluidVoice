// MeetAI v2 meeting Q&A.
//
// Answers questions about the meeting-so-far by sending the live transcript
// plus the question to the user's configured AI provider (via MeetingAIClient).

import Combine
import Foundation

@MainActor
final class MeetingQAService: ObservableObject {
    /// Shared so the conversation survives sidebar navigation.
    static let shared = MeetingQAService()

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isThinking = false
    @Published var error: String?

    func reset() {
        self.messages = []
        self.error = nil
        self.isThinking = false
    }

    func ask(_ question: String, transcript: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !self.isThinking else { return }

        self.error = nil
        self.messages.append(Message(role: .user, text: question))
        self.isThinking = true
        defer { self.isThinking = false }

        let systemPrompt = """
        You are a meeting assistant. Below is the machine-generated transcript so far of a \
        meeting between the user (labelled "Me") and the other participants (labelled "Them", \
        or "Them 1"/"Them 2"/... when individual speakers were distinguished). \
        Timestamps are minutes:seconds from the start. The transcription may contain \
        recognition errors; infer the intended meaning where it is obvious. Answer the user's \
        questions about the meeting concisely and factually. If the transcript does not \
        contain the answer, say so plainly.

        Transcript so far:
        \(transcript.isEmpty ? "(no speech captured yet)" : transcript)
        """

        // Include recent turns so follow-up questions have context.
        let turns = self.messages.suffix(9).map {
            MeetingAIClient.Turn(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }

        do {
            let answer = try await MeetingAIClient.complete(systemPrompt: systemPrompt, turns: turns)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MeetingRecordingError("The AI provider returned an empty response.")
            }
            self.messages.append(Message(role: .assistant, text: trimmed))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

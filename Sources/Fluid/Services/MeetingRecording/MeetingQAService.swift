// MeetAI v2 meeting Q&A.
//
// Answers questions about the meeting-so-far by sending the live transcript
// plus the question to the user's configured AI provider (same settings as
// AI Enhancement: built-in providers, custom OpenAI-compatible endpoints
// like Ollama, or Apple Intelligence).

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
        meeting between the user (labelled "Me") and the other participants (labelled "Them"). \
        Timestamps are minutes:seconds from the start. The transcription may contain \
        recognition errors; infer the intended meaning where it is obvious. Answer the user's \
        questions about the meeting concisely and factually. If the transcript does not \
        contain the answer, say so plainly.

        Transcript so far:
        \(transcript.isEmpty ? "(no speech captured yet)" : transcript)
        """

        do {
            let answer = try await self.complete(systemPrompt: systemPrompt, question: question)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MeetingRecordingError("The AI provider returned an empty response.")
            }
            self.messages.append(Message(role: .assistant, text: trimmed))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Provider plumbing

    private func complete(systemPrompt: String, question: String) async throws -> String {
        let resolved = Self.resolveProvider()

        if resolved.providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                return try await provider.process(
                    systemPrompt: systemPrompt,
                    userText: self.conversationForSingleTurn(question: question)
                )
            }
            #endif
            throw MeetingRecordingError("Apple Intelligence is not available on this system.")
        }

        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingRecordingError("No AI model selected. Configure one under AI Enhancement.")
        }
        let isLocal = ModelRepository.shared.isLocalEndpoint(resolved.baseURL)
        if !isLocal, resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MeetingRecordingError("Missing API key for \(resolved.providerID). Configure it under AI Enhancement.")
        }

        var llmMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        // Include recent turns so follow-up questions have context.
        for message in self.messages.suffix(9) {
            llmMessages.append([
                "role": message.role == .user ? "user" : "assistant",
                "content": message.text,
            ])
        }

        var config = LLMClient.Config(
            messages: llmMessages,
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: SettingsStore.shared.isTemperatureUnsupported(resolved.model) ? nil : 0.3,
            extraParameters: [:]
        )
        config.timeoutSeconds = 120

        let response = try await LLMClient.shared.call(config)
        return response.content
    }

    /// Apple Intelligence takes a single user string; flatten recent turns.
    private func conversationForSingleTurn(question: String) -> String {
        let history = self.messages.suffix(9).dropLast()
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")
        return history.isEmpty ? question : "\(history)\nUser: \(question)"
    }

    private struct ResolvedProvider {
        let providerID: String
        let baseURL: String
        let model: String
        let apiKey: String
    }

    /// Mirror of the AI Enhancement provider resolution (see
    /// DictationPostProcessingService.resolveProvider), without the
    /// dictation-slot and Private AI special cases.
    private static func resolveProvider() -> ResolvedProvider {
        let settings = SettingsStore.shared
        let providerID = settings.selectedProviderID
        let selectedModels = settings.selectedModelByProvider
        let providerKeys = settings.providerAPIKeys

        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            let key = "custom:\(saved.id)"
            return ResolvedProvider(
                providerID: providerID,
                baseURL: saved.baseURL,
                model: selectedModels[key] ?? saved.models.first ?? "",
                apiKey: providerKeys[key] ?? providerKeys[providerID] ?? ""
            )
        }

        if ModelRepository.shared.isBuiltIn(providerID) {
            return ResolvedProvider(
                providerID: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: selectedModels[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? "",
                apiKey: providerKeys[providerID] ?? ""
            )
        }

        return ResolvedProvider(
            providerID: providerID,
            baseURL: "",
            model: selectedModels[providerID] ?? "",
            apiKey: providerKeys[providerID] ?? ""
        )
    }
}

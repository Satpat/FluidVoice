import Foundation

/// Local API `/postprocess` adapter. The implementation lives in
/// DictationAIProcessor (`.localAPI` mode), shared with dictation.
@MainActor
final class DictationPostProcessingService {
    static let shared = DictationPostProcessingService()

    private init() {}

    struct Result {
        let text: String
        let providerID: String
        let model: String
    }

    func process(_ inputText: String, dictationSlot: SettingsStore.DictationShortcutSlot = .primary) async throws -> Result {
        let result = try await DictationAIProcessor.shared.process(DictationAIProcessor.Request(
            text: inputText,
            mode: .localAPI,
            slot: dictationSlot
        ))
        return Result(text: result.text, providerID: result.providerID, model: result.model)
    }
}

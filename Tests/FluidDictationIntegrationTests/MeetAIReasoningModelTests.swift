@testable import FluidVoice_Debug
import XCTest

// Carried from the fork (90234f5): gpt-6.x models reject max_tokens and temperature.
// Upstream's isReasoningModel already covers them; this pins it so a narrowing fails loudly.
@MainActor
final class MeetAIReasoningModelTests: XCTestCase {
    func testGPT6GenerationIsReasoningModel() {
        let reasoning = ["gpt-6.1-sol", "gpt-6", "gpt-6-mini", "openai/gpt-6.1", "azure/gpt-6.1-sol"]
        for model in reasoning {
            XCTAssertTrue(SettingsStore.shared.isReasoningModel(model), "\(model) needs max_completion_tokens")
            XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported(model, baseURL: "https://api.openai.com/v1"), "\(model) rejects temperature")
        }
        let chat = ["gpt-4.1", "gpt-4o", "gpt-4o-mini", "gpt-3.5-turbo", "gpt-4.1-nano"]
        for model in chat {
            XCTAssertFalse(SettingsStore.shared.isReasoningModel(model), "\(model) still uses max_tokens")
        }
    }
}

@testable import FluidVoice_Debug
import XCTest

// Shared LLM helpers: endpoint classification, reasoning request params, and
// the meeting transcript context-window retry policy.

@MainActor
final class LLMHelpersTests: XCTestCase {
    // MARK: - EndpointClassifier

    func testIsLocal() {
        let local = [
            "http://localhost:11434/v1", "http://127.0.0.1:8080", "http://127.0.1.1",
            "http://[::1]:1234/v1", "http://10.0.0.5:8000", "http://192.168.1.20:1234/v1",
            "http://172.16.0.1", "http://172.31.255.255:9000",
        ]
        let remote = [
            "https://api.openai.com/v1", "https://api.anthropic.com/v1", "http://172.15.0.1",
            "http://172.32.0.1", "http://11.0.0.1", "not a url", "",
        ]
        for url in local { XCTAssertTrue(EndpointClassifier.isLocal(url), url) }
        for url in remote { XCTAssertFalse(EndpointClassifier.isLocal(url), url) }
    }

    // MARK: - Reasoning params

    func testReasoningExtraParameters() {
        let settings = SettingsStore.shared
        let provider = "test-provider-\(UUID().uuidString)"
        let saved = settings.modelReasoningConfigs
        defer { settings.modelReasoningConfigs = saved }

        var configs = saved
        configs["\(provider):effort-model"] = SettingsStore.ModelReasoningConfig(
            parameterName: "reasoning_effort", parameterValue: "medium", isEnabled: true
        )
        configs["\(provider):thinking-model"] = SettingsStore.ModelReasoningConfig(
            parameterName: "enable_thinking", parameterValue: "true", isEnabled: true
        )
        configs["\(provider):disabled-model"] = SettingsStore.ModelReasoningConfig(
            parameterName: "reasoning_effort", parameterValue: "high", isEnabled: false
        )
        settings.modelReasoningConfigs = configs

        XCTAssertEqual(
            settings.reasoningExtraParameters(forModel: "effort-model", provider: provider) as? [String: String],
            ["reasoning_effort": "medium"]
        )
        XCTAssertEqual(
            settings.reasoningExtraParameters(forModel: "effort-model", provider: provider, responsesAPI: true)["reasoning"]
                as? [String: String],
            ["effort": "medium"]
        )
        XCTAssertEqual(
            settings.reasoningExtraParameters(forModel: "thinking-model", provider: provider) as? [String: Bool],
            ["enable_thinking": true]
        )
        XCTAssertTrue(settings.reasoningExtraParameters(forModel: "disabled-model", provider: provider).isEmpty)
    }

    // MARK: - Context-window retry

    private struct FakeOverflow: LocalizedError {
        var errorDescription: String? { "This model's maximum context length is 4096 tokens" }
    }

    private func transcript(lines: Int) -> String {
        (0..<lines).map { "[00:\(String(format: "%02d", $0 % 60))] Them: line number \($0) of the meeting transcript" }
            .joined(separator: "\n")
    }

    func testCompleteFittingContext_convergesUnderSmallLocalWindow() async throws {
        let window = 4_096
        var attempts = 0
        let reply = try await MeetingAIClient.completeFittingContext(
            transcript: self.transcript(lines: 5_000),
            turns: [MeetingAIClient.Turn(role: "user", content: "Summarise this meeting.")],
            systemPrompt: { "You summarise meetings.\n\($0)" },
            startingBudgetTokens: 1_000_000,
            maxAttempts: 20,
            complete: { prompt, _ in
                attempts += 1
                guard MeetingAIClient.approxTokens(prompt) <= window - 1_024 else { throw FakeOverflow() }
                return "ok"
            }
        )
        XCTAssertEqual(reply, "ok")
        XCTAssertLessThanOrEqual(attempts, 20)
        XCTAssertGreaterThan(attempts, 1)
    }

    func testCompleteFittingContext_remoteAttemptCap() async {
        var attempts = 0
        do {
            _ = try await MeetingAIClient.completeFittingContext(
                transcript: self.transcript(lines: 5_000),
                turns: [],
                systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000,
                maxAttempts: 4,
                complete: { _, _ in
                    attempts += 1
                    throw FakeOverflow()
                }
            )
            XCTFail("expected the overflow to surface")
        } catch {
            XCTAssertTrue(MeetingAIClient.isContextOverflow(error))
        }
        XCTAssertEqual(attempts, 4)
    }

    func testCompleteFittingContext_nonOverflowErrorIsNotRetried() async {
        var attempts = 0
        do {
            _ = try await MeetingAIClient.completeFittingContext(
                transcript: "[00:01] Me: hi",
                turns: [],
                systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000,
                maxAttempts: 20,
                complete: { _, _ in
                    attempts += 1
                    throw URLError(.cannotConnectToHost)
                }
            )
            XCTFail("expected the connection error to surface")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }
}

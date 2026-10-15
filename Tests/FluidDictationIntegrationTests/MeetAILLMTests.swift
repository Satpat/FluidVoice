@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAILLMTests: XCTestCase {
    func testIsLocal() {
        let local = ["http://localhost:11434/v1", "http://127.0.0.1:8080", "http://[::1]:1234/v1", "http://10.0.0.5:8000", "http://192.168.1.20:1234/v1", "http://172.16.0.1", "http://172.31.255.255:9000"]
        let remote = ["https://api.openai.com/v1", "https://api.anthropic.com/v1", "http://172.15.0.1", "http://172.32.0.1", "http://11.0.0.1", "not a url", ""]
        for url in local { XCTAssertTrue(EndpointClassifier.isLocal(url), url) }
        for url in remote { XCTAssertFalse(EndpointClassifier.isLocal(url), url) }
    }

    private struct FakeOverflow: LocalizedError {
        var errorDescription: String? { "This model's maximum context length is 4096 tokens" }
    }

    private func transcript(lines: Int) -> String {
        (0..<lines).map { "Speaker 1: line number \($0) of the meeting transcript" }.joined(separator: "\n")
    }

    func testFittingContextConvergesUnderSmallLocalWindow() async throws {
        let window = 4_096
        var attempts = 0
        let reply = try await MeetAILLM.completeFittingContext(
            transcript: self.transcript(lines: 5_000),
            turns: [MeetAILLMTurn(role: "user", content: "Summarise this meeting.")],
            systemPrompt: { "You summarise meetings.\n\($0)" },
            startingBudgetTokens: 1_000_000,
            maxAttempts: 20,
            complete: { prompt, _ in
                attempts += 1
                guard MeetAILLM.approxTokens(prompt) <= window - 1_024 else { throw FakeOverflow() }
                return "ok"
            }
        )
        XCTAssertEqual(reply, "ok")
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThanOrEqual(attempts, 20)
    }

    func testFittingContextRemoteAttemptCap() async {
        var attempts = 0
        do {
            _ = try await MeetAILLM.completeFittingContext(
                transcript: self.transcript(lines: 5_000), turns: [], systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000, maxAttempts: 4,
                complete: { _, _ in attempts += 1; throw FakeOverflow() }
            )
            XCTFail("expected the overflow to surface")
        } catch {
            XCTAssertTrue(MeetAILLM.isContextOverflow(error))
        }
        XCTAssertEqual(attempts, 4)
    }

    func testFittingContextDoesNotRetryOtherErrors() async {
        var attempts = 0
        do {
            _ = try await MeetAILLM.completeFittingContext(
                transcript: "You: hi", turns: [], systemPrompt: { $0 },
                startingBudgetTokens: 1_000_000, maxAttempts: 20,
                complete: { _, _ in attempts += 1; throw URLError(.cannotConnectToHost) }
            )
            XCTFail("expected the connection error to surface")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    func testTrimmedTranscriptKeepsMostRecentLinesWithMarker() {
        let trimmed = MeetAILLM.trimmedTranscript(self.transcript(lines: 100), maxTokens: 50)
        XCTAssertTrue(trimmed.hasPrefix("[Earlier part of the meeting ("))
        XCTAssertTrue(trimmed.hasSuffix("line number 99 of the meeting transcript"))
    }
}

import Foundation

/// The only entry points upstream code calls (H1, H6). Unset handlers are no-ops, so upstream
/// tests and builds without MeetAI wiring behave exactly as before.
@MainActor
enum MeetAIHooks {
    static var sessionDidComplete: (@MainActor (MeetingSession) async -> Void)?
    static var sessionCorrected: (@MainActor (MeetingSession) -> Void)?
    static let completionTimeout: Duration = .seconds(30)

    /// H1: awaited by the coordinator before its audio-retention sweep. Returns when the handler
    /// finishes or `timeout` elapses, whichever is first. Never throws.
    static func runSessionDidComplete(_ session: MeetingSession, timeout: Duration = completionTimeout) async {
        guard let handler = self.sessionDidComplete else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = OnceGate(continuation)
            Task { @MainActor in
                await handler(session)
                gate.fire()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !gate.fired { DebugLogger.shared.warning("MeetAI completion hook timed out", source: "MeetAI") }
                gate.fire()
            }
        }
    }

    /// H6: called after any transcript correction is saved. Must not mutate the session synchronously.
    static func notifySessionCorrected(_ session: MeetingSession) {
        self.sessionCorrected?(session)
    }

    @MainActor
    private final class OnceGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var fired = false

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func fire() {
            guard !self.fired else { return }
            self.fired = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}

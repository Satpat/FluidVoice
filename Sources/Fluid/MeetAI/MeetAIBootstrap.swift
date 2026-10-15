import Foundation

/// H4: launch wiring for the MeetAI layer.
@MainActor
enum MeetAIBootstrap {
    private static var started = false

    /// Tests run hosted in the debug app, which shares Application Support with the real app.
    /// Never touch real meeting data from a test process.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func start() {
        guard !self.started, !self.isTestHost else { return }
        self.started = true
        Task { await self.sweepOrphanedSidecars() }
    }

    static func sweepOrphanedSidecars() async {
        do {
            let ids = Set(try await MeetingSessionStore.shared.loadAll().map(\.id))
            // loadAll skips unreadable sessions, so also consult the directory: never delete on doubt.
            let removed = try await MeetAISidecarStore.shared.sweepOrphans { id in
                if ids.contains(id) { return true }
                do {
                    return try await MeetingSessionStore.shared.existingSessionDirectory(for: id) != nil
                } catch {
                    return true
                }
            }
            if !removed.isEmpty {
                DebugLogger.shared.info("Removed \(removed.count) orphaned MeetAI sidecars", source: "MeetAI")
            }
        } catch {
            DebugLogger.shared.warning("MeetAI sidecar sweep failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
}

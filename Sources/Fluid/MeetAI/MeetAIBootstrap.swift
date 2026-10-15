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
        let paths = MeetAIPaths.standard()
        _ = MeetAISpeakerProfileStore.shared.copyLegacyProfilesIfNeeded(from: paths.legacyProfilesFile)
        MeetAIHooks.sessionDidComplete = { session in await MeetAISessionProcessor.shared.sessionDidComplete(session) }
        MeetAIHooks.sessionCorrected = { session in MeetAISessionProcessor.shared.sessionCorrected(session) }
        Task { await self.sweepOrphanedSidecars() }
    }

    /// Data-loss guard: a session is live if it loaded, or its folder exists, or the lookup failed.
    static func isSessionLive(
        _ id: MeetingSessionID,
        loadedIDs: Set<MeetingSessionID>,
        directory: (MeetingSessionID) async throws -> URL?
    ) async -> Bool {
        if loadedIDs.contains(id) { return true }
        do {
            return try await directory(id) != nil
        } catch {
            return true
        }
    }

    static func sweepOrphanedSidecars() async {
        do {
            let ids = Set(try await MeetingSessionStore.shared.loadAll().map(\.id))
            // loadAll skips unreadable sessions, so also consult the directory: never delete on doubt.
            let removed = try await MeetAISidecarStore.shared.sweepOrphans { id in
                await self.isSessionLive(id, loadedIDs: ids) { try await MeetingSessionStore.shared.existingSessionDirectory(for: $0) }
            }
            if !removed.isEmpty {
                DebugLogger.shared.info("Removed \(removed.count) orphaned MeetAI sidecars", source: "MeetAI")
            }
        } catch {
            DebugLogger.shared.warning("MeetAI sidecar sweep failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }
}

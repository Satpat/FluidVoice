import Foundation

nonisolated struct MeetAIPaths: Equatable, Sendable {
    /// `~/Library/Application Support/FluidVoice` (shared with upstream and the fork's legacy data).
    let supportRoot: URL

    static func standard(fileManager: FileManager = .default) -> MeetAIPaths {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return MeetAIPaths(supportRoot: applicationSupport.appendingPathComponent("FluidVoice", isDirectory: true))
    }

    var root: URL { self.supportRoot.appendingPathComponent("MeetAI", isDirectory: true) }
    var profilesFile: URL { self.root.appendingPathComponent("SpeakerProfiles/profiles.json") }
    var sessionsDirectory: URL { self.root.appendingPathComponent("Sessions", isDirectory: true) }
    var migrationFile: URL { self.root.appendingPathComponent("migration.json") }
    var legacyMeetingsDirectory: URL { self.supportRoot.appendingPathComponent("MeetingRecordings", isDirectory: true) }
    var legacyProfilesFile: URL { self.supportRoot.appendingPathComponent("SpeakerProfiles/profiles.json") }

    func sessionDirectory(for id: MeetingSessionID) -> URL {
        self.sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

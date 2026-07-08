// Re-run the full meeting pipeline (transcription + diarization + summary)
// on an already-recorded session folder. Used by the "Re-transcribe" action
// in the meetings history and by a one-shot launch trigger.

import Foundation

@MainActor
enum MeetingReprocessor {
    /// UserDefaults flag: when true, reprocess the most recent recording once
    /// on launch, then clear. Lets an updated pipeline be applied to the last
    /// meeting without manual steps.
    static let reprocessLatestOnLaunchKey = "MeetAIReprocessLatestOnLaunch"

    /// Reconstruct artifacts from a session folder. Prefers session.json;
    /// falls back to the conventional file names when it is absent.
    static func artifacts(inFolder folder: URL) -> MeetingRecordingArtifacts? {
        let manifestURL = folder.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: manifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let artifacts = try? decoder.decode(MeetingRecordingArtifacts.self, from: data) {
                return artifacts
            }
        }

        let systemURL = folder.appendingPathComponent("system.wav")
        let micURL = folder.appendingPathComponent("mic.wav")
        guard FileManager.default.fileExists(atPath: systemURL.path),
              FileManager.default.fileExists(atPath: micURL.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: systemURL.path)
        let created = (attrs?[.creationDate] as? Date) ?? Date()
        return MeetingRecordingArtifacts(
            folder: folder,
            systemAudio: systemURL,
            microphone: micURL,
            startedAt: created,
            endedAt: created
        )
    }

    /// Most recent recording folder under the sessions directory.
    static func latestRecordingFolder() -> URL? {
        let base = MeetingRecordingSession.defaultBaseDirectory()
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            .first
    }

    /// If the launch flag is set, reprocess the latest recording once.
    static func runLaunchReprocessIfRequested(asrService: ASRService) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: reprocessLatestOnLaunchKey) else { return }
        defaults.set(false, forKey: reprocessLatestOnLaunchKey)

        guard let folder = latestRecordingFolder(),
              let artifacts = artifacts(inFolder: folder) else {
            DebugLogger.shared.warning("Launch reprocess requested but no recording found", source: "MeetingReprocessor")
            return
        }

        DebugLogger.shared.info("Launch reprocess: \(folder.lastPathComponent)", source: "MeetingReprocessor")
        let pipeline = MeetingTranscriptPipeline(asrService: asrService)
        Task {
            do {
                _ = try await pipeline.process(artifacts)
                DebugLogger.shared.info("Launch reprocess complete", source: "MeetingReprocessor")
            } catch {
                DebugLogger.shared.error("Launch reprocess failed: \(error.localizedDescription)", source: "MeetingReprocessor")
            }
        }
    }
}

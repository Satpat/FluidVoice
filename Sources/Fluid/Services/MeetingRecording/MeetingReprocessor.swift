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

    /// UserDefaults flag: when true, sweep every recording folder once on
    /// launch — full pipeline for folders without the new diarization output,
    /// title backfill only for those that already have it.
    static let reprocessAllOnLaunchKey = "MeetAIReprocessAllOnLaunch"

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

    /// Most recent recording folder by recording time. Folder names are ISO
    /// timestamps (see ISO8601DateFormatter.meetingFileSafe), so a descending
    /// lexical sort is chronological — unlike file modification time, which
    /// reprocessing rewrites.
    static func latestRecordingFolder() -> URL? {
        let base = MeetingRecordingSession.defaultBaseDirectory()
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    /// If a launch flag is set, run the corresponding one-shot reprocess.
    static func runLaunchReprocessIfRequested(asrService: ASRService) {
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: reprocessAllOnLaunchKey) {
            defaults.set(false, forKey: reprocessAllOnLaunchKey)
            Task { await reprocessAll(asrService: asrService) }
            return
        }

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

    /// A folder has the new diarization output when both the speaker
    /// embeddings and a transcript exist.
    static func hasDiarizationOutput(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("speakers.json").path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path)
    }

    static func allRecordingFolders() -> [URL] {
        let base = MeetingRecordingSession.defaultBaseDirectory()
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Sweep every recording, newest first, sequentially: full pipeline for
    /// folders without the new diarization output; folders that already have
    /// it only get the friendly title backfilled when missing.
    static func reprocessAll(asrService: ASRService) async {
        let folders = allRecordingFolders()
        DebugLogger.shared.info("Reprocess-all: \(folders.count) recording folder(s)", source: "MeetingReprocessor")

        for folder in folders {
            guard let artifacts = artifacts(inFolder: folder) else {
                DebugLogger.shared.warning("Reprocess-all: skipping \(folder.lastPathComponent) (no audio)", source: "MeetingReprocessor")
                continue
            }

            if hasDiarizationOutput(folder) {
                if MeetingFiles.title(inFolder: folder) == nil {
                    let transcript = (try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
                    let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
                    let startedAt = ISO8601DateFormatter.meetingFileSafe.date(from: folder.lastPathComponent) ?? artifacts.startedAt
                    let title = await MeetingTranscriptPipeline.generateTitleLine(
                        context: summary ?? transcript,
                        startedAt: startedAt
                    )
                    MeetingTranscriptPipeline.writeTitle(title, folder: folder)
                    DebugLogger.shared.info("Reprocess-all: titled \(folder.lastPathComponent): \(title)", source: "MeetingReprocessor")
                } else {
                    DebugLogger.shared.info("Reprocess-all: \(folder.lastPathComponent) already complete", source: "MeetingReprocessor")
                }
                continue
            }

            DebugLogger.shared.info("Reprocess-all: full pipeline for \(folder.lastPathComponent)", source: "MeetingReprocessor")
            let pipeline = MeetingTranscriptPipeline(asrService: asrService)
            do {
                _ = try await pipeline.process(artifacts)
            } catch {
                DebugLogger.shared.error(
                    "Reprocess-all failed for \(folder.lastPathComponent): \(error.localizedDescription)",
                    source: "MeetingReprocessor"
                )
            }
        }
        DebugLogger.shared.info("Reprocess-all complete", source: "MeetingReprocessor")
    }
}

// Imports a user-picked audio/video file into a meeting-recording session
// folder so uploaded files can run through the exact same
// MeetingTranscriptPipeline as a live recording (diarization, speaker
// naming, summary, title) instead of a separate simplified path.

import AVFoundation
import Foundation

enum MeetingUploadImporter {
    /// Placeholder length for the "Me" track. Uploaded files are a single
    /// mixed-down recording with no isolated mic feed, so there is nothing
    /// to put on that track — a short silence keeps `MeetingRecordingArtifacts`
    /// (and every pipeline stage that reads `.microphone`) unchanged.
    private static let micPlaceholderSamples = [Float](repeating: 0, count: 1_600) // 0.1s @ 16kHz

    /// Convert `sourceURL`'s audio into a new session folder laid out exactly
    /// like a recorded meeting (system.wav + mic.wav + session.json), so the
    /// rest of the app (MeetingTranscriptPipeline, MeetingReprocessor,
    /// MeetingsView) can't tell the difference from a live recording.
    nonisolated static func importArtifacts(
        from sourceURL: URL,
        importedAt: Date = Date()
    ) throws -> MeetingRecordingArtifacts {
        let samples = try MeetingTranscriptPipeline.loadSamples16kMono(url: sourceURL)
        guard !samples.isEmpty else {
            throw MeetingRecordingError("No audio detected in \(sourceURL.lastPathComponent).")
        }

        let baseDirectory = MeetingRecordingSession.defaultBaseDirectory()
        let folderName = ISO8601DateFormatter.meetingFileSafe.string(from: importedAt)
        let folder = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let systemURL = folder.appendingPathComponent("system.wav")
            let micURL = folder.appendingPathComponent("mic.wav")
            try Self.writeWav(samples: samples, to: systemURL)
            try Self.writeWav(samples: Self.micPlaceholderSamples, to: micURL)

            let duration = Double(samples.count) / 16_000
            let artifacts = MeetingRecordingArtifacts(
                folder: folder,
                systemAudio: systemURL,
                microphone: micURL,
                startedAt: importedAt,
                endedAt: importedAt.addingTimeInterval(duration)
            )
            Self.writeManifest(artifacts)
            return artifacts
        } catch {
            // Don't leave a half-written session folder (partial audio, no
            // manifest) behind for a failed import.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Mirrors MeetingRecordingSession's manifest write so re-transcribe and
    /// reprocess-all find imported meetings the same way as recorded ones.
    private static func writeManifest(_ artifacts: MeetingRecordingArtifacts) {
        let manifestURL = artifacts.folder.appendingPathComponent("session.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(artifacts)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            DebugLogger.shared.warning(
                "MeetingUploadImporter: manifest write failed: \(error.localizedDescription)",
                source: "MeetingUploadImporter"
            )
        }
    }

    /// Write 16kHz mono Float32 samples out as 16-bit PCM WAV, matching the
    /// format MeetingMicRecorder/ProcessTapRecorder use for live recordings.
    private static func writeWav(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw MeetingRecordingError("Failed to build 16k mono format.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )

        let chunkSize = 16_000 * 60 // 1 minute per write, matching loadSamples16kMono's read chunking
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let frameCount = AVAudioFrameCount(end - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw MeetingRecordingError("Failed to allocate WAV write buffer.")
            }
            buffer.frameLength = frameCount
            if let channel = buffer.floatChannelData {
                for i in 0..<Int(frameCount) {
                    channel[0][i] = samples[offset + i]
                }
            }
            try file.write(from: buffer)
            offset = end
        }
    }
}

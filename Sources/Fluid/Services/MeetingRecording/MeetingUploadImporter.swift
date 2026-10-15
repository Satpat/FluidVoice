// Imports a user-picked audio/video file into a meeting-recording session
// folder so uploaded files can run through the exact same
// MeetingTranscriptPipeline as a live recording (diarization, speaker
// naming, summary, title) instead of a separate simplified path.

import AVFoundation
import Foundation

nonisolated enum MeetingUploadImporter {
    /// Placeholder length for the "Me" track. Uploaded files are a single
    /// mixed-down recording with no isolated mic feed, so there is nothing
    /// to put on that track — a short silence keeps `MeetingRecordingArtifacts`
    /// (and every pipeline stage that reads `.microphone`) unchanged.
    private static let micPlaceholderSamples = [Float](repeating: 0, count: 1_600) // 0.1s @ 16kHz

    /// Convert `sourceURL`'s audio into a new session folder laid out exactly
    /// like a recorded meeting (system.wav + mic.wav + session.json), so the
    /// rest of the app (MeetingTranscriptPipeline, MeetingReprocessor,
    /// MeetingsView) can't tell the difference from a live recording.
    ///
    /// Runs off the main actor and streams the conversion one chunk at a
    /// time, so a multi-hour upload never sits in memory as a whole.
    @concurrent
    static func importArtifacts(
        from sourceURL: URL,
        baseDirectory: URL,
        importedAt: Date = Date()
    ) async throws -> MeetingRecordingArtifacts {
        let folderName = ISO8601DateFormatter.meetingFileSafe.string(from: importedAt)
        let folder = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw MeetingRecordingError("A meeting folder named \(folderName) already exists; try again in a moment.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let systemURL = folder.appendingPathComponent("system.wav")
            let micURL = folder.appendingPathComponent("mic.wav")

            let systemWriter = try Self.makeWavWriter(url: systemURL)
            var sampleCount = 0
            try MeetingProcessingEngine.forEach16kMonoChunk(url: sourceURL) { chunk in
                try Self.write(chunk, to: systemWriter)
                sampleCount += chunk.count
            }
            guard sampleCount > 0 else {
                throw MeetingRecordingError("No audio detected in \(sourceURL.lastPathComponent).")
            }
            try Self.write(Self.micPlaceholderSamples, to: Self.makeWavWriter(url: micURL))

            let duration = Double(sampleCount) / Double(MeetingProcessingEngine.sampleRate)
            let artifacts = MeetingRecordingArtifacts(
                folder: folder,
                systemAudio: systemURL,
                microphone: micURL,
                startedAt: importedAt,
                endedAt: importedAt.addingTimeInterval(duration),
                sourceFileName: sourceURL.lastPathComponent
            )
            try Self.writeManifest(artifacts)
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
    private static func writeManifest(_ artifacts: MeetingRecordingArtifacts) throws {
        let manifestURL = artifacts.folder.appendingPathComponent("session.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifacts).write(to: manifestURL, options: .atomic)
    }

    /// 16 kHz mono 16-bit PCM WAV, matching the format
    /// MeetingMicRecorder/ProcessTapRecorder use for live recordings.
    private static func makeWavWriter(url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MeetingProcessingEngine.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw MeetingRecordingError("Failed to allocate WAV write buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { source in
                channel[0].update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}

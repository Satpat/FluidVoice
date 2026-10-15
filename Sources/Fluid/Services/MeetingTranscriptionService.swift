import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Result of a transcription operation
struct TranscriptionResult: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        duration: TimeInterval,
        processingTime: TimeInterval,
        fileName: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
        self.fileName = fileName
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encode(self.timestamp, forKey: .timestamp)
    }
}

/// Service for transcribing complete audio/video files with optional speaker diarization
/// NOTE: This service shares the ASR models with ASRService to avoid duplicate memory usage
@MainActor
final class MeetingTranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var error: String?
    @Published var result: TranscriptionResult?

    // MARK: - Supported Formats

    /// File extensions the OS can actually decode, queried dynamically from AVFoundation.
    /// Filtered to audio/video types only — excludes subtitles, playlists, etc.
    static let supportedFileExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension
        }
        return Set(extensions)
    }()

    /// Content types accepted by the file picker — broad categories so the OS filters naturally.
    static let allowedContentTypes: [UTType] = [.audio, .movie]

    /// User-facing description of supported formats (curated for readability).
    static let supportedFormatsDescription = "Supported: WAV, MP3, M4A, OGG, MP4, MOV, and more"

    /// Error copy shown when a dropped file is not accepted.
    static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, OGG, MP4, MOV, and more."

    /// Share the ASR service instance to avoid loading models twice
    private let asrService: ASRService

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    enum TranscriptionError: LocalizedError {
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case fileNotSupported(String)

        var errorDescription: String? {
            switch self {
            case let .audioConversionFailed(msg):
                return "Failed to convert audio: \(msg)"
            case let .transcriptionFailed(msg):
                return "Transcription failed: \(msg)"
            case let .fileNotSupported(msg):
                return "File format not supported: \(msg)"
            }
        }
    }

    private func errorCategory(for error: Error) -> String {
        guard let transcriptionError = error as? TranscriptionError else {
            return "unknownError"
        }
        return self.errorCategory(for: transcriptionError)
    }

    private func errorCategory(for error: TranscriptionError) -> String {
        switch error {
        case .audioConversionFailed:
            return "audioConversionFailed"
        case .transcriptionFailed:
            return "transcriptionFailed"
        case .fileNotSupported:
            return "fileNotSupported"
        }
    }

    /// Transcribe an audio or video file by importing it into a meeting
    /// session folder and running it through MeetingTranscriptPipeline —
    /// the same diarization + speaker naming + summary + title pipeline a
    /// live-recorded meeting gets. The result also lands in the Meetings
    /// history (as "Meeting <folder>"), not just here.
    /// - Parameters:
    ///   - fileURL: URL to the audio/video file
    func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        self.isTranscribing = true
        error = nil
        self.progress = 0.0
        self.currentStatus = "Preparing..."
        let startTime = Date()

        let pipeline = MeetingTranscriptPipeline(asrService: self.asrService)
        var cancellables = Set<AnyCancellable>()
        pipeline.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &cancellables)
        pipeline.$currentStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.currentStatus = value }
            .store(in: &cancellables)

        defer {
            isTranscribing = false
            cancellables.removeAll()
        }

        do {
            // Check file extension
            let fileExtension = fileURL.pathExtension.lowercased()
            guard Self.supportedFileExtensions.contains(fileExtension) else {
                throw TranscriptionError
                    .fileNotSupported("Format .\(fileExtension) not supported. \(Self.supportedFormatsDescription)")
            }

            self.currentStatus = "Importing file..."
            let artifacts: MeetingRecordingArtifacts
            do {
                // importArtifacts does blocking file I/O (full-file resample +
                // two WAV writes); hop off the main actor so a large/long
                // upload doesn't freeze the UI for the whole import.
                artifacts = try await Task.detached(priority: .userInitiated) {
                    try MeetingUploadImporter.importArtifacts(from: fileURL)
                }.value
            } catch {
                throw TranscriptionError.audioConversionFailed(error.localizedDescription)
            }

            _ = try await pipeline.process(artifacts)

            let processingTime = Date().timeIntervalSince(startTime)
            let expectedFileName = "Meeting \(artifacts.displayName)"
            guard let historyEntry = FileTranscriptionHistoryStore.shared.entries
                .first(where: { $0.fileName == expectedFileName })
            else {
                throw TranscriptionError.transcriptionFailed("Transcription completed but produced no text.")
            }
            let result = historyEntry.toTranscriptionResult()

            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": true,
                    "file_type": fileExtension,
                    "audio_duration_bucket": AnalyticsBuckets.bucketSeconds(artifacts.duration),
                    "processing_time_bucket": AnalyticsBuckets.bucketSeconds(processingTime),
                ]
            )

            self.result = result
            return result

        } catch let error as TranscriptionError {
            self.error = error.localizedDescription
            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": false,
                    "file_type": fileURL.pathExtension.lowercased(),
                    "category": errorCategory(for: error),
                ]
            )
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            self.error = wrappedError.localizedDescription
            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": false,
                    "file_type": fileURL.pathExtension.lowercased(),
                    "category": self.errorCategory(for: wrappedError),
                ]
            )
            throw wrappedError
        }
    }

    /// Export transcription result to text file
    nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let content = """
        Transcription: \(result.fileName)
        Date: \(result.timestamp.formatted())
        Duration: \(String(format: "%.1f", result.duration))s
        Processing Time: \(String(format: "%.1f", result.processingTime))s
        Confidence: \(String(format: "%.1f%%", result.confidence * 100))

        ---

        \(result.text)
        """

        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    /// Export transcription result to JSON
    nonisolated func exportToJSON(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(result)
        try jsonData.write(to: destinationURL)
    }

    /// Reset the service state
    func reset() {
        self.result = nil
        self.error = nil
        self.currentStatus = ""
        self.progress = 0.0
    }
}

//
//  FileTranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence for file (meeting) transcription history so results survive navigation.
//

import Combine
import Foundation

// MARK: - File Transcription Entry Model

struct FileTranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let duration: TimeInterval
    let processingTime: TimeInterval
    let confidence: Float
    let text: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        confidence: Float,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.duration = duration
        self.processingTime = processingTime
        self.confidence = confidence
        self.text = text
    }

    init(from result: TranscriptionResult) {
        self.id = result.id
        self.timestamp = result.timestamp
        self.fileName = result.fileName
        self.duration = result.duration
        self.processingTime = result.processingTime
        self.confidence = result.confidence
        self.text = result.text
    }

    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let trimmed = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 {
            return String(trimmed.prefix(77)) + "..."
        }
        return trimmed
    }

    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.timestamp, relativeTo: Date())
    }

    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.timestamp)
    }

    /// Convert to TranscriptionResult for reuse of export/copy UI
    func toTranscriptionResult() -> TranscriptionResult {
        TranscriptionResult(
            id: self.id,
            text: self.text,
            confidence: self.confidence,
            duration: self.duration,
            processingTime: self.processingTime,
            fileName: self.fileName,
            timestamp: self.timestamp
        )
    }
}

// MARK: - File Transcription History Store

@MainActor
final class FileTranscriptionHistoryStore: ObservableObject {
    static let shared = FileTranscriptionHistoryStore()

    private let defaults = UserDefaults.standard
    private let maxEntries = 50

    /// History entries written by MeetingTranscriptPipeline are named
    /// "Meeting <session folder>".
    static let meetingEntryPrefix = "Meeting "

    private enum Keys {
        static let fileTranscriptionHistory = "FileTranscriptionHistoryEntries"
    }

    @Published private(set) var entries: [FileTranscriptionEntry] = []
    @Published var selectedEntryID: UUID?

    private init() {
        self.loadEntries()
    }

    // MARK: - Public Methods

    var selectedEntry: FileTranscriptionEntry? {
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    /// Add a completed file transcription to history (call after successful
    /// transcribeFile). Returns the new entry's id, or nil when the result
    /// has no text (empty transcripts aren't stored).
    @discardableResult
    func addEntry(_ result: TranscriptionResult) -> UUID? {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let entry = FileTranscriptionEntry(from: result)
        self.entries.insert(entry, at: 0)

        // Cap plain file transcriptions only. Meeting entries are the
        // Meetings tab's index of recorded meetings; evicting them would hide
        // meetings whose folders (audio, transcript, summary) still exist.
        if self.entries.count > self.maxEntries,
           let oldestFileIndex = self.entries.lastIndex(where: { !$0.fileName.hasPrefix(Self.meetingEntryPrefix) }) {
            self.entries.remove(at: oldestFileIndex)
        }

        self.selectedEntryID = entry.id
        self.saveEntries()

        DebugLogger.shared.debug(
            "Added file transcription to history (total: \(self.entries.count))",
            source: "FileTranscriptionHistoryStore"
        )
        return entry.id
    }

    /// Replace an entry's transcript text in place (e.g. after relabelling
    /// speakers), preserving its identity and position.
    func updateEntryText(id: UUID, newText: String) {
        guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
        let old = self.entries[index]
        self.entries[index] = FileTranscriptionEntry(
            id: old.id,
            timestamp: old.timestamp,
            fileName: old.fileName,
            duration: old.duration,
            processingTime: old.processingTime,
            confidence: old.confidence,
            text: newText
        )
        self.saveEntries()
    }

    func deleteEntry(id: UUID) {
        self.entries.removeAll { $0.id == id }
        if self.selectedEntryID == id {
            self.selectedEntryID = self.entries.first?.id
        }
        self.saveEntries()
    }

    func clearAll() {
        self.entries.removeAll()
        self.selectedEntryID = nil
        self.saveEntries()
        DebugLogger.shared.info("Cleared all file transcription history", source: "FileTranscriptionHistoryStore")
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard let data = self.defaults.data(forKey: Keys.fileTranscriptionHistory),
              let decoded = try? JSONDecoder().decode([FileTranscriptionEntry].self, from: data)
        else {
            self.entries = []
            return
        }
        self.entries = decoded
    }

    private func saveEntries() {
        if let encoded = try? JSONEncoder().encode(self.entries) {
            self.defaults.set(encoded, forKey: Keys.fileTranscriptionHistory)
        }
        self.objectWillChange.send()
    }
}

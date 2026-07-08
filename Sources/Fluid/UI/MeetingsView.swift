import AppKit
import SwiftUI

/// Dedicated tab for meeting recording and transcription (MeetAI v2):
/// live two-track capture with the recorder card, plus a history of
/// transcribed meetings. File-based transcription stays in its own tab.
struct MeetingsView: View {
    let asrService: ASRService
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @State private var expandedEntryID: FileTranscriptionEntry.ID?
    @StateObject private var reprocessPipeline: MeetingTranscriptPipeline
    @State private var reprocessingFolder: String?
    @Environment(\.theme) private var theme

    init(asrService: ASRService) {
        self.asrService = asrService
        _reprocessPipeline = StateObject(wrappedValue: MeetingTranscriptPipeline(asrService: asrService))
    }

    /// Meeting transcripts are stored in the shared file-transcription
    /// history under this prefix (see MeetingTranscriptPipeline).
    private static let meetingEntryPrefix = "Meeting "

    private var meetingEntries: [FileTranscriptionEntry] {
        self.fileHistoryStore.entries.filter { $0.fileName.hasPrefix(Self.meetingEntryPrefix) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.fluidGreen.gradient)

                Text("Meetings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Record and transcribe meetings — your mic is \"Me\", system audio is \"Them\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            ScrollView {
                VStack(spacing: 24) {
                    MeetingRecorderCard(asrService: self.asrService)

                    MeetingQAPanel()

                    if !self.meetingEntries.isEmpty {
                        self.recentMeetingsSection
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
    }

    // MARK: - Recent meetings

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent meetings")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(self.meetingEntries) { entry in
                    self.meetingRow(entry: entry)
                }
            }
        }
    }

    /// Meeting history entries are named "Meeting <folderName>"; recover the
    /// session folder from that.
    private func folderName(for entry: FileTranscriptionEntry) -> String {
        String(entry.fileName.dropFirst(Self.meetingEntryPrefix.count))
    }

    private func recordingFolder(for entry: FileTranscriptionEntry) -> URL {
        MeetingRecordingSession.defaultBaseDirectory()
            .appendingPathComponent(self.folderName(for: entry), isDirectory: true)
    }

    private func canReprocess(_ entry: FileTranscriptionEntry) -> Bool {
        MeetingReprocessor.artifacts(inFolder: self.recordingFolder(for: entry)) != nil
    }

    private func reprocess(entry: FileTranscriptionEntry) {
        let folder = self.recordingFolder(for: entry)
        guard let artifacts = MeetingReprocessor.artifacts(inFolder: folder) else { return }
        self.reprocessingFolder = self.folderName(for: entry)
        Task {
            defer { self.reprocessingFolder = nil }
            do {
                _ = try await self.reprocessPipeline.process(artifacts)
            } catch {
                DebugLogger.shared.error("Re-transcribe failed: \(error)", source: "MeetingsView")
            }
        }
    }

    private func meetingRow(entry: FileTranscriptionEntry) -> some View {
        let isExpanded = self.expandedEntryID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                self.expandedEntryID = isExpanded ? nil : entry.id
            }) {
                HStack {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.body)
                        .foregroundColor(Color.fluidGreen)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.fileName)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Text("\(entry.relativeTimeString) · \(MeetingTranscriptPipeline.timestamp(entry.duration))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !isExpanded {
                            Text(entry.previewText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    Text(entry.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)

                if self.reprocessingFolder == self.folderName(for: entry), self.reprocessPipeline.isProcessing {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: self.reprocessPipeline.progress)
                            .progressViewStyle(.linear)
                        Text(self.reprocessPipeline.currentStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                }

                HStack {
                    Button(action: { self.reprocess(entry: entry) }) {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }
                    .disabled(self.reprocessPipeline.isProcessing || !self.canReprocess(entry))
                    .help(self.canReprocess(entry)
                        ? "Re-run transcription, speaker labels, and summary with the current pipeline"
                        : "Original audio for this meeting was not found")
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive, action: {
                        self.fileHistoryStore.deleteEntry(id: entry.id)
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isExpanded ? Color.fluidGreen.opacity(0.5) : self.theme.palette.cardBorder.opacity(0.3),
                            lineWidth: isExpanded ? 2 : 1
                        )
                )
        )
    }
}

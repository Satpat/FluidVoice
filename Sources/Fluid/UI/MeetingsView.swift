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
    @ObservedObject private var speakerStore = SpeakerProfileStore.shared
    @State private var reprocessingFolder: String?
    @State private var speakerNameInputs: [String: String] = [:]
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

                    KnownSpeakersPanel()

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

    /// Friendly generated title when the pipeline has written one; the raw
    /// "Meeting <timestamp>" name otherwise.
    private func displayTitle(for entry: FileTranscriptionEntry) -> String {
        MeetingFiles.title(inFolder: self.recordingFolder(for: entry)) ?? entry.fileName
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

    /// Distinct speaker labels parsed from the meeting's transcript lines
    /// ("[MM:SS] Label: ..."), excluding "Me". Parsing the transcript (rather
    /// than speakers.json) means every speaker is offered — including ones
    /// the automatic namer got wrong, so they can be corrected here.
    private func speakerLabels(for entry: FileTranscriptionEntry) -> [String] {
        var labels: [String] = []
        for line in entry.text.components(separatedBy: "\n") {
            guard line.hasPrefix("["),
                  let bracketEnd = line.range(of: "] "),
                  let colon = line.range(of: ":", range: bracketEnd.upperBound..<line.endIndex)
            else { continue }
            let label = String(line[bracketEnd.upperBound..<colon.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty,
                  label != MeetingTranscriptPipeline.micSpeakerLabel,
                  !labels.contains(label)
            else { continue }
            labels.append(label)
        }
        return labels
    }

    @ViewBuilder
    private func nameSpeakersSection(entry: FileTranscriptionEntry) -> some View {
        let labels = self.speakerLabels(for: entry)
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speakers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Rename a speaker to correct or assign their identity. The voice is saved, so that person is recognised automatically in future meetings.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.callout)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        TextField("Real name", text: self.nameBinding(entry: entry, label: label))
                            .textFieldStyle(.roundedBorder)
                        Button("Save & apply") { self.nameSpeaker(entry: entry, label: label) }
                            .disabled(
                                self.reprocessPipeline.isProcessing
                                    || (self.speakerNameInputs[self.nameKey(entry, label)] ?? "")
                                    .trimmingCharacters(in: .whitespaces).isEmpty
                            )
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func nameKey(_ entry: FileTranscriptionEntry, _ label: String) -> String {
        "\(self.folderName(for: entry))|\(label)"
    }

    private func nameBinding(entry: FileTranscriptionEntry, label: String) -> Binding<String> {
        let key = self.nameKey(entry, label)
        return Binding(
            get: { self.speakerNameInputs[key] ?? "" },
            set: { self.speakerNameInputs[key] = $0 }
        )
    }

    /// Save the chosen name for this speaker's voice (so future meetings
    /// recognise them), then relabel this meeting in place — no re-transcribe.
    /// Handles corrections: renaming a mislabelled speaker moves their voice
    /// samples to the new name, merging with an existing profile if one exists.
    private func nameSpeaker(entry: FileTranscriptionEntry, label: String) {
        let key = self.nameKey(entry, label)
        let name = (self.speakerNameInputs[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != label else { return }
        let folder = self.recordingFolder(for: entry)
        let embeddings = MeetingFiles.speakerEmbeddings(inFolder: folder)

        if let wrongProfile = self.speakerStore.profiles.first(where: { $0.name.lowercased() == label.lowercased() }) {
            // The label was a (mis)assigned name with an enrolled voice: move
            // its embedding to the corrected name (enroll merges centroids)
            // and drop the wrong profile.
            self.speakerStore.enroll(name: name, embedding: wrongProfile.embedding)
            self.speakerStore.delete(id: wrongProfile.id)
        } else if let embedding = embeddings[label]
            ?? (embeddings.count == 1 ? embeddings.values.first : nil) {
            // Provisional label ("Them"/"Them N"): enrol its voice centroid.
            // Fall back to the sole embedding when the label was renamed after
            // speakers.json was written.
            self.speakerStore.enroll(name: name, embedding: embedding)
        }

        self.speakerNameInputs[key] = nil
        self.reprocessingFolder = self.folderName(for: entry)
        Task {
            defer { self.reprocessingFolder = nil }
            await MeetingRelabeler.relabel(folder: folder, historyEntryID: entry.id, map: [label: name])
        }
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
                        Text(self.displayTitle(for: entry))
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

                self.nameSpeakersSection(entry: entry)

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
                    if let transcriptURL = MeetingFiles.transcriptURL(inFolder: self.recordingFolder(for: entry)) {
                        Button(action: { NSWorkspace.shared.open(transcriptURL) }) {
                            Label("Transcript", systemImage: "doc.text")
                        }
                        .help("Open transcript.md")
                    }
                    if let summaryURL = MeetingFiles.summaryURL(inFolder: self.recordingFolder(for: entry)) {
                        Button(action: { NSWorkspace.shared.open(summaryURL) }) {
                            Label("Summary", systemImage: "doc.plaintext")
                        }
                        .help("Open summary.md")
                    }
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

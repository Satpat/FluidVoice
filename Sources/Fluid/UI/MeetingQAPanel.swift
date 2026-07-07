import SwiftUI

/// Chat panel for asking the configured AI provider questions about the
/// meeting-so-far. Reads the live transcript; falls back to the most recent
/// transcribed meeting when nothing is live.
struct MeetingQAPanel: View {
    @ObservedObject private var qaService = MeetingQAService.shared
    @ObservedObject private var liveTranscriber = MeetingLiveTranscriber.shared
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @State private var question: String = ""
    @Environment(\.theme) private var theme

    private var transcript: String {
        let live = self.liveTranscriber.transcriptText
        if !live.isEmpty { return live }
        return self.fileHistoryStore.entries
            .first { $0.fileName.hasPrefix("Meeting ") }?.text ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundColor(Color.fluidGreen)
                Text("Ask about this meeting")
                    .font(.headline)
                Spacer()
                if !self.qaService.messages.isEmpty {
                    Button("Clear") { self.qaService.reset() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            if self.qaService.messages.isEmpty {
                Text(self.transcript.isEmpty
                    ? "Start recording and the transcript becomes queryable here."
                    : "Uses the transcript so far — e.g. \"What did they say about deadlines?\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(self.qaService.messages) { message in
                                self.messageRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(self.theme.palette.contentBackground)
                    )
                    .onChange(of: self.qaService.messages.count) {
                        if let last = self.qaService.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            if let error = self.qaService.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("Ask a question about the meeting...", text: self.$question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.send() }
                    .disabled(self.qaService.isThinking)

                Button(action: { self.send() }) {
                    if self.qaService.isThinking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    self.qaService.isThinking
                        || self.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || self.transcript.isEmpty
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func messageRow(_ message: MeetingQAService.Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(message.role == .user ? Color.fluidGreen : .secondary)
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        let text = self.question
        let transcript = self.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !transcript.isEmpty else { return }
        self.question = ""
        Task { await self.qaService.ask(text, transcript: transcript) }
    }
}

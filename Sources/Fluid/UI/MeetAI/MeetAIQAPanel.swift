import SwiftUI

struct MeetAIQAPanel: View {
    let session: MeetingSession

    @StateObject private var service: MeetAIQAService
    @State private var question = ""
    @Environment(\.theme) private var theme

    init(session: MeetingSession) {
        self.session = session
        self._service = StateObject(wrappedValue: MeetAIQAService(sessionID: session.id))
    }

    private var isAvailable: Bool { self.session.state == .completed }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            if !self.isAvailable {
                Text("Ask is available once this meeting has finished processing.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.service.records) { record in
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text(record.question)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    MarkdownText(markdown: record.answer)
                        .textSelection(.enabled)
                }
            }
            if self.service.isThinking {
                ProgressView("Thinking…").controlSize(.small)
            }
            if let error = self.service.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
            HStack(spacing: self.theme.metrics.spacing.sm) {
                TextField("Ask about this meeting", text: self.$question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.send() }
                Button("Ask") { self.send() }
                    .disabled(!self.isAvailable || self.service.isThinking || self.question.trimmingCharacters(in: .whitespaces).isEmpty)
                if !self.service.records.isEmpty {
                    Button("Clear") { Task { await self.service.clear() } }
                }
            }
            .disabled(!self.isAvailable)
        }
        .task { await self.service.load() }
    }

    private func send() {
        // onSubmit bypasses the Ask button's disabled state: keep the typed text while an answer is pending.
        guard !self.service.isThinking else { return }
        let text = self.question
        self.question = ""
        Task { await self.service.ask(text, session: self.session) }
    }
}

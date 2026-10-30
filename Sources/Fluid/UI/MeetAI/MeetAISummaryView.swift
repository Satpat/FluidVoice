import SwiftUI

/// MeetAI additions under upstream's summary: voice confirmations for AI-named speakers and,
/// collapsed, the summary MeetAI wrote before upstream 1.6.12 took over summaries.
struct MeetAISummaryView: View {
    let session: MeetingSession

    @ObservedObject private var processor = MeetAISessionProcessor.shared
    @Environment(\.theme) private var theme
    @State private var record: MeetAISummaryRecord?
    @State private var confirmable: [MeetAISessionProcessor.ConfirmableSpeaker] = []

    private var isBusy: Bool { self.processor.busySessions.contains(self.session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            if self.isBusy {
                ProgressView("MeetAI is working on this meeting…").controlSize(.small)
            }

            ForEach(self.confirmable, id: \.speakerID) { speaker in
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label("AI named a speaker \(speaker.name).", systemImage: "person.wave.2")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button("Save this voice as \(speaker.name)") {
                        Task {
                            _ = await self.processor.confirmSpeakerName(sessionID: self.session.id, speakerID: speaker.speakerID)
                            await self.reload()
                        }
                    }
                    .disabled(self.isBusy)
                }
            }

            if let record {
                DisclosureGroup("Earlier MeetAI summary") {
                    MarkdownText(markdown: record.markdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(self.theme.typography.body)
            }
        }
        .task(id: self.session.updatedAt) { await self.reload() }
        .onChange(of: self.processor.busySessions) { _, _ in Task { await self.reload() } }
    }

    private func reload() async {
        self.record = try? await MeetAISidecarStore.shared.summary(for: self.session.id)
        self.confirmable = await self.processor.confirmableSpeakers(sessionID: self.session.id)
    }
}

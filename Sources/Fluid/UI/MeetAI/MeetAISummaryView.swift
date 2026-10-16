import AppKit
import SwiftUI

struct MeetAISummaryView: View {
    let session: MeetingSession

    @ObservedObject private var processor = MeetAISessionProcessor.shared
    @Environment(\.theme) private var theme
    @State private var record: MeetAISummaryRecord?
    @State private var style: MeetAISummaryStyle = MeetAISettings.shared.summaryStyle

    private var isBusy: Bool { self.processor.busySessions.contains(self.session.id) }
    private var isStale: Bool { self.record.map { $0.transcriptHash != MeetAITranscript.hash(for: self.session) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Picker("Style", selection: self.$style) {
                    ForEach(MeetAISummaryStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 320)
                Button(self.record == nil ? "Generate" : "Regenerate") { self.regenerate() }
                    .disabled(self.isBusy)
                if let record {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.markdown, forType: .string)
                    }
                }
                Spacer(minLength: 0)
            }

            if self.isBusy {
                ProgressView("Working on this meeting…").controlSize(.small)
            }

            if let error = self.processor.summaryErrors[self.session.id] {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                    Button("Retry") { self.regenerate() }.disabled(self.isBusy)
                }
            }

            if self.isStale {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Label("The transcript changed since this summary was written.", systemImage: "arrow.triangle.2.circlepath")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button("Regenerate") { self.regenerate() }.disabled(self.isBusy)
                }
            }

            if let record {
                if MeetAISummaryStyle(rawValue: record.style) == nil {
                    Text("Summary from the previous MeetAI version")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                MarkdownText(markdown: record.markdown)
                    .textSelection(.enabled)
            } else if !self.isBusy {
                Text("No summary yet.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .task(id: self.session.updatedAt) { await self.reload() }
        .onChange(of: self.processor.busySessions) { _, _ in Task { await self.reload() } }
    }

    private func reload() async {
        self.record = try? await MeetAISidecarStore.shared.summary(for: self.session.id)
        if let saved = self.record.flatMap({ MeetAISummaryStyle(rawValue: $0.style) }) { self.style = saved }
    }

    /// The style picker here is per meeting; the global default is set only in the MeetAI settings sheet.
    private func regenerate() {
        Task {
            await self.processor.regenerateSummary(sessionID: self.session.id, style: self.style)
            await self.reload()
        }
    }
}

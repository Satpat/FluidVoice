import SwiftUI

struct MeetAISettingsSheet: View {
    @ObservedObject private var settings = MeetAISettings.shared
    @ObservedObject private var migrator = MeetAIMigrator.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            Text("MeetAI")
                .font(self.theme.typography.bodyStrong)
            Form {
                Section("After each meeting") {
                    Toggle("Recognise saved voices", isOn: Binding(get: { self.settings.speakerMatching }, set: { self.settings.speakerMatching = $0 }))
                    Toggle("Name speakers from the conversation", isOn: Binding(get: { self.settings.autoName }, set: { self.settings.autoName = $0 }))
                    Toggle("Write a summary", isOn: Binding(get: { self.settings.autoSummarize }, set: { self.settings.autoSummarize = $0 }))
                    Picker("Summary style", selection: Binding(get: { self.settings.summaryStyle }, set: { self.settings.summaryStyle = $0 })) {
                        ForEach(MeetAISummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("Names, titles, summaries and answers use the provider chosen under AI Enhancement.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Section("Known speakers") {
                    MeetAIKnownSpeakersView()
                }
                Section("Meetings from the previous MeetAI version") {
                    Text("Imported \(self.count(.done)) · skipped \(self.count(.skipped)) · failed \(self.count(.failed))")
                    ForEach(self.folders { $0.status != .done }, id: \.self) { folder in
                        Text("\(self.migrator.entries[folder]?.status.rawValue.capitalized ?? ""): \(folder) — \(self.migrator.entries[folder]?.reason ?? "")")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Button(self.migrator.isRunning ? "Importing…" : "Re-run migration") {
                        Task { await self.migrator.run(retryFailed: true) }
                    }
                    .disabled(self.migrator.isRunning)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { self.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(self.theme.metrics.spacing.xl)
        .frame(minWidth: 520, minHeight: 480)
        .task { self.migrator.loadEntries() }
    }

    private func count(_ status: MeetAIMigrationEntry.Status) -> Int {
        self.migrator.entries.values.filter { $0.status == status }.count
    }

    private func folders(where predicate: (MeetAIMigrationEntry) -> Bool) -> [String] {
        self.migrator.entries.filter { predicate($0.value) }.map(\.key).sorted()
    }
}

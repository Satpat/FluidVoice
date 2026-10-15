import SwiftUI

struct MeetAISettingsSheet: View {
    @ObservedObject private var settings = MeetAISettings.shared
    @ObservedObject private var migrator = MeetAIMigrator.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var pendingReprocess: String?
    @State private var reprocessing: String?
    @State private var reprocessMessage: String?

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
                    ForEach(self.folders { $0.status == .done }.filter { self.migrator.hasLegacyAudio(folder: $0) }, id: \.self) { folder in
                        HStack {
                            Text(folder).font(self.theme.typography.caption)
                            if self.migrator.entries[folder]?.reprocessedAt != nil {
                                Text("re-processed").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                            }
                            Spacer()
                            Button("Re-process…") { self.pendingReprocess = folder }
                                .disabled(self.reprocessing != nil)
                        }
                    }
                    if let message = self.reprocessMessage {
                        Text(message).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    }
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
        .confirmationDialog(
            "Re-process this meeting with FluidMeet?",
            isPresented: Binding(get: { self.pendingReprocess != nil }, set: { if !$0 { self.pendingReprocess = nil } })
        ) {
            Button("Re-process") {
                guard let folder = self.pendingReprocess else { return }
                self.pendingReprocess = nil
                self.reprocessing = folder
                self.reprocessMessage = "Re-processing \(folder)…"
                Task {
                    do {
                        _ = try await self.migrator.reprocess(folder: folder, retry: {
                            _ = try await AppServices.shared.meetingSessionCoordinator.retryProcessing(sessionID: $0)
                        })
                        self.reprocessMessage = "Re-processed \(folder)."
                    } catch {
                        self.reprocessMessage = "Couldn't re-process \(folder): \(error.localizedDescription)"
                    }
                    self.reprocessing = nil
                }
            }
        } message: {
            Text("The transcript will be replaced with a new one from the original audio. Speaker names come back where voices match saved speakers. This can take several minutes.")
        }
    }

    private func count(_ status: MeetAIMigrationEntry.Status) -> Int {
        self.migrator.entries.values.filter { $0.status == status }.count
    }

    private func folders(where predicate: (MeetAIMigrationEntry) -> Bool) -> [String] {
        self.migrator.entries.filter { predicate($0.value) }.map(\.key).sorted()
    }
}

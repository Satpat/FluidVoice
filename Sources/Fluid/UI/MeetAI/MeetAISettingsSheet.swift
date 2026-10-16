import SwiftUI

struct MeetAISettingsSheet: View {
    @ObservedObject private var settings = MeetAISettings.shared
    @ObservedObject private var migrator = MeetAIMigrator.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var pendingReprocess: String?
    @State private var reprocessing: String?
    @State private var reprocessMessage: String?
    @State private var candidates: [MeetAIMigrator.ReprocessCandidate] = []

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
                    if let aside = self.migrator.unreadableStateFile {
                        Text("Migration state unreadable; moved aside (\(aside)) — Re-run migration to rebuild.")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Text("Imported \(self.count(.done)) · skipped \(self.count(.skipped)) · failed \(self.count(.failed))")
                    ForEach(self.candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(self.theme.typography.caption)
                                Text(self.subtitle(for: candidate))
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                            if candidate.reprocessed {
                                Text("re-processed").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                            }
                            Spacer()
                            Button("Re-process…") { self.pendingReprocess = candidate.folder }
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
        .task(id: self.migrator.entries) { self.candidates = await self.migrator.reprocessCandidates() }
        .confirmationDialog(
            "Re-process this meeting with FluidMeet?",
            isPresented: Binding(get: { self.pendingReprocess != nil }, set: { if !$0 { self.pendingReprocess = nil } })
        ) {
            Button("Re-process") {
                guard let folder = self.pendingReprocess else { return }
                self.pendingReprocess = nil
                guard AppServices.shared.meetingSessionCoordinator.isQuiescent else {
                    self.reprocessMessage = "Finish or stop the current meeting first."
                    return
                }
                let name = self.displayName(folder)
                self.reprocessing = folder
                self.reprocessMessage = "Re-processing \(name)…"
                Task {
                    do {
                        let result = try await self.migrator.reprocess(folder: folder, retry: {
                            _ = try await AppServices.shared.meetingSessionCoordinator.retryProcessing(sessionID: $0)
                        }, discard: { id in
                            try await Self.deleteViaCoordinator(id)
                        })
                        if let problem = result.oldCopyRemovalError {
                            self.reprocessMessage = "Re-processed \(name), but the old copy couldn't be removed: \(problem)"
                        } else {
                            self.reprocessMessage = "Re-processed \(name)."
                        }
                    } catch {
                        self.reprocessMessage = "Couldn't re-process \(name): \(error.localizedDescription)"
                    }
                    self.reprocessing = nil
                }
            }
        } message: {
            Text("FluidMeet will transcribe the original audio again and replace this meeting. Speaker names come back only where voices match saved speakers. Transcript corrections and the current summary are discarded; a new summary is written only if 'Write a summary' is on. This can take several minutes.")
        }
    }

    /// Goes through the coordinator so a failed/interrupted offer for the session is cleared too.
    /// Retries briefly while the coordinator is still winding down.
    private static func deleteViaCoordinator(_ id: MeetingSessionID) async throws {
        var attempt = 0
        while true {
            do {
                try await AppServices.shared.meetingSessionCoordinator.deleteSession(id: id)
                return
            } catch MeetingCoordinatorError.activityInProgress where attempt < 10 {
                attempt += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch MeetingCoordinatorError.maintenanceInProgress where attempt < 10 {
                attempt += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func displayName(_ folder: String) -> String {
        self.candidates.first { $0.folder == folder }?.title ?? folder
    }

    private func subtitle(for candidate: MeetAIMigrator.ReprocessCandidate) -> String {
        guard let startedAt = candidate.startedAt else { return candidate.folder }
        return "\(startedAt.formatted(date: .abbreviated, time: .shortened)) · \(candidate.folder)"
    }

    private func count(_ status: MeetAIMigrationEntry.Status) -> Int {
        self.migrator.entries.values.filter { $0.status == status }.count
    }

    private func folders(where predicate: (MeetAIMigrationEntry) -> Bool) -> [String] {
        self.migrator.entries.filter { predicate($0.value) }.map(\.key).sorted()
    }
}

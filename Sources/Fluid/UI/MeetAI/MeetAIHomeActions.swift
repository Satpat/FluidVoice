import SwiftUI
import UniformTypeIdentifiers

struct MeetAIHomeActions: View {
    @ObservedObject private var importer = MeetAIAudioImporter.shared
    @State private var showsSettings = false
    @State private var showsImporter = false
    @Environment(\.theme) private var theme

    private var isWorking: Bool {
        if case .working = self.importer.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Button {
                    self.showsImporter = true
                } label: {
                    Label("Import audio as meeting…", systemImage: "square.and.arrow.down")
                }
                .disabled(self.isWorking)
                Button {
                    self.showsSettings = true
                } label: {
                    Label("MeetAI settings…", systemImage: "gearshape")
                }
                Spacer(minLength: 0)
            }
            switch self.importer.status {
            case .idle:
                EmptyView()
            case let .working(message):
                ProgressView(message).controlSize(.small)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            case let .done(message):
                Label(message, systemImage: "checkmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .sheet(isPresented: self.$showsSettings) { MeetAISettingsSheet() }
        .fileImporter(isPresented: self.$showsImporter, allowedContentTypes: [.audio, .movie]) { result in
            guard case let .success(url) = result else { return }
            Task { await self.importer.importFile(url) }
        }
    }
}

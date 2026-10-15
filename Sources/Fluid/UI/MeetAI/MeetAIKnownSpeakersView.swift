import SwiftUI

struct MeetAIKnownSpeakersView: View {
    @ObservedObject private var store = MeetAISpeakerProfileStore.shared
    @State private var pendingDelete: MeetAISpeakerProfile?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            if self.store.profiles.isEmpty {
                Text("No saved voices yet. Rename a speaker in a meeting to save their voice.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.store.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { profile in
                HStack(spacing: self.theme.metrics.spacing.md) {
                    ProfileNameField(profile: profile) { self.store.rename(id: profile.id, to: $0) }
                    Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button(role: .destructive) { self.pendingDelete = profile } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(profile.name)")
                }
            }
        }
        .confirmationDialog(
            "Delete \(self.pendingDelete?.name ?? "")'s saved voice?",
            isPresented: Binding(get: { self.pendingDelete != nil }, set: { if !$0 { self.pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = self.pendingDelete { self.store.delete(id: profile.id) }
                self.pendingDelete = nil
            }
        } message: {
            Text("Future meetings won't recognise this voice. Past meetings keep their names.")
        }
    }

    private struct ProfileNameField: View {
        let profile: MeetAISpeakerProfile
        let commit: (String) -> Void
        @State private var name = ""

        var body: some View {
            TextField("Name", text: self.$name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onAppear { self.name = self.profile.name }
                .onSubmit { self.commit(self.name) }
        }
    }
}

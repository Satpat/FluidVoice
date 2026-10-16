import SwiftUI

struct MeetAIKnownSpeakersView: View {
    @ObservedObject private var store = MeetAISpeakerProfileStore.shared
    @State private var pendingDelete: MeetAISpeakerProfile?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            if self.store.profiles.isEmpty {
                Text("No saved voices yet. Rename a speaker in a meeting, or use Save this voice on its Summary tab, to save their voice.")
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
        @FocusState private var focused: Bool

        var body: some View {
            TextField("Name", text: self.$name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .focused(self.$focused)
                .accessibilityLabel("Name for \(self.profile.name)")
                .onAppear { self.name = self.profile.name }
                .onSubmit { self.commitIfChanged() }
                .onChange(of: self.focused) { _, isFocused in
                    if !isFocused { self.commitIfChanged() }
                }
                .onChange(of: self.profile.name) { _, new in
                    if !self.focused { self.name = new }
                }
                .onDisappear { self.commitIfChanged() }
        }

        private func commitIfChanged() {
            let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != self.profile.name {
                self.commit(trimmed)
            }
            // Snap back to the stored name so a rejected (empty) edit does not linger.
            let stored = MeetAISpeakerProfileStore.shared.profiles.first { $0.id == self.profile.id }?.name
            self.name = stored ?? self.profile.name
        }
    }
}

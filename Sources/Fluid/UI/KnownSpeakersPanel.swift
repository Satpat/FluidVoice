import SwiftUI

/// Manage persistent voice identities. Speakers are enrolled automatically
/// when a name is discovered (self-introduction) or matched to a saved voice;
/// this panel lets the user review, rename, and remove them.
struct KnownSpeakersPanel: View {
    @ObservedObject private var store = SpeakerProfileStore.shared
    @State private var renamingID: String?
    @State private var renameText: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundColor(Color.fluidGreen)
                Text("Known speakers")
                    .font(.headline)
                Spacer()
                Text("\(self.store.profiles.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if self.store.profiles.isEmpty {
                Text("People are recognised automatically once their name is heard in a meeting. Recognised voices are then labelled by name in future meetings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(self.store.profiles) { profile in
                        self.profileRow(profile)
                    }
                }
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

    private func profileRow(_ profile: SpeakerProfile) -> some View {
        HStack {
            Image(systemName: "waveform.and.person.filled")
                .foregroundColor(.secondary)
                .frame(width: 24)

            if self.renamingID == profile.id {
                TextField("Name", text: self.$renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.commitRename(profile) }
                Button("Save") { self.commitRename(profile) }
                    .buttonStyle(.borderless)
                Button("Cancel") { self.renamingID = nil }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .medium))
                    Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    self.renameText = profile.name
                    self.renamingID = profile.id
                }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename")
                Button(role: .destructive, action: { self.store.delete(id: profile.id) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget this voice")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground)
        )
    }

    private func commitRename(_ profile: SpeakerProfile) {
        self.store.rename(id: profile.id, to: self.renameText)
        self.renamingID = nil
    }
}

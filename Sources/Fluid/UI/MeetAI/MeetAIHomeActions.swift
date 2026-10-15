import SwiftUI

struct MeetAIHomeActions: View {
    @State private var showsSettings = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Button {
                self.showsSettings = true
            } label: {
                Label("MeetAI settings…", systemImage: "gearshape")
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: self.$showsSettings) { MeetAISettingsSheet() }
    }
}

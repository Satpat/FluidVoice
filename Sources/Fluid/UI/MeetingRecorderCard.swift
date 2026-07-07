import SwiftUI
import AppKit

extension MeetingRecordingSession {
    /// Shared instance so a recording survives sidebar navigation — the card
    /// view is recreated whenever the user switches tabs, and holding the
    /// session as view @State would stop the recorders on teardown.
    @MainActor static let shared = MeetingRecordingSession()
}

/// Start/stop card for live two-track meeting recording (system audio + mic).
struct MeetingRecorderCard: View {
    @State private var session = MeetingRecordingSession.shared
    @StateObject private var pipeline: MeetingTranscriptPipeline
    @Environment(\.theme) private var theme

    init(asrService: ASRService) {
        _pipeline = StateObject(wrappedValue: MeetingTranscriptPipeline(asrService: asrService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch self.session.state {
            case .idle:
                self.idleContent
            case .recording(let startedAt):
                self.recordingContent(startedAt: startedAt)
            case .stopped(let artifacts):
                self.stoppedContent(artifacts: artifacts)
            case .failed(let message):
                self.failedContent(message: message)
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

    // MARK: - States

    private var idleContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record Meeting")
                    .font(.headline)
                Text("Captures system audio (them) and microphone (you) as separate tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { self.session.start() }) {
                HStack {
                    Image(systemName: "record.circle")
                    Text("Start")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func recordingContent(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "record.circle.fill")
                    .foregroundColor(.red)
                    .symbolEffect(.pulse, options: .repeating)

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.format(elapsed: context.date.timeIntervalSince(startedAt)))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                }

                Spacer()

                Button(action: { self.session.stop() }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }

            TimelineView(.periodic(from: startedAt, by: 0.1)) { _ in
                VStack(spacing: 6) {
                    self.levelMeter(label: "System", level: self.session.systemPeak)
                    self.levelMeter(label: "Mic", level: self.session.micPeak)
                }
            }
        }
    }

    private func stoppedContent(artifacts: MeetingRecordingArtifacts) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(Color.fluidGreen)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.pipeline.transcriptURL == nil ? "Recording saved" : "Transcript ready")
                        .font(.headline)
                    Text("\(artifacts.displayName) · \(Self.format(elapsed: artifacts.duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let transcriptURL = self.pipeline.transcriptURL {
                    Button("Open Transcript") {
                        NSWorkspace.shared.open(transcriptURL)
                    }
                } else {
                    Button(action: { self.transcribe(artifacts) }) {
                        HStack {
                            Image(systemName: "waveform")
                            Text("Transcribe")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.pipeline.isProcessing)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([artifacts.systemAudio, artifacts.microphone])
                }

                Button("New Recording") {
                    self.pipeline.transcriptURL = nil
                    self.session.reset()
                }
                .disabled(self.pipeline.isProcessing)
            }

            if self.pipeline.isProcessing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: self.pipeline.progress)
                        .progressViewStyle(.linear)
                    Text(self.pipeline.currentStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = self.pipeline.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func transcribe(_ artifacts: MeetingRecordingArtifacts) {
        Task {
            do {
                _ = try await self.pipeline.process(artifacts)
            } catch {
                DebugLogger.shared.error("Meeting transcription failed: \(error)", source: "MeetingRecorderCard")
            }
        }
    }

    private func failedContent(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recording failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Dismiss") {
                self.session.reset()
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Helpers

    private func levelMeter(label: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(self.theme.palette.contentBackground)
                    Capsule()
                        .fill(Color.fluidGreen.gradient)
                        .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.1), value: level)
        }
    }

    private static func format(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

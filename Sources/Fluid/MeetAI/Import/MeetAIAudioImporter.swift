import Combine
import Foundation

@MainActor
final class MeetAIAudioImporter: ObservableObject {
    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done(String)
    }

    static let shared = MeetAIAudioImporter(
        store: MeetingSessionStore.shared,
        retry: { _ = try await AppServices.shared.meetingSessionCoordinator.retryProcessing(sessionID: $0) }
    )

    @Published private(set) var status: Status = .idle

    private let store: any MeetingSessionStoring
    private let retry: @MainActor (MeetingSessionID) async throws -> Void

    init(store: any MeetingSessionStoring, retry: @escaping @MainActor (MeetingSessionID) async throws -> Void) {
        self.store = store
        self.retry = retry
    }

    func importFile(_ url: URL) async {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        self.status = .working("Reading \(name)…")
        let samples: [Float]
        do {
            samples = try await MeetAIAudioDecoder.decode(url: url)
        } catch {
            self.status = .failed(error.localizedDescription)
            return
        }
        guard samples.count >= Int(MeetAISyntheticSessionBuilder.sampleRate) else {
            self.status = .failed("\(name) is shorter than one second.")
            return
        }

        let title = url.deletingPathExtension().lastPathComponent
        let startedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let session: MeetingSession
        do {
            session = try await MeetAISessionImport.createAudioSession(
                store: self.store,
                title: title,
                languageCode: SettingsStore.shared.meetingRecordingDefaults.languageCode ?? "en",
                startedAt: startedAt,
                tracks: [.init(kind: .microphone, samples: samples, echoProtection: .acousticallyClosed)]
            )
        } catch {
            self.status = .failed(error.localizedDescription)
            return
        }

        self.status = .working("Transcribing \(title)…")
        do {
            try await self.retry(session.id)
            self.status = .done("Imported \(title).")
        } catch {
            // The session stays saved and retryable from the meeting's own recovery controls.
            self.status = .failed("Saved \(title), but processing failed: \(error.localizedDescription) You can retry from the meeting.")
        }
    }
}

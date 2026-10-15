import Foundation

@MainActor
enum MeetAISessionImport {
    /// Creates the session in `store`, writes each track's chunks into its directory and saves it.
    /// On any failure the half-written session is deleted.
    static func createAudioSession(
        store: any MeetingSessionStoring,
        id: MeetingSessionID = UUID(),
        title: String,
        languageCode: String,
        startedAt: Date,
        tracks: [MeetAISyntheticSessionBuilder.TrackAudio]
    ) async throws -> MeetingSession {
        let duration = (tracks.map { Double($0.samples.count) }.max() ?? 0) / MeetAISyntheticSessionBuilder.sampleRate
        var session = MeetAISyntheticSessionBuilder.audioSessionShell(
            id: id, title: title, languageCode: languageCode, startedAt: startedAt,
            duration: duration, trackKinds: tracks.map(\.kind)
        )
        try await store.create(session)
        do {
            let directory = try await store.sessionDirectory(for: session.id)
            for track in tracks {
                let chunks = try await MeetAISyntheticSessionBuilder.writeChunksAsync(samples: track.samples, kind: track.kind, sessionDirectory: directory)
                MeetAISyntheticSessionBuilder.attach(chunks, kind: track.kind, echoProtection: track.echoProtection, to: &session)
            }
            try await store.save(session)
            return session
        } catch {
            try? await store.delete(id: session.id)
            throw error
        }
    }
}

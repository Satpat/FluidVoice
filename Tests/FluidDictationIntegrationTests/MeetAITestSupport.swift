@testable import FluidVoice_Debug
import XCTest

enum MeetAIFixtures {
    static func tempDirectory(_ test: XCTestCase, _ prefix: String = "meetai") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    struct Line {
        let speaker: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// A completed session. `speakers[i]` is (displayName, isLocalUser); lines reference speakers by index.
    static func session(
        speakers: [(String, Bool)],
        lines: [Line],
        title: String = "Fixture meeting",
        defaultTitle: Bool = true
    ) -> MeetingSession {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom, title: title,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic"),
                timestampDefaultTitle: defaultTitle
            ),
            startedAt: started,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic", format: nil,
            timebase: session.timebase, health: .waiting, chunks: []
        )
        session.audioTracks = [track]
        session.speakers = speakers.map { name, isLocal in
            MeetingSessionSpeaker(id: UUID(), displayName: name, diarizationClusterID: nil, trackKind: .microphone, isLocalUser: isLocal, identityCandidates: [])
        }
        session.transcriptSegments = lines.map { line in
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: Int64(line.start * 1_000), timescale: 1_000),
                end: MeetingMediaTime(value: Int64(line.end * 1_000), timescale: 1_000),
                sourceTrackID: track.id,
                speakerID: session.speakers[line.speaker].id,
                text: line.text,
                revision: 1,
                status: .final,
                overlap: .none,
                completeness: .complete,
                attributionState: .assigned
            )
        }
        session.state = .completed
        session.endedAt = started.addingTimeInterval((lines.map(\.end).max() ?? 0) + 1)
        session.transcriptIsComplete = true
        return session
    }
}

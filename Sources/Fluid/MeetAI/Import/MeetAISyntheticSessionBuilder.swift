import AVFoundation
import CryptoKit
import Foundation

/// Builds FluidMeet sessions for audio MeetAI imports instead of captures (an audio file, or a
/// fork recording) and for transcript-only legacy meetings. See spec §6.6, §7 and §12.6.
nonisolated enum MeetAISyntheticSessionBuilder {
    static let chunkSeconds: Double = 60
    static let sampleRate: Double = 16_000
    static let importBundleIdentifier = "com.meetai.import"
    static let importDeviceID = "meetai-import"

    struct LegacySpeaker: Equatable, Sendable {
        let label: String
        let isLocalUser: Bool
    }

    struct LegacySegment: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let speakerLabel: String
        let text: String
    }

    struct TrackAudio: Sendable {
        let kind: MeetingAudioTrackKind
        let samples: [Float]
        /// Only used for microphone tracks.
        let echoProtection: MeetingMicrophoneEchoProtection
    }

    enum BuildError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            switch self { case let .writeFailed(detail): "Couldn't save the imported audio: \(detail)" }
        }
    }

    static let timebase = MeetingTimebaseMetadata(
        startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
    )

    static func configuration(title: String, languageCode: String, hasApplicationAudio: Bool) -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(
            mode: hasApplicationAudio ? .onlineCall : .inRoom,
            title: title,
            languageCode: languageCode,
            application: hasApplicationAudio
                ? MeetingApplicationIdentity(bundleIdentifier: self.importBundleIdentifier, displayName: "Imported recording")
                : nil,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: self.importDeviceID, displayName: "Imported audio")
        )
    }

    static func milliseconds(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1_000).rounded()), timescale: 1_000)
    }

    static func emptyTrack(kind: MeetingAudioTrackKind) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: kind == .microphone ? self.importDeviceID : self.importBundleIdentifier,
            sourceDisplayName: kind == .microphone ? "Imported audio" : "Imported recording",
            format: MeetingAudioFormat(codec: "lpcm-s16", sampleRate: self.sampleRate, channelCount: 1, bitRate: nil),
            timebase: self.timebase,
            health: MeetingTrackHealth(status: .stopped, lastPresentationTime: nil, lastSampleAt: nil, level: 0, droppedSampleCount: 0, detail: nil),
            chunks: [],
            captureMethod: kind == .microphone ? .avCaptureSession : .screenCaptureKit
        )
    }

    /// A session whose tracks have no chunks yet. State `.interrupted` means "audio captured, not
    /// processed", so upstream's recovery UI can retry it if MeetAI's own processing call fails.
    static func audioSessionShell(
        id: MeetingSessionID = UUID(),
        title: String,
        languageCode: String,
        startedAt: Date,
        duration: TimeInterval,
        trackKinds: [MeetingAudioTrackKind]
    ) -> MeetingSession {
        var session = MeetingSession(
            id: id,
            configuration: self.configuration(title: title, languageCode: languageCode, hasApplicationAudio: trackKinds.contains(.applicationAudio)),
            startedAt: startedAt,
            timebase: self.timebase
        )
        session.audioTracks = trackKinds.map { self.emptyTrack(kind: $0) }
        session.endedAt = startedAt.addingTimeInterval(duration)
        session.state = .interrupted
        session.updatedAt = Date()
        return session
    }

    /// Writes 16 kHz mono Float32 CAF chunks of `chunkSeconds` at `tracks/<kind>/NNNNNN.caf`, in
    /// upstream's PCM-first schema (version 2 plus a ready `captureAnalysisAsset`). Legacy WAV/AAC
    /// chunks have unknown codec priming, so the canonical backend marks every span
    /// `timingUncertain` and attributes no speakers (found by the Task 3 spike).
    static func writeChunks(samples: [Float], kind: MeetingAudioTrackKind, sessionDirectory: URL) throws -> [MeetingAudioChunk] {
        let chunkLength = Int(self.chunkSeconds * self.sampleRate)
        let folder = sessionDirectory.appendingPathComponent("tracks/\(kind.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false) else {
            throw BuildError.writeFailed("unsupported format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var chunks: [MeetingAudioChunk] = []
        var offset = 0
        var sequence = 0
        while offset < samples.count {
            let end = min(samples.count, offset + chunkLength)
            let relativePath = "tracks/\(kind.rawValue)/\(String(format: "%06d", sequence)).caf"
            let url = sessionDirectory.appendingPathComponent(relativePath)
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let frames = AVAudioFrameCount(end - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    throw BuildError.writeFailed("buffer allocation")
                }
                buffer.frameLength = frames
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: Int(frames))
                }
                try file.write(from: buffer)
                file.close()
            } catch let error as BuildError {
                throw error
            } catch {
                throw BuildError.writeFailed(error.localizedDescription)
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            chunks.append(MeetingAudioChunk(
                id: UUID(),
                sequence: sequence,
                relativeFilePath: relativePath,
                presentationStart: self.milliseconds(Double(offset) / self.sampleRate),
                presentationEnd: self.milliseconds(Double(end) / self.sampleRate),
                discontinuities: [],
                sha256: hash,
                byteCount: Int64(data.count),
                finalizationState: .finalized,
                audioSchemaVersion: 2,
                captureAnalysisAsset: MeetingAudioAsset(
                    role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
                    relativeFilePath: relativePath, byteCount: Int64(data.count),
                    sha256: hash,
                    sampleRate: self.sampleRate, channelCount: 1, frameCount: Int64(end - offset)
                )
            ))
            offset = end
            sequence += 1
        }
        return chunks
    }

    /// `writeChunks` off the caller's actor: an hour of audio is hundreds of MB to write and hash,
    /// which must not run on the main actor (spec §5.5).
    @concurrent static func writeChunksAsync(samples: [Float], kind: MeetingAudioTrackKind, sessionDirectory: URL) async throws -> [MeetingAudioChunk] {
        try self.writeChunks(samples: samples, kind: kind, sessionDirectory: sessionDirectory)
    }

    static func attach(
        _ chunks: [MeetingAudioChunk],
        kind: MeetingAudioTrackKind,
        echoProtection: MeetingMicrophoneEchoProtection,
        to session: inout MeetingSession
    ) {
        guard let index = session.audioTracks.firstIndex(where: { $0.kind == kind }) else { return }
        session.audioTracks[index].chunks = chunks
        session.audioTracks[index].health.lastPresentationTime = chunks.last?.presentationEnd
        if kind == .microphone {
            session.audioTracks[index].captureEras = [MeetingCaptureEra(
                method: .avCaptureSession,
                deviceUID: self.importDeviceID,
                deviceName: "Imported audio",
                roleAtElection: .unknown,
                echoProtection: echoProtection,
                startSeconds: 0
            )]
        }
    }

    /// A completed session with a transcript and no audio (audio "deleted" at `audioDeletedAt`).
    static func transcriptOnlySession(
        id: MeetingSessionID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        speakers: [LegacySpeaker],
        segments: [LegacySegment],
        audioDeletedAt: Date
    ) -> MeetingSession {
        let hasRemote = speakers.contains { !$0.isLocalUser }
        var session = MeetingSession(
            id: id,
            configuration: self.configuration(title: title, languageCode: "en", hasApplicationAudio: hasRemote),
            startedAt: startedAt,
            timebase: self.timebase
        )
        let microphone = self.emptyTrack(kind: .microphone)
        let application = hasRemote ? self.emptyTrack(kind: .applicationAudio) : nil
        session.audioTracks = [microphone] + (application.map { [$0] } ?? [])
        var speakerIDs: [String: (id: SessionSpeakerID, isLocal: Bool)] = [:]
        session.speakers = speakers.map { speaker in
            let id = UUID()
            speakerIDs[speaker.label] = (id, speaker.isLocalUser)
            return MeetingSessionSpeaker(
                id: id,
                displayName: speaker.label,
                diarizationClusterID: nil,
                trackKind: speaker.isLocalUser ? .microphone : .applicationAudio,
                isLocalUser: speaker.isLocalUser,
                identityCandidates: []
            )
        }
        session.transcriptSegments = segments.compactMap { segment in
            guard let speaker = speakerIDs[segment.speakerLabel] else { return nil }
            return MeetingTranscriptSegment(
                id: UUID(),
                start: self.milliseconds(segment.start),
                end: self.milliseconds(segment.end),
                sourceTrackID: speaker.isLocal ? microphone.id : (application?.id ?? microphone.id),
                speakerID: speaker.id,
                text: segment.text,
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete,
                attributionState: .assigned
            )
        }
        session.state = .completed
        session.endedAt = endedAt
        session.transcriptIsComplete = true
        session.retention.audioDeletedAt = audioDeletedAt
        session.updatedAt = Date()
        return session
    }
}

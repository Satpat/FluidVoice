// Ported from the MeetAI native recorder.
// One recording session = one tap recorder (system audio) + one mic recorder,
// writing two parallel WAV files into a per-session folder under
// ~/Library/Application Support/FluidVoice/MeetingRecordings/.

import Foundation
import SwiftUI
import OSLog

struct MeetingRecordingArtifacts: Codable, Hashable {
    let folder: URL
    let systemAudio: URL
    let microphone: URL
    let startedAt: Date
    let endedAt: Date

    var displayName: String { self.folder.lastPathComponent }
    var duration: TimeInterval { self.endedAt.timeIntervalSince(self.startedAt) }
}

@MainActor
@Observable
final class MeetingRecordingSession {

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case stopped(MeetingRecordingArtifacts)
        case failed(String)
    }

    private let logger = Logger(subsystem: kMeetingRecordingSubsystem, category: "MeetingRecordingSession")
    private let baseDirectory: URL

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var systemRecorder: ProcessTapRecorder?
    @ObservationIgnored private var micRecorder: MeetingMicRecorder?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var startedAt: Date?

    private(set) var state: State = .idle
    var systemPeak: Float { self.systemRecorder?.lastPeak ?? 0 }
    var micPeak: Float { self.micRecorder?.lastPeak ?? 0 }

    /// Optional 16 kHz mono sample tees for live transcription. Set before
    /// calling start(); invoked on audio threads.
    @ObservationIgnored var liveMicSampleHandler: (([Float]) -> Void)?
    @ObservationIgnored var liveSystemSampleHandler: (([Float]) -> Void)?
    var isRecording: Bool {
        if case .recording = self.state { return true }
        return false
    }

    var elapsedSeconds: TimeInterval {
        guard case .recording(let startedAt) = self.state else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    init(baseDirectory: URL = MeetingRecordingSession.defaultBaseDirectory()) {
        self.baseDirectory = baseDirectory
        try? FileManager.default.createDirectory(at: baseDirectory,
                                                 withIntermediateDirectories: true)
    }

    nonisolated static func defaultBaseDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        return support.appendingPathComponent("FluidVoice/MeetingRecordings", isDirectory: true)
    }

    func start() {
        guard case .idle = self.state else { return }
        do {
            let timestamp = ISO8601DateFormatter.meetingFileSafe.string(from: Date())
            let folder = self.baseDirectory.appendingPathComponent(timestamp, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.folder = folder

            let tap = SystemAudioTap(muteWhenRunning: false)
            tap.activate()
            if let err = tap.errorMessage {
                throw MeetingRecordingError(err)
            }
            self.tap = tap

            let systemURL = folder.appendingPathComponent("system.wav")
            let micURL = folder.appendingPathComponent("mic.wav")

            let sysRec = ProcessTapRecorder(fileURL: systemURL, tap: tap)
            sysRec.liveSampleHandler = self.liveSystemSampleHandler
            try sysRec.start()
            self.systemRecorder = sysRec

            let mic = MeetingMicRecorder(fileURL: micURL)
            mic.liveSampleHandler = self.liveMicSampleHandler
            // Feed the system-output level to the mic's leak gate: when the
            // speakers are loud and the mic hears only a weak signal, that is
            // bleed and gets silenced at the source.
            mic.systemLevelProvider = { [weak sysRec] in sysRec?.lastPeak ?? 0 }
            try mic.start()
            self.micRecorder = mic

            let started = Date()
            self.startedAt = started
            self.state = .recording(startedAt: started)
            self.logger.info("started session at \(folder.path, privacy: .public)")
        } catch {
            self.cleanup()
            self.state = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func stop() -> MeetingRecordingArtifacts? {
        guard case .recording = self.state,
              let folder = self.folder,
              let startedAt = self.startedAt else { return nil }

        self.systemRecorder?.stop()
        self.micRecorder?.stop()
        self.tap?.invalidate()

        let artifacts = MeetingRecordingArtifacts(
            folder: folder,
            systemAudio: folder.appendingPathComponent("system.wav"),
            microphone: folder.appendingPathComponent("mic.wav"),
            startedAt: startedAt,
            endedAt: Date()
        )
        self.writeManifest(artifacts)
        self.cleanup()
        self.state = .stopped(artifacts)
        return artifacts
    }

    func reset() { self.state = .idle }

    /// session.json makes each recording folder self-describing, so later
    /// pipeline stages (native or the MeetAI Python bridge) can process it
    /// without this app running.
    private func writeManifest(_ artifacts: MeetingRecordingArtifacts) {
        let manifestURL = artifacts.folder.appendingPathComponent("session.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(artifacts)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            self.logger.error("manifest write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cleanup() {
        self.systemRecorder = nil
        self.micRecorder = nil
        self.tap = nil
        self.folder = nil
        self.startedAt = nil
    }
}

extension ISO8601DateFormatter {
    static let meetingFileSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                           .withTime, .withColonSeparatorInTime]
        return f
    }()
}

// Ported from the MeetAI native recorder, adapted from insidegui/AudioCap.
// Captures the system audio tap into a WAV file at native tap format.

import SwiftUI
import AudioToolbox
import AVFoundation
import OSLog

@Observable
final class ProcessTapRecorder {

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.fluidvoice.meetai.tap-recorder", qos: .userInitiated)
    private let logger: Logger

    @ObservationIgnored private weak var _tap: SystemAudioTap?
    @ObservationIgnored private var currentFile: AVAudioFile?
    @ObservationIgnored private(set) var lastPeak: Float = 0

    private(set) var isRecording = false

    init(fileURL: URL, tap: SystemAudioTap) {
        self.fileURL = fileURL
        self._tap = tap
        self.logger = Logger(subsystem: kMeetingRecordingSubsystem,
                             category: "ProcessTapRecorder(\(fileURL.lastPathComponent))")
    }

    @MainActor
    func start() throws {
        guard !self.isRecording else { return }
        guard let tap = self._tap else { throw MeetingRecordingError("System audio tap unavailable") }
        if !tap.activated { tap.activate() }

        guard var streamDescription = tap.tapStreamDescription else {
            throw MeetingRecordingError("Tap stream description not available — permission may be denied.")
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw MeetingRecordingError("Failed to derive AVAudioFormat from tap stream description.")
        }
        // .log (default level) so it persists for `log show` diagnostics; .info is memory-only.
        self.logger.log("system tap format: \(format, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey: streamDescription.mFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let file = try AVAudioFile(forWriting: self.fileURL,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: format.isInterleaved)
        self.currentFile = file

        try tap.run(on: self.queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.currentFile else { return }
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: inInputData,
                                                    deallocator: nil) else {
                    throw MeetingRecordingError("Failed to wrap PCM buffer")
                }
                self.lastPeak = ProcessTapRecorder.peak(of: buffer)
                try file.write(from: buffer)
            } catch {
                self.logger.error("write: \(error.localizedDescription, privacy: .public)")
            }
        } invalidationHandler: { [weak self] _ in
            self?.handleInvalidation()
        }

        self.isRecording = true
    }

    func stop() {
        guard self.isRecording else { return }
        self.currentFile = nil
        self.isRecording = false
        self._tap?.invalidate()
    }

    private func handleInvalidation() {
        guard self.isRecording else { return }
        self.logger.debug("tap invalidated externally")
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var maxAbs: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[ch]
            for i in 0..<frameLength {
                let v = abs(samples[i])
                if v > maxAbs { maxAbs = v }
            }
        }
        return maxAbs
    }
}

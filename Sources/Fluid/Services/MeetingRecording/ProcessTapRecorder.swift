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
    @ObservationIgnored private var startHostTime: UInt64 = 0
    @ObservationIgnored private var framesWritten: Int64 = 0
    @ObservationIgnored private var liveConverter: AVAudioConverter?
    @ObservationIgnored private var liveFormat: AVAudioFormat?

    /// Optional tee of the recorded audio as 16 kHz mono samples, called on
    /// the tap IO queue. Silence gaps are delivered as zeros so live sample
    /// offsets stay wall-clock aligned with the file. Must be cheap.
    @ObservationIgnored var liveSampleHandler: (([Float]) -> Void)?

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

        self.startHostTime = mach_absolute_time()
        self.framesWritten = 0

        if self.liveSampleHandler != nil {
            let liveFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            )
            self.liveFormat = liveFormat
            self.liveConverter = liveFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        }

        try tap.run(on: self.queue) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, let file = self.currentFile else { return }
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: inInputData,
                                                    deallocator: nil) else {
                    throw MeetingRecordingError("Failed to wrap PCM buffer")
                }

                // The device delivers no buffers while every process is
                // silent (idle output), so file time would drift from wall
                // time and later gap-less audio would glue together. Pad any
                // gap with silence so system-track timestamps stay aligned
                // with the mic track.
                let hostTime = inInputTime.pointee.mHostTime
                if hostTime > self.startHostTime {
                    let elapsed = Self.hostTicksToSeconds(hostTime - self.startHostTime)
                    // The timestamp can reference the end of the capture
                    // cycle rather than its first sample; subtract this
                    // buffer's own duration so a continuous stream never
                    // looks gapped (it did: 0.26 s of silence was being
                    // injected every cycle, shredding the audio).
                    let expectedFrames = Int64(elapsed * format.sampleRate) - Int64(buffer.frameLength)
                    let gap = expectedFrames - self.framesWritten
                    if gap > Int64(format.sampleRate / 4) { // tolerate <0.25 s of jitter
                        try self.writeSilence(frames: gap, format: format, to: file)
                        self.framesWritten += gap
                        if let handler = self.liveSampleHandler {
                            let liveCount = Int(Double(gap) * 16_000 / format.sampleRate)
                            handler([Float](repeating: 0, count: liveCount))
                        }
                    }
                }

                self.lastPeak = ProcessTapRecorder.peak(of: buffer)
                try file.write(from: buffer)
                self.framesWritten += Int64(buffer.frameLength)
                self.teeLiveSamples(from: buffer)
            } catch {
                self.logger.error("write: \(error.localizedDescription, privacy: .public)")
            }
        } invalidationHandler: { [weak self] _ in
            self?.handleInvalidation()
        }

        self.isRecording = true
    }

    private func teeLiveSamples(from buffer: AVAudioPCMBuffer) {
        guard let handler = self.liveSampleHandler,
              let converter = self.liveConverter,
              let liveFormat = self.liveFormat else { return }

        let ratio = liveFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: liveFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = converted.floatChannelData else { return }
        handler(Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))))
    }

    private func writeSilence(frames: Int64, format: AVAudioFormat, to file: AVAudioFile) throws {
        let chunkCapacity = AVAudioFrameCount(format.sampleRate) // 1 s per chunk
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunkCapacity), remaining))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw MeetingRecordingError("Failed to allocate silence buffer")
            }
            silence.frameLength = count
            let byteCount = Int(count) * Int(format.streamDescription.pointee.mBytesPerFrame)
            let bufferList = silence.mutableAudioBufferList
            for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
                let audioBuffer = UnsafeMutableAudioBufferListPointer(bufferList)[i]
                if let data = audioBuffer.mData {
                    memset(data, 0, min(Int(audioBuffer.mDataByteSize), byteCount))
                }
            }
            try file.write(from: silence)
            remaining -= Int64(count)
        }
    }

    private static let hostTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func hostTicksToSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(hostTimebase.numer) / Double(hostTimebase.denom) / 1_000_000_000
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

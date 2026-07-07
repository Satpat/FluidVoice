// Ported from the MeetAI native recorder.
// Captures the default input device (microphone) into a separate WAV file
// at 16 kHz mono — matches what the ASR providers want downstream and keeps
// the file small for long meetings.
//
// Deliberately separate from DirectCoreAudioInput (the dictation capture
// path): meeting recording writes to disk for later two-track processing,
// while dictation feeds the live ASR buffer. Unifying them onto the C ring
// buffer is a possible later optimization.

import Foundation
import AVFoundation
import OSLog

@Observable
final class MeetingMicRecorder {
    let fileURL: URL
    private let engine = AVAudioEngine()
    private let logger: Logger
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat!
    private var file: AVAudioFile?

    private(set) var isRecording = false
    @ObservationIgnored private(set) var lastPeak: Float = 0

    /// Optional tee of the recorded audio as 16 kHz mono samples, called on
    /// the audio tap thread. Used for live transcription; must be cheap.
    @ObservationIgnored var liveSampleHandler: (([Float]) -> Void)?

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.logger = Logger(subsystem: kMeetingRecordingSubsystem,
                             category: "MeetingMicRecorder(\(fileURL.lastPathComponent))")
    }

    func start() throws {
        guard !self.isRecording else { return }

        let input = self.engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MeetingRecordingError("Microphone not available (no input device).")
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false) else {
            throw MeetingRecordingError("Failed to build 16k mono format.")
        }
        self.outputFormat = target
        self.converter = AVAudioConverter(from: inputFormat, to: target)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        self.file = try AVAudioFile(forWriting: self.fileURL,
                                    settings: settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer)
        }

        self.engine.prepare()
        try self.engine.start()
        self.isRecording = true
    }

    func stop() {
        guard self.isRecording else { return }
        self.engine.inputNode.removeTap(onBus: 0)
        self.engine.stop()
        self.file = nil
        self.isRecording = false
    }

    private func handleInput(buffer: AVAudioPCMBuffer) {
        guard let converter = self.converter, let outputFormat = self.outputFormat, let file = self.file else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                               frameCapacity: outFrameCapacity) else { return }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)

        if let error {
            self.logger.error("convert: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try file.write(from: converted)
            self.lastPeak = MeetingMicRecorder.peak(of: converted)
        } catch {
            self.logger.error("write: \(error.localizedDescription, privacy: .public)")
        }

        if let handler = self.liveSampleHandler,
           let channel = converted.floatChannelData
        {
            handler(Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))))
        }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var maxAbs: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            let v = abs(samples[i])
            if v > maxAbs { maxAbs = v }
        }
        return maxAbs
    }
}

import AVFoundation
import Foundation

/// Decodes any AVFoundation-readable file into 16 kHz mono Float32 samples.
nonisolated enum MeetAIAudioDecoder {
    static let sampleRate: Double = 16_000

    enum DecodeError: LocalizedError {
        case unreadable(String)
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "Couldn't read audio from \(name)."
            case .conversionFailed: "Couldn't convert the audio to 16 kHz mono."
            }
        }
    }

    /// Off-main wrapper for whole-file decoding.
    @concurrent static func decode(url: URL) async throws -> [Float] {
        try self.load16kMono(url: url)
    }

    /// The whole file, or `[start, end)` seconds of it.
    static func load16kMono(url: URL, start: TimeInterval = 0, end: TimeInterval? = nil) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DecodeError.unreadable(url.lastPathComponent) }
        let inputFormat = file.processingFormat
        let sourceRate = inputFormat.sampleRate
        guard sourceRate > 0 else { throw DecodeError.unreadable(url.lastPathComponent) }
        let startFrame = AVAudioFramePosition(max(0, start) * sourceRate)
        let endFrame = min(file.length, end.map { AVAudioFramePosition(max(0, $0) * sourceRate) } ?? file.length)
        guard endFrame > startFrame else { return [] }
        file.framePosition = startFrame

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw DecodeError.conversionFailed }
        converter.downmix = true

        var remaining = endFrame - startFrame
        var inputDone = false
        var readError: Error?
        let inputCapacity: AVAudioFrameCount = 32_768
        var output: [Float] = []
        output.reserveCapacity(Int(Double(remaining) * self.sampleRate / sourceRate) + 1_024)

        while true {
            let outCapacity = AVAudioFrameCount(Double(inputCapacity) * self.sampleRate / sourceRate) + 1_024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                throw DecodeError.conversionFailed
            }
            let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
                if inputDone || remaining <= 0 {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let count = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: count) else {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: count)
                } catch {
                    readError = error
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                remaining -= AVAudioFramePosition(inBuffer.frameLength)
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw DecodeError.unreadable("\(url.lastPathComponent): \(readError.localizedDescription)") }
            if status == .error { throw DecodeError.conversionFailed }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (inputDone && outBuffer.frameLength == 0) { break }
        }
        return output
    }
}

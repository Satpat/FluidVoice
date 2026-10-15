import CoreML
import FluidAudio
import Foundation

nonisolated protocol MeetAISpeakerEmbedding: Sendable {
    /// WeSpeaker centroid for `turns`, or nil when there is not enough decodable audio.
    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]?
}

nonisolated enum MeetAIEmbeddingError: LocalizedError {
    case unsupportedModel
    var errorDescription: String? { "The speaker voice model has an unsupported input format." }
}

/// Same model and calls as upstream's `MeetingProductionParakeetNemotronRuntime.speakerVoiceProfiles`
/// (spec §12.2), so embeddings are compatible with the fork's existing WeSpeaker profiles.
nonisolated struct MeetAIFluidAudioEmbedder: MeetAISpeakerEmbedding {
    static let clipSamples = 160_000 // 10 s
    static let minimumClipSamples = 48_000 // 3 s

    func embedding(for turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        try await Self.compute(turns: turns, session: session, sessionDirectory: sessionDirectory)
    }

    /// Decoding and CoreML run off the caller's actor.
    @concurrent static func compute(turns: [MeetingTranscriptSegment], session: MeetingSession, sessionDirectory: URL) async throws -> [Float]? {
        var audio: [Float] = []
        for turn in turns {
            try Task.checkCancellation()
            let slices = try MeetingSegmentPlaybackPlan.slices(session: session, segment: turn, directory: sessionDirectory)
            for slice in slices {
                audio += try MeetAIAudioDecoder.load16kMono(url: slice.url, start: slice.start, end: slice.end)
            }
        }
        let clips = self.clips(from: audio)
        guard !clips.isEmpty else { return nil }
        return MeetAISpeakerMath.centroid(try await self.embed(clips: clips))
    }

    static func clips(from audio: [Float]) -> [[Float]] {
        stride(from: 0, to: audio.count, by: self.clipSamples).compactMap { start in
            let clip = Array(audio[start..<min(audio.count, start + self.clipSamples)])
            return clip.count >= self.minimumClipSamples ? clip : nil
        }
    }

    @concurrent static func embed(clips: [[Float]]) async throws -> [[Float]] {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "meetai-speakers", modelID: ModelNames.Diarizer.embeddingFile) {
            let models = try await DownloadUtils.loadModels(
                .diarizer,
                modelNames: [ModelNames.Diarizer.embeddingFile],
                directory: DiarizerModels.defaultModelsDirectory().deletingLastPathComponent(),
                computeUnits: .cpuAndNeuralEngine
            )
            guard let model = models[ModelNames.Diarizer.embeddingFile],
                  let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue,
                  (1...4096).contains(maskFrames)
            else { throw MeetAIEmbeddingError.unsupportedModel }
            let extractor = EmbeddingExtractor(embeddingModel: model)
            let mask = [Float](repeating: 1, count: maskFrames)
            var embeddings: [[Float]] = []
            for clip in clips {
                try Task.checkCancellation()
                if let embedding = try extractor.getEmbeddings(audio: clip, masks: [mask]).first,
                   embedding.count == 256, embedding.allSatisfy(\.isFinite)
                {
                    embeddings.append(embedding)
                }
            }
            return embeddings
        }
    }
}

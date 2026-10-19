import Foundation

/// Explicit temporary compatibility path (plan §6: "A may wrap the existing final times as an
/// explicit temporary compatibility path").
///
/// It runs the unchanged in-pipeline workflow — the same `SpeakerDiarizationService` passes, echo
/// policy, near-field gate, "You" election, checkpoint read/write, segment IDs and timestamps — by
/// calling the executor the pipeline injects. It deliberately produces no
/// `MeetingFinalTranscriptEvidence`: mapping the legacy result onto canonical text units requires
/// the analysis manifest and assembler that belong to Stage C, and inventing that mapping now would
/// fabricate per-word timing and provenance the legacy path never computed.
@MainActor
final class MeetingLegacyCompatibilityBackend: MeetingTranscriptionBackend {
    static let descriptor = MeetingBackendDescriptor(
        id: .legacyCompatibility,
        version: "1",
        execution: .local,
        supportedLanguageCodes: ["en"],
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        // Legacy output is already-merged turn text. It carries no word-level final units, so it
        // must never be read as word precision.
        supportedFinalPrecisions: [.utterance],
        resultContract: .legacyResult,
        knownLimits: [
            "Returns the existing MeetingProcessingResult directly; it emits no canonical final text-unit evidence.",
            "Per-word timings, coverage receipts and a disposition ledger are not produced.",
            "Speaker identity keeps the existing prototype-based local-speaker election unchanged.",
        ]
    )

    /// Same workflow as `descriptor`, selected per meeting for Whisper sessions and therefore
    /// accepting every Whisper language instead of English only.
    static let whisperDescriptor = MeetingBackendDescriptor(
        id: .whisperCompatibility,
        version: "1",
        execution: .local,
        supportedLanguageCodes: VoiceEngineLanguageCatalog.whisperSupportedLanguageCodes.union([MeetingTranscriptionEngine.autoLanguageCode]),
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.utterance],
        resultContract: .legacyResult,
        knownLimits: MeetingLegacyCompatibilityBackend.descriptor.knownLimits + [
            "Runs Whisper Large Turbo; no vocabulary boosting. Mixed-language speech is transcribed in the one language chosen for the meeting.",
        ]
    )

    let descriptor: MeetingBackendDescriptor

    private let legacyExecutor: MeetingLegacyBackendExecutor

    init(
        legacyExecutor: @escaping MeetingLegacyBackendExecutor,
        descriptor: MeetingBackendDescriptor = MeetingLegacyCompatibilityBackend.descriptor
    ) {
        self.legacyExecutor = legacyExecutor
        self.descriptor = descriptor
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard self.descriptor.supportedLanguageCodes.contains(request.session.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        let plan = MeetingBackendPlan(request: request, descriptor: self.descriptor)
        guard !plan.trackKindsByID.isEmpty else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.descriptor.id)
        }
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        // The legacy contract receives no manifest: the existing in-pipeline workflow keeps its
        // own timing and mapping, and a second mapper would double-apply the de-drift correction.
        try .legacyCompatibility(await self.legacyExecutor(plan.request, progress))
    }
}

import Combine
import Foundation

@MainActor
protocol MeetAISessionMutating: AnyObject {
    @discardableResult
    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async throws -> MeetingSession
    @discardableResult
    func renameSession(sessionID: MeetingSessionID, to title: String) async throws -> MeetingSession
}

extension MeetingSessionCoordinator: MeetAISessionMutating {}

/// Per-session MeetAI work, serialized per session: speakers → names → title → summary (spec §5.5).
@MainActor
final class MeetAISessionProcessor: ObservableObject {
    struct Dependencies {
        var sidecars: MeetAISidecarStore
        var profiles: MeetAISpeakerProfileStore
        var settings: MeetAISettings
        var embedder: any MeetAISpeakerEmbedding
        var llm: any MeetAILLMCompleting
        var mutator: @MainActor () -> any MeetAISessionMutating
        var loadSession: @MainActor (MeetingSessionID) async throws -> MeetingSession?
        var sessionDirectory: @MainActor (MeetingSessionID) async throws -> URL
        var retryDelay: Duration = .seconds(1)

        static func live() -> Dependencies {
            Dependencies(
                sidecars: .shared,
                profiles: .shared,
                settings: .shared,
                embedder: MeetAIFluidAudioEmbedder(),
                llm: MeetAILLM(),
                mutator: { AppServices.shared.meetingSessionCoordinator },
                loadSession: { try await MeetingSessionStore.shared.load(id: $0) },
                sessionDirectory: { try await MeetingSessionStore.shared.sessionDirectory(for: $0) }
            )
        }
    }

    static let shared = MeetAISessionProcessor(dependencies: .live())
    static let maximumMutationRetries = 10

    @Published private(set) var busySessions: Set<MeetingSessionID> = []
    @Published var summaryErrors: [MeetingSessionID: String] = [:]

    let deps: Dependencies
    private var chains: [MeetingSessionID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: Hook handlers

    /// H1. Awaited (bounded) by the coordinator: only the audio-dependent step runs inline.
    func sessionDidComplete(_ session: MeetingSession) async {
        if self.deps.settings.speakerMatching {
            // Queued so its sidecar read-modify-write cannot race an H6 correction (spec 5.5).
            await self.enqueue(session.id) { await $0.captureEmbeddings(session) }.value
        }
        self.enqueue(session.id) { await $0.runAutomation(sessionID: session.id) }
    }

    /// H6. Never mutates synchronously: the coordinator still holds its mutation gate.
    func sessionCorrected(_ session: MeetingSession) {
        self.enqueue(session.id) { await $0.handleCorrection(sessionID: session.id) }
    }

    // MARK: Queue

    @discardableResult
    func enqueue(_ id: MeetingSessionID, _ work: @escaping @MainActor (MeetAISessionProcessor) async -> Void) -> Task<Void, Never> {
        let previous = self.chains[id]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.busySessions.insert(id)
            await work(self)
            if self.chains[id]?.token == token {
                self.chains[id] = nil
                self.busySessions.remove(id)
            }
        }
        self.chains[id] = (token, task)
        return task
    }

    // MARK: Pipeline

    func runAutomation(sessionID: MeetingSessionID) async {
        guard var session = await self.load(sessionID), session.state == .completed else { return }
        if self.deps.settings.speakerMatching, let updated = await self.applyProfileMatches(session) {
            session = updated
        }
        if self.deps.settings.autoName, let updated = await self.applyLLMNames(session) {
            session = updated
        }
        if let updated = await self.applyTitle(session) {
            session = updated
        }
        if self.deps.settings.autoSummarize {
            await self.generateSummaryIfMissing(session)
        }
    }

    func generateSummaryIfMissing(_ session: MeetingSession) async {
        do {
            guard try await self.deps.sidecars.summary(for: session.id) == nil else { return }
        } catch {
            return
        }
        await self.writeSummary(session, style: self.deps.settings.summaryStyle)
    }

    /// Summary tab's Generate/Regenerate. Runs in the session's queue.
    func regenerateSummary(sessionID: MeetingSessionID, style: MeetAISummaryStyle) async {
        await self.enqueue(sessionID) { processor in
            guard let session = await processor.load(sessionID) else { return }
            await processor.writeSummary(session, style: style)
        }.value
    }

    private func writeSummary(_ session: MeetingSession, style: MeetAISummaryStyle) async {
        do {
            let record = try await MeetAISummarizer.generate(session: session, style: style, llm: self.deps.llm)
            try await self.deps.sidecars.saveSummary(record, for: session.id)
            self.summaryErrors[session.id] = nil
        } catch {
            self.summaryErrors[session.id] = error.localizedDescription
            DebugLogger.shared.warning("MeetAI summary failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func handleCorrection(sessionID: MeetingSessionID) async {
        guard let session = await self.load(sessionID) else { return }
        do {
            let result = MeetAICorrectionDiff.apply(session: session, records: try await self.deps.sidecars.speakers(for: sessionID))
            guard result.changed else { return }
            var records = result.records
            for enrolment in result.enrolments {
                if let profile = self.deps.profiles.enroll(name: enrolment.name, embedding: enrolment.embedding) {
                    records[enrolment.speakerID]?.matchedProfileID = profile.id
                }
            }
            try await self.deps.sidecars.saveSpeakers(records, for: sessionID)
            if result.renamedSpeakers {
                await self.refreshTitleAfterRename(sessionID: sessionID)
            }
        } catch {
            DebugLogger.shared.warning("MeetAI correction handling failed: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    /// An AI-named speaker whose voice can be saved under that name.
    struct ConfirmableSpeaker: Equatable {
        let speakerID: SessionSpeakerID
        let name: String
    }

    /// Speakers still carrying the name the LLM gave them, with a stored voice. Renaming to the same
    /// name is a no-op upstream, so this is the only way to save such a voice.
    func confirmableSpeakers(sessionID: MeetingSessionID) async -> [ConfirmableSpeaker] {
        guard let session = await self.load(sessionID),
              let records = try? await self.deps.sidecars.speakers(for: sessionID) else { return [] }
        return Self.confirmable(session: session, records: records)
    }

    private static func confirmable(session: MeetingSession, records: [SessionSpeakerID: MeetAISpeakerRecord]) -> [ConfirmableSpeaker] {
        session.activeSpeakers.compactMap { speaker in
            let name = speaker.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isLocalUser, let record = records[speaker.id],
                  record.nameSource == .llm, record.embedding != nil,
                  name == record.lastAppliedName, !MeetAITranscript.isDefaultSpeakerName(name)
            else { return nil }
            return ConfirmableSpeaker(speakerID: speaker.id, name: name)
        }
    }

    /// Enrols the speaker's stored voice under its current AI-assigned name and marks the name as the
    /// user's. Runs in the session's queue. False when the speaker is no longer confirmable.
    func confirmSpeakerName(sessionID: MeetingSessionID, speakerID: SessionSpeakerID) async -> Bool {
        var saved = false
        await self.enqueue(sessionID) { processor in
            guard let session = await processor.load(sessionID) else { return }
            do {
                var records = try await processor.deps.sidecars.speakers(for: sessionID)
                guard let candidate = Self.confirmable(session: session, records: records).first(where: { $0.speakerID == speakerID }),
                      let embedding = records[speakerID]?.embedding,
                      let profile = processor.deps.profiles.enroll(name: candidate.name, embedding: embedding)
                else { return }
                records[speakerID]?.matchedProfileID = profile.id
                records[speakerID]?.nameSource = .user
                try await processor.deps.sidecars.saveSpeakers(records, for: sessionID)
                saved = true
            } catch {
                DebugLogger.shared.warning("MeetAI couldn't save the speaker's voice: \(error.localizedDescription)", source: "MeetAI")
            }
        }.value
        return saved
    }

    func captureEmbeddings(_ session: MeetingSession) async {
        do {
            let directory = try await self.deps.sessionDirectory(session.id)
            var records = try await self.deps.sidecars.speakers(for: session.id)
            for speaker in session.activeSpeakers where !speaker.isLocalUser {
                let turns = MeetAICleanTurns.select(for: speaker.id, in: session)
                guard !turns.isEmpty,
                      let embedding = try await self.deps.embedder.embedding(for: turns, session: session, sessionDirectory: directory)
                else { continue }
                records[speaker.id, default: MeetAISpeakerRecord()].embedding = embedding
            }
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
        } catch {
            DebugLogger.shared.warning("MeetAI speaker embeddings skipped: \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func applyProfileMatches(_ session: MeetingSession) async -> MeetingSession? {
        do {
            let records = try await self.deps.sidecars.speakers(for: session.id)
            let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: self.deps.profiles.profiles)
            var proposals: [SessionSpeakerID: NameProposal] = [:]
            for decision in decisions {
                let name = decision.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                proposals[decision.speakerID] = NameProposal(name: name, expectedLabel: nil, source: .profile, profileID: decision.profile.id)
            }
            guard !proposals.isEmpty else { return nil }
            return try await self.applyNames(sessionID: session.id, proposals: proposals)
        } catch {
            DebugLogger.shared.warning("MeetAI profile matching failed: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    /// A rename MeetAI wants to make. It stays valid only while the speaker still carries
    /// `expectedLabel` (or, when nil, any default label): a user rename in between wins (spec §5.3).
    struct NameProposal {
        let name: String
        let expectedLabel: String?
        let source: MeetAINameSource
        let profileID: String?
    }

    /// Re-reads the session on every attempt and drops proposals whose speaker the user renamed
    /// meanwhile. Records are written immediately before the rename (so its H6 echo is recognised as
    /// MeetAI's own) and rolled back if the rename throws.
    func applyNames(sessionID: MeetingSessionID, proposals: [SessionSpeakerID: NameProposal]) async throws -> MeetingSession? {
        try await self.mutate { mutator in
            guard let current = try await self.deps.loadSession(sessionID) else { return nil }
            var names: [SessionSpeakerID: String] = [:]
            for speaker in current.activeSpeakers where !speaker.isLocalUser {
                guard let proposal = proposals[speaker.id] else { continue }
                let stillOurs = proposal.expectedLabel.map { $0 == speaker.displayName }
                    ?? MeetAITranscript.isDefaultSpeakerName(speaker.displayName)
                if stillOurs { names[speaker.id] = proposal.name }
            }
            let taken = Set(current.activeSpeakers.filter { names[$0.id] == nil }.map { $0.displayName.lowercased() })
            names = names.filter { !taken.contains($0.value.lowercased()) }
            guard !names.isEmpty else { return nil }

            let previous = try await self.deps.sidecars.speakers(for: sessionID)
            var records = previous
            for (id, name) in names {
                guard let proposal = proposals[id] else { continue }
                if let profileID = proposal.profileID {
                    records[id, default: MeetAISpeakerRecord()].matchedProfileID = profileID
                }
                records[id, default: MeetAISpeakerRecord()].nameSource = proposal.source
                records[id, default: MeetAISpeakerRecord()].lastAppliedName = name
            }
            try await self.deps.sidecars.saveSpeakers(records, for: sessionID)
            do {
                return try await mutator.renameSpeakers(sessionID: sessionID, names: names)
            } catch {
                await self.rollBack("speaker records") { try await self.deps.sidecars.saveSpeakers(previous, for: sessionID) }
                throw error
            }
        }
    }

    // MARK: Helpers

    func applyLLMNames(_ session: MeetingSession) async -> MeetingSession? {
        let candidates = session.activeSpeakers.filter { !$0.isLocalUser && MeetAITranscript.isDefaultSpeakerName($0.displayName) }
        guard !candidates.isEmpty, !MeetAITranscript.turns(for: session).isEmpty else { return nil }
        let labels = Set(candidates.map(\.displayName))
        let taken = Set(session.activeSpeakers.filter { !labels.contains($0.displayName) }.map { $0.displayName.lowercased() })
        do {
            let reply = try await self.deps.llm.completeAboutTranscript(
                transcript: MeetAITranscript.text(for: session),
                turns: [MeetAILLMTurn(role: "user", content: "Return the speaker-name JSON.")],
                systemPrompt: MeetAISpeakerNamer.systemPrompt(labels: labels.sorted(), localLabel: MeetAITranscript.localUserLabel(in: session))
            )
            let parsed = MeetAISpeakerNamer.parseNameMap(from: reply, validLabels: labels)
            let counts = Dictionary(grouping: parsed.values, by: { $0.lowercased() }).mapValues(\.count)
            let map = parsed.filter { counts[$0.value.lowercased()] == 1 && !taken.contains($0.value.lowercased()) }
            var proposals: [SessionSpeakerID: NameProposal] = [:]
            for speaker in candidates {
                guard let name = map[speaker.displayName] else { continue }
                proposals[speaker.id] = NameProposal(name: name, expectedLabel: speaker.displayName, source: .llm, profileID: nil)
            }
            guard !proposals.isEmpty else { return nil }
            return try await self.applyNames(sessionID: session.id, proposals: proposals)
        } catch {
            DebugLogger.shared.warning("MeetAI speaker naming skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    func applyTitle(_ session: MeetingSession) async -> MeetingSession? {
        do {
            guard try await self.ownsTitleElseMarkUser(session) else { return nil }
            guard !MeetAITranscript.turns(for: session).isEmpty else { return nil }
            let context = String(MeetAITranscript.text(for: session).prefix(4_000))
            let raw = try await self.deps.llm.complete(systemPrompt: MeetAITitler.systemPrompt, turns: [MeetAILLMTurn(role: "user", content: context)])
            guard let title = MeetAITitler.clean(raw) else { return nil }
            // The LLM call can take minutes: re-check ownership on the current session on every attempt.
            return try await self.mutate { mutator in
                guard let current = try await self.deps.loadSession(session.id),
                      try await self.ownsTitleElseMarkUser(current),
                      title != current.title
                else { return nil }
                let previous = try await self.deps.sidecars.meta(for: session.id)
                var meta = previous
                meta.titleSource = .llm
                meta.lastLLMTitle = title
                try await self.deps.sidecars.saveMeta(meta, for: session.id)
                do {
                    return try await mutator.renameSession(sessionID: session.id, to: title)
                } catch {
                    await self.rollBack("title meta") { try await self.deps.sidecars.saveMeta(previous, for: session.id) }
                    throw error
                }
            }
        } catch {
            DebugLogger.shared.warning("MeetAI title skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    /// False (and the title recorded as the user's) once the user has edited it (spec §6.3).
    private func ownsTitleElseMarkUser(_ session: MeetingSession) async throws -> Bool {
        var meta = try await self.deps.sidecars.meta(for: session.id)
        guard !MeetAITitler.ownsTitle(session: session, meta: meta) else { return true }
        if meta.titleSource != .user {
            meta.titleSource = .user
            try await self.deps.sidecars.saveMeta(meta, for: session.id)
        }
        return false
    }

    private func rollBack(_ what: String, _ restore: () async throws -> Void) async {
        do {
            try await restore()
        } catch {
            DebugLogger.shared.warning("MeetAI could not roll back \(what): \(error.localizedDescription)", source: "MeetAI")
        }
    }

    func refreshTitleAfterRename(sessionID: MeetingSessionID) async {
        guard let session = await self.load(sessionID) else { return }
        _ = await self.applyTitle(session)
    }

    func load(_ id: MeetingSessionID) async -> MeetingSession? {
        do { return try await self.deps.loadSession(id) } catch { return nil }
    }

    /// Retries while the coordinator is busy; any other error (e.g. a deleted session) propagates.
    func mutate<T>(_ body: @MainActor (any MeetAISessionMutating) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body(self.deps.mutator())
            } catch let error as MeetingCoordinatorError
                where (error == .activityInProgress || error == .maintenanceInProgress) && attempt < Self.maximumMutationRetries
            {
                attempt += 1
                try await Task.sleep(for: self.deps.retryDelay)
            }
        }
    }
}

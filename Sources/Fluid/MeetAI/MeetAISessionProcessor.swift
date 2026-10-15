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
            var records = try await self.deps.sidecars.speakers(for: session.id)
            let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: self.deps.profiles.profiles)
            guard !decisions.isEmpty else { return nil }
            for decision in decisions {
                records[decision.speakerID, default: MeetAISpeakerRecord()].matchedProfileID = decision.profile.id
                records[decision.speakerID, default: MeetAISpeakerRecord()].nameSource = .profile
                records[decision.speakerID, default: MeetAISpeakerRecord()].lastAppliedName = decision.profile.name
            }
            // Saved before renaming so the H6 echo of this rename is recognised as MeetAI's own.
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
            let names = Dictionary(uniqueKeysWithValues: decisions.map { ($0.speakerID, $0.profile.name) })
            return try await self.mutate { try await $0.renameSpeakers(sessionID: session.id, names: names) }
        } catch {
            DebugLogger.shared.warning("MeetAI profile matching failed: \(error.localizedDescription)", source: "MeetAI")
            return nil
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
            guard !map.isEmpty else { return nil }
            var records = try await self.deps.sidecars.speakers(for: session.id)
            var names: [SessionSpeakerID: String] = [:]
            for speaker in candidates {
                guard let name = map[speaker.displayName] else { continue }
                names[speaker.id] = name
                records[speaker.id, default: MeetAISpeakerRecord()].nameSource = .llm
                records[speaker.id, default: MeetAISpeakerRecord()].lastAppliedName = name
            }
            try await self.deps.sidecars.saveSpeakers(records, for: session.id)
            return try await self.mutate { try await $0.renameSpeakers(sessionID: session.id, names: names) }
        } catch {
            DebugLogger.shared.warning("MeetAI speaker naming skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
        }
    }

    func applyTitle(_ session: MeetingSession) async -> MeetingSession? {
        do {
            var meta = try await self.deps.sidecars.meta(for: session.id)
            guard MeetAITitler.ownsTitle(session: session, meta: meta) else {
                if meta.titleSource != .user {
                    meta.titleSource = .user
                    try await self.deps.sidecars.saveMeta(meta, for: session.id)
                }
                return nil
            }
            guard !MeetAITranscript.turns(for: session).isEmpty else { return nil }
            let context = String(MeetAITranscript.text(for: session).prefix(4_000))
            let raw = try await self.deps.llm.complete(systemPrompt: MeetAITitler.systemPrompt, turns: [MeetAILLMTurn(role: "user", content: context)])
            guard let title = MeetAITitler.clean(raw), title != session.title else { return nil }
            meta.titleSource = .llm
            meta.lastLLMTitle = title
            try await self.deps.sidecars.saveMeta(meta, for: session.id)
            return try await self.mutate { try await $0.renameSession(sessionID: session.id, to: title) }
        } catch {
            DebugLogger.shared.warning("MeetAI title skipped: \(error.localizedDescription)", source: "MeetAI")
            return nil
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
    func mutate(_ body: @MainActor (any MeetAISessionMutating) async throws -> MeetingSession) async throws -> MeetingSession {
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

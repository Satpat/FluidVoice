@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MeetAISpeakerTests: XCTestCase {
    private func vector(_ seed: Float, dims: Int = 256) -> [Float] {
        MeetAISpeakerMath.normalize((0..<dims).map { sin(Float($0) * seed) })
    }

    // MARK: Math

    func testCentroidIsNormalisedMean() throws {
        let c = try XCTUnwrap(MeetAISpeakerMath.centroid([[1, 0], [0, 1]]))
        XCTAssertEqual(c[0], c[1], accuracy: 1e-5)
        XCTAssertEqual(MeetAISpeakerMath.dot(c, c), 1, accuracy: 1e-5)
        XCTAssertNil(MeetAISpeakerMath.centroid([]))
        XCTAssertEqual(MeetAISpeakerMath.dot([1, 0], [1, 0, 0]), -1)
    }

    // MARK: Profile store

    func testEnrollUpdatesByNameAndPersistsForkFormat() throws {
        let file = try MeetAIFixtures.tempDirectory(self).appendingPathComponent("SpeakerProfiles/profiles.json")
        let store = MeetAISpeakerProfileStore(fileURL: file)
        let first = try XCTUnwrap(store.enroll(name: "Sam", embedding: self.vector(0.1)))
        let second = try XCTUnwrap(store.enroll(name: " sam ", embedding: self.vector(0.12)))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].sampleCount, 2)
        let reloaded = MeetAISpeakerProfileStore(fileURL: file)
        XCTAssertEqual(reloaded.profiles, store.profiles)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"sampleCount\""))
    }

    func testEnrollRejectsInvalidInputWithoutChange() throws {
        let file = try MeetAIFixtures.tempDirectory(self).appendingPathComponent("profiles.json")
        let store = MeetAISpeakerProfileStore(fileURL: file)
        let original = try XCTUnwrap(store.enroll(name: "Sam", embedding: self.vector(0.1)))
        XCTAssertNil(store.enroll(name: "  ", embedding: self.vector(0.1)))
        XCTAssertNil(store.enroll(name: "Sam", embedding: []))
        XCTAssertNil(store.enroll(name: "Sam", embedding: self.vector(0.1, dims: 128)))
        XCTAssertNil(store.enroll(name: "New", embedding: self.vector(0.1, dims: 128)))
        var nonFinite = self.vector(0.1)
        nonFinite[3] = .nan
        XCTAssertNil(store.enroll(name: "Sam", embedding: nonFinite))
        XCTAssertEqual(store.profiles, [original])
    }

    func testCorruptProfilesFileIsMovedAsideNotOverwritten() throws {
        let dir = try MeetAIFixtures.tempDirectory(self)
        let file = dir.appendingPathComponent("profiles.json")
        let junk = Data("{ not json".utf8)
        try junk.write(to: file)
        let store = MeetAISpeakerProfileStore(fileURL: file)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("profiles.json.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), junk)
    }

    func testUnreadableProfilesThatCannotBeMovedAsideAreNeverOverwritten() throws {
        let dir = try MeetAIFixtures.tempDirectory(self)
        let file = dir.appendingPathComponent("profiles.json")
        let junk = Data("{ not json".utf8)
        try junk.write(to: file)
        struct MoveFailed: Error {}
        let store = MeetAISpeakerProfileStore(fileURL: file, moveAside: { _, _ in throw MoveFailed() })
        XCTAssertTrue(store.saveBlocked)
        _ = store.enroll(name: "Sam", embedding: self.vector(0.1))
        XCTAssertEqual(try Data(contentsOf: file), junk, "save is a no-op while blocked")
    }

    func testCopyLegacyProfilesOnlyWhenMissing() throws {
        let root = try MeetAIFixtures.tempDirectory(self)
        let legacy = root.appendingPathComponent("legacy.json")
        let legacyStore = MeetAISpeakerProfileStore(fileURL: legacy)
        _ = legacyStore.enroll(name: "Girish", embedding: self.vector(0.3))
        let store = MeetAISpeakerProfileStore(fileURL: root.appendingPathComponent("MeetAI/profiles.json"))
        XCTAssertTrue(store.copyLegacyProfilesIfNeeded(from: legacy))
        XCTAssertEqual(store.profiles.map(\.name), ["Girish"])
        XCTAssertFalse(store.copyLegacyProfilesIfNeeded(from: legacy), "second copy must not overwrite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "legacy file is copied, not moved")
    }

    // MARK: Clean turns

    func testCleanTurnsPickLongestAdmissibleTurnsUpToThirtySeconds() {
        var session = MeetAIFixtures.session(
            speakers: [("You", true), ("Speaker 1", false)],
            lines: [
                .init(speaker: 1, start: 0, end: 1, text: "too short"),
                .init(speaker: 1, start: 1, end: 13, text: "twelve"),
                .init(speaker: 1, start: 13, end: 33, text: "twenty"),
                .init(speaker: 1, start: 33, end: 41, text: "eight"),
                .init(speaker: 1, start: 41, end: 51, text: "echo"),
                .init(speaker: 0, start: 51, end: 70, text: "local"),
            ]
        )
        session.transcriptSegments[4].isLikelyEcho = true
        let picked = MeetAICleanTurns.select(for: session.speakers[1].id, in: session)
        XCTAssertEqual(picked.map(\.text), ["twenty", "twelve"])
    }

    func testCleanTurnsSkipSpeakerWithUnderThreeSeconds() {
        let session = MeetAIFixtures.session(
            speakers: [("Speaker 1", false)],
            lines: [.init(speaker: 0, start: 0, end: 2, text: "short")]
        )
        XCTAssertTrue(MeetAICleanTurns.select(for: session.speakers[0].id, in: session).isEmpty)
    }

    // MARK: Matching

    func testMatchRenamesOnlyDefaultLabelsAboveThreshold() {
        let session = MeetAIFixtures.session(speakers: [("You", true), ("Speaker 1", false), ("Speaker 2", false), ("Alex", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [
            session.speakers[1].id: .init(embedding: self.vector(0.1)),
            session.speakers[2].id: .init(embedding: self.vector(0.9)),
            session.speakers[3].id: .init(embedding: self.vector(0.1)),
            session.speakers[0].id: .init(embedding: self.vector(0.1)),
        ]
        let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam])
        XCTAssertEqual(decisions.map(\.speakerID), [session.speakers[1].id])
    }

    func testSameProfileGoesToBestSpeakerOnly() {
        let session = MeetAIFixtures.session(speakers: [("Speaker 1", false), ("Speaker 2", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [
            session.speakers[0].id: .init(embedding: self.vector(0.1)),
            session.speakers[1].id: .init(embedding: MeetAISpeakerMath.normalize(zip(self.vector(0.1), self.vector(0.11)).map { $0 + $1 })),
        ]
        let decisions = MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam])
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.speakerID, session.speakers[0].id)
    }

    func testNoMatchWhenProfileNameAlreadyUsedInSession() {
        let session = MeetAIFixtures.session(speakers: [("Speaker 1", false), ("Sam", false)], lines: [])
        let sam = MeetAISpeakerProfile(name: "Sam", embedding: self.vector(0.1))
        let records: [SessionSpeakerID: MeetAISpeakerRecord] = [session.speakers[0].id: .init(embedding: self.vector(0.1))]
        XCTAssertTrue(MeetAIProfileMatching.decide(session: session, records: records, profiles: [sam]).isEmpty)
    }
}

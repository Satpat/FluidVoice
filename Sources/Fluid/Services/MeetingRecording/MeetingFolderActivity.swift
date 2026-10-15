// Tracks which meeting session folders have a write in flight.
//
// Three independent entry points read/write the same transcript.md /
// summary.md / speakers.json for a folder: MeetingTranscriptPipeline.process()
// (full re-transcribe), MeetingTranscriptPipeline.regenerateSummary(), and
// MeetingRelabeler.relabel(). Without a shared lock, two of them running
// concurrently against the same folder race to write those files. A shared
// singleton (rather than per-view @State) also means the busy flag survives
// SwiftUI view recreation — e.g. sidebar navigation recreating MeetingsView —
// instead of resetting and re-enabling a button mid-operation.

import Combine
import Foundation

@MainActor
final class MeetingFolderActivity: ObservableObject {
    static let shared = MeetingFolderActivity()

    private init() {}

    @Published private(set) var busyFolders: Set<String> = []

    /// Claim `folderName` for an operation. Returns false if another
    /// operation already holds it — callers should treat that as "already in
    /// progress" and bail rather than proceeding.
    @discardableResult
    func begin(_ folderName: String) -> Bool {
        guard !self.busyFolders.contains(folderName) else { return false }
        self.busyFolders.insert(folderName)
        return true
    }

    func end(_ folderName: String) {
        self.busyFolders.remove(folderName)
    }

    func isBusy(_ folderName: String) -> Bool {
        self.busyFolders.contains(folderName)
    }
}

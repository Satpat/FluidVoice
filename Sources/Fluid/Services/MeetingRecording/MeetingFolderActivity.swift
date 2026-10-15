// Tracks which meeting session folders have a write in flight, and what kind.
//
// Three independent entry points read/write the same transcript.md /
// summary.md / speakers.json for a folder: MeetingTranscriptPipeline.process()
// (transcribe / re-transcribe), MeetingTranscriptPipeline.regenerateSummary(),
// and MeetingRelabeler.relabel(). Without a shared lock, two of them running
// concurrently against the same folder race to write those files. A shared
// singleton (rather than per-view @State) also means the busy state survives
// SwiftUI view recreation — e.g. sidebar navigation recreating MeetingsView —
// instead of resetting and re-enabling a button mid-operation, and lets every
// meeting row show its own operation's progress label.

import Combine
import Foundation

@MainActor
final class MeetingFolderActivity: ObservableObject {
    static let shared = MeetingFolderActivity()

    enum Operation: Equatable {
        case transcribing
        case summarizing
        case relabeling

        var progressLabel: String {
            switch self {
            case .transcribing: return "Transcribing..."
            case .summarizing: return "Summarising (\(MeetingSummaryStyle.current.displayName))..."
            case .relabeling: return "Applying speaker names..."
            }
        }
    }

    private init() {}

    @Published private(set) var busy: [String: Operation] = [:]

    /// Claim `folderName` for `operation`. Returns false if another
    /// operation already holds it — callers should treat that as "already in
    /// progress" and bail rather than proceeding.
    @discardableResult
    func begin(_ folderName: String, _ operation: Operation) -> Bool {
        guard self.busy[folderName] == nil else { return false }
        self.busy[folderName] = operation
        return true
    }

    func end(_ folderName: String) {
        self.busy[folderName] = nil
    }

    func isBusy(_ folderName: String) -> Bool {
        self.busy[folderName] != nil
    }

    func operation(for folderName: String) -> Operation? {
        self.busy[folderName]
    }
}

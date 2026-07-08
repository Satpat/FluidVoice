import Foundation

/// Locators for the output files a meeting produces in its session folder.
enum MeetingFiles {
    static func transcriptURL(inFolder folder: URL) -> URL? {
        Self.existing(folder.appendingPathComponent("transcript.md"))
    }

    static func summaryURL(inFolder folder: URL) -> URL? {
        Self.existing(folder.appendingPathComponent("summary.md"))
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

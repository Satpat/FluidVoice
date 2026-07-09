import Foundation

/// Locators for the output files a meeting produces in its session folder.
enum MeetingFiles {
    static func transcriptURL(inFolder folder: URL) -> URL? {
        Self.existing(folder.appendingPathComponent("transcript.md"))
    }

    static func summaryURL(inFolder folder: URL) -> URL? {
        Self.existing(folder.appendingPathComponent("summary.md"))
    }

    /// Friendly display name written by the pipeline ("Title (friendly date)").
    static func title(inFolder folder: URL) -> String? {
        guard let url = Self.existing(folder.appendingPathComponent("title.txt")),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Per-meeting speaker voice centroids written by the pipeline
    /// (label -> embedding), used for manual naming/enrolment.
    static func speakerEmbeddings(inFolder folder: URL) -> [String: [Float]] {
        let url = folder.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]]
        else { return [:] }
        return raw.mapValues { $0.map(Float.init) }
    }
}

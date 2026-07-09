// In-place speaker relabelling, modelled on MeetAI's apply_speaker_name_map:
// apply a {old label -> new name} map to an already-processed meeting without
// re-running transcription/diarization. Rewrites transcript.md, the history
// entry, speakers.json, and regenerates the summary from the relabelled text.

import Foundation

@MainActor
enum MeetingRelabeler {
    /// Apply `map` (old label -> new name) to the meeting in `folder`.
    /// Returns true if anything changed.
    @discardableResult
    static func relabel(folder: URL, historyEntryID: UUID?, map: [String: String]) async -> Bool {
        let clean = map.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
        guard !clean.isEmpty else { return false }

        // 1) transcript.md — replace the "] <label>:" token on each line.
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        var relabelledTranscript: String?
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let updated = Self.applyToTranscript(text, map: clean)
            try? updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
            relabelledTranscript = updated
        }

        // 2) history entry text (the "[MM:SS] Label: ..." merged transcript).
        if let id = historyEntryID,
           let entry = FileTranscriptionHistoryStore.shared.entries.first(where: { $0.id == id }) {
            let updated = Self.applyToTranscript(entry.text, map: clean)
            FileTranscriptionHistoryStore.shared.updateEntryText(id: id, newText: updated)
        }

        // 3) speakers.json — rename keys so relabelled speakers are no longer
        //    offered for naming, and future lookups use the name.
        let speakersURL = folder.appendingPathComponent("speakers.json")
        if let data = try? Data(contentsOf: speakersURL),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (old, new) in clean where obj[old] != nil {
                obj[new] = obj[old]
                obj.removeValue(forKey: old)
            }
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: speakersURL, options: .atomic)
            }
        }

        // 4) regenerate the summary from the relabelled transcript so names are
        //    reflected there too, then the title from that summary (best-effort).
        if let mergedText = relabelledTranscript ?? (try? String(contentsOf: transcriptURL, encoding: .utf8)),
           let body = try? await MeetingTranscriptPipeline.generateSummaryBody(mergedText: Self.plainTranscript(mergedText)) {
            try? MeetingTranscriptPipeline.writeSummary(body: body, displayName: folder.lastPathComponent, folder: folder)

            let startedAt = ISO8601DateFormatter.meetingFileSafe.date(from: folder.lastPathComponent)
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date()
            let title = await MeetingTranscriptPipeline.generateTitleLine(context: body, startedAt: startedAt)
            MeetingTranscriptPipeline.writeTitle(title, folder: folder)
        }

        return true
    }

    /// Replace speaker labels appearing as `Label:` after a timestamp bracket,
    /// e.g. "[00:12] Them 1: hi" or "**[00:12] Them 1:** hi". Only the label
    /// token is replaced, never body text, and longer labels are applied first
    /// so "Them 1" is matched before "Them".
    private static func applyToTranscript(_ text: String, map: [String: String]) -> String {
        let ordered = map.sorted { $0.key.count > $1.key.count }
        let lines = text.components(separatedBy: "\n")
        let updated = lines.map { line -> String in
            for (old, new) in ordered {
                for token in ["] \(old):", "] \(old):**"] {
                    if let range = line.range(of: token) {
                        return line.replacingCharacters(in: range, with: token.replacingOccurrences(of: old, with: new))
                    }
                }
            }
            return line
        }
        return updated.joined(separator: "\n")
    }

    /// Strip Markdown header/bold so the summary model sees plain lines.
    private static func plainTranscript(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { $0.contains("]") && $0.contains(":") }
            .map { $0.replacingOccurrences(of: "**", with: "") }
            .joined(separator: "\n")
    }
}

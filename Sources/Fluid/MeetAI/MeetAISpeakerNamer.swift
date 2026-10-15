import Foundation

nonisolated enum MeetAISpeakerNamer {
    static func systemPrompt(labels: [String], localLabel: String) -> (String) -> String {
        let labelList = labels.joined(separator: ", ")
        return { transcript in
            """
            You identify speakers in a meeting transcript. The local user is labelled "\(localLabel)". \
            The other speakers have provisional labels: \(labelList).

            Determine the real first name of each provisional label ONLY when the transcript \
            clearly evidences it — for example the speaker introduces themselves ("I'm Sarah", \
            "this is John speaking"). IMPORTANT: a name a speaker uses while talking TO someone \
            (direct address, e.g. "thanks, Sam" or "what do you think, Sam?") identifies the \
            LISTENER, not the speaker — never assign such a name to the speaker's own label. \
            Since "\(localLabel)" is usually the person being addressed by the others, names they use in \
            direct address most likely belong to "\(localLabel)" and must NOT be assigned to any label. \
            Do NOT guess, and do NOT infer a name from topic or context. If a label's name is \
            not clearly evidenced, use null.

            Respond with ONLY a JSON object mapping each provisional label to a name string or null, e.g.:
            {"\(labels.first ?? "Speaker 1")": "Sarah"}

            Transcript:
            \(transcript)
            """
        }
    }

    /// `{label: name}` from the model's reply, keeping only valid labels with real names.
    static func parseNameMap(from response: String, validLabels: Set<String>) -> [String: String] {
        guard let range = self.firstJSONObjectRange(in: response),
              let data = String(response[range]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (label, value) in raw {
            guard validLabels.contains(label), let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "null", trimmed != label,
                  !MeetAITranscript.isDefaultSpeakerName(trimmed)
            else { continue }
            map[label] = trimmed
        }
        return map
    }

    private static func firstJSONObjectRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

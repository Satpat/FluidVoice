// Automatic speaker names from the transcript.
//
// Inspired by the MeetAI Python pipeline's rename_speakers step, which applies
// a {label -> name} map to every segment. MeetAI sources that map from
// enrolled voice profiles (ECAPA embeddings); here we source it from the
// transcript itself via the configured LLM — assigning a real name to a
// speaker label only when the transcript clearly evidences it (someone
// introduces themselves, or is unambiguously addressed by name).

import Foundation

enum MeetingSpeakerNamer {
    struct Result {
        var segments: [MeetingSegment]
        /// Original label -> discovered real name, for enrolling voice profiles.
        var appliedMap: [String: String]
    }

    /// Return `segments` with speaker labels replaced by real names where the
    /// transcript supports it, plus the applied {label -> name} map. Best-effort:
    /// any failure returns the input unchanged. "Me" is never renamed, and
    /// labels already resolved to a real name (via a voice profile) are left as
    /// is — only provisional "Them"/"Them N" labels are candidates.
    static func nameSpeakers(in segments: [MeetingSegment]) async -> Result {
        let systemLabel = MeetingTranscriptPipeline.systemSpeakerLabel
        let labels = Set(segments.map(\.speaker))
            .subtracting([MeetingTranscriptPipeline.micSpeakerLabel])
            .filter { $0 == systemLabel || $0.hasPrefix("\(systemLabel) ") } // only provisional labels
        guard !labels.isEmpty else { return Result(segments: segments, appliedMap: [:]) }

        let transcript = segments
            .map { "[\(MeetingTranscriptPipeline.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")

        let labelList = labels.sorted().joined(separator: ", ")
        let systemPrompt = { (transcript: String) in
            """
            You label speakers in a meeting transcript. The current speaker labels are: \
            \(labelList) (plus "Me", the app user, which you must never rename).

            Determine the real first name of each labelled speaker ONLY when the transcript \
            clearly evidences it — for example the speaker introduces themselves ("I'm Sarah", \
            "this is John speaking"). IMPORTANT: a name a speaker uses while talking TO someone \
            (direct address, e.g. "thanks, Sam" or "what do you think, Sam?") identifies the \
            LISTENER, not the speaker — never assign such a name to the speaker's own label. \
            Since "Me" is usually the person being addressed by the others, names they use in \
            direct address most likely belong to "Me" and must NOT be assigned to any label. \
            Do NOT guess, and do NOT infer a name from topic or context. If a label's name is \
            not clearly evidenced, use null.

            Respond with ONLY a JSON object mapping each label to a name string or null, e.g.:
            {"Them 1": "Sarah", "Them 2": null}

            Transcript:
            \(transcript)
            """
        }

        let response: String
        do {
            response = try await MeetingAIClient.completeAboutTranscript(
                transcript: transcript,
                turns: [MeetingAIClient.Turn(role: "user", content: "Return the speaker-name JSON.")],
                systemPrompt: systemPrompt
            )
        } catch {
            DebugLogger.shared.warning(
                "Speaker naming skipped: \(error.localizedDescription)",
                source: "MeetingSpeakerNamer"
            )
            return Result(segments: segments, appliedMap: [:])
        }

        let nameMap = Self.parseNameMap(from: response, validLabels: labels)
        guard !nameMap.isEmpty else { return Result(segments: segments, appliedMap: [:]) }

        DebugLogger.shared.info(
            "Speaker names from transcript: \(nameMap)",
            source: "MeetingSpeakerNamer"
        )

        // Apply the map (MeetAI rename_speakers pattern).
        let renamed = segments.map { segment -> MeetingSegment in
            guard let name = nameMap[segment.speaker] else { return segment }
            return MeetingSegment(start: segment.start, end: segment.end, speaker: name, text: segment.text)
        }
        return Result(segments: renamed, appliedMap: nameMap)
    }

    /// Extract a {label: name} map from the model's JSON reply, keeping only
    /// valid labels with non-empty string names.
    static func parseNameMap(from response: String, validLabels: Set<String>) -> [String: String] {
        guard let jsonRange = Self.firstJSONObjectRange(in: response),
              let data = String(response[jsonRange]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var map: [String: String] = [:]
        for (label, value) in raw {
            guard validLabels.contains(label), let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty, null-ish, or names that just echo the label.
            guard !trimmed.isEmpty,
                  trimmed.lowercased() != "null",
                  trimmed != label
            else { continue }
            map[label] = trimmed
        }
        return map
    }

    /// Range of the first balanced `{ ... }` block, tolerating code fences or
    /// prose around the JSON.
    private static func firstJSONObjectRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return start..<text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

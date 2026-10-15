import Combine
import Foundation

@MainActor
final class MeetAISettings: ObservableObject {
    static let shared = MeetAISettings(defaults: .standard)

    enum Key {
        static let autoSummarize = "MeetAIAutoSummarize"
        static let summaryStyle = "MeetAISummaryStyle"
        static let autoName = "MeetAIAutoName"
        static let speakerMatching = "MeetAISpeakerMatching"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var autoSummarize: Bool {
        get { self.bool(Key.autoSummarize) }
        set { self.set(newValue, Key.autoSummarize) }
    }

    var autoName: Bool {
        get { self.bool(Key.autoName) }
        set { self.set(newValue, Key.autoName) }
    }

    var speakerMatching: Bool {
        get { self.bool(Key.speakerMatching) }
        set { self.set(newValue, Key.speakerMatching) }
    }

    private func bool(_ key: String) -> Bool {
        (self.defaults.object(forKey: key) as? Bool) ?? true
    }

    private func set(_ value: Bool, _ key: String) {
        self.objectWillChange.send()
        self.defaults.set(value, forKey: key)
    }
}

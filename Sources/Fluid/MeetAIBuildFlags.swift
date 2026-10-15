import Foundation

/// Build-level switches for the MeetAI fork of FluidVoice.
enum MeetAIBuildFlags {
    /// The updater installs upstream altic-dev release builds over the running app, which would
    /// replace this fork's binary. Disabled in the app; update by merging upstream into the fork.
    /// Enabled only when hosted by XCTest so upstream's updater tests still exercise the real code.
    static var updaterEnabled: Bool {
        self.updaterEnabled(isTestHost: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }

    static func updaterEnabled(isTestHost: Bool) -> Bool {
        isTestHost
    }
}

import Foundation

/// Build-level switches for the MeetAI v2 fork of FluidVoice.
enum MeetAIBuildFlags {
    /// The updater installs upstream altic-dev/Fluid-oss release builds over the
    /// running app, which would replace this fork's binary. Keep disabled; update
    /// by pulling upstream into the meetai-v2 branch and rebuilding instead.
    static let updaterEnabled = false
}

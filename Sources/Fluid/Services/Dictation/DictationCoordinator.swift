import AppKit
import Combine
import Foundation

/// Owns the dictation runtime: recording-session state, the start → transcribe
/// → AI → format → type flow, the command/rewrite voice routes, history actions
/// and (from P3) the global hotkey manager. Previously all of this lived inside
/// ContentView, a SwiftUI view. Created lazily by AppServices; ContentView only
/// binds UI to it.
@MainActor
final class DictationCoordinator: ObservableObject {
    enum ActiveRecordingMode: String {
        case none
        case dictate
        case promptMode
        case edit
        case command
    }

    enum DictationOutputRoute: String {
        case normal
        case onboardingSandbox
    }

    /// The only couplings to view state the flow needs. Installed by
    /// ContentView in `attach`.
    struct DictationHostBridge {
        let currentSidebarItem: () -> SidebarItem?
        let selectSidebarItem: (SidebarItem) -> Void
        let isAccessibilityEnabled: () -> Bool
    }

    // MARK: - Collaborators

    var asr: ASRService { AppServices.shared.asr }
    var settings: SettingsStore { .shared }
    /// FluidApp's @StateObject; lives for the whole app. Set in `attach`
    /// before any recording can start.
    var menuBarManager: MenuBarManager!
    var host: DictationHostBridge?
    let commandModeService = CommandModeService()
    let rewriteModeService = RewriteModeService()

    // MARK: - Session state (moved from ContentView @State)

    var activeRecordingMode: ActiveRecordingMode = .none
    var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot?
    var isRecordingForRewrite: Bool = false
    var isRecordingForCommand: Bool = false
    var promptModeOverrideText: String?
    var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)?
    var recordingPrecedingText: String = ""
    var overlayLifecycleID: UInt64 = 0
    var prewarmDictationTask: Task<Void, Never>?
    var pendingAIReprocessText: String?

    init() {}

    func attach(menuBar: MenuBarManager, host: DictationHostBridge) {
        self.menuBarManager = menuBar
        self.host = host
    }

    // MARK: - Pure decisions

    static func outputRoute(mode: ActiveRecordingMode, onboardingCompleted: Bool, onboardingStep: Int) -> DictationOutputRoute {
        let onboardingPlaygroundStep = 4
        let onboardingAIEnhancementStep = 5
        let isSandboxStep = !onboardingCompleted
            && (onboardingStep == onboardingPlaygroundStep || onboardingStep == onboardingAIEnhancementStep)
        let isDictationMode = mode == .dictate || mode == .promptMode
        return isSandboxStep && isDictationMode ? .onboardingSandbox : .normal
    }

    var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
    }

    var isOnboardingSandboxRouteActive: Bool {
        let onboardingAIEnhancementStep = 5
        return self.isOnboardingVoicePlaygroundStepActive ||
            (!self.settings.onboardingCompleted && self.settings.onboardingCurrentStep == onboardingAIEnhancementStep)
    }

    func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        Self.outputRoute(
            mode: self.activeRecordingMode,
            onboardingCompleted: self.settings.onboardingCompleted,
            onboardingStep: self.settings.onboardingCurrentStep
        )
    }

    // MARK: - Mode state

    func setActiveRecordingMode(_ mode: ActiveRecordingMode) {
        if mode != .dictate, mode != .promptMode {
            self.clearActiveDictationShortcutState()
        }
        self.activeRecordingMode = mode
        switch mode {
        case .none, .dictate, .promptMode:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = false
        case .edit:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = true
        case .command:
            self.isRecordingForCommand = true
            self.isRecordingForRewrite = false
        }
    }

    func clearActiveRecordingMode() {
        self.setActiveRecordingMode(.none)
    }

    /// Cancel an in-flight prewarm. Called on abort / new recording start — NOT on
    /// a normal stop, because AI post-processing runs after stop and benefits from
    /// the warm prefix cache the prewarm prime.
    func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    func currentDictationShortcutSlot(for mode: ActiveRecordingMode) -> SettingsStore.DictationShortcutSlot? {
        switch mode {
        case .dictate:
            return self.activeDictationShortcutSlot ?? .primary
        case .promptMode:
            return self.activeDictationShortcutSlot ?? .secondary
        case .none, .edit, .command:
            return nil
        }
    }

    func clearActiveDictationShortcutState() {
        self.activeDictationShortcutSlot = nil
        self.promptModeOverrideText = nil
        NotchContentState.shared.activeDictationShortcutSlot = nil
        NotchContentState.shared.promptModeOverrideProfileName = nil
        NotchContentState.shared.promptModeOverrideProfileID = nil
        NotchContentState.shared.isPromptModeActive = false
    }
}

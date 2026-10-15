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
        /// Whether Fluid's own transcription editor has focus (typing decision)
        let isTranscriptionEditorFocused: () -> Bool
        /// Settings is capturing a new shortcut; hotkeys must not fire.
        let isShortcutCaptureActive: () -> Bool
        /// Sync ContentView's AI-settings UI mirrors after a prompt shortcut switched provider/model.
        let providerSelectionDidChange: (_ providerID: String, _ providerKey: String, _ selectedModels: [String: String], _ modelName: String) -> Void
    }

    // MARK: - Collaborators

    var asr: ASRService { AppServices.shared.asr }
    var settings: SettingsStore { .shared }
    /// FluidApp's @StateObject; lives for the whole app. Set in `attach`
    /// before any recording can start.
    var menuBarManager: MenuBarManager!
    var host: DictationHostBridge?
    @Published private(set) var hotkeyManager: GlobalHotkeyManager?
    @Published var hotkeyManagerInitialized: Bool = false
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

    // MARK: - Hotkey boot

    func bootIfNeeded() {
        NotchContentState.shared.onPromptModeSwitchRequested = { mode in
            self.handleLivePromptModeSwitch(mode)
        }
        NotchContentState.shared.onOverlayModeSwitchRequested = { mode in
            self.handleLiveOverlayModeSwitch(mode)
        }
        NotchContentState.shared.onReprocessLastRequested = {
            self.reprocessLastDictation()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            self.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onUndoLastAIRequested = {
            self.undoLastAIProcessingFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }
        NotchContentState.shared.onDictationPromptSelectionRequested = { selection in
            let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable()
            switch selection {
            case .off:
                break
            case .privateAI:
                guard privateAIAvailable else { return }
            case .default, .profile:
                guard !privateAIAvailable else { return }
            }
            let slot = self.activeDictationShortcutSlot ?? .primary
            SettingsStore.shared.setDictationPromptSelection(selection, for: slot)
            self.applyDictationShortcutSelectionContext(for: slot)
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: self.settings.primaryDictationShortcuts,
            promptModeShortcut: self.settings.promptModeHotkeyShortcut,
            commandModeShortcut: self.settings.commandModeHotkeyShortcut,
            rewriteModeShortcut: self.settings.rewriteModeHotkeyShortcut,
            promptShortcutAssignments: SettingsStore.shared.dictationPromptShortcutAssignments(),
            promptModeShortcutEnabled: self.settings.promptModeShortcutEnabled,
            commandModeShortcutEnabled: self.settings.commandModeShortcutEnabled,
            rewriteModeShortcutEnabled: self.settings.rewriteModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("ContentView: startRecordingCallback invoked by hotkey", source: "ContentView")
                self.startRecording()
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "ContentView")
                DebugLogger.shared.debug(
                    "ContentView: selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "ContentView"
                )
                self.beginDictationRecording(for: .primary, mode: .dictate)
            },
            stopAndProcessCallback: {
                let route = self.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "ContentView")
                await self.stopAndProcessTranscription(route: route)
            },
            promptModeCallback: {
                DebugLogger.shared.info("Prompt mode triggered", source: "ContentView")
                self.beginDictationRecording(for: .secondary, mode: .promptMode)
            },
            promptSelectionCallback: { selection in
                DebugLogger.shared.info("Prompt selection shortcut triggered", source: "ContentView")
                self.beginDictationRecording(for: selection, mode: .promptMode)
            },
            commandModeCallback: {
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")
                self.captureRecordingContext()

                // Set flag so stopAndProcessTranscription knows to process as command
                self.setActiveRecordingMode(.command)

                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)

                guard !self.asr.isRunning else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the command
                DebugLogger.shared.info(
                    "Starting voice recording for command",
                    source: "ContentView"
                )
                TranscriptionSoundPlayer.shared.playStartSound()
                Task {
                    await self.asr.start()
                }
            },
            rewriteModeCallback: {
                self.captureRecordingContext()

                // Try to capture text first while still in the other app
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Rewrite mode triggered, text captured: \(captured)", source: "ContentView")

                if !captured {
                    // No text selected - start in "write mode" where user speaks
                    // what to write
                    DebugLogger.shared
                        .info(
                            "No text selected - starting in write/improve mode",
                            source: "ContentView"
                        )
                    self.rewriteModeService.startWithoutSelection()
                    // Set overlay mode to edit
                    self.menuBarManager.setOverlayMode(.edit)
                } else {
                    // Text was selected - edit mode (with selected context)
                    self.menuBarManager.setOverlayMode(.edit)
                }

                // Set flag so stopAndProcessTranscription knows to process as rewrite
                self.setActiveRecordingMode(.edit)

                guard !self.asr.isRunning else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the edit instruction
                DebugLogger.shared.info("Starting voice recording for edit mode", source: "ContentView")
                TranscriptionSoundPlayer.shared.playStartSound()
                Task {
                    await self.asr.start()
                }
            },
            isDictateRecordingProvider: {
                self.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.activeRecordingMode == .promptMode
            },
            isCommandRecordingProvider: {
                self.activeRecordingMode == .command
            },
            isRewriteRecordingProvider: {
                self.activeRecordingMode == .edit
            },
            isShortcutCaptureActiveProvider: {
                (self.host?.isShortcutCaptureActive() ?? false)
            }
        )

        self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false

        self.hotkeyManager?.setHotkeyMode(self.settings.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Returns true if it handled something (so GlobalHotkeyManager knows to consume the event)
        self.hotkeyManager?.setCancelCallback {
            var handled = false

            // Close expanded command notch if visible (highest priority)
            if NotchOverlayManager.shared.isCommandOutputExpanded {
                DebugLogger.shared.debug("Cancel callback: closing expanded command notch", source: "ContentView")
                NotchOverlayManager.shared.hideExpandedCommandOutput()
                handled = true
            }

            // Reset recording mode flags
            if self.activeRecordingMode != .none {
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                handled = true
            }

            // Close rewrite mode if open. Command Mode stays open so Escape can cancel voice capture without leaving the tool.
            if self.host?.currentSidebarItem() == .rewriteMode {
                DebugLogger.shared.debug("Cancel callback: closing mode view", source: "ContentView")
                DispatchQueue.main.async {
                    self.host?.selectSidebarItem(.welcome)
                }
                handled = true
            }

            return handled
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            self.pasteLastDictationFromHistory()
        }

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && (self.host?.isAccessibilityEnabled() ?? false) {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && (self.host?.isAccessibilityEnabled() ?? false) {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "ContentView")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
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

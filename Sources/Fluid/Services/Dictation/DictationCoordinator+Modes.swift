import AppKit
import Foundation

// Command/rewrite voice routes, live mode switches, prompt configuration and
// Private AI prewarm for the dictation flow. Moved verbatim from ContentView.

extension DictationCoordinator {
    func processRewriteWithVoiceInstruction(
        _ instruction: String,
        appInfo: (name: String, bundleId: String, windowTitle: String)
    ) async {
        self.rewriteModeService.setPromptAppBundleID(appInfo.bundleId)
        let hasOriginalText = !self.rewriteModeService.originalText.isEmpty
        DebugLogger.shared.info("Processing \(hasOriginalText ? "rewrite" : "write/improve") - instruction: '\(instruction)', originalText length: \(self.rewriteModeService.originalText.count)", source: "ContentView")

        // Show processing animation
        self.menuBarManager.setProcessing(true)

        // Process the request - service handles both cases:
        // - With originalText: rewrites existing text based on instruction
        // - Without originalText: improves/refines the spoken text
        await self.rewriteModeService.processRewriteRequest(instruction)

        // If rewrite was successful, type the result
        if !self.rewriteModeService.rewrittenText.isEmpty {
            DebugLogger.shared.info("Rewrite successful, typing result (chars: \(self.rewriteModeService.rewrittenText.count))", source: "ContentView")

            // Copy to clipboard as backup
            if SettingsStore.shared.copyTranscriptionToClipboard {
                ClipboardService.copyToClipboard(self.rewriteModeService.rewrittenText)
                AnalyticsService.shared.capture(
                    .outputDelivered,
                    properties: [
                        "mode": AnalyticsMode.rewrite.rawValue,
                        "method": AnalyticsOutputMethod.clipboard.rawValue,
                    ]
                )
            }

            // Type the rewritten text
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeTextToActiveField(
                self.rewriteModeService.rewrittenText,
                preferredTargetPID: typingTarget.pid
            )
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.rewrite.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Clear the rewrite service state for next use
            self.rewriteModeService.clearState()
            self.hideOverlayAfterOutput()
        } else {
            await self.menuBarManager.finishProcessingAndHideOverlay()
            DebugLogger.shared.error("Rewrite failed - no result", source: "ContentView")
            AnalyticsService.shared.capture(
                .errorOccurred,
                properties: [
                    "domain": AnalyticsErrorDomain.llm.rawValue,
                    "category": "rewrite_no_result",
                ]
            )
        }
    }

    func handleLivePromptModeSwitch(_ mode: SettingsStore.PromptMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode.normalized {
        case .dictate:
            guard self.activeRecordingMode != .dictate || NotchContentState.shared.mode != .dictation else { return }
            self.setActiveRecordingMode(.dictate)
            self.rewriteModeService.clearState()
            self.menuBarManager.setOverlayMode(.dictation)
        case .edit:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteModeService.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteModeService.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "ContentView")
                if !captured {
                    self.rewriteModeService.startWithoutSelection()
                }
            }
            self.menuBarManager.setOverlayMode(.edit)
        case .write, .rewrite:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteModeService.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteModeService.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "ContentView")
                if !captured {
                    self.rewriteModeService.startWithoutSelection()
                }
            }
            self.menuBarManager.setOverlayMode(.edit)
        }
    }

    func handleLiveOverlayModeSwitch(_ mode: OverlayMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode {
        case .dictation:
            self.handleLivePromptModeSwitch(.dictate)
        case .edit, .write, .rewrite:
            self.handleLivePromptModeSwitch(.edit)
        case .command:
            guard self.activeRecordingMode != .command || NotchContentState.shared.mode != .command else { return }
            self.rewriteModeService.clearState()
            self.setActiveRecordingMode(.command)
            self.menuBarManager.setOverlayMode(.command)
        }
    }

    func processCommandWithVoice(_ command: String) async {
        DebugLogger.shared.info("Processing voice command: '\(command)'", source: "ContentView")

        // Show processing animation
        self.menuBarManager.setProcessing(true)

        // Process the command through CommandModeService
        // This stores the conversation history and executes any terminal commands
        await self.commandModeService.processUserCommand(command, notifyInvalidRequest: true)

        // Hide processing animation
        self.menuBarManager.setProcessing(false)

        DebugLogger.shared.info("Command processed, conversation stored in Command Mode", source: "ContentView")
    }

    func prewarmPrivateAIDictationIfNeeded(for slot: SettingsStore.DictationShortcutSlot) {
        let appBundleID = self.recordingAppInfo?.bundleId
        guard PrivateAIProviderPromptFormat.isAvailable(settings: SettingsStore.shared),
              DictationAIPostProcessingGate.isConfigured(for: slot, appBundleID: appBundleID)
        else { return }

        // Cancel any prior prewarm so rapid start/stop doesn't queue duplicate
        // actor work on PrivateAIIntegrationService.
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = Task {
            DebugLogger.shared.debug(
                "ContentView: AI dictation prewarm started slot=\(slot.rawValue)",
                source: "ContentView"
            )
            await PrivateAIIntegrationService.shared.prewarmDictation()
            DebugLogger.shared.debug(
                "AI dictation prewarm complete slot=\(slot.rawValue)",
                source: "ContentView"
            )
            if !Task.isCancelled {
                self.prewarmDictationTask = nil
            }
        }
    }

    func applyDictationShortcutSelectionContext(for slot: SettingsStore.DictationShortcutSlot) {
        let settings = SettingsStore.shared
        self.activeDictationShortcutSlot = slot
        NotchContentState.shared.activeDictationShortcutSlot = slot
        NotchContentState.shared.isPromptModeActive = (slot == .secondary)

        switch settings.dictationPromptSelection(for: slot) {
        case .off, .default:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = nil
            NotchContentState.shared.promptModeOverrideProfileID = nil
        case .privateAI:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = PrivateAIProviderFeature.displayName
            NotchContentState.shared.promptModeOverrideProfileID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(profileID):
            guard let profile = settings.selectedDictationPromptProfile(for: slot) ?? settings.dictationPromptProfiles.first(where: {
                $0.id == profileID && $0.mode.normalized == .dictate
            }) else {
                settings.setDictationPromptSelection(.default, for: slot)
                self.promptModeOverrideText = nil
                NotchContentState.shared.promptModeOverrideProfileName = nil
                NotchContentState.shared.promptModeOverrideProfileID = nil
                return
            }

            self.promptModeOverrideText = SettingsStore.combineBasePrompt(
                for: .dictate,
                with: SettingsStore.stripBasePrompt(for: .dictate, from: profile.prompt)
            )
            NotchContentState.shared.promptModeOverrideProfileName = profile.name
            NotchContentState.shared.promptModeOverrideProfileID = profile.id
        }
    }

    func applyDictationPromptConfiguration(for selection: SettingsStore.DictationPromptSelection) {
        let providerID: String
        let modelName: String

        if selection == .privateAI {
            providerID = PrivateAIProviderFeature.shared.providerID
            modelName = PrivateAIIntegrationService.configuredModelID
        } else {
            let configuration = SettingsStore.shared.dictationPromptConfiguration(for: selection)
            providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            modelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !providerID.isEmpty, !modelName.isEmpty else { return }
        }

        let providerKey = ModelRepository.shared.providerKey(for: providerID)
        SettingsStore.shared.selectedProviderID = providerID
        var selectedModels = SettingsStore.shared.selectedModelByProvider
        selectedModels[providerKey] = modelName
        SettingsStore.shared.selectedModelByProvider = selectedModels
        self.host?.providerSelectionDidChange(providerID, providerKey, selectedModels, modelName)
    }
}

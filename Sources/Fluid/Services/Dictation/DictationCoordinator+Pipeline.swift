import AVFoundation
import AppKit
import Foundation

extension DictationCoordinator {
    // MARK: - Begin Recording

    func beginDictationRecording(for slot: SettingsStore.DictationShortcutSlot, mode: DictationCoordinator.ActiveRecordingMode) {
        DebugLogger.shared.debug("Begin dictation recording for slot \(slot.rawValue)", source: "ContentView")
        self.appBench("begin_recording slot=\(slot.rawValue) mode=\(mode.rawValue)")
        if self.isOnboardingVoicePlaygroundStepActive {
            self.asr.finalText = ""
            self.settings.onboardingPlaygroundValidated = false
            self.settings.onboardingPlaygroundSkipped = false
            self.settings.playgroundUsed = false
        }
        self.applyDictationShortcutSelectionContext(for: slot)
        self.setActiveRecordingMode(mode)
        self.rewriteModeService.clearState()

        guard !self.asr.isRunning else {
            self.appBench("asr_start_skipped reason=already_running")
            return
        }
        self.advanceOverlayLifecycle()
        Task {
            let asrStartStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.benchmark("APP_BENCH", message: "asr_start_call", source: "AppBenchmark")
            if SettingsStore.shared.enableTranscriptionSounds, !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.applyDictationPromptConfiguration(for: SettingsStore.shared.dictationPromptSelection(for: slot))
                self.appBench("overlay_mode_request mode=Dictation")
                self.menuBarManager.setOverlayMode(.dictation)
                self.menuBarManager.showRecordingOverlayImmediately()
                self.appBench("overlay_mode_requested mode=Dictation")
                self.prewarmPrivateAIDictationIfNeeded(for: slot)
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "asr_start_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStartStartedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
        }
    }

    func beginDictationRecording(for selection: SettingsStore.DictationPromptSelection, mode: DictationCoordinator.ActiveRecordingMode) {
        let settings = SettingsStore.shared
        settings.setDictationPromptSelection(selection, for: .secondary)
        self.applyDictationPromptConfiguration(for: selection)
        self.beginDictationRecording(for: .secondary, mode: mode)
    }

    // MARK: - Start Recording

    /// Capture app context at start to avoid mismatches if the user switches apps mid-session
    func startRecording() {
        let model = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ContentView: startRecording() for model=\(model.displayName), supportsStreaming=\(model.supportsStreaming)",
            source: "ContentView"
        )

        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        let shouldShowDictationOverlay = !self.isRecordingForCommand && !self.isRecordingForRewrite
        let shouldPlayStartSound = !self.isRecordingForCommand
            && !self.isRecordingForRewrite
            && self.asr.micStatus == .authorized

        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if shouldShowDictationOverlay {
            self.menuBarManager.setOverlayMode(.dictation)
        }

        Task {
            if shouldPlayStartSound, !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.prewarmPrivateAIDictationIfNeeded(for: .primary)
                if shouldShowDictationOverlay {
                    self.menuBarManager.showRecordingOverlayImmediately()
                }
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                DebugLogger.shared.debug("ContentView: pre-load model task started", source: "ContentView")
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "ContentView")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "ContentView")
            }
        }
    }

    // MARK: - Stop and Process Transcription

    func stopAndProcessTranscription(route: DictationCoordinator.DictationOutputRoute = .normal) async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "ContentView")
        self.appBench("stop_path_enter route=\(route.rawValue)")

        // Check if we're in rewrite or command mode
        let modeAtStop = self.activeRecordingMode
        let wasRewriteMode = modeAtStop == .edit || self.isRecordingForRewrite
        let wasCommandMode = modeAtStop == .command || self.isRecordingForCommand
        let activeDictationSlot = self.currentDictationShortcutSlot(for: modeAtStop)
        let promptOverride = self.promptModeOverrideText
        let promptTest = DictationPromptTestCoordinator.shared
        let shouldUseAIOnStop = activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: self.recordingAppInfo?.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: self.recordingAppInfo?.bundleId)
        let shouldHideOverlayOnStop = route == .normal &&
            !wasRewriteMode &&
            !wasCommandMode &&
            !promptTest.isActive &&
            !shouldUseAIOnStop
        var didRequestOverlayHideOnStop = false
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | rewrite=\(wasRewriteMode) | command=\(wasCommandMode) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "ContentView"
        )

        self.clearActiveRecordingMode()

        if shouldHideOverlayOnStop {
            didRequestOverlayHideOnStop = true
            DebugLogger.shared.debug("Hiding dictation overlay at stop path", source: "ContentView")
            self.hideOverlayAsync(reason: "stop_path")
        } else {
            // Show "Transcribing" state before calling stop() when the overlay needs
            // to remain available for prompt, command, rewrite, or AI feedback.
            DebugLogger.shared.debug("Showing transcription processing state", source: "ContentView")
            self.appBench("processing_ui_request status=Transcribing")
            self.menuBarManager.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing")

            // Give SwiftUI a chance to render the processing state before heavier work.
            await Task.yield()
        }

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let asrStopStartedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("asr_stop_call")
        // Play the stop cue as soon as the audio engine has stopped, before the
        // (potentially slow) final transcription pass. Scoped to dictation only —
        // Command/Edit modes call asr.stop() without this callback.
        let transcribedText = await asr.stop(onCaptureStopped: {
            TranscriptionSoundPlayer.shared.playStopSound()
        })
        self.appBench("asr_stop_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStopStartedAt) * 1000).rounded()))")
        let audioSnapshot = self.asr.consumeLastCompletedAudioSnapshot()
        DebugLogger.shared.info(
            "Stop transcription result | chars=\(transcribedText.count) | empty=\(transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            source: "ContentView"
        )

        // Reset the transcription text display after transcription completes
        NotchOverlayManager.shared.updateTranscriptionText("")

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            // Finish the same short exit transition even when no text is emitted.
            if !didRequestOverlayHideOnStop {
                await self.menuBarManager.finishProcessingAndHideOverlay()
            }
            return
        }

        // Prompt Test Mode: reroute dictation hotkey output into the prompt editor (no typing/clipboard/history).
        if promptTest.isActive {
            promptTest.lastTranscriptionText = transcribedText
            promptTest.lastOutputText = ""
            promptTest.lastError = ""

            guard DictationAIPostProcessingGate.isProviderConfigured() else {
                promptTest.lastError = "AI post-processing is not configured. Configure a provider/model (and API key for non-local endpoints) to test prompts."
                self.menuBarManager.setProcessing(false)
                return
            }

            promptTest.isProcessing = true
            // Processing already true from above
            defer {
                self.menuBarManager.setProcessing(false)
                promptTest.isProcessing = false
            }

            do {
                let result = try await self.processTextWithAI(transcribedText, overrideSystemPrompt: promptTest.draftPromptText)
                let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
                let literalFormattedResult = ASRService.applyDictationLiteralFormatting(
                    result,
                    appName: appInfo.name,
                    bundleID: appInfo.bundleId,
                    windowTitle: appInfo.windowTitle
                )
                promptTest.lastOutputText = ASRService.applyGAAVFormatting(literalFormattedResult)
            } catch {
                DebugLogger.shared.error("Prompt test AI call failed: \(error.localizedDescription)", source: "ContentView")
                promptTest.lastError = error.localizedDescription
            }
            return
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.beginReleaseTransition()
        }

        // If this was a rewrite recording, process the rewrite instead of typing
        if wasRewriteMode {
            DebugLogger.shared.info("Processing rewrite with instruction: \(transcribedText)", source: "ContentView")
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            await self.processRewriteWithVoiceInstruction(transcribedText, appInfo: appInfo)
            AnalyticsService.shared.capture(
                .transcriptionCompleted,
                properties: [
                    "mode": AnalyticsMode.rewrite.rawValue,
                    "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: transcribedText)),
                    "ai_used": true,
                ]
            )
            return
        }

        // If this was a command recording, process the command
        if wasCommandMode {
            DebugLogger.shared.info("Processing command: \(transcribedText)", source: "ContentView")
            await self.processCommandWithVoice(transcribedText)
            AnalyticsService.shared.capture(
                .transcriptionCompleted,
                properties: [
                    "mode": AnalyticsMode.command.rawValue,
                    "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: transcribedText)),
                    "ai_used": true,
                ]
            )
            return
        }

        var finalText: String
        var aiFallbackReason: String?
        var postProcessingModel: String?
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        let shouldUseAI = activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: appInfo.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            let postProcessingModelInfo = self.currentDictationAIModelInfo()
            postProcessingModel = postProcessingModelInfo.model
            let postProcessingInputChars = normalizedTranscribedText.count
            let postProcessingStart = Date()

            // Update overlay text to show we're now refining (processing already true)
            self.appBench("processing_ui_request status=Refining")
            NotchOverlayManager.shared.updateTranscriptionText("Refining")
            self.appBench("processing_ui_requested status=Refining")

            // Ensure the status label becomes visible immediately.
            await Task.yield()

            do {
                finalText = try await self.processTextWithAI(
                    normalizedTranscribedText,
                    overrideSystemPrompt: promptOverride,
                    dictationSlot: activeDictationSlot
                )
            } catch {
                // Fall back to the raw transcription so the user still gets
                // their words typed instead of an error string.
                DebugLogger.shared.error(
                    "AI post-processing failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                // Configuration errors are actionable — point the user at settings
                // rather than just echoing the technical error string.
                if let aiError = error as? AIProcessingError,
                   aiError.isConfigurationError
                {
                    NotificationService.showAIProcessingFallback(
                        error: "\(aiError.localizedDescription). Open AI Enhancement settings to configure a provider."
                    )
                } else {
                    NotificationService.showAIProcessingFallback(error: error.localizedDescription)
                }
                finalText = normalizedTranscribedText
            }
            let postProcessingLatencyMs = Int((Date().timeIntervalSince(postProcessingStart) * 1000).rounded())
            AnalyticsService.shared.capture(
                .dictationPostProcessingCompleted,
                properties: [
                    "latency_ms": postProcessingLatencyMs,
                    "input_chars": postProcessingInputChars,
                    "post_processing_provider": postProcessingModelInfo.provider ?? "unknown",
                    "post_processing_model": postProcessingModelInfo.model ?? "unknown",
                    "transcription_provider": transcriptionModelInfo.provider,
                    "transcription_model": transcriptionModelInfo.model,
                ]
            )

            // Clear transient status text before leaving processing state to avoid
            // a brief non-shimmer "Refining..." preview flash.
            NotchOverlayManager.shared.updateTranscriptionText("")

        } else {
            finalText = normalizedTranscribedText
        }

        // Normalize literal command and mention syntax after AI cleanup and before final user preferences.
        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        // Apply GAAV formatting as the FINAL step (after AI post-processing)
        // This ensures the user's preference for no capitalization/period is respected
        finalText = ASRService.applyGAAVFormatting(finalText)
        // Apply Continuous Dictation Mode after GAAV so smart caps use the field
        // context captured at recording start, and the trailing space enables chaining.
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: self.recordingPrecedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        self.asr.finalText = finalText
        if route == .onboardingSandbox,
           self.isOnboardingVoicePlaygroundStepActive,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.settings.onboardingPlaygroundValidated = true
            self.settings.playgroundUsed = true
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")
        let finalTextReadyAt = ProcessInfo.processInfo.systemUptime
        let finalOutputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.appBench("transcription_finalized chars=\(finalText.count)")
        self.appBench("text_ready chars=\(finalText.count)")

        AnalyticsService.shared.capture(
            .transcriptionCompleted,
            properties: [
                "mode": AnalyticsMode.dictation.rawValue,
                "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: finalText)),
                "ai_used": shouldUseAI,
                "ai_changed_text": transcribedText != finalText,
                "transcription_provider": transcriptionModelInfo.provider,
                "transcription_model": transcriptionModelInfo.model,
            ]
        )

        let shouldPersistOutputs = route == .normal
        if !shouldPersistOutputs {
            DebugLogger.shared.info(
                "Sandbox route active: suppressing clipboard/history/external typing side effects",
                source: "ContentView"
            )
        }

        let shouldShowAIProcessingFailure = shouldPersistOutputs && aiFallbackReason != nil
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
        } else {
            self.pendingAIReprocessText = nil
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostName = frontmostApp?.localizedName ?? "Unknown"
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingError: aiFallbackReason
            )
            self.persistDictationAudioIfNeeded(
                audioSnapshot,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: transcriptionModelInfo.model
            )
        }
        // When FluidVoice itself is frontmost, the bound editor already receives `finalText`.
        // Avoid re-inserting or overwriting the clipboard in that self-target case.
        let shouldCopyToClipboard = shouldPersistOutputs &&
            SettingsStore.shared.copyTranscriptionToClipboard &&
            !isFluidFrontmost

        if shouldCopyToClipboard {
            ClipboardService.copyToClipboard(finalText)
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.clipboard.rawValue,
                ]
            )
        }

        var didTypeExternally = false
        let shouldTypeExternally = shouldPersistOutputs && !isFluidFrontmost

        DebugLogger.shared.debug(
            "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \((self.host?.isTranscriptionEditorFocused() ?? false)), willTypeExternally: \(shouldTypeExternally)",
            source: "ContentView"
        )

        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            // Dispatch insertion as soon as the destination app is ready; the
            // overlay hides asynchronously after output so it cannot delay paste.
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.appBench(
                "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
            )
            self.asr.typeOutputPlanToActiveField(
                finalOutputPlan,
                preferredTargetPID: typingTarget.pid,
                textReadyAt: finalTextReadyAt
            )
            didTypeExternally = true
            if !shouldShowAIProcessingFailure, !didRequestOverlayHideOnStop {
                self.hideOverlayAfterOutput()
            }
        }

        if didTypeExternally {
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Register the post-transcription edit observation after insertion is dispatched.
            let wordsBucket = AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: finalText))
            let modelInfo = self.currentDictationAIModelInfo()
            await PostTranscriptionEditTracker.shared.markTranscriptionCompleted(
                mode: AnalyticsMode.dictation.rawValue,
                outputMethod: AnalyticsOutputMethod.typed.rawValue,
                wordsBucket: wordsBucket,
                aiUsed: shouldUseAI,
                aiModel: modelInfo.model,
                aiProvider: modelInfo.provider
            )
        } else if shouldPersistOutputs,
                  SettingsStore.shared.copyTranscriptionToClipboard == false,
                  SettingsStore.shared.saveTranscriptionHistory
        {
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.historyOnly.rawValue,
                ]
            )
        }

        if !didTypeExternally, !shouldShowAIProcessingFailure, !didRequestOverlayHideOnStop {
            self.hideOverlayAfterOutput()
        }
    }

    // MARK: - Reprocess

    func reprocessDictationText(_ transcribedText: String) async {
        // If live recording is still active, stop it first so reprocess does not
        // leave ASR running in the background (which causes the next hotkey press
        // to behave like a stop instead of start).
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before reprocess", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        self.setActiveRecordingMode(.dictate)
        self.menuBarManager.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Reprocessing...")
        await Task.yield()

        var aiFallbackReason: String?
        var postProcessingModel: String?
        let appInfo = self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        var finalText = normalizedTranscribedText
        let shouldUseAI = DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        if shouldUseAI {
            postProcessingModel = self.currentDictationAIModelInfo().model
            do {
                finalText = try await self.processTextWithAI(
                    normalizedTranscribedText,
                    dictationSlot: .primary
                )
            } catch {
                DebugLogger.shared.error(
                    "AI reprocess failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                NotificationService.showAIProcessingFallback(error: error.localizedDescription)
                finalText = normalizedTranscribedText
            }
        }

        NotchOverlayManager.shared.updateTranscriptionText("")

        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        finalText = ASRService.applyGAAVFormatting(finalText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingError: aiFallbackReason
            )
        }
        if aiFallbackReason != nil {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
        } else {
            self.pendingAIReprocessText = nil
        }

        if SettingsStore.shared.copyTranscriptionToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
        let shouldTypeExternally = !isFluidFrontmost || (self.host?.isTranscriptionEditorFocused() ?? false) == false
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid
            )
        }

        if aiFallbackReason == nil {
            self.hideOverlayAfterOutput()
        }

        self.clearActiveRecordingMode()
    }
}

import AppKit
import Foundation

// App/target context capture, focus restore, overlay lifecycle and model
// metadata for the dictation flow. Moved verbatim from ContentView.

extension DictationCoordinator {
    func currentDictationAIModelInfo() -> (provider: String?, model: String?) {
        let providerID = SettingsStore.shared.selectedProviderID

        if providerID == "apple-intelligence" {
            return (provider: "apple-intelligence", model: "apple-intelligence")
        }

        let storedSelectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        let storedSavedProviders = SettingsStore.shared.savedProviders

        let derivedProvider: String
        let derivedModel: String

        if let saved = storedSavedProviders.first(where: { $0.id == providerID }) {
            derivedProvider = "custom:\(saved.id)"
            derivedModel = storedSelectedModelByProvider[derivedProvider] ?? saved.models.first ?? ""
        } else if providerID == "openai" {
            derivedProvider = "openai"
            derivedModel = storedSelectedModelByProvider["openai"] ?? "gpt-4.1"
        } else if providerID == "groq" {
            derivedProvider = "groq"
            derivedModel = storedSelectedModelByProvider["groq"] ?? "llama-3.3-70b-versatile"
        } else {
            derivedProvider = providerID
            derivedModel = storedSelectedModelByProvider[providerID] ?? ""
        }

        let providerOut = derivedProvider.isEmpty ? nil : derivedProvider
        let modelOut = derivedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : derivedModel
        return (provider: providerOut, model: modelOut)
    }

    func currentTranscriptionModelInfo() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    /// Best-effort frontmost window title lookup for the current app
    func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }

    func captureRecordingTargetContext() {
        // Capture the focused target PID BEFORE any overlay/UI changes.
        // Used to restore focus when the user interacts with overlay dropdowns.
        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        self.rewriteModeService.setPromptAppBundleID(info.bundleId)
        DebugLogger.shared.debug(
            "Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)",
            source: "ContentView"
        )
    }

    func captureRecordingFormattingContextIfNeeded() {
        // Capture text before the caret only when formatting needs focused-field context.
        if SettingsStore.shared.needsDictationFormattingContext {
            self.recordingPrecedingText = TypingService.textBeforeCursorInFocusedField()
            DebugLogger.shared.debug(
                "Captured preceding text for continuous dictation (chars=\(self.recordingPrecedingText.count))",
                source: "ContentView"
            )
        } else {
            self.recordingPrecedingText = ""
        }
    }

    func captureRecordingContext() {
        self.captureRecordingTargetContext()
        self.captureRecordingFormattingContextIfNeeded()
    }

    func resolveTypingTargetPID() -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool) {
        let originalPID = NotchContentState.shared.recordingTargetPID
        let currentFocusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let selfBundleID = Bundle.main.bundleIdentifier
        if let currentFocusedPID,
           let app = NSRunningApplication(processIdentifier: currentFocusedPID),
           app.bundleIdentifier != selfBundleID
        {
            return (currentFocusedPID, currentFocusedPID == originalPID)
        }

        return (originalPID, true)
    }

    func processTextWithAI(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) async throws -> String {
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let result = try await DictationAIProcessor.shared.process(DictationAIProcessor.Request(
            text: inputText,
            mode: .dictation,
            overridePrompt: overrideSystemPrompt,
            slot: dictationSlot,
            activeSlot: self.currentDictationShortcutSlot(for: self.activeRecordingMode),
            app: DictationAIProcessor.AppContext(name: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle)
        ))
        return result.text
    }

    func hideOverlayAfterOutput() {
        self.hideOverlayAsync(reason: "after_output")
    }

    func advanceOverlayLifecycle() {
        self.overlayLifecycleID &+= 1
    }

    func hideOverlayAsync(reason: String) {
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("overlay_hide_request reason=\(reason) lifecycle=\(expectedOverlayLifecycleID)")
        Task { @MainActor in
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
                self.appBench(
                    "overlay_hide_skipped reason=\(reason) staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
                )
                return
            }

            let overlayHideStartedAt = ProcessInfo.processInfo.systemUptime
            await self.menuBarManager.finishProcessingAndHideOverlay()
            self.appBench(
                "overlay_hidden reason=\(reason) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - overlayHideStartedAt) * 1000).rounded()))"
            )
        }
    }

    func persistDictationAudioIfNeeded(
        _ snapshot: DictationAudioSnapshot?,
        entryID: UUID,
        timestamp: Date,
        model: String
    ) {
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory,
              let snapshot = snapshot
        else {
            return
        }

        Task.detached(priority: .utility) {
            let result: (metadata: DictationAudioMetadata?, error: String?) = {
                do {
                    let metadata = try DictationAudioHistoryStore.shared.save(
                        snapshot: snapshot,
                        entryID: entryID,
                        timestamp: timestamp,
                        model: model
                    )
                    return (metadata, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }()

            await MainActor.run {
                if let metadata = result.metadata {
                    TranscriptionHistoryStore.shared.attachAudio(metadata, to: entryID)
                } else if let error = result.error {
                    DebugLogger.shared.error("Failed to save dictation audio: \(error)", source: "ContentView")
                }
            }
        }
    }

    /// Best-effort: re-activate the app that was focused when recording started.
    /// Skips the AX restore work when the captured text element is already focused.
    func restoreFocusToRecordingTarget() async {
        guard let pid = NotchContentState.shared.recordingTargetPID else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("focus_restore_start targetPID=\(pid)")
        if TypingService.isCapturedFocusStillActive(for: pid) {
            self.appBench("focus_restore_result activated=false element=true elapsedMs=0 reason=already_focused")
            DebugLogger.shared.debug(
                "Restore focus skipped; captured element still focused, targetPID: \(pid)",
                source: "ContentView"
            )
            self.appBench("focus_restore_settle_done delayMs=0")
            return
        }
        let activated = TypingService.activateApp(pid: pid)
        let focusedElementRestored = TypingService.restoreCapturedFocus(in: pid)
        self.appBench(
            "focus_restore_result activated=\(activated) element=\(focusedElementRestored) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
        )
        DebugLogger.shared.debug(
            "Restore focus -> appActivated: \(activated), elementFocusRestored: \(focusedElementRestored), targetPID: \(pid)",
            source: "ContentView"
        )
        self.appBench("focus_restore_settle_done delayMs=0")
    }

    func appBench(_ message: String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message, source: "AppBenchmark")
    }
}

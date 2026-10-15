import AppKit
import CoreGraphics
import Foundation

// Dictation history actions (reprocess, copy, paste, undo-AI for the latest
// transcription) and their shared output helper. Moved verbatim from ContentView.

extension DictationCoordinator {
    func reprocessLastDictation() {
        if let pendingText = self.pendingAIReprocessText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingText.isEmpty
        {
            DebugLogger.shared.info("Actions: Reprocessing pending failed dictation", source: "ContentView")
            Task { @MainActor in
                await self.reprocessDictationText(pendingText)
            }
            return
        }

        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Reprocess requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Reprocess skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Reprocessing latest dictation history entry", source: "ContentView")
        Task { @MainActor in
            await self.reprocessDictationText(rawText)
        }
    }

    func copyLastDictationFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Copy requested but history is empty", source: "ContentView")
            return
        }

        // Fallback to raw text when no processed text is available
        // (for example older entries or edge cases with AI enhancement off).
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Copy skipped because latest history text is empty", source: "ContentView")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "ContentView")
    }

    /// Re-inserts the most recent transcription into the focused text field using the same
    /// clipboard-free insertion path as live dictation. Unlike copy, this never touches the
    /// system clipboard, and unlike reprocess, it pastes the existing text verbatim (no new
    /// history entry, no reformatting). Useful when the original auto-insert dropped the tail.
    func pasteLastDictationFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Paste requested but history is empty", source: "ContentView")
            return
        }

        // Prefer the processed text (what was actually delivered, possibly AI-enhanced),
        // falling back to raw for older entries or when enhancement was off.
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Paste skipped because latest history text is empty", source: "ContentView")
            return
        }

        Task { @MainActor in
            // Only one paste may be pending at a time. Because the paste waits for the modifier keys
            // to release, a quick double/triple-tap of the chord would otherwise queue several Tasks
            // that all insert at once on release. This collapses them to a single paste while still
            // allowing a deliberate repeat (press, it lands, then press again).
            guard !Self.isPasteLastInProgress else {
                DebugLogger.shared.info("Actions: Paste skipped - a paste is already pending", source: "ContentView")
                return
            }
            Self.isPasteLastInProgress = true
            defer { Self.isPasteLastInProgress = false }

            // The hotkey fires on key-down while its own modifier keys (e.g. ⌘⌃) are still
            // physically held. Synthesizing text in that state makes the target app treat the
            // characters as keyboard shortcuts and drop them, so the paste lands once the keys are
            // released — effectively "paste when you let go". The timeout is generous so a normal
            // hold (or a quick repeated press) still pastes on release; it only aborts if a modifier
            // is genuinely stuck, rather than typing a corrupted/destructive shortcut sequence.
            guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
                DebugLogger.shared.info("Actions: Paste aborted - modifier keys still held after timeout", source: "ContentView")
                return
            }

            // Re-check here rather than only at the hotkey trigger: the overlay menu entry point
            // has no pre-check, and the wait above may have elapsed since the trigger fired.
            guard !self.asr.isRunning else {
                DebugLogger.shared.info("Actions: Paste skipped - recording in progress", source: "ContentView")
                return
            }

            let typingTarget = self.resolveTypingTargetPID()
            guard typingTarget.pid != nil else {
                DebugLogger.shared.info("Actions: Paste skipped - no external target field available", source: "ContentView")
                return
            }
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            let appInfo = self.getCurrentAppInfo()
            let outputPlan = ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            self.asr.typeOutputPlanToActiveField(outputPlan, preferredTargetPID: typingTarget.pid)
            DebugLogger.shared.info("Actions: Pasted latest transcription into focused field", source: "ContentView")
        }
    }

    /// Guards against overlapping paste insertions: only one "paste last transcription" may be
    /// pending at a time (see pasteLastDictationFromHistory). A rapid re-tap while one is still
    /// waiting for the modifier keys to release is ignored rather than queuing a duplicate insert.
    /// Only ever touched on the main actor.
    static var isPasteLastInProgress = false

    /// Polls until the keyboard modifier keys are released, returning `true` once they are, or
    /// `false` if the timeout elapses with keys still held. Used before synthesizing a paste so the
    /// inserted characters aren't swallowed as modifier+key shortcuts.
    static func waitForHotkeyModifiersReleased(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        }
        return false
    }

    func undoLastAIProcessingFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Undo AI requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        guard last.wasAIProcessed else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest entry was not AI processed", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Restoring latest transcription raw text (undo AI)", source: "ContentView")
        Task { @MainActor in
            await self.applyHistoryTextOutput(rawText, saveToHistory: true)
        }
    }

    func applyHistoryTextOutput(_ text: String, saveToHistory: Bool) async {
        // Keep hotkey/recording state deterministic before applying output text.
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before history action output", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        let appInfo = self.getCurrentAppInfo()
        let literalFormattedText = ASRService.applyDictationLiteralFormatting(
            text,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let gaavText = ASRService.applyGAAVFormatting(literalFormattedText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        var finalText = ASRService.applyContinuousDictationFormatting(gaavText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if saveToHistory, SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: text,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false
            )
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        if SettingsStore.shared.copyTranscriptionToClipboard, !isFluidFrontmost {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let shouldTypeExternally = !isFluidFrontmost
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
    }
}

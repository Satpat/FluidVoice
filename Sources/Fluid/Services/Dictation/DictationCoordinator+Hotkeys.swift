import AppKit
import Foundation

// Hotkey wiring: cancel shortcut, applying persisted shortcut settings to the
// manager, and health checks. `bootIfNeeded` lives in DictationCoordinator.swift
// because `hotkeyManager` is `private(set)`.

extension DictationCoordinator {
    @discardableResult
    func handleCancelShortcut() -> Bool {
        var handled = false

        if NotchOverlayManager.shared.isCommandOutputExpanded {
            DebugLogger.shared.debug("Cancel shortcut: closing expanded command notch", source: "ContentView")
            NotchOverlayManager.shared.hideExpandedCommandOutput()
            NotchOverlayManager.shared.onCommandOutputDismiss?()
            handled = true
        }

        if self.asr.isRunning {
            DebugLogger.shared.debug("Cancel shortcut: cancelling ASR recording", source: "ContentView")
            Task { await self.asr.stopWithoutTranscription() }
            self.cancelPrewarmDictationIfNeeded()
            handled = true
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            DebugLogger.shared.debug("Cancel shortcut: hiding recording overlay", source: "ContentView")
            NotchOverlayManager.shared.hide()
            handled = true
        }

        if self.host?.currentSidebarItem() == .rewriteMode {
            DebugLogger.shared.debug("Cancel shortcut: closing mode view", source: "ContentView")
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.host?.selectSidebarItem(isOnboarded ? .preferences : .welcome)
            handled = true
        }

        return handled
    }

    /// Push every persisted shortcut setting into the hotkey manager. All
    /// calls are plain setters (idempotent); hotkey *mode* is deliberately
    /// excluded because setHotkeyMode resets press state and can stop an
    /// active press — it keeps its own call path.
    func applyShortcutSettings() {
        guard let manager = self.hotkeyManager else { return }
        manager.updatePrimaryShortcuts(self.settings.primaryDictationShortcuts)
        manager.updatePromptModeShortcut(self.settings.promptModeHotkeyShortcut)
        manager.updatePromptModeShortcutEnabled(self.settings.promptModeShortcutEnabled)
        manager.updatePromptShortcutAssignments(self.settings.dictationPromptShortcutAssignments())
        manager.updateCommandModeShortcut(self.settings.commandModeHotkeyShortcut)
        manager.updateCommandModeShortcutEnabled(self.settings.commandModeShortcutEnabled)
        manager.updateRewriteModeShortcut(self.settings.rewriteModeHotkeyShortcut)
        manager.updateRewriteModeShortcutEnabled(self.settings.rewriteModeShortcutEnabled)
    }

    func reinitializeHotkeys() {
        self.hotkeyManager?.reinitialize()
    }

    /// Re-check the event tap after a shortcut change (was an inline
    /// asyncAfter in ContentView's primary-shortcut onChange).
    func refreshHotkeyHealth(after delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
            DebugLogger.shared.debug("Hotkey manager initialized: \(self.hotkeyManagerInitialized)", source: "ContentView")
        }
    }
}

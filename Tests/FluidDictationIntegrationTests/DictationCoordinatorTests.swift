@testable import FluidVoice_Debug
import XCTest

// Pure decisions moved from ContentView into DictationCoordinator.

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testOutputRoute_onboardingSandboxOnlyForDictationModesOnSteps4And5() {
        typealias C = DictationCoordinator
        for step in [4, 5] {
            XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: step), .onboardingSandbox)
            XCTAssertEqual(C.outputRoute(mode: .promptMode, onboardingCompleted: false, onboardingStep: step), .onboardingSandbox)
            XCTAssertEqual(C.outputRoute(mode: .command, onboardingCompleted: false, onboardingStep: step), .normal)
            XCTAssertEqual(C.outputRoute(mode: .edit, onboardingCompleted: false, onboardingStep: step), .normal)
            XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: true, onboardingStep: step), .normal)
        }
        XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: 3), .normal)
        XCTAssertEqual(C.outputRoute(mode: .dictate, onboardingCompleted: false, onboardingStep: 6), .normal)
    }

    func testCurrentSlot_defaultsPerModeAndHonoursActiveSlot() {
        let coordinator = DictationCoordinator()
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .dictate), .primary)
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .promptMode), .secondary)
        XCTAssertNil(coordinator.currentDictationShortcutSlot(for: .command))
        XCTAssertNil(coordinator.currentDictationShortcutSlot(for: .none))
        coordinator.activeDictationShortcutSlot = .secondary
        XCTAssertEqual(coordinator.currentDictationShortcutSlot(for: .dictate), .secondary)
    }

    func testSetActiveRecordingMode_setsFlagsAndClearsSlotOutsideDictation() {
        let coordinator = DictationCoordinator()
        coordinator.activeDictationShortcutSlot = .secondary
        coordinator.promptModeOverrideText = "x"

        coordinator.setActiveRecordingMode(.edit)
        XCTAssertTrue(coordinator.isRecordingForRewrite)
        XCTAssertFalse(coordinator.isRecordingForCommand)
        XCTAssertNil(coordinator.activeDictationShortcutSlot)
        XCTAssertNil(coordinator.promptModeOverrideText)

        coordinator.setActiveRecordingMode(.command)
        XCTAssertTrue(coordinator.isRecordingForCommand)
        XCTAssertFalse(coordinator.isRecordingForRewrite)

        coordinator.activeDictationShortcutSlot = .primary
        coordinator.setActiveRecordingMode(.dictate)
        XCTAssertEqual(coordinator.activeDictationShortcutSlot, .primary, "dictation keeps its slot")
        XCTAssertFalse(coordinator.isRecordingForCommand)

        coordinator.clearActiveRecordingMode()
        XCTAssertEqual(coordinator.activeRecordingMode, .none)
    }

    func testCancelPrewarm_cancelsAndClearsTask() {
        let coordinator = DictationCoordinator()
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        coordinator.prewarmDictationTask = task
        coordinator.cancelPrewarmDictationIfNeeded()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.prewarmDictationTask)
    }

    func testApplyShortcutSettings_isSafeBeforeBoot() {
        let coordinator = DictationCoordinator()
        XCTAssertNil(coordinator.hotkeyManager)
        coordinator.applyShortcutSettings() // no manager yet: must be a no-op, not a crash
        XCTAssertFalse(coordinator.hotkeyManagerInitialized)
    }
}

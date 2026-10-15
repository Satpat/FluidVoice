import XCTest
@testable import FluidVoice_Debug

@MainActor
final class MeetAIBuildFlagsTests: XCTestCase {
    func testUpdaterIsDisabledOutsideTestHost() {
        XCTAssertFalse(MeetAIBuildFlags.updaterEnabled(isTestHost: false))
    }

    func testUpdaterIsEnabledInsideTestHost() {
        XCTAssertTrue(MeetAIBuildFlags.updaterEnabled(isTestHost: true))
    }
}

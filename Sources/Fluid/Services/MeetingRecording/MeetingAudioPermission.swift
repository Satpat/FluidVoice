// Ported from the MeetAI native recorder, adapted from insidegui/AudioCap.
// Uses TCC private SPI to query/request the "audio capture" permission (the
// one that gates Core Audio process taps). Gated behind ENABLE_TCC_SPI
// because TCC.framework is private; without the flag the status is assumed
// authorized and the first AudioHardwareCreateProcessTap call triggers the
// system permission prompt instead.

import SwiftUI
import OSLog

@Observable
final class MeetingAudioPermission {
    private let logger = Logger(subsystem: kMeetingRecordingSubsystem, category: "MeetingAudioPermission")

    enum Status: String { case unknown, denied, authorized }

    private(set) var status: Status = .unknown

    init() {
        #if ENABLE_TCC_SPI
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateStatus() }
        self.updateStatus()
        #else
        self.status = .authorized
        #endif
    }

    func request() {
        #if ENABLE_TCC_SPI
        guard let request = Self.requestSPI else {
            self.logger.fault("TCCAccessRequest SPI missing")
            return
        }
        request("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
            DispatchQueue.main.async {
                self?.status = granted ? .authorized : .denied
            }
        }
        #endif
    }

    private func updateStatus() {
        #if ENABLE_TCC_SPI
        guard let preflight = Self.preflightSPI else {
            self.logger.fault("TCCAccessPreflight SPI missing")
            return
        }
        let result = preflight("kTCCServiceAudioCapture" as CFString, nil)
        self.status = (result == 1) ? .denied : (result == 0 ? .authorized : .unknown)
        #endif
    }

    #if ENABLE_TCC_SPI
    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFuncType? = {
        guard let h = apiHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
        guard let h = apiHandle, let sym = dlsym(h, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFuncType.self)
    }()
    #endif
}

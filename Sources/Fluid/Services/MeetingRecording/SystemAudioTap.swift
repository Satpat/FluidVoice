// Ported from the MeetAI native recorder, adapted from insidegui/AudioCap.
// Taps the *default output device* (everything currently playing) rather than
// a specific process, which is what meeting capture wants for Teams/Zoom/etc.
// without binding to one PID.

import SwiftUI
import AudioToolbox
import OSLog
import AVFoundation

@Observable
final class SystemAudioTap {

    typealias InvalidationHandler = (SystemAudioTap) -> Void

    let muteWhenRunning: Bool
    private let logger = Logger(subsystem: kMeetingRecordingSubsystem, category: "SystemAudioTap")

    private(set) var errorMessage: String? = nil

    init(muteWhenRunning: Bool = false) {
        self.muteWhenRunning = muteWhenRunning
    }

    @ObservationIgnored private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private var invalidationHandler: InvalidationHandler?
    @ObservationIgnored private(set) var activated = false

    @MainActor
    func activate() {
        guard !self.activated else { return }
        self.activated = true
        self.errorMessage = nil
        do {
            try self.prepare()
        } catch {
            self.logger.error("activate failed: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = error.localizedDescription
            self.activated = false
        }
    }

    func invalidate() {
        guard self.activated else { return }
        defer { self.activated = false }

        self.invalidationHandler?(self)
        self.invalidationHandler = nil

        if self.aggregateDeviceID.isValid {
            var err = AudioDeviceStop(self.aggregateDeviceID, self.deviceProcID)
            if err != noErr { self.logger.warning("AudioDeviceStop: \(err, privacy: .public)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(self.aggregateDeviceID, deviceProcID)
                if err != noErr { self.logger.warning("AudioDeviceDestroyIOProcID: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
            if err != noErr { self.logger.warning("DestroyAggregateDevice: \(err, privacy: .public)") }
            self.aggregateDeviceID = .unknown
        }

        if self.processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(self.processTapID)
            if err != noErr { self.logger.warning("DestroyProcessTap: \(err, privacy: .public)") }
            self.processTapID = .unknown
        }
    }

    private func prepare() throws {
        // Capture every process EXCEPT our own (so we don't tap our own UI sounds)
        // mixed down to stereo. macOS handles routing via a private aggregate device.
        var excluded: [AudioObjectID] = []
        if let selfProcessObject = try? AudioObjectID.translatePIDToProcessObjectID(pid: getpid()) {
            excluded.append(selfProcessObject)
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = self.muteWhenRunning ? .mutedWhenTapped : .unmuted
        tapDescription.isPrivate = true

        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw MeetingRecordingError(
                "AudioHardwareCreateProcessTap failed (\(err)). " +
                    "Check that System Settings → Privacy & Security → Microphone & " +
                    "System Audio Recording grants permission to FluidVoice."
            )
        }
        self.processTapID = tapID
        self.logger.debug("Process tap #\(tapID, privacy: .public)")

        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FluidVoice-MeetAI-Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        self.aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &self.aggregateDeviceID)
        guard err == noErr else { throw MeetingRecordingError("AudioHardwareCreateAggregateDevice: \(err)") }
        self.logger.debug("Aggregate device #\(self.aggregateDeviceID, privacy: .public)")
    }

    func run(on queue: DispatchQueue,
             ioBlock: @escaping AudioDeviceIOBlock,
             invalidationHandler: @escaping InvalidationHandler) throws
    {
        assert(self.activated, "run() called with inactive tap")
        assert(self.invalidationHandler == nil, "run() called with tap already running")
        self.invalidationHandler = invalidationHandler

        var err = AudioDeviceCreateIOProcIDWithBlock(&self.deviceProcID, self.aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw MeetingRecordingError("AudioDeviceCreateIOProcIDWithBlock: \(err)") }

        err = AudioDeviceStart(self.aggregateDeviceID, self.deviceProcID)
        guard err == noErr else { throw MeetingRecordingError("AudioDeviceStart: \(err)") }
    }

    deinit { self.invalidate() }
}

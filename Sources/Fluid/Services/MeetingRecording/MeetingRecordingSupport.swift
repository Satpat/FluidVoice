// Ported from the MeetAI native recorder (macos/claude/MeetAI), which adapted
// insidegui/AudioCap. Helper extensions on AudioObjectID for property access
// and process discovery, used by the system-audio tap.

import Foundation
import AudioToolbox

/// OSLog subsystem for the meeting-recording layer (kept separate from
/// DebugLogger because tap/IO callbacks run on realtime-adjacent queues).
let kMeetingRecordingSubsystem = "com.fluidvoice.meetai.recording"

struct MeetingRecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { self.message }
}

// MARK: - Constants

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !self.isUnknown }
}

// MARK: - Concrete property helpers

extension AudioObjectID {
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioDeviceID.system.readDefaultSystemOutputDevice()
    }

    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try AudioDeviceID.system.translatePIDToProcessObjectID(pid: pid)
    }

    func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try self.requireSystemObject()
        let processObject = try self.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid
        )
        guard processObject.isValid else { throw MeetingRecordingError("Invalid process identifier: \(pid)") }
        return processObject
    }

    func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try self.requireSystemObject()
        return try self.read(kAudioHardwarePropertyDefaultSystemOutputDevice,
                             defaultValue: AudioDeviceID.unknown)
    }

    func readDeviceUID() throws -> String { try self.readString(kAudioDevicePropertyDeviceUID) }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try self.read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    private func requireSystemObject() throws {
        if self != .system { throw MeetingRecordingError("Only supported for the system object.") }
    }
}

// MARK: - Generic property access

extension AudioObjectID {
    func read<T, Q>(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    defaultValue: T,
                    qualifier: Q) throws -> T
    {
        try self.read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
                      defaultValue: defaultValue, qualifier: qualifier)
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T
    {
        try self.read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
                      defaultValue: defaultValue)
    }

    func read<T, Q>(_ address: AudioObjectPropertyAddress, defaultValue: T, qualifier: Q) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { qualifierPtr in
            try self.read(address, defaultValue: defaultValue,
                          inQualifierSize: qualifierSize, inQualifierData: qualifierPtr)
        }
    }

    func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
        try self.read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        try self.read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
                      defaultValue: "" as CFString) as String
    }

    private func read<T>(_ inAddress: AudioObjectPropertyAddress,
                         defaultValue: T,
                         inQualifierSize: UInt32 = 0,
                         inQualifierData: UnsafeRawPointer? = nil) throws -> T {
        var address = inAddress
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, inQualifierSize, inQualifierData, &dataSize)
        guard err == noErr else { throw MeetingRecordingError("Error reading data size for \(inAddress): \(err)") }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
        }
        guard err == noErr else { throw MeetingRecordingError("Error reading data for \(inAddress): \(err)") }
        return value
    }
}

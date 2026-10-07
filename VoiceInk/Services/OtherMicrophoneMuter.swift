import CoreAudio
import Foundation
import os

/// Hardware-mutes every *other* microphone that is in use while VoiceInk records,
/// so a call app on a different mic (e.g. Telegram on a USB mic) can't hear the dictation.
/// Only devices muted by VoiceInk are restored, and the list is persisted so a crash
/// mid-recording is repaired on the next launch.
final class OtherMicrophoneMuter: ObservableObject {
    static let shared = OtherMicrophoneMuter()

    static let enabledKey = "isOtherMicrophoneMuteEnabled"
    private static let pendingRestoreKey = "otherMicrophoneMutePendingRestoreUIDs"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OtherMicrophoneMuter")
    private let lock = NSLock()
    private var mutedDeviceUIDs: Set<String> = []

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: OtherMicrophoneMuter.enabledKey) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private init() {}

    enum MuteResult {
        case disabled
        /// Muted these device names.
        case muted([String])
        /// Nothing else was in use.
        case nothingToMute
        /// Another app is capturing from the same mic VoiceInk records from, so it can't be muted.
        case sharedWithRecordingDevice
    }

    /// Call right before VoiceInk starts capturing from `recordingDeviceID`.
    @discardableResult
    func muteOtherMicrophones(recordingDeviceID: AudioDeviceID) -> MuteResult {
        guard isEnabled else { return .disabled }

        var names: [String] = []
        for device in Self.inputDevices() where device.id != recordingDeviceID {
            guard Self.isRunningSomewhere(device.id),
                let currentlyMuted = Self.isMuted(device.id),
                !currentlyMuted
            else { continue }

            guard Self.setMuted(true, deviceID: device.id) else {
                logger.warning("Could not mute input device \(device.name, privacy: .public)")
                continue
            }
            lock.withLock { _ = mutedDeviceUIDs.insert(device.uid) }
            names.append(device.name)
        }
        persistPendingRestore()

        if !names.isEmpty {
            logger.notice("Muted other microphones: \(names, privacy: .public)")
            return .muted(names)
        }
        if Self.isRunningSomewhere(recordingDeviceID) {
            return .sharedWithRecordingDevice
        }
        return .nothingToMute
    }

    /// Unmutes a single device we muted (e.g. VoiceInk switched to it mid-recording).
    func release(deviceID: AudioDeviceID) {
        guard let uid = Self.deviceUID(deviceID) else { return }
        let wasMutedByUs = lock.withLock { mutedDeviceUIDs.remove(uid) != nil }
        guard wasMutedByUs else { return }
        _ = Self.setMuted(false, deviceID: deviceID)
        persistPendingRestore()
    }

    /// Restores every microphone VoiceInk muted. Safe to call repeatedly.
    func restoreOtherMicrophones() {
        let uids = lock.withLock { () -> Set<String> in
            let current = mutedDeviceUIDs
            mutedDeviceUIDs.removeAll()
            return current
        }
        restore(uids: uids)
        persistPendingRestore()
    }

    /// Repairs mutes left behind by a crash or force-quit during a recording.
    func restoreAfterUnexpectedExit() {
        let pending = Set(UserDefaults.standard.stringArray(forKey: Self.pendingRestoreKey) ?? [])
        guard !pending.isEmpty else { return }
        logger.notice("Restoring microphones left muted by a previous session")
        restore(uids: pending)
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    private func restore(uids: Set<String>) {
        guard !uids.isEmpty else { return }
        for device in Self.inputDevices() where uids.contains(device.uid) {
            if !Self.setMuted(false, deviceID: device.id) {
                logger.warning("Could not unmute input device \(device.name, privacy: .public)")
            }
        }
    }

    private func persistPendingRestore() {
        let uids = lock.withLock { Array(mutedDeviceUIDs) }
        if uids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
        } else {
            UserDefaults.standard.set(uids, forKey: Self.pendingRestoreKey)
        }
    }

    // MARK: - Core Audio helpers

    private struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
            == noErr
        else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id), let uid = deviceUID(id) else { return nil }
            return InputDevice(id: id, uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func muteAddress(_ deviceID: AudioDeviceID) -> AudioObjectPropertyAddress? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address) { return address }
        address.mElement = 1
        return AudioObjectHasProperty(deviceID, &address) ? address : nil
    }

    private static func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        guard var address = muteAddress(deviceID) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private static func setMuted(_ muted: Bool, deviceID: AudioDeviceID) -> Bool {
        guard var address = muteAddress(deviceID) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }
}

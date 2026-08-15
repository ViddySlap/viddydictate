import CoreAudio
import Foundation

/// Core Audio input-device enumeration + UID resolution for the Settings mic picker.
///
/// Every device is identified by its UID (`kAudioDevicePropertyDeviceUID`) — the stable id that
/// survives unplug/reconnect — so a pinned mic re-binds to the same physical device by name. The
/// AudioRecorder binds the engine's HAL input to the resolved AudioDeviceID before reading the
/// format; this enum only reads, it never mutates device state.
enum AudioDevices {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// All input-capable hardware devices (those with at least one input channel), in system order.
    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// The AudioDeviceID currently present for `uid`, if that device is plugged in and input-capable.
    /// Returns nil when the pinned device is absent — the caller then falls back to the system default.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }?.id
    }

    // MARK: Core Audio property reads

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// True when the device exposes at least one input channel (filters output-only devices out).
    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        // An output-only device reports a buffer list with zero AudioBuffers; allocate(maximumBuffers:0)
        // traps, so bail early — no input buffers means no input streams.
        let maxBuffers = (Int(size) - MemoryLayout<UInt32>.size) / MemoryLayout<AudioBuffer>.stride
        guard maxBuffers > 0 else { return false }
        let bufList = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(bufList.unsafeMutablePointer) }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList.unsafeMutablePointer) == noErr else {
            return false
        }
        for buf in bufList where buf.mNumberChannels > 0 { return true }
        return false
    }

    /// The device's current nominal sample rate (the hardware truth) — used both as the authoritative
    /// tap rate when an engine reports a stale format after a device bind, and as a probe cross-check.
    static func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        cfStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        cfStringProperty(id, selector: kAudioObjectPropertyName)
    }

    /// Read a CFString device property (UID or name) on the global scope.
    private static func cfStringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cf else { return nil }
        return s as String
    }
}

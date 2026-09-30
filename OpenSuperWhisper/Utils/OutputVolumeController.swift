import AudioToolbox
import CoreAudio
import Foundation

protocol OutputVolumeControlling: AnyObject {
    func mute()
    func restore()
}

final class OutputVolumeController: OutputVolumeControlling {
    static let shared = OutputVolumeController()

    private struct MutedDevice {
        let deviceID: AudioDeviceID
        let volume: Float32
    }

    private let lock = NSLock()
    private var mutedDevice: MutedDevice?

    private init() {}

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutedDevice != nil
    }

    /// Drops the default output device to silence so the Mac's own playback is
    /// not captured by the microphone while dictating. The previous level is
    /// remembered so `restore()` puts the user back exactly where they were.
    func mute() {
        lock.lock()
        defer { lock.unlock() }
        guard mutedDevice == nil, let deviceID = defaultOutputDeviceID() else { return }
        guard let volume = scalarVolume(deviceID: deviceID), volume > 0 else { return }
        guard setScalarVolume(deviceID: deviceID, volume: 0) else { return }
        mutedDevice = MutedDevice(deviceID: deviceID, volume: volume)
    }

    /// Restores the volume captured by `mute()`. Restoring targets the device
    /// that was actually muted, so switching output mid-session cannot write the
    /// old device's level onto the new one. Safe to call when nothing is muted,
    /// which makes it usable as a termination safety net.
    func restore() {
        lock.lock()
        let muted = mutedDevice
        mutedDevice = nil
        lock.unlock()

        guard let muted else { return }
        _ = setScalarVolume(deviceID: muted.deviceID, volume: muted.volume)
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Prefers the virtual main volume so a single write silences every channel.
    /// Falls back to the main element scalar, which some devices expose instead.
    private func readVolume(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)

        return status == noErr ? volume : nil
    }

    private func scalarVolume(deviceID: AudioDeviceID) -> Float32? {
        readVolume(deviceID: deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            ?? readVolume(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
    }

    private func setScalarVolume(deviceID: AudioDeviceID, volume: Float32) -> Bool {
        writeVolume(deviceID: deviceID, volume: volume, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            || writeVolume(deviceID: deviceID, volume: volume, selector: kAudioDevicePropertyVolumeScalar)
    }

    private func writeVolume(deviceID: AudioDeviceID, volume: Float32, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableVolume = volume
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )

        return status == noErr
    }
}

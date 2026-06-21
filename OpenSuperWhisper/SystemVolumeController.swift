import Foundation
import CoreAudio
import AudioToolbox

/// Temporarily lowers the system output volume while recording, then restores it.
/// Uses the default output device's "virtual main volume" (the one the volume keys
/// control). Reliable and detection-free — unlike pausing, there's nothing to probe.
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    /// The volume captured before ducking, restored on `restore()`. nil when not ducked.
    private var savedVolume: Float32?

    /// Lowers the output volume to `level` (0...1), remembering the current volume.
    /// No-op if already ducked or the device volume can't be read.
    func duck(to level: Float32) {
        guard savedVolume == nil, let device = Self.defaultOutputDevice(),
              let current = Self.volume(of: device) else { return }
        savedVolume = current
        Self.setVolume(level, of: device)
    }

    /// Restores the volume captured by the last `duck`.
    func restore() {
        defer { savedVolume = nil }
        guard let saved = savedVolume, let device = Self.defaultOutputDevice() else { return }
        Self.setVolume(saved, of: device)
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    private static func mainVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of device: AudioDeviceID) -> Float32? {
        var addr = mainVolumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol)
        return status == noErr ? vol : nil
    }

    @discardableResult
    private static func setVolume(_ level: Float32, of device: AudioDeviceID) -> Bool {
        var addr = mainVolumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value = max(0, min(1, level))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr
    }
}

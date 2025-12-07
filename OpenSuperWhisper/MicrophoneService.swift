import AVFoundation
import Foundation
import Combine
import CoreAudio

class MicrophoneService: ObservableObject {
    static let shared = MicrophoneService()
    
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice?
    @Published var currentMicrophone: AudioDevice?
    
    private var deviceChangeObserver: Any?
    private var timer: Timer?
    
    struct AudioDevice: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let manufacturer: String?
        let isBuiltIn: Bool
        
        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            return lhs.id == rhs.id
        }
        
        var displayName: String {
            return name
        }
    }
    
    private init() {
        loadSavedMicrophone()
        refreshAvailableMicrophones()
        setupDeviceMonitoring()
        updateCurrentMicrophone()
    }
    
    deinit {
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
    }
    
    private func setupDeviceMonitoring() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAvailableMicrophones()
            self?.updateCurrentMicrophone()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAvailableMicrophones()
            self?.updateCurrentMicrophone()
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateCurrentMicrophone()
        }
    }
    
    func refreshAvailableMicrophones() {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.microphone, .external, .builtInMicrophone]
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        availableMicrophones = discoverySession.devices
            .filter { device in
                !device.uniqueID.contains("CADefaultDeviceAggregate")
            }
            .map { device in
                let isBuiltIn = isBuiltInDevice(device)
                return AudioDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    manufacturer: device.manufacturer,
                    isBuiltIn: isBuiltIn
                )
            }
        
        if availableMicrophones.isEmpty {
            selectedMicrophone = nil
            currentMicrophone = nil
        }
    }
    
    private func isBuiltInDevice(_ device: AVCaptureDevice) -> Bool {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if device.deviceType == .microphone {
                let uniqueID = device.uniqueID.lowercased()
                if uniqueID.contains("builtin") || uniqueID.contains("internal") {
                    return true
                }
            }
        } else {
            if device.deviceType == .builtInMicrophone {
                return true
            }
        }
        
        let manufacturer = device.manufacturer
        let mfr = manufacturer.lowercased()
        if mfr.contains("apple") {
            let uniqueID = device.uniqueID.lowercased()
            if uniqueID.contains("builtin") || 
               uniqueID.contains("internal") ||
               (!uniqueID.contains("usb") &&
               !uniqueID.contains("bluetooth") &&
               !uniqueID.contains("airpods")) {
                return true
            }
        }
        
        return false
        #else
        return device.deviceType == .builtInMicrophone
        #endif
    }
    
    private func updateCurrentMicrophone() {
        guard let selected = selectedMicrophone else {
            currentMicrophone = getDefaultMicrophone()
            return
        }
        
        if isDeviceAvailable(selected) {
            currentMicrophone = selected
        } else {
            currentMicrophone = getDefaultMicrophone()
        }
    }
    
    func isDeviceAvailable(_ device: AudioDevice) -> Bool {
        return availableMicrophones.contains(where: { $0.id == device.id })
    }
    
    func getDefaultMicrophone() -> AudioDevice? {
        if let builtIn = availableMicrophones.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        return availableMicrophones.first
    }
    
    func selectMicrophone(_ device: AudioDevice) {
        selectedMicrophone = device
        saveMicrophone(device)
        updateCurrentMicrophone()
        
        NotificationCenter.default.post(
            name: .microphoneDidChange,
            object: nil,
            userInfo: ["device": device]
        )
    }
    
    func getActiveMicrophone() -> AudioDevice? {
        return currentMicrophone
    }
    
    func getAVCaptureDevice() -> AVCaptureDevice? {
        guard let active = getActiveMicrophone() else { return nil }
        return AVCaptureDevice(uniqueID: active.id)
    }
    
    private func saveMicrophone(_ device: AudioDevice) {
        if let encoded = try? JSONEncoder().encode(device) {
            AppPreferences.shared.selectedMicrophoneData = encoded
        }
    }
    
    private func loadSavedMicrophone() {
        guard let data = AppPreferences.shared.selectedMicrophoneData,
              let device = try? JSONDecoder().decode(AudioDevice.self, from: data) else {
            return
        }
        selectedMicrophone = device
    }
    
    func resetToDefault() {
        selectedMicrophone = nil
        AppPreferences.shared.selectedMicrophoneData = nil
        updateCurrentMicrophone()
    }
    
    #if os(macOS)
    func getCoreAudioDeviceID(for device: AudioDevice) -> AudioDeviceID? {
        var deviceID = device.id as CFString
        var audioDeviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var translation = AudioValueTranslation(
            mInputData: &deviceID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &audioDeviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        propertySize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translationAddress,
            0,
            nil,
            &propertySize,
            &translation
        )
        
        return status == noErr ? audioDeviceID : nil
    }
    
    func setAsSystemDefaultInput(_ device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return false
        }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        
        return status == noErr
    }
    
    func getCurrentSystemDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    #endif
}

extension Notification.Name {
    static let microphoneDidChange = Notification.Name("microphoneDidChange")
}


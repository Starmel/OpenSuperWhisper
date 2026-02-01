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
            let name = device.localizedName.lowercased()
            
            let isContinuity = name.contains("iphone") || name.contains("continuity") || name.contains("handoff") ||
                               uniqueID.contains("iphone") || uniqueID.contains("continuity") || uniqueID.contains("handoff")
            
            if uniqueID.contains("builtin") || 
               uniqueID.contains("internal") ||
               (!uniqueID.contains("usb") &&
               !uniqueID.contains("bluetooth") &&
               !uniqueID.contains("airpods") &&
               !isContinuity) {
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
    
    func isActiveMicrophoneBluetooth() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isBluetoothMicrophone(device)
    }
    
    func isActiveMicrophoneRequiresConnection() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isBluetoothMicrophone(device) || isContinuityMicrophone(device)
    }
    
    func isBluetoothMicrophone(_ device: AudioDevice) -> Bool {
        if let avDevice = AVCaptureDevice(uniqueID: device.id) {
            let transportType = avDevice.transportType
            if transportType == 1651275109 {
                return true
            }
        }
        
        let name = device.name.lowercased()
        let id = device.id.lowercased()
        let hasBluetoothInName = name.contains("bluetooth")
        let hasBluetoothInID = id.contains("bluetooth")
        let macAddressPattern = "^[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}"
        let hasMACAddress = id.range(of: macAddressPattern, options: .regularExpression) != nil
        
        if hasBluetoothInName || hasBluetoothInID {
            return true
        }
        
        if hasMACAddress {
            let transportType = getTransportType(for: device)
            return transportType == 1651275109
        }
        
        return false
    }
    
    private func getTransportType(for device: AudioDevice) -> Int32 {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return 0 }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &transportType
        )
        
        return status == noErr ? Int32(transportType) : 0
    }
    
    func isActiveMicrophoneContinuity() -> Bool {
        guard let device = getActiveMicrophone() else { return false }
        return isContinuityMicrophone(device)
    }
    
    func isContinuityMicrophone(_ device: AudioDevice) -> Bool {
        let name = device.name.lowercased()
        let id = device.id.lowercased()
        let manufacturer = (device.manufacturer ?? "").lowercased()
        let isApple = manufacturer.contains("apple")
        let hasContinuityName = name.contains("continuity") || id.contains("continuity")
        let hasIPhoneName = name.contains("iphone") || id.contains("iphone")
        let hasHandoffName = name.contains("handoff") || id.contains("handoff")
        return isApple && (hasContinuityName || hasIPhoneName || hasHandoffName)
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
    
    func getInputVolume(for deviceID: AudioDeviceID) -> Float? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 1
        )
        
        var hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        
        if !hasProperty {
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        }
        
        guard hasProperty else {
            return nil
        }
        
        var volume: Float32 = 0.0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )
        
        return status == noErr ? volume : nil
    }
    
    func setInputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 1
        )
        
        var hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        
        if !hasProperty {
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            hasProperty = AudioObjectHasProperty(deviceID, &propertyAddress)
        }
        
        guard hasProperty else {
            return false
        }
        
        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        
        guard status == noErr, isSettable.boolValue else {
            return false
        }
        
        var mutableVolume = max(0.0, min(1.0, volume))
        status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )
        
        return status == noErr
    }
    
    func getInputVolume(for device: AudioDevice) -> Float? {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return nil
        }
        return getInputVolume(for: deviceID)
    }
    
    func setInputVolume(_ volume: Float, for device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return false
        }
        return setInputVolume(volume, for: deviceID)
    }
    #endif
}

extension Notification.Name {
    static let microphoneDidChange = Notification.Name("microphoneDidChange")
}


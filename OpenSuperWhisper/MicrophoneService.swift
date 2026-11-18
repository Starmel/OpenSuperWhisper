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
        #if os(macOS)
        // The microphone the system uses as default input right now is the one the
        // user actually talks into elsewhere, so it beats any guess: a built-in
        // device may exist while the real microphone is an external or webcam one.
        if let defaultID = getCurrentSystemDefaultInputDevice(),
           isValidInputDeviceID(defaultID),
           let matching = availableMicrophones.first(where: { getCoreAudioDeviceID(for: $0) == defaultID }) {
            return matching
        }
        #endif
        
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
        Self.isBluetoothMicrophone(
            device,
            avTransportType: AVCaptureDevice(uniqueID: device.id)?.transportType,
            coreAudioTransportType: { self.getTransportType(for: device) }
        )
    }

    static func isBluetoothMicrophone(
        _ device: AudioDevice,
        avTransportType: Int32?,
        coreAudioTransportType: () -> Int32
    ) -> Bool {
        if avTransportType == Int32(kAudioDeviceTransportTypeBluetooth) {
            return true
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
            return coreAudioTransportType() == Int32(kAudioDeviceTransportTypeBluetooth)
        }
        
        return false
    }
    
    private func getTransportType(for device: AudioDevice) -> Int32 {
        guard let deviceID = getCoreAudioDeviceID(for: device),
              isValidInputDeviceID(deviceID) else {
            // Not a device we can read from: report "unknown" rather than a 0 that
            // looks like a transport type the HAL actually returned.
            return Int32(kAudioDeviceTransportTypeUnknown)
        }
        
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
        
        return status == noErr ? Int32(transportType) : Int32(kAudioDeviceTransportTypeUnknown)
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
        
        // A successful lookup can still hand back 0 (`kAudioObjectUnknown`),
        // which means "no such device": there is nothing to point the engine at.
        guard status == noErr, audioDeviceID != kAudioObjectUnknown else { return nil }
        return audioDeviceID
    }
    
    /// Whether `deviceID` can actually record: 0 is `kAudioObjectUnknown`, the HAL
    /// does not know unknown ids, and an id with no input streams is not a microphone.
    /// Aggregates, virtual devices and loopbacks all have input streams, so they are
    /// valid here: only a class check would have thrown them out.
    func isValidInputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return false }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize) == noErr,
              propertySize >= UInt32(MemoryLayout<UInt32>.size) else {
            return false
        }
        
        let bufferListRawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListRawPointer.deallocate() }
        
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListRawPointer) == noErr else {
            return false
        }
        
        // mNumberBuffers is the first field of AudioBufferList, and the list was
        // sized for at least one field: no input buffers means nothing to record.
        return bufferListRawPointer.assumingMemoryBound(to: UInt32.self).pointee > 0
    }
    
    /// The system's default input device, read and never written.
    ///
    /// This is the app's only reach of `kAudioHardwarePropertyDefaultInputDevice`:
    /// it is what the picker falls back to, and what recording is measured
    /// against. Nothing here — or anywhere else in the app — writes it, so a
    /// capture that dies mid-recording cannot leave the user's own setting
    /// pointing somewhere he did not choose.
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
        // 0 (`kAudioObjectUnknown`) and ids without input streams are not devices,
        // so there is no volume to read: unavailable, not a value.
        guard isValidInputDeviceID(deviceID) else { return nil }
        
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
        // Writing a volume to 0 (`kAudioObjectUnknown`) or to an id with no input
        // streams would report success for a device that cannot record at all.
        guard isValidInputDeviceID(deviceID) else { return false }
        
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


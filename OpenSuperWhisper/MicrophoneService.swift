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
        let transportType: UInt32?

        init(
            id: String,
            name: String,
            manufacturer: String?,
            isBuiltIn: Bool,
            transportType: UInt32? = nil
        ) {
            self.id = id
            self.name = name
            self.manufacturer = manufacturer
            self.isBuiltIn = isBuiltIn
            self.transportType = transportType
        }
        
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
        availableMicrophones = Self.coreAudioInputDevices()
        
        if availableMicrophones.isEmpty {
            selectedMicrophone = nil
            currentMicrophone = nil
        }
    }

    private static func coreAudioInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        let returnedCount = min(Int(dataSize) / MemoryLayout<AudioDeviceID>.size, count)

        return deviceIDs.prefix(returnedCount).compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(
                    kAudioDevicePropertyDeviceUID,
                    for: deviceID
                  ),
                  !uid.contains("CADefaultDeviceAggregate"),
                  let name = stringProperty(
                    kAudioObjectPropertyName,
                    for: deviceID
                  ) else {
                return nil
            }

            let manufacturer = stringProperty(
                kAudioObjectPropertyManufacturer,
                for: deviceID
            )
            let transportType = uint32Property(
                kAudioDevicePropertyTransportType,
                for: deviceID
            )

            return AudioDevice(
                id: uid,
                name: name,
                manufacturer: manufacturer,
                isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
                transportType: transportType
            )
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr && dataSize >= MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }

        return value
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
        let name = device.name.lowercased()
        let id = device.id.lowercased()
        let hasBluetoothInName = name.contains("bluetooth")
        let hasBluetoothInID = id.contains("bluetooth")
        
        if hasBluetoothInName || hasBluetoothInID {
            return true
        }
        
        let transportType = device.transportType ?? getTransportType(for: device)
        return transportType == kAudioDeviceTransportTypeBluetooth ||
               transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    
    private func getTransportType(for device: AudioDevice) -> UInt32 {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return 0 }
        return Self.uint32Property(kAudioDevicePropertyTransportType, for: deviceID) ?? 0
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

        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
            withUnsafeMutablePointer(to: &audioDeviceID) { audioDeviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(audioDeviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var propertySize = UInt32(MemoryLayout<AudioValueTranslation>.size)

                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &translationAddress,
                    0,
                    nil,
                    &propertySize,
                    &translation
                )
            }
        }
        
        return status == noErr ? audioDeviceID : nil
    }
    
    func setAsSystemDefaultInput(_ device: AudioDevice) -> Bool {
        guard let deviceID = getCoreAudioDeviceID(for: device) else {
            return false
        }
        return setSystemDefaultInputDevice(deviceID)
    }
    
    func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
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
    
    func getInputChannelCount(for device: AudioDevice) -> Int {
        guard let deviceID = getCoreAudioDeviceID(for: device) else { return 1 }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard sizeStatus == noErr, propertySize > 0 else { return 1 }
        
        let bufferListRawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListRawPointer.deallocate() }
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListRawPointer)
        guard status == noErr else { return 1 }
        
        let bufferList = bufferListRawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        
        var totalChannels = 0
        withUnsafeMutablePointer(to: &bufferList.pointee.mBuffers) { firstBufferPtr in
            let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: firstBufferPtr, count: bufferCount)
            for buffer in buffers {
                totalChannels += Int(buffer.mNumberChannels)
            }
        }
        
        return max(totalChannels, 1)
    }
    #endif
}

extension Notification.Name {
    static let microphoneDidChange = Notification.Name("microphoneDidChange")
}

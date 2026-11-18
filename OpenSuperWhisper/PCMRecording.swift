import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct RecordedAudio {
    let url: URL
    let samples: [Float]

    var duration: TimeInterval { Double(samples.count) / 16000 }
}

struct RecordingCaptureError: Error {
    let audio: RecordedAudio
    let underlying: Error
}

final class PCMRecordingWriter {
    private let url: URL
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var channels: [[Float]]

    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.url = url
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | inputFormat.channelCount) else {
            throw TranscriptionError.audioConversionFailed
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   interleaved: true, channelLayout: layout)
        guard let converter = AVAudioConverter(from: inputFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw TranscriptionError.audioConversionFailed
        }
        self.converter = converter
        self.output = output
        channels = Array(repeating: [], count: Int(format.channelCount))
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.channelMap = (0..<inputFormat.channelCount).map { NSNumber(value: $0) }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                              commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard file != nil else { throw TranscriptionError.audioConversionFailed }
        var consumed = false
        try convert { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }

    func finish() throws -> RecordedAudio {
        guard file != nil else { throw TranscriptionError.audioConversionFailed }
        try convert { _, status in
            status.pointee = .endOfStream
            return nil
        }
        file = nil
        return RecordedAudio(url: url, samples: mixedSamples())
    }

    func closeAfterFailure() -> RecordedAudio {
        file = nil
        return RecordedAudio(url: url, samples: mixedSamples())
    }

    private func convert(_ input: @escaping AVAudioConverterInputBlock) throws {
        guard let file else { throw TranscriptionError.audioConversionFailed }
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            output.frameLength = 0
            var error: NSError?
            status = converter.convert(to: output, error: &error, withInputFrom: input)
            if let error { throw error }
            guard status != .error else { throw TranscriptionError.audioConversionFailed }
            guard output.frameLength > 0 else { continue }
            try file.write(from: output)
            // What is written here is what the device produced: no trimming of
            // the leading silence, and no gain. Both are ruled, not assumed
            // (Jev 1.13.0).
            //
            // Trimming the ~217 ms of leading exact zeros is rejected: measured,
            // it recovered 0 words, and it can drop a real first phoneme
            // (trim 0.01, trim_alone_not_shippable 0.92, trim_phoneme_risk 0.91).
            //
            // Gain or normalisation belongs at decode if it is ever added, never
            // at capture (at_decode_not_capture 0.97, confidence 0.95). It is not
            // a fix for quiet input either, measured on the captain's own
            // recordings: over 23 quiet rows normalisation recovered 14 words and
            // lost 13 (net +1), a peak target netted 0, no previously-missing row
            // gained content, and the loud control was word-identical — while
            // pushing a near-silent file to a target made whisper invent words
            // ("*Bad music*" at an rms target, "*BOOM*" at a peak target).
            //
            // The app must never write the device's input volume and never refuse
            // a device for being quiet (never_write_device_absolute 0.90,
            // confidence 0.87; may_write_input_volume 0.00; may_refuse_quiet_device
            // 0.00).
            //
            // The level is the microphone's business, which is the reason not to
            // correct it here: the app applies no gain anywhere and follows the
            // system default input device, so nothing chooses the microphone.
            // Measured on this machine, a Jabra Evolve2 30 SE arrived at peak
            // −31.2 dBFS and rms −54.2 dBFS with a 217 ms zero head, an Anker
            // PowerConf C200 at peak −12.8 dBFS and rms −32.9 dBFS with 0.0 ms.
            // The quieter microphone is why the silero VAD pre-filter was eating
            // speech; that filter is off by default now.
            let data = output.int16ChannelData![0]
            let count = channels.count
            for channel in 0..<count {
                for frame in 0..<Int(output.frameLength) {
                    channels[channel].append(Float(data[frame * count + channel]) / 32768)
                }
            }
        }
    }

    private func mixedSamples() -> [Float] {
        if channels.count == 1 { return channels[0] }
        let frameCount = channels[0].count
        let workers = frameCount > 160000 ? ProcessInfo.processInfo.activeProcessorCount : 1
        let framesPerWorker = frameCount / workers
        let inputChunkSize = workers == 1 ? 1_048_576 : 262_144
        let chunkSize = min(inputChunkSize, max(8 * 1024 * 1024 / (channels.count * 4), 65536))
        var result = [Float]()
        result.reserveCapacity(frameCount)
        for worker in 0..<workers {
            let start = worker * framesPerWorker
            let end = worker == workers - 1 ? frameCount : start + framesPerWorker
            for offset in stride(from: start, to: end, by: chunkSize) {
                let range = offset..<min(offset + chunkSize, end)
                let active = channels.indices.filter { channel in
                    var energy: Float = 0
                    for sample in channels[channel][range] { energy += sample * sample }
                    return sqrtf(energy / Float(range.count)) > 0.0001
                }
                let selected = active.isEmpty ? Array(channels.indices) : active
                let normalization = 1 / Float(selected.count)
                for frame in range {
                    var sample: Float = 0
                    for channel in selected { sample += channels[channel][frame] }
                    result.append(sample * normalization)
                }
            }
        }
        return result
    }
}

/// The microphone the user chose could not be opened for capture.
///
/// There is no fallback to another device. Recording from the system default
/// while the user asked for this microphone would record the wrong thing
/// without saying so, and the system's default input is his own setting: this
/// app never writes it. Carrying the device's name out is what lets the
/// recorder name the microphone that failed.
struct MicrophoneCaptureError: Error {
    let deviceName: String
    let stage: String
    let status: OSStatus
}

/// The HAL input callback: renders one buffer of the bound device and hands it
/// to the session. Runs on the audio thread, so it must not block.
private func pcmCaptureInputProc(_ refCon: UnsafeMutableRawPointer,
                                 _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 _ inBusNumber: UInt32,
                                 _ inNumberFrames: UInt32,
                                 _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<PCMRecordingSession>.fromOpaque(refCon).takeUnretainedValue()
        .receive(numberFrames: inNumberFrames, flags: ioActionFlags, timestamp: inTimeStamp)
}

final class PCMRecordingSession {
    private let unit: AudioUnit
    private let deviceName: String
    private let format: AVAudioFormat
    private let bytesPerFrame: UInt32
    private let queue = DispatchQueue(label: "com.opensuperwhisper.pcm", qos: .userInitiated)
    private let writer: PCMRecordingWriter
    private var failure: Error?
    private let onFailure: (Error) -> Void

    /// Opens a HAL output unit for capture only — input enabled on element 1,
    /// output disabled on element 0 — bound to `deviceID` through
    /// `kAudioOutputUnitProperty_CurrentDevice`.
    ///
    /// That binding is this process's own audio unit state. It is not the
    /// system's default input device, so however this process ends — a crash, a
    /// forced quit, a power cut — there is no setting of the user's left
    /// repointed to undo. An engine with its own output side is not used here
    /// precisely because CoreAudio answers such a graph by building a
    /// `CADefaultDeviceAggregate` around the two devices.
    init(url: URL,
         deviceID: AudioDeviceID,
         deviceName: String,
         onFailure: @escaping (Error) -> Void = { _ in }) throws {
        self.onFailure = onFailure
        self.deviceName = deviceName
        let opened = try Self.openCaptureUnit(deviceID: deviceID, deviceName: deviceName)
        let writer: PCMRecordingWriter
        do {
            writer = try PCMRecordingWriter(url: url, inputFormat: opened.format)
        } catch {
            // Nothing owns the unit yet, so this failure has to close it.
            AudioComponentInstanceDispose(opened.unit)
            throw error
        }
        // Every stored property is set from here on, so a throw below disposes
        // the unit through `deinit` instead and it is never disposed twice.
        unit = opened.unit
        format = opened.format
        bytesPerFrame = opened.format.streamDescription.pointee.mBytesPerFrame
        self.writer = writer

        var callback = AURenderCallbackStruct(inputProc: pcmCaptureInputProc,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let callbackStatus = AudioUnitSetProperty(unit,
                                                  kAudioOutputUnitProperty_SetInputCallback,
                                                  kAudioUnitScope_Global,
                                                  1,
                                                  &callback,
                                                  UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard callbackStatus == noErr else {
            throw MicrophoneCaptureError(deviceName: deviceName, stage: "input callback", status: callbackStatus)
        }

        let initializeStatus = AudioUnitInitialize(unit)
        guard initializeStatus == noErr else {
            throw MicrophoneCaptureError(deviceName: deviceName, stage: "initialize", status: initializeStatus)
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Creates the capture unit bound to `deviceID`, with the device's own
    /// sample rate as a mono Float32 client format. The format returned is the
    /// one the writer is built from, so what the unit delivers and what the
    /// writer converts are the same format by construction. Every failure
    /// disposes the unit before throwing: a device that will not open leaves
    /// nothing behind.
    private static func openCaptureUnit(deviceID: AudioDeviceID,
                                        deviceName: String) throws -> (unit: AudioUnit, format: AVAudioFormat) {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicrophoneCaptureError(deviceName: deviceName, stage: "component", status: 0)
        }
        var unitOptional: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &unitOptional)
        guard newStatus == noErr, let unit = unitOptional else {
            throw MicrophoneCaptureError(deviceName: deviceName, stage: "component instance", status: newStatus)
        }
        func failure(_ stage: String, _ status: OSStatus) -> MicrophoneCaptureError {
            AudioComponentInstanceDispose(unit)
            return MicrophoneCaptureError(deviceName: deviceName, stage: stage, status: status)
        }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                          &enableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw failure("enable input", status) }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                      &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw failure("disable output", status) }

        var device = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw failure("bind device", status) }

        var deviceFormat = AudioStreamBasicDescription()
        var deviceFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                      &deviceFormat, &deviceFormatSize)
        guard status == noErr, deviceFormat.mSampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.mSampleRate, channels: 1) else {
            throw failure("device format", status)
        }
        var clientFormat = format.streamDescription.pointee
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                      &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw failure("client format", status) }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, 1,
                                      &layout, UInt32(MemoryLayout<AudioChannelLayout>.size))
        guard status == noErr else { throw failure("channel layout", status) }

        return (unit, format)
    }

    /// Records the first failure and tells the recorder. Only ever called on
    /// `queue`, which is also the only place `failure` is read.
    private func recordFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure(error)
    }

    /// Called on the audio thread for every captured buffer. The device's frames
    /// are rendered straight into the buffer the writer will read — a buffer of
    /// this session's own format, so no copy of the audio is needed — and handed
    /// to the writer's serial queue.
    func receive(numberFrames: AVAudioFrameCount,
                 flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                 timestamp: UnsafePointer<AudioTimeStamp>) -> OSStatus {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numberFrames) else {
            // Nothing to render into. The recording is failed either way, so the
            // failure is not also reported to the HAL as a render error.
            queue.async { self.recordFailure(TranscriptionError.audioConversionFailed) }
            return noErr
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<list.count {
            list[index].mDataByteSize = numberFrames * bytesPerFrame
        }
        let renderStatus = AudioUnitRender(unit, flags, timestamp, 1, numberFrames, list.unsafeMutablePointer)
        guard renderStatus == noErr else {
            queue.async { self.recordFailure(TranscriptionError.audioConversionFailed) }
            return renderStatus
        }
        buffer.frameLength = numberFrames
        queue.async {
            guard self.failure == nil else { return }
            do { try self.writer.append(buffer) }
            catch { self.recordFailure(error) }
        }
        return noErr
    }

    func start() throws {
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            throw MicrophoneCaptureError(deviceName: deviceName, stage: "start", status: status)
        }
    }

    func cancel() {
        AudioOutputUnitStop(unit)
        queue.sync {}
    }

    func finish() throws -> RecordedAudio {
        AudioOutputUnitStop(unit)
        return try queue.sync {
            do {
                if let failure { throw failure }
                return try writer.finish()
            } catch {
                throw RecordingCaptureError(audio: writer.closeAfterFailure(), underlying: error)
            }
        }
    }
}

import AVFoundation
import Foundation

struct RecordedAudio {
    let url: URL
    let samples: [Float]

    var duration: TimeInterval { Double(samples.count) / 16000 }
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

final class PCMRecordingSession {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.opensuperwhisper.pcm", qos: .userInitiated)
    private let writer: PCMRecordingWriter
    private var failure: Error?

    init(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        writer = try PCMRecordingWriter(url: url, inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.queue.async { self.failure = TranscriptionError.audioConversionFailed }
                return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                memcpy(destination[index].mData!, source[index].mData!, Int(source[index].mDataByteSize))
            }
            self.queue.async {
                guard self.failure == nil else { return }
                do { try self.writer.append(copy) }
                catch { self.failure = error }
            }
        }
        engine.prepare()
    }

    func start() throws { try engine.start() }

    func cancel() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync {}
    }

    func finish() throws -> RecordedAudio {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return try queue.sync {
            if let failure { throw failure }
            return try writer.finish()
        }
    }
}

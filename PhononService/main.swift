import Foundation
import PhononCoreML

private struct ServiceWord: Codable {
    let text: String
    let start: Double
    let end: Double
}

private struct ServiceTranscriptionResult: Codable {
    let text: String
    let words: [ServiceWord]
    let audioSeconds: Double
    let decodeSeconds: Double
    let windows: Int
    let peakResidentMemoryBytes: UInt64?
}

private struct ServicePreparationResult: Codable {
    let loadSeconds: Double
    let compileSeconds: Double
    let loadedFunctions: [Int]
    let peakResidentMemoryBytes: UInt64?
}

@objc(PhononXPCProtocol)
private protocol PhononXPCProtocol {
    func prepare(modelDirectory: String, withReply reply: @escaping (Data?, String?) -> Void)
    func transcribe(samples: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func transcribe(filePath: String, withReply reply: @escaping (Data?, String?) -> Void)
    func cancel(withReply reply: @escaping () -> Void)
}

@objc(PhononXPCProgressProtocol)
private protocol PhononXPCProgressProtocol {
    func phononProgress(phase: String, seconds: Double)
}

private final class PhononService: NSObject, PhononXPCProtocol {
    private let queue = DispatchQueue(label: "ru.starmel.OpenSuperWhisper.PhononService", qos: .userInitiated)
    private weak var connection: NSXPCConnection?
    private var transcriber: Transcriber?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func prepare(modelDirectory: String, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                var options = Transcriber.Options()
                options.computeUnits = .cpuAndNeuralEngine
                // A single eager 15-second function serves both short dictation
                // and the runtime's 15-second long-audio windows. Loading the
                // remaining palettes in the background made the first queued
                // transcription contend with ANE compilation on an M5.
                options.functions = [15]
                options.eagerFunctions = [15]
                options.backgroundLoad = false
                options.progress = { [weak self] phase, seconds in
                    guard let self,
                          let proxy = self.connection?.remoteObjectProxy as? PhononXPCProgressProtocol else { return }
                    proxy.phononProgress(phase: phase, seconds: seconds)
                }
                let transcriber = try Transcriber(bundle: URL(fileURLWithPath: modelDirectory), options: options)
                self.transcriber = transcriber
                let result = ServicePreparationResult(
                    loadSeconds: transcriber.loadSeconds,
                    compileSeconds: transcriber.compileSeconds,
                    loadedFunctions: transcriber.loadedFunctions,
                    peakResidentMemoryBytes: Self.peakResidentMemoryBytes()
                )
                reply(try JSONEncoder().encode(result), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func transcribe(samples: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard samples.count.isMultiple(of: MemoryLayout<Float>.stride) else {
                    throw NSError(domain: "PhononService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid PCM buffer."])
                }
                let wave = samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard !wave.isEmpty else {
                    throw NSError(domain: "PhononService", code: 3, userInfo: [NSLocalizedDescriptionKey: "The PCM buffer is empty."])
                }
                guard let transcriber = self.transcriber else {
                    throw NSError(domain: "PhononService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Phonon-2 is not prepared."])
                }
                reply(try self.encode(transcriber.transcribe(wave)), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func transcribe(filePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let transcriber = self.transcriber else {
                    throw NSError(domain: "PhononService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Phonon-2 is not prepared."])
                }
                reply(try self.encode(transcriber.transcribe(url: URL(fileURLWithPath: filePath))), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func cancel(withReply reply: @escaping () -> Void) {
        queue.async {
            reply()
        }
    }

    private func encode(_ transcript: Transcript) throws -> Data {
        try JSONEncoder().encode(ServiceTranscriptionResult(
            text: transcript.text,
            words: transcript.words.map { ServiceWord(text: $0.text, start: $0.start, end: $0.end) },
            audioSeconds: transcript.audioSeconds,
            decodeSeconds: transcript.decodeSeconds,
            windows: transcript.windows,
            peakResidentMemoryBytes: Self.peakResidentMemoryBytes()
        ))
    }

    private static func peakResidentMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.ledger_phys_footprint_peak > 0
            ? UInt64(info.ledger_phys_footprint_peak)
            : UInt64(info.phys_footprint)
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = PhononService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: PhononXPCProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: PhononXPCProgressProtocol.self)
        connection.resume()
        return true
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

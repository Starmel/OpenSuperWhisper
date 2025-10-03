import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    
    private var context: MyWhisperContext?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    private var abortFlag: UnsafeMutablePointer<Bool>? = nil
    private let openAIClient = OpenAITranscriptionClient()
    private let apiKeyStore = OpenAIAPIKeyStore.shared
    
    init() {
        loadModel()
    }
    
    func cancelTranscription() {
        isCancelled = true
        
        // Set the abort flag to true to signal the whisper processing to stop
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }
        
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        // Reset state
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    deinit {
        // Free the abort flag if it exists
        abortFlag?.deallocate()
    }
    
    private func loadModel() {
        print("Loading model")
        if let modelPath = AppPreferences.shared.selectedModelPath {
            isLoading = true
            
            // Capture the weak self reference before the task
            weak var weakSelf = self
            
            Task.detached(priority: .userInitiated) {
                let params = WhisperContextParams()
                let newContext = MyWhisperContext.initFromFile(path: modelPath, params: params)
                
                await MainActor.run {
                    // Use the weak self reference inside MainActor.run
                    guard let self = weakSelf else { return }
                    self.context = newContext
                    self.isLoading = false
                    print("Model loaded")
                }
            }
        }
    }
    
    func reloadModel(with path: String) {
        print("Reloading model")
        isLoading = true
        
        // Capture the weak self reference before the task
        weak var weakSelf = self
        
        Task.detached(priority: .userInitiated) {
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: path, params: params)
            
            await MainActor.run {
                // Use the weak self reference inside MainActor.run
                guard let self = weakSelf else { return }
                self.context = newContext
                self.isLoading = false
                print("Model reloaded")
            }
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        await MainActor.run {
            self.progress = 0.0
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false

            if let abortFlag = self.abortFlag {
                abortFlag.deallocate()
                self.abortFlag = nil
            }
        }

        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
                if let abortFlag = self.abortFlag {
                    abortFlag.deallocate()
                    self.abortFlag = nil
                }
            }
        }

        switch settings.transcriptionBackend {
        case .local:
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationInSeconds = Float(CMTimeGetSeconds(duration))
            await MainActor.run {
                self.totalDuration = durationInSeconds
            }
            return try await transcribeWithLocal(url: url, settings: settings)
        case .openAI:
            await MainActor.run {
                self.totalDuration = 0.0
            }
            return try await transcribeWithOpenAI(url: url, settings: settings)
        }
    }

    private func transcribeWithLocal(url: URL, settings: Settings) async throws -> String {
        let abortPointer = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        abortPointer.initialize(to: false)

        guard let contextForTask = context else {
            abortPointer.deallocate()
            throw TranscriptionError.contextInitializationFailed
        }

        await MainActor.run {
            self.abortFlag = abortPointer
        }

        let abortFlagForTask = abortPointer

        let task = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            let context = contextForTask

            guard let samples = try await self.convertAudioToPCM(fileURL: url) else {
                throw TranscriptionError.audioConversionFailed
            }

            try Task.checkCancellation()

            let nThreads = 4

            guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            guard context.encode(offset: 0, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            var params = WhisperFullParams()

            params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
            params.nThreads = Int32(nThreads)
            params.noTimestamps = !settings.showTimestamps
            params.suppressBlank = settings.suppressBlankAudio
            params.translate = settings.translateToEnglish
            params.language = settings.selectedLanguage != "auto" ? settings.selectedLanguage : nil
            params.detectLanguage = false

            params.temperature = Float(settings.temperature)
            params.noSpeechThold = Float(settings.noSpeechThreshold)
            params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt

            typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool

            let abortCallback: GGMLAbortCallback = { userData in
                guard let userData = userData else { return false }
                let flag = userData.assumingMemoryBound(to: Bool.self)
                return flag.pointee
            }

            if settings.useBeamSearch {
                params.beamSearchBeamSize = Int32(settings.beamSize)
            }

            params.printRealtime = true
            params.print_realtime = true

            let segmentCallback: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void = { ctx, state, n_new, user_data in
                guard let ctx = ctx,
                      let userData = user_data,
                      let service = Unmanaged<TranscriptionService>.fromOpaque(userData).takeUnretainedValue() as TranscriptionService?
                else { return }

                let segmentInfo = service.processNewSegment(context: ctx, state: state, nNew: Int(n_new))

                Task { @MainActor in
                    if service.isCancelled { return }

                    if !segmentInfo.text.isEmpty {
                        service.currentSegment = segmentInfo.text
                        service.transcribedText += segmentInfo.text + "\n"
                    }

                    if service.totalDuration > 0 && segmentInfo.timestamp > 0 {
                        let newProgress = min(segmentInfo.timestamp / service.totalDuration, 1.0)
                        service.progress = newProgress
                    }
                }
            }

            params.newSegmentCallback = segmentCallback
            params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()

            var cParams = params.toC()
            cParams.abort_callback = abortCallback

            cParams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlagForTask)

            try Task.checkCancellation()

            guard context.full(samples: samples, params: &cParams) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            var text = ""
            let nSegments = context.fullNSegments

            for i in 0..<nSegments {
                if i % 5 == 0 {
                    try Task.checkCancellation()
                }

                guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }

                if settings.showTimestamps {
                    let t0 = context.fullGetSegmentT0(iSegment: i)
                    let t1 = context.fullGetSegmentT1(iSegment: i)
                    text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
                }
                text += segmentText + "\n"
            }

            let cleanedText = text
                .replacingOccurrences(of: "[MUSIC]", with: "")
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var processedText = cleanedText
            if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !cleanedText.isEmpty {
                processedText = AutocorrectWrapper.format(cleanedText)
            }

            let finalText = processedText.isEmpty ? "No speech detected in the audio" : processedText

            await MainActor.run {
                if !self.isCancelled {
                    self.transcribedText = finalText
                    self.progress = 1.0
                }
            }

            return finalText
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
                self.abortFlag?.pointee = true
            }
            throw TranscriptionError.processingFailed
        }
    }

    private func transcribeWithOpenAI(url: URL, settings: Settings) async throws -> String {
        let apiKey: String
        do {
            apiKey = (try apiKeyStore.loadKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriptionError.openAIError("Unable to read API key from Keychain: \(error.localizedDescription)")
        }

        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey
        }

        let task = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()

            await MainActor.run {
                self.currentSegment = "Contacting OpenAI..."
                self.progress = 0.1
            }

            do {
                let transcript = try await openAIClient.transcribeAudio(at: url, settings: settings, apiKey: apiKey)

                try Task.checkCancellation()

                let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                var processedText = cleaned
                if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !cleaned.isEmpty {
                    processedText = AutocorrectWrapper.format(cleaned)
                }
                let finalText = processedText.isEmpty ? "No speech detected in the audio" : processedText

                await MainActor.run {
                    if !self.isCancelled {
                        self.transcribedText = finalText
                        self.currentSegment = finalText
                        self.progress = 1.0
                    }
                }

                return finalText
            } catch let error as OpenAITranscriptionClientError {
                throw TranscriptionError.openAIError(error.localizedDescription)
            } catch {
                throw TranscriptionError.openAIError(error.localizedDescription)
            }
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
            }
            throw TranscriptionError.processingFailed
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.openAIError(error.localizedDescription)
        }
    }

    // Make this method nonisolated to be callable from any context
    nonisolated func processNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int) -> (text: String, timestamp: Float) {
        let nSegments = Int(whisper_full_n_segments(context))
        let startIdx = max(0, nSegments - nNew)
        
        var newText = ""
        var latestTimestamp: Float = 0
        
        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText + " "
            
            let t1 = Float(whisper_full_get_segment_t1(context, Int32(i))) / 100.0
            latestTimestamp = max(latestTimestamp, t1)
        }
        
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedText, latestTimestamp)
    }
    
    // Make this method nonisolated to be callable from any context
    nonisolated func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            return nil
        }
        
        let params = WhisperContextParams()
        return MyWhisperContext.initFromFile(path: modelPath, params: params)
    }
    
    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: false)!
            
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
            
            let lengthInFrames = UInt32(audioFile.length)
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(lengthInFrames))
            
            guard let buffer = buffer else { return nil }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                do {
                    let tempBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(inNumPackets))
                    guard let tempBuffer = tempBuffer else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    try audioFile.read(into: tempBuffer)
                    outStatus.pointee = .haveData
                    return tempBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            
            converter.convert(to: buffer,
                              error: &error,
                              withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                return nil
            }
            
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0],
                                             count: Int(buffer.frameLength)))
        }.value
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case missingAPIKey
    case openAIError(String)
}

struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

struct OpenAIAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
        let type: String?
    }

    let error: APIError
}

enum OpenAITranscriptionClientError: LocalizedError {
    case invalidURL
    case httpError(status: Int, message: String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "OpenAI endpoint URL is invalid."
        case let .httpError(status, message):
            if let message = message, !message.isEmpty {
                return "OpenAI API error (status \(status)): \(message)"
            } else {
                return "OpenAI API request failed with status \(status)."
            }
        case .decodingFailed:
            return "Unable to decode OpenAI response."
        }
    }
}

final class OpenAITranscriptionClient {
    private let session: URLSession
    private let endpoint = "https://api.openai.com/v1/audio/transcriptions"
    private let model = "whisper-1"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribeAudio(at fileURL: URL, settings: Settings, apiKey: String) async throws -> String {
        guard let requestURL = URL(string: endpoint) else {
            throw OpenAITranscriptionClientError.invalidURL
        }

        let boundary = UUID().uuidString

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try buildMultipartBody(
            fileURL: fileURL,
            boundary: boundary,
            settings: settings
        )
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionClientError.decodingFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message: String?
            if let errorResponse = try? JSONDecoder().decode(OpenAIAPIErrorResponse.self, from: data) {
                message = errorResponse.error.message
            } else {
                message = String(data: data, encoding: .utf8)
            }
            throw OpenAITranscriptionClientError.httpError(status: httpResponse.statusCode, message: message)
        }

        if let textResponse = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) {
            return textResponse.text
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }

        throw OpenAITranscriptionClientError.decodingFailed
    }

    private func buildMultipartBody(fileURL: URL, boundary: String, settings: Settings) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            guard let fieldData = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8) else { return }
            body.append(fieldData)
        }

        func appendFileField(name: String, fileURL: URL) throws {
            let fileData = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mimeType = mimeTypeForFile(url: fileURL)

            guard let headerData = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8) else { return }
            body.append(headerData)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)

        if settings.translateToEnglish {
            appendField(name: "translate", value: "true")
        }

        if !settings.initialPrompt.isEmpty {
            appendField(name: "prompt", value: settings.initialPrompt)
        }

        appendField(name: "temperature", value: String(settings.temperature))

        if settings.selectedLanguage != "auto" {
            appendField(name: "language", value: settings.selectedLanguage)
        }

        appendField(name: "response_format", value: "json")

        try appendFileField(name: "file", fileURL: fileURL)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func mimeTypeForFile(url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension),
           let mime = utType.preferredMIMEType {
            return mime
        }
        return "audio/wav"
    }
}

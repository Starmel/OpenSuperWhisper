//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var recordings: [Recording] = []
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    
    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    
    func loadInitialData() {
        currentSearchQuery = ""
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        
        // Capture current state for async task
        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let offset = page * limit
        
        
        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }
            
            
            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }
                
                // Ensure we are still consistent with the request (basic check)
                guard self.currentSearchQuery == query else { 
                    return 
                }
                
                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }
                
                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }
    
    func search(query: String) {
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }
    
    func handleProgressUpdate(id: UUID, transcription: String, progress: Float, status: RecordingStatus) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].transcription = transcription
            recordings[index].progress = progress
            recordings[index].status = status
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
    }
    
    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
    }

    var isRecording: Bool {
        recorder.isRecording
    }
    
    func startRecording() {
        state = .recording
        startBlinking()
        recordingStartTime = Date()
        recordingDuration = 0
        
        // Start timer to track recording duration
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Capture the start time in a local variable to avoid actor isolation issues
            let startTime = Date()
            
            // Update duration on the main thread
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = startTime.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.current.add(durationTimer!, forMode: .common)
        
        recorder.startRecording()
    }

    func startDecoding() {
        state = .decoding
        stopBlinking()
        stopDurationTimer()

        if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    print("start decoding...")
                    let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())

                    // Capture the current recording duration
                    let duration = await MainActor.run { self.recordingDuration }
                    
                    // Create a new Recording instance
                    let timestamp = Date()
                    let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                    let recordingId = UUID()
                    let finalURL = Recording(
                        id: recordingId,
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: duration,
                        status: .completed,
                        progress: 1.0,
                        sourceFileURL: nil
                    ).url

                    // Move the temporary recording to final location
                    try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)

                    // Save the recording to store
                    await MainActor.run {
                        let newRecording = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: self.recordingDuration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        )
                        self.recordingStore.addRecording(newRecording)
                        // Prepend to the list if not searching or if it matches (simplification: just prepend)
                        if self.currentSearchQuery.isEmpty {
                            self.recordings.insert(newRecording, at: 0)
                        }
                    }

                    print("Transcription result: \(text)")
                } catch {
                    print("Error transcribing audio: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                }

                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }

    private func startBlinking() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.current.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showDeleteConfirmation = false
    @State private var searchTask: Task<Void, Never>? = nil

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        
        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }

    var body: some View {
        VStack {
            if !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted
            {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .onChange(of: searchText) { _, newValue in
                                performSearch(newValue)
                            }

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                debouncedSearchText = ""
                                searchTask?.cancel()
                                viewModel.search(query: "")
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(20)
                    .padding([.horizontal, .top])

                    ScrollView(showsIndicators: false) {
                        if viewModel.recordings.isEmpty {
                            VStack(spacing: 16) {
                                if !debouncedSearchText.isEmpty {
                                    // Show "no results" for search
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No results found")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Try different search terms")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                } else {
                                    // Show "start recording" tip
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No recordings yet")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Tap the record button below to get started")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)

                                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                        VStack(spacing: 8) {
                                            Text("Pro Tip:")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)

                                            HStack(spacing: 4) {
                                                Text("Press")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                                Text(shortcut.description)
                                                    .font(.system(size: 16, weight: .medium))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color.secondary.opacity(0.2))
                                                    .cornerRadius(6)
                                                Text("anywhere")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }

                                            Text("to quickly record and paste text")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 16)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(viewModel.recordings) { recording in
                                    RecordingRow(recording: recording, onDelete: {
                                        viewModel.deleteRecording(recording)
                                    })
                                    .id(recording.id)
                                    .onAppear {
                                        if recording.id == viewModel.recordings.last?.id {
                                            viewModel.loadMore()
                                        }
                                    }
                                }
                                
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 16)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.recordings.count)
                    .animation(.easeInOut(duration: 0.2), value: debouncedSearchText.isEmpty)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(NSColor.windowBackgroundColor).opacity(1),
                                        Color(NSColor.windowBackgroundColor).opacity(0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 20)
                    }

                    VStack(spacing: 16) {
                        Button(action: {
                            if viewModel.isRecording {
                                viewModel.startDecoding()
                            } else {
                                viewModel.startRecording()
                            }
                        }) {
                            if viewModel.state == .decoding {
                                ProgressView()
                                    .scaleEffect(1.0)
                                    .frame(width: 48, height: 48)
                                    .contentTransition(.symbolEffect(.replace))
                            } else {
                                MainRecordButton(isRecording: viewModel.isRecording)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.transcriptionService.isLoading || viewModel.transcriptionService.isTranscribing || viewModel.transcriptionQueue.isProcessing || viewModel.state == .decoding)
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)

                        // Нижняя панель с подсказкой и кнопками управления
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                // Подсказка о шорткате
                                HStack(spacing: 6) {
                                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                        Text(shortcut.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("to show mini recorder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)

                                // Подсказка о drag-n-drop
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .foregroundColor(.secondary)
                                        .imageScale(.medium)
                                    Text("Drop audio file here to transcribe")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)
                            }

                            Spacer()

                            HStack(spacing: 12) {
                                MicrophonePickerIconView(microphoneService: viewModel.microphoneService)
                                
                                if !viewModel.recordings.isEmpty {
                                    Button(action: {
                                        showDeleteConfirmation = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.title3)
                                            .foregroundColor(.secondary)
                                            .frame(width: 32, height: 32)
                                            .background(Color.gray.opacity(0.1))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete all recordings")
                                    .confirmationDialog(
                                        "Delete All Recordings",
                                        isPresented: $showDeleteConfirmation,
                                        titleVisibility: .visible
                                    ) {
                                        Button("Delete All", role: .destructive) {
                                            viewModel.deleteAllRecordings()
                                        }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                                    }
                                    .interactiveDismissDisabled()
                                }
                                
                                Button(action: {
                                    isSettingsPresented.toggle()
                                }) {
                                    Image(systemName: "gear")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                        .frame(width: 32, height: 32)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("Settings")
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.loadInitialData()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let transcription = userInfo["transcription"] as? String,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }
            
            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                progress: progress,
                status: status
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            // For now, reload if we are at the top or just reload everything.
            // Ideally we should intelligently merge, but for simplicity:
            viewModel.loadInitialData()
        }
        .overlay {
            let isPermissionsGranted = permissionsManager.isMicrophonePermissionGranted
                && permissionsManager.isAccessibilityPermissionGranted

            if viewModel.transcriptionService.isLoading && isPermissionsGranted {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading Whisper Model...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let onDelete: () -> Void
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var isHovered = false

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }
    
    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }
    
    private var statusText: String {
        switch recording.status {
        case .pending:
            return "In queue..."
        case .converting:
            return "Converting..."
        case .transcribing:
            return "Transcribing..."
        case .completed:
            return ""
        case .failed:
            return "Failed"
        }
    }
    
    private var displayText: String {
        if recording.transcription.isEmpty || recording.transcription == "Starting transcription..." {
            return ""
        }
        return recording.transcription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status indicator for pending/processing recordings
            if isPending {
                VStack(alignment: .leading, spacing: 4) {
                    // Show source filename
                    if let sourceFileName = recording.sourceFileName {
                        Text(sourceFileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack(spacing: 6) {
                        if recording.status == .pending {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                           
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(recording.progress))
                                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 16, height: 16)

                             Text("\(Int(recording.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            
            // Transcription content - same style for all states
            if recording.status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text("Transcription failed")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if !recording.transcription.isEmpty {
                        Text(recording.transcription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, isPending ? 4 : 8)
            } else if !displayText.isEmpty {
                TranscriptionView(
                    transcribedText: displayText, isExpanded: $showTranscription
                )
                .padding(.horizontal, 4)
                .padding(.top, isPending ? 4 : 8)
            } else if !isPending {
                // Completed but empty transcription
                Text("No speech detected")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.timestamp, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(recording.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    if !isPending && recording.status != .failed && (isHovered || isPlaying) {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            } else {
                                audioRecorder.playRecording(url: recording.url)
                            }
                        }) {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isPlaying ? .red : .accentColor)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                recording.transcription, forType: .string
                            )
                        }) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")
                    }
                    
                    if isHovered || isPlaying || isPending || recording.status == .failed {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            }
                            onDelete()
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.vertical, 4)
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    @Binding var isExpanded: Bool
    
    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isExpanded {
                    ScrollView {
                        Text(transcribedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                if hasMoreLines {
                                    isExpanded.toggle()
                                }
                            }
                    )
                } else {
                    if hasMoreLines {
                        Button(action: { isExpanded.toggle() }) {
                            Text(transcribedText)
                                .font(.body)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(transcribedText)
                            .font(.body)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(.blue)
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false
    
    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }
    
    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }
    
    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(externalMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 200)
            .padding(.vertical, 8)
        }
    }
}

struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var buttonColor: Color {
        colorScheme == .dark ? .white : .gray
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        isRecording ? Color.red.opacity(0.8) : buttonColor.opacity(0.8),
                        isRecording ? Color.red : buttonColor.opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 48, height: 48)
            .shadow(
                color: isRecording ? .red.opacity(0.5) : buttonColor.opacity(0.3),
                radius: 12,
                x: 0,
                y: 0
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                isRecording ? .red.opacity(0.6) : buttonColor.opacity(0.6),
                                isRecording ? .red.opacity(0.3) : buttonColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(isRecording ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

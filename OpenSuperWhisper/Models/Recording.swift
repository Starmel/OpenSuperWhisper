import Foundation
import GRDB

enum RecordingStatus: String, Codable {
    case pending
    case converting
    case transcribing
    case completed
    case failed
}

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    var transcription: String
    let duration: TimeInterval
    var status: RecordingStatus
    var progress: Float
    var sourceFileURL: String?
    
    var isRegeneration: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL
    }

    static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id &&
               lhs.status == rhs.status &&
               lhs.progress == rhs.progress &&
               lhs.transcription == rhs.transcription &&
               lhs.isRegeneration == rhs.isRegeneration
    }

    static var recordingsDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        return appDirectory.appendingPathComponent("recordings")
    }

    static func fileName(for id: UUID) -> String {
        "\(id.uuidString).wav"
    }

    var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }
    
    var isPending: Bool {
        status == .pending || status == .converting || status == .transcribing
    }
    
    var sourceFileName: String? {
        guard let sourceFileURL = sourceFileURL else { return nil }
        return URL(fileURLWithPath: sourceFileURL).lastPathComponent
    }

    static let databaseTableName = "recordings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
        static let status = Column(CodingKeys.status)
        static let progress = Column(CodingKeys.progress)
        static let sourceFileURL = Column(CodingKeys.sourceFileURL)
    }
}

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue?
    private let initializationError: Error?

    private convenience init() {
        let directory = Recording.recordingsDirectory.deletingLastPathComponent()
        self.init(databaseURL: directory.appendingPathComponent("recordings.sqlite"))
    }

    init(databaseURL: URL) {
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let database = try DatabaseQueue(path: databaseURL.path)
            try Self.setupDatabase(database)
            dbQueue = database
            initializationError = nil
        } catch {
            dbQueue = nil
            initializationError = error
            AppErrorCenter.shared.report("Recordings database is unavailable", error: error)
        }
    }

    init(databaseQueue: DatabaseQueue) throws {
        try Self.setupDatabase(databaseQueue)
        dbQueue = databaseQueue
        initializationError = nil
    }

    private nonisolated func database() throws -> DatabaseQueue {
        if let initializationError { throw initializationError }
        guard let dbQueue else { throw TranscriptionError.processingFailed }
        return dbQueue
    }

    private nonisolated static func setupDatabase(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1") { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
        
        migrator.registerMigration("v2_add_status") { db in
            let columns = try db.columns(in: Recording.databaseTableName)
            let columnNames = columns.map { $0.name }
            
            if !columnNames.contains("status") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "status", .text).notNull().defaults(to: "completed")
                }
            }
            if !columnNames.contains("progress") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "progress", .double).notNull().defaults(to: 1.0)
                }
            }
            if !columnNames.contains("sourceFileURL") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "sourceFileURL", .text)
                }
            }
        }
        
        try migrator.migrate(dbQueue)
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await database().read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }
    
    nonisolated func fetchRecordings(limit: Int, offset: Int) async throws -> [Recording] {
        try await database().read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func getPendingRecordings() throws -> [Recording] {
        return try database().read { db in
            try Recording
                .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                .order(Recording.Columns.timestamp.asc)
                .fetchAll(db)
        }
    }

    func getNextPendingRecording() throws -> Recording? {
        return try database().read { db in
            try Recording
                .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                .order(Recording.Columns.timestamp.asc)
                .limit(1)
                .fetchOne(db)
        }
    }

    static let recordingsDidUpdateNotification = Notification.Name("RecordingStore.recordingsDidUpdate")

    func saveFailedDictation(_ audio: RecordedAudio, error: Error) async throws -> Recording {
        let id = UUID()
        let alreadySaved = audio.url.deletingLastPathComponent().standardizedFileURL == Recording.recordingsDirectory.standardizedFileURL
        let name = alreadySaved ? audio.url.lastPathComponent : Recording.fileName(for: id)
        let destination = Recording.recordingsDirectory.appendingPathComponent(name)
        if !alreadySaved {
            try AudioRecorder.shared.moveTemporaryRecording(from: audio.url, to: destination)
        }
        let row = Recording(id: id, timestamp: Date(), fileName: name,
                            transcription: error.localizedDescription, duration: audio.duration,
                            status: .failed, progress: 0, sourceFileURL: destination.path)
        do { try await addRecordingSync(row) }
        catch { throw PreservedAudioError(url: destination, underlying: error) }
        return row
    }

    func preserveFailedDictation(_ audio: RecordedAudio, error: Error) async {
        do {
            let row = try await saveFailedDictation(audio, error: error)
            AppErrorCenter.shared.report("Recording failed", message: "\(error.localizedDescription)\nAudio saved: \(row.url.path)")
        } catch {
            AppErrorCenter.shared.report("Recording could not be added to history",
                message: "\(error.localizedDescription)\nOriginal audio location: \(audio.url.path)")
        }
    }

    func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                AppErrorCenter.shared.report("Recording could not be saved", error: error)
            }
        }
    }
    
    func addRecordingSync(_ recording: Recording) async throws {
        try await insertRecording(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await database().write { db in
            try recording.insert(db)
        }
    }
    
    func updateRecording(_ recording: Recording) {
        Task {
            do {
                try await updateRecordingInDB(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                AppErrorCenter.shared.report("Recording could not be updated", error: error)
            }
        }
    }
    
    func updateRecordingSync(_ recording: Recording) async throws {
        try await updateRecordingInDB(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    func updateRecordingProgressOnly(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus) {
        Task {
            do { try await updateRecordingProgressOnlySync(id, transcription: transcription, progress: progress, status: status) }
            catch { AppErrorCenter.shared.report("Recording could not be updated", error: error) }
        }
    }
    
    static let recordingProgressDidUpdateNotification = Notification.Name("RecordingStore.recordingProgressDidUpdate")
    
    /// Updates the in-memory copy and notifies observers without touching the database.
    private func applyLocalProgressUpdate(_ id: UUID, transcription: String? = nil, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            var updated = recordings[index]
            if let transcription = transcription {
                updated.transcription = transcription
            }
            updated.progress = progress
            updated.status = status
            if let isRegeneration = isRegeneration {
                updated.isRegeneration = isRegeneration
            }
            recordings[index] = updated
        }
        
        var userInfo: [String: Any] = [
            "id": id,
            "progress": progress,
            "status": status
        ]
        if let transcription = transcription {
            userInfo["transcription"] = transcription
        }
        if let isRegeneration = isRegeneration {
            userInfo["isRegeneration"] = isRegeneration
        }
        
        NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
    }
    
    /// Progress ticks are ephemeral UI state: persisting each one caused up to
    /// ~100 SQLite transactions per transcription. Status transitions are still
    /// persisted by the explicit update methods.
    func updateRecordingProgressTransient(_ id: UUID, progress: Float, status: RecordingStatus) {
        applyLocalProgressUpdate(id, progress: progress, status: status)
    }
    
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async throws {
        _ = try await database().write { db -> Int in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.transcription.set(to: transcription),
                    Recording.Columns.progress.set(to: progress),
                    Recording.Columns.status.set(to: status.rawValue)
                ])
        }
        applyLocalProgressUpdate(id, transcription: transcription, progress: progress, status: status, isRegeneration: isRegeneration)
    }

    nonisolated func updateSourceFileURL(_ id: UUID, sourceURL: String) async throws {
        try await database().write { db in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.sourceFileURL.set(to: sourceURL)
                ])
        }
    }

    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async throws {
        _ = try await database().write { db -> Int in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.progress.set(to: progress),
                    Recording.Columns.status.set(to: status.rawValue)
                ])
        }
        applyLocalProgressUpdate(id, progress: progress, status: status, isRegeneration: isRegeneration)
    }

    private nonisolated func updateRecordingInDB(_ recording: Recording) async throws {
        try await database().write { db in
            try recording.update(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        Task {
            do { try await deleteRecordingSync(recording) }
            catch { AppErrorCenter.shared.report("Recording could not be deleted", error: error) }
        }
    }

    func deleteRecordingSync(_ recording: Recording, cancelTranscription: Bool = true) async throws {
        try await database().write { db in _ = try recording.delete(db) }
        defer { NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil) }
        if cancelTranscription && recording.isPending {
            await TranscriptionQueue.shared.cancelRecordingAndWait(recording.id)
        }
        if FileManager.default.fileExists(atPath: recording.url.path) {
            try FileManager.default.removeItem(at: recording.url)
        }
    }

    func deleteAllRecordings() {
        Task {
            do { try await deleteAllRecordingsSync() }
            catch { AppErrorCenter.shared.report("Recordings could not be deleted", error: error) }
        }
    }

    func deleteAllRecordingsSync() async throws {
        await TranscriptionQueue.shared.stopProcessingQueue()
        let removed = try await database().write { db in
            let rows = try Recording.fetchAll(db)
            _ = try Recording.deleteAll(db)
            return rows
        }
        defer { NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil) }
        for recording in removed where FileManager.default.fileExists(atPath: recording.url.path) {
            try FileManager.default.removeItem(at: recording.url)
        }
    }

    nonisolated static func retentionCutoffDate(daysToKeep: Int, now: Date = Date()) -> Date? {
        guard daysToKeep > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -daysToKeep, to: now)
    }

    nonisolated static func isDeletableRecordingURL(_ url: URL) -> Bool {
        let recordingsPath = Recording.recordingsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(recordingsPath + "/") && filePath != recordingsPath
    }

    private nonisolated static let pendingStatuses = [
        RecordingStatus.pending.rawValue,
        RecordingStatus.converting.rawValue,
        RecordingStatus.transcribing.rawValue
    ]

    nonisolated func recordingsOlderThan(days: Int) async throws -> (count: Int, oldestDate: Date?) {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return (0, nil) }
        return try await database().read { db in
            let request = Recording
                .filter(Recording.Columns.timestamp < cutoff)
                .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
            let count = try request.fetchCount(db)
            let oldest = try request
                .order(Recording.Columns.timestamp.asc)
                .limit(1)
                .fetchOne(db)
            return (count, oldest?.timestamp)
        }
    }

    func deleteRecordings(olderThanDays days: Int) async throws {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return }
        let outdated = try await database().read { db in
            try Recording
                .filter(Recording.Columns.timestamp < cutoff)
                .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
                .fetchAll(db)
        }
        guard !outdated.isEmpty else { return }

        let ids = outdated.map { $0.id }
        try await database().write { db in
            _ = try Recording
                .filter(ids.contains(Recording.Columns.id))
                .deleteAll(db)
        }
        for recording in outdated where Self.isDeletableRecordingURL(recording.url) {
            try? FileManager.default.removeItem(at: recording.url)
        }
        NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
    }

    /// Recordings created through the indicator flow used to be saved with
    /// duration = 0. Restores real durations from the audio files on disk.
    nonisolated func backfillMissingDurations() async {
        let zeroDurationRecordings = (try? await database().read { db in
            try Recording
                .filter(Recording.Columns.duration <= 0)
                .filter(Recording.Columns.status == RecordingStatus.completed.rawValue)
                .fetchAll(db)
        }) ?? []
        guard !zeroDurationRecordings.isEmpty else { return }

        var updatedAny = false
        for recording in zeroDurationRecordings {
            guard FileManager.default.fileExists(atPath: recording.url.path) else { continue }
            let duration = await AudioUtil.audioDuration(url: recording.url)
            guard duration > 0 else { continue }
            do {
                try await database().write { db in
                    _ = try Recording
                        .filter(Recording.Columns.id == recording.id)
                        .updateAll(db, [Recording.Columns.duration.set(to: duration)])
                }
                updatedAny = true
            } catch {
                print("Failed to backfill duration for \(recording.id): \(error)")
            }
        }

        if updatedAny {
            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
            }
        }
    }

    nonisolated static func recordingsDiskUsage() -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Recording.recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    func searchRecordings(query: String) throws -> [Recording] {
        return try database().read { db in
            try Recording
                .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                .order(Recording.Columns.timestamp.desc)
                .limit(100)
                .fetchAll(db)
        }
    }
    
    nonisolated func searchRecordingsAsync(query: String, limit: Int = 100, offset: Int = 0) async throws -> [Recording] {
        return try await database().read { db in
            try Recording
                .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }
}

struct PreservedAudioError: LocalizedError {
    let url: URL
    let underlying: Error
    var errorDescription: String? { "\(underlying.localizedDescription)\nAudio preserved at: \(url.path)" }
}

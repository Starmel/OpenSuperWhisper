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
    // Where the dictation happened (captured at record-start). All optional with
    // nil defaults so existing Recording(...) call sites (file imports, etc.) and
    // older recordings keep working.
    var sourceAppName: String? = nil
    var sourceWindowTitle: String? = nil
    var sourceURL: String? = nil
    /// Display name of the model used for this transcription (e.g. "whisper-large-v3").
    var modelUsed: String? = nil

    var isRegeneration: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL
        case sourceAppName, sourceWindowTitle, sourceURL, modelUsed
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
        static let sourceAppName = Column(CodingKeys.sourceAppName)
        static let sourceWindowTitle = Column(CodingKeys.sourceWindowTitle)
        static let sourceURL = Column(CodingKeys.sourceURL)
        static let modelUsed = Column(CodingKeys.modelUsed)
    }
}

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue
    private var retentionTimer: Timer?

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        let dbPath = appDirectory.appendingPathComponent("recordings.sqlite")

        print("Database path: \(dbPath.path)")

        do {
            try FileManager.default.createDirectory(
                at: appDirectory, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: dbPath.path)
            try setupDatabase()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    private nonisolated func setupDatabase() throws {
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

        // Appended AFTER my-monkeys' latest migration (v2_add_status). Both columns are
        // nullable text, so old rows simply get NULL. Guarded by a column-existence check
        // so re-running is a no-op.
        migrator.registerMigration("v3_add_source_context") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            for column in ["sourceAppName", "sourceWindowTitle", "sourceURL"]
            where !columnNames.contains(column) {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: column, .text)
                }
            }
        }

        migrator.registerMigration("v4_add_model_used") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map { $0.name }
            if !columnNames.contains("modelUsed") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "modelUsed", .text)
                }
            }
        }

        try migrator.migrate(dbQueue)
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }
    
    nonisolated func fetchRecordings(limit: Int, offset: Int) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func getPendingRecordings() -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to get pending recordings: \(error)")
            return []
        }
    }

    func getNextPendingRecording() -> Recording? {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .limit(1)
                    .fetchOne(db)
            }
        } catch {
            print("Failed to get next pending recording: \(error)")
            return nil
        }
    }

    static let recordingsDidUpdateNotification = Notification.Name("RecordingStore.recordingsDidUpdate")

    func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
                // Keep the store within the retention limit right after a new
                // recording lands, so the count behaves like a fixed-size buffer
                // instead of overshooting until the next periodic check.
                await enforceRetentionPolicy()
            } catch {
                print("Failed to add recording: \(error)")
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
        try await dbQueue.write { db in
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
                print("Failed to update recording: \(error)")
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
            await updateRecordingProgressOnlySync(id, transcription: transcription, progress: progress, status: status)
        }
    }
    
    static let recordingProgressDidUpdateNotification = Notification.Name("RecordingStore.recordingProgressDidUpdate")
    
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil, modelUsed: String? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                var assignments = [
                    Recording.Columns.transcription.set(to: transcription),
                    Recording.Columns.progress.set(to: progress),
                    Recording.Columns.status.set(to: status.rawValue)
                ]
                if let modelUsed {
                    assignments.append(Recording.Columns.modelUsed.set(to: modelUsed))
                }
                return try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, assignments)
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                var updated = recordings[index]
                updated.transcription = transcription
                updated.progress = progress
                updated.status = status
                if let isRegeneration = isRegeneration {
                    updated.isRegeneration = isRegeneration
                }
                if let modelUsed {
                    updated.modelUsed = modelUsed
                }
                recordings[index] = updated
            }

            var userInfo: [String: Any] = [
                "id": id,
                "transcription": transcription,
                "progress": progress,
                "status": status
            ]
            if let isRegeneration = isRegeneration {
                userInfo["isRegeneration"] = isRegeneration
            }
            if let modelUsed {
                userInfo["modelUsed"] = modelUsed
            }

            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
            }
        } catch {
            print("Failed to update recording progress: \(error)")
        }
    }

    nonisolated func updateSourceFileURL(_ id: UUID, sourceURL: String) async throws {
        try await dbQueue.write { db in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.sourceFileURL.set(to: sourceURL)
                ])
        }
    }

    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                var updated = recordings[index]
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
            if let isRegeneration = isRegeneration {
                userInfo["isRegeneration"] = isRegeneration
            }
            
            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
            }
        } catch {
            print("Failed to update recording status: \(error)")
        }
    }

    private nonisolated func updateRecordingInDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.update(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        if recording.isPending {
            TranscriptionQueue.shared.cancelRecording(recording.id)
        }
        
        Task {
            do {
                try await deleteRecordingFromDB(recording)
                try? FileManager.default.removeItem(at: recording.url)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete recording: \(error)")
            }
        }
    }
    
    private nonisolated func deleteRecordingFromDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            _ = try recording.delete(db)
        }
    }

    func deleteAllRecordings() {
        Task {
            do {
                let allRecordings = try await fetchAllRecordings()
                for recording in allRecordings {
                    try? FileManager.default.removeItem(at: recording.url)
                }
                try await deleteAllRecordingsFromDB()
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to delete all recordings: \(error)")
            }
        }
    }
    
    private nonisolated func deleteAllRecordingsFromDB() async throws {
        try await dbQueue.write { db in
            _ = try Recording.deleteAll(db)
        }
    }

    // MARK: - Retention policy

    /// Applies the user's retention policy, deleting recordings that exceed the
    /// configured maximum count and/or that are older than the configured age.
    /// In-progress recordings (pending / converting / transcribing) are never
    /// removed. Returns the number of recordings that were deleted.
    @discardableResult
    func enforceRetentionPolicy() async -> Int {
        let policy = RetentionPolicy()
        guard policy.isActive else { return 0 }

        let deleted: [Recording]
        do {
            deleted = try await deleteExpiredRecordings(policy: policy)
        } catch {
            print("Failed to enforce retention policy: \(error)")
            return 0
        }

        guard !deleted.isEmpty else { return 0 }

        // Remove the stored audio files off the main actor.
        await Task.detached(priority: .utility) {
            for recording in deleted {
                try? FileManager.default.removeItem(at: recording.url)
            }
        }.value

        let deletedIds = Set(deleted.map { $0.id })
        recordings.removeAll { deletedIds.contains($0.id) }

        NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        return deleted.count
    }

    /// Interval between periodic age-based retention checks.
    private static let retentionCheckInterval: TimeInterval = 60

    /// Starts a periodic timer that re-applies the retention policy.
    ///
    /// This is needed for the age-based limit: recordings expire as real time
    /// passes, even when no new recordings are added. The count-based limit does
    /// not need this — it is enforced whenever recordings are added (when the
    /// transcription queue drains). The periodic check therefore only does work
    /// while the age policy is enabled.
    func startRetentionScheduler() {
        // Run once immediately so expired recordings are cleaned up on launch.
        Task { await enforceRetentionPolicy() }

        retentionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.retentionCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                guard AppPreferences.shared.retentionMaxAgeEnabled else { return }
                await RecordingStore.shared.enforceRetentionPolicy()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    private nonisolated func deleteExpiredRecordings(policy: RetentionPolicy) async throws -> [Recording] {
        try await dbQueue.write { db in
            let activeStatuses = [
                RecordingStatus.pending.rawValue,
                RecordingStatus.converting.rawValue,
                RecordingStatus.transcribing.rawValue
            ]

            var toDelete: [UUID: Recording] = [:]

            // Age-based expiration: anything older than the cutoff date.
            if let cutoff = policy.ageCutoffDate() {
                let expired = try Recording
                    .filter(!activeStatuses.contains(Recording.Columns.status))
                    .filter(Recording.Columns.timestamp < cutoff)
                    .fetchAll(db)
                for recording in expired {
                    toDelete[recording.id] = recording
                }
            }

            // Count-based expiration: keep the newest `maxCount`, drop the rest.
            if policy.maxCountEnabled, policy.maxCount > 0 {
                let finished = try Recording
                    .filter(!activeStatuses.contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
                if finished.count > policy.maxCount {
                    for recording in finished[policy.maxCount...] {
                        toDelete[recording.id] = recording
                    }
                }
            }

            for recording in toDelete.values {
                _ = try recording.delete(db)
            }

            return Array(toDelete.values)
        }
    }

    func searchRecordings(query: String) -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .limit(100)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
    
    nonisolated func searchRecordingsAsync(query: String, limit: Int = 100, offset: Int = 0) async -> [Recording] {
        do {
            return try await dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
}

import Foundation
import GRDB

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let transcription: String
    let duration: TimeInterval

    static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id
    }

    var url: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        let recordingsDirectory = appDirectory.appendingPathComponent("recordings")
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Database Table Definition

    static let databaseTableName = "recordings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
    }
}

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue

    private init() {
        // Setup database
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
            Task {
                await loadRecordings()
            }
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    private nonisolated func setupDatabase() throws {
        try dbQueue.write { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
    }

    func loadRecordings() async {
        do {
            let loadedRecordings = try await fetchAllRecordings()
            await MainActor.run {
                self.recordings = loadedRecordings
            }
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await loadRecordings()
            } catch {
                print("Failed to add recording: \(error)")
            }
        }
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.insert(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        Task {
            do {
                try await deleteRecordingFromDB(recording)
                try FileManager.default.removeItem(at: recording.url)
                await loadRecordings()
            } catch {
                print("Failed to delete recording: \(error)")
                await loadRecordings()
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
                // Delete all files first
                for recording in recordings {
                    try? FileManager.default.removeItem(at: recording.url)
                }

                // Then clear the database
                try await deleteAllRecordingsFromDB()
                await loadRecordings()
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

    func searchRecordings(query: String) -> [Recording] {
        // For search, we'll keep it synchronous since it's used directly in UI
        // and we want immediate results
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
}

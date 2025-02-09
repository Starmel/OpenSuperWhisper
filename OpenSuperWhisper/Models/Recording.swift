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
            loadRecordings()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    private func setupDatabase() throws {
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

    private func loadRecordings() {
        do {
            recordings = try dbQueue.read { db in
                try Recording
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }

    func addRecording(_ recording: Recording) {
        do {
            try dbQueue.write { db in
                try recording.insert(db)
            }
            loadRecordings()
        } catch {
            print("Failed to add recording: \(error)")
        }
    }

    func deleteRecording(_ recording: Recording) {
        do {
            try dbQueue.write { db in
                _ = try recording.delete(db)
            }
            try FileManager.default.removeItem(at: recording.url)
        } catch {
            print("Failed to delete recording: \(error)")
        }
        loadRecordings()
    }

    func deleteAllRecordings() {
        do {
            // Delete all files first
            for recording in recordings {
                try? FileManager.default.removeItem(at: recording.url)
            }

            // Then clear the database
            try dbQueue.write { db in
                _ = try Recording.deleteAll(db)
            }
            loadRecordings()
        } catch {
            print("Failed to delete all recordings: \(error)")
        }
    }

    func searchRecordings(query: String) -> [Recording] {
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

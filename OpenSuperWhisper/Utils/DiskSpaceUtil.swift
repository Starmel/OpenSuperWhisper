import Foundation

struct DiskSpaceError: LocalizedError {
    var errorDescription: String? {
        "Very low disk space for downloading models (less than 10 GB free). Please free up some space and try again."
    }
}

enum DiskSpaceUtil {
    static let requiredFreeSpace: Int64 = 10_000_000_000

    static func hasEnoughFreeSpace(freeSpace: Int64? = nil) -> Bool {
        let available = freeSpace ?? availableFreeSpace()
        return available >= requiredFreeSpace
    }

    static func ensureEnoughFreeSpaceForModelDownload() throws {
        guard hasEnoughFreeSpace() else {
            throw DiskSpaceError()
        }
    }

    private static func availableFreeSpace() -> Int64 {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

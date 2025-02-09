import Foundation

class FileUtil {

    static func copyFileToRecordsFolder(url: URL, fileName: String) -> URL {
        
        let fileManager = FileManager.default
        let recordsFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let destinationURL = recordsFolder.appendingPathComponent(fileName)
        try! fileManager.copyItem(at: url, to: destinationURL)

        return destinationURL
    }

}

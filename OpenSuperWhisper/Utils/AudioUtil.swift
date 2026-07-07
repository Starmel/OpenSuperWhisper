import AVFoundation
import Foundation

enum AudioUtil {
    static func audioDuration(url: URL) async -> TimeInterval {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return 0 }
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : 0
        }.value
    }
}

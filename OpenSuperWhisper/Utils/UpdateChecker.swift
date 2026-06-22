import Foundation

/// A published GitHub release of the app.
struct GitHubRelease: Decodable, Identifiable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let prerelease: Bool

    var id: String { tagName }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? tagName }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// Checks for app updates and lists release notes via the public GitHub Releases API
/// (no auth, no Sparkle). The actual download is a link to the release page.
enum UpdateChecker {
    static let repo = "my-monkeys/OpenSuperWhisper"
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func fetchReleases() async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
            .filter { !$0.prerelease }
    }

    /// The newest stable release strictly newer than the running version, if any.
    static func availableUpdate(in releases: [GitHubRelease]) -> GitHubRelease? {
        releases.first { isVersion($0.tagName, newerThan: currentVersion) }
    }

    /// Numeric, component-wise semver-ish comparison ("v0.2.10" > "0.2.9").
    static func isVersion(_ tag: String, newerThan current: String) -> Bool {
        let a = components(tag), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

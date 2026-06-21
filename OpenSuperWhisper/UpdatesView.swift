import SwiftUI

/// The "Updates" settings tab: shows the current version, a manual update check, and the
/// release-note history pulled from GitHub Releases.
struct UpdatesView: View {
    @State private var releases: [GitHubRelease] = []
    @State private var isChecking = false
    @State private var availableUpdate: GitHubRelease?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                versionCard
                whatsNewSection
            }
            .padding()
        }
        .task { await loadReleases() }
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                Text("OpenSuperWhisper \(UpdateChecker.currentVersion)")
                    .font(.subheadline)

                Spacer()

                Button(action: { Task { await checkForUpdates() } }) {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled(isChecking)
            }

            if let update = availableUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.green)
                    Text("Update available: \(update.tagName)")
                        .font(.subheadline)
                    Button("Download") { NSWorkspace.shared.open(update.htmlURL) }
                        .controlSize(.small)
                }
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's New")
                .font(.headline)
                .foregroundColor(.primary)

            if releases.isEmpty {
                Text("Loading release notes…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(releases) { release in
                    releaseRow(release)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func releaseRow(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.displayName).font(.subheadline).bold()
                Spacer()
                if let date = release.publishedAt {
                    Text(date, style: .date).font(.caption).foregroundColor(.secondary)
                }
            }
            if let body = release.body, !body.isEmpty {
                Text(renderedNotes(body))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }
    }

    /// Render the markdown release notes, keeping line breaks (inline markdown only).
    /// Header markers ("## ") are stripped since SwiftUI's inline markdown shows them literally.
    private func renderedNotes(_ markdown: String) -> AttributedString {
        let cleaned = markdown.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)
        return (try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }

    private func loadReleases() async {
        guard releases.isEmpty else { return }
        releases = (try? await UpdateChecker.fetchReleases()) ?? []
    }

    private func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        statusMessage = nil
        availableUpdate = nil
        defer { isChecking = false }
        do {
            let fetched = try await UpdateChecker.fetchReleases()
            releases = fetched
            if let update = UpdateChecker.availableUpdate(in: fetched) {
                availableUpdate = update
            } else {
                statusMessage = "You're on the latest version."
            }
        } catch {
            errorMessage = "Couldn't check for updates. Check your connection and try again."
        }
    }
}

import Foundation

// Minimal subset of the GitHub "get latest release" response.
struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case prerelease
    }

    /// Finds an asset by exact name.
    func asset(named name: String) -> GitHubAsset? {
        assets.first { $0.name == name }
    }
}

enum LauncherError: LocalizedError {
    case releaseUnavailable(status: Int)
    case noReleaseForPrefix(prefix: String)
    case assetMissing(name: String, tag: String)
    case toolFailed(tool: String, status: Int32, output: String)
    case binaryMissingAfterInstall
    case launcherNotWritable(path: String)
    case dataDirInvalid

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable(let status):
            if status == 404 || status == 401 || status == 403 {
                return "Release not available yet (HTTP \(status)). The repository must be "
                     + "public and have at least one published release."
            }
            return "Failed to fetch release info (HTTP \(status))."
        case .noReleaseForPrefix(let prefix):
            return "No published release found with a \(prefix)* tag."
        case .assetMissing(let name, let tag):
            return "Release \(tag) has no asset named \(name)."
        case .toolFailed(let tool, let status, let output):
            return "\(tool) failed with code \(status): \(output)"
        case .binaryMissingAfterInstall:
            return "Game executable not found after install."
        case .launcherNotWritable(let path):
            return "Can't update the launcher in place — \(path) is not writable. "
                 + "Move the app to /Applications and try again."
        case .dataDirInvalid:
            return "The selected folder doesn't look like a Generals Zero Hour "
                 + "install (no .big archives found)."
        }
    }
}

/// Fetches release metadata from GitHub (anonymous; works once the repo is public).
enum GitHubClient {
    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GeneralsZHLauncher", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LauncherError.releaseUnavailable(status: status) }
        return data
    }

    /// All releases, newest first (client filters by tag prefix).
    static func listReleases() async throws -> [GitHubRelease] {
        let data = try await get(Config.releasesListAPI)
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// The highest-semver release whose tag starts with `prefix`. Prefers stable
    /// releases, falling back to pre-releases only if no stable one exists.
    static func latest(in releases: [GitHubRelease], prefix: String) -> GitHubRelease? {
        let matching = releases.filter { $0.tagName.hasPrefix(prefix) && SemVer($0.tagName) != nil }
        let stable = matching.filter { !$0.prerelease }
        let pool = stable.isEmpty ? matching : stable
        return pool.max { (SemVer($0.tagName)!) < (SemVer($1.tagName)!) }
    }

    /// Convenience: fetch + filter in one call.
    static func latestRelease(withPrefix prefix: String) async throws -> GitHubRelease {
        guard let r = latest(in: try await listReleases(), prefix: prefix) else {
            throw LauncherError.noReleaseForPrefix(prefix: prefix)
        }
        return r
    }
}

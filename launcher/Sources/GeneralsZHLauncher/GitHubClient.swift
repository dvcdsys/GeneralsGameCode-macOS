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

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    /// Finds the engine payload asset by exact name.
    func asset(named name: String) -> GitHubAsset? {
        assets.first { $0.name == name }
    }
}

enum LauncherError: LocalizedError {
    case releaseUnavailable(status: Int)
    case assetMissing(name: String, tag: String)
    case toolFailed(tool: String, status: Int32, output: String)
    case binaryMissingAfterInstall
    case dataDirInvalid

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable(let status):
            if status == 404 || status == 401 || status == 403 {
                return "Release not available yet (HTTP \(status)). The repository must be "
                     + "public and have at least one v* tag with a published release."
            }
            return "Failed to fetch release info (HTTP \(status))."
        case .assetMissing(let name, let tag):
            return "Release \(tag) has no asset named \(name)."
        case .toolFailed(let tool, let status, let output):
            return "\(tool) failed with code \(status): \(output)"
        case .binaryMissingAfterInstall:
            return "Game executable not found after install."
        case .dataDirInvalid:
            return "The selected folder doesn't look like a Generals Zero Hour "
                 + "install (no .big archives found)."
        }
    }
}

/// Fetches release metadata from GitHub (anonymous; works once the repo is public).
enum GitHubClient {
    static func fetchLatestRelease() async throws -> GitHubRelease {
        var req = URLRequest(url: Config.latestReleaseAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GeneralsZHLauncher", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw LauncherError.releaseUnavailable(status: status)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

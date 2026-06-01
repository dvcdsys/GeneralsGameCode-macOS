import Foundation

/// Static configuration: which repo to pull releases from, where the game
/// runtime is installed on disk, and the relevant filenames.
enum Config {
    /// GitHub repo that publishes the release assets.
    static let repoOwner = "dvcdsys"
    static let repoName  = "GeneralsGameCode-macOS"

    /// Name of the engine payload asset attached to each release
    /// (produced by scripts/package-macos-release.sh).
    static let assetName  = "GeneralsZH-macOS-arm64.zip"

    /// The executable inside the payload.
    static let binaryName = "generalszh"

    // MARK: - On-disk layout: ~/Library/Application Support/GeneralsZH/

    static var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("GeneralsZH", isDirectory: true)
    }

    /// Directory the engine binary + dylibs live in after install.
    static var runtimeDir: URL {
        supportDir.appendingPathComponent("runtime", isDirectory: true)
    }

    static var runtimeBinary: URL {
        runtimeDir.appendingPathComponent(binaryName)
    }

    /// Records the release tag currently installed (for update checks).
    static var versionFile: URL {
        supportDir.appendingPathComponent("installed-version.txt")
    }

    // MARK: - GitHub API

    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// Dev override: point at a local .zip to install instead of downloading.
    /// Lets the launcher be exercised end-to-end before any release exists.
    static var localPayloadOverride: URL? {
        guard let p = ProcessInfo.processInfo.environment["GZH_LOCAL_PAYLOAD"],
              !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    // MARK: - UserDefaults keys

    static let kDataDirBookmark = "originalDataDirBookmark"
}

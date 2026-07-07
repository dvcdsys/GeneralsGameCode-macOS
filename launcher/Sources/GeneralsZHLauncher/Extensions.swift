import Foundation

// MARK: - Manifest models (extensions/manifest.json)

/// One file an extension installs: `src` = path in the repo, `dest` = path
/// relative to the game-data folder it is copied to.
struct ExtensionFile: Decodable, Hashable {
    let src: String
    let dest: String
}

/// One catalog entry. Two kinds:
///  - "files" (default): additive loose files we host; the launcher installs/
///    removes them into the game folder.
///  - "mod-link": a third-party mod we may NOT redistribute (e.g. Cold War Crisis).
///    The launcher only links to its official download page and helps register the
///    file the user downloaded — it never hosts or fetches the mod itself.
struct ExtensionEntry: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String?           // "files" (default) | "mod-link"
    let name: String
    let summary: String
    let description: String?
    let forMod: String?
    let version: String?
    let credits: String?
    let files: [ExtensionFile]?

    // mod-link only:
    let downloadURL: String?    // official download page (opened in the browser)
    let homepageURL: String?    // mod's ModDB / home page
    let instructions: String?   // short how-to shown under the entry
    let modFileHint: String?    // e.g. "_469_CWC.gib" — which file to pick afterwards

    var isModLink: Bool { kind == "mod-link" }
    var fileList: [ExtensionFile] { files ?? [] }
}

struct ExtensionManifest: Decodable {
    let schema: Int
    let extensions: [ExtensionEntry]
}

// MARK: - Fetch client

/// Reads the extensions catalog + individual files, either from the repo over
/// GitHub raw, or from a local `extensions/` checkout when `GZH_EXTENSIONS_DIR`
/// is set (dev). No auth — the repo is public.
enum ExtensionsClient {
    private static func httpGet(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("GeneralsZHLauncher", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LauncherError.releaseUnavailable(status: status) }
        return data
    }

    /// Map a repo-relative `src` (e.g. "extensions/vehicle-dual-guard/…") to a
    /// path under the local `extensions/` dir by stripping the leading segment.
    private static func localPath(for src: String, base: URL) -> URL {
        let prefix = "extensions/"
        let rel = src.hasPrefix(prefix) ? String(src.dropFirst(prefix.count)) : src
        return base.appendingPathComponent(rel)
    }

    static func fetchManifest() async throws -> ExtensionManifest {
        let data: Data
        if let local = Config.localExtensionsDir {
            data = try Data(contentsOf: local.appendingPathComponent("manifest.json"))
        } else {
            data = try await httpGet(Config.extensionsManifestURL)
        }
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    static func fetchFile(src: String) async throws -> Data {
        if let local = Config.localExtensionsDir {
            return try Data(contentsOf: localPath(for: src, base: local))
        }
        return try await httpGet(Config.rawURL(src))
    }
}

import Foundation
import SwiftUI

/// Drives the whole launcher flow: pick data dir → ensure the engine is
/// installed (download from the latest release if missing) → launch the game
/// with the data dir as its working directory.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var dataDirPath: String =
        UserDefaults.standard.string(forKey: "originalDataDirPath") ?? "" {
        didSet { UserDefaults.standard.set(dataDirPath, forKey: "originalDataDirPath") }
    }

    /// Optional mod: a single .big/.gib archive (-> GEN_MOD) or a folder of
    /// *.big archives (-> GEN_MOD_DIR). Empty = launch the original game.
    @Published var modPath: String =
        UserDefaults.standard.string(forKey: "modPath") ?? "" {
        didSet { UserDefaults.standard.set(modPath, forKey: "modPath") }
    }
    @Published var useMod: Bool =
        UserDefaults.standard.bool(forKey: "useMod") {
        didSet { UserDefaults.standard.set(useMod, forKey: "useMod") }
    }

    @Published var status: String = "Ready."
    @Published var isBusy: Bool = false
    /// 0…1 download progress, or nil for indeterminate / hidden.
    @Published var progress: Double? = nil
    @Published var gameRunning: Bool = false
    @Published var lastError: String? = nil

    private var gameProcess: Process?

    var dataDirIsValid: Bool {
        guard !dataDirPath.isEmpty else { return false }
        return Self.looksLikeGameData(URL(fileURLWithPath: dataDirPath))
    }

    /// True when a mod path is set and exists on disk.
    var modPathIsValid: Bool {
        guard !modPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: modPath)
    }

    /// True when the selected mod path is a directory (GEN_MOD_DIR) vs a file (GEN_MOD).
    var modIsDirectory: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: modPath, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// Whether the next launch will apply a mod.
    var willUseMod: Bool { useMod && modPathIsValid }

    var engineInstalled: Bool {
        FileManager.default.fileExists(atPath: Config.runtimeBinary.path)
    }

    // MARK: - Folder picking

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select your original Generals Zero Hour folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            dataDirPath = url.path
            if !dataDirIsValid {
                status = "Warning: no .big archives in this folder. Check the path."
            } else {
                status = "Data folder selected."
            }
        }
    }

    func chooseMod() {
        let panel = NSOpenPanel()
        panel.title = "Select the mod: a .big/.gib archive, or a folder of .big files"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            modPath = url.path
            useMod = true
            status = modIsDirectory ? "Mod folder selected." : "Mod archive selected."
        }
    }

    func clearMod() {
        modPath = ""
        useMod = false
        status = "Mod cleared — will launch the original game."
    }

    /// A real Zero Hour install has *.big archives (and usually Generals.dat).
    static func looksLikeGameData(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in entries {
            let lower = name.lowercased()
            if lower.hasSuffix(".big") || lower == "generals.dat" { return true }
        }
        return false
    }

    // MARK: - Main action

    func start() {
        guard !isBusy else { return }
        lastError = nil
        guard dataDirIsValid else {
            fail(LauncherError.dataDirInvalid); return
        }
        let dataDir = URL(fileURLWithPath: dataDirPath)

        isBusy = true
        Task {
            do {
                if !engineInstalled {
                    try await installEngine()
                }
                try launchGame(dataDir: dataDir)
                status = willUseMod ? "Game launched (mod)." : "Game launched."
            } catch {
                fail(error)
            }
            progress = nil
            isBusy = false
        }
    }

    /// Wipe the installed runtime and run the full download+launch flow again.
    func reinstall() {
        guard !isBusy else { return }
        try? FileManager.default.removeItem(at: Config.runtimeDir)
        try? FileManager.default.removeItem(at: Config.versionFile)
        status = "Engine removed — will download again."
        start()
    }

    private func fail(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = msg
        status = "Error."
    }

    // MARK: - Install

    private func installEngine() async throws {
        let zipURL: URL
        let tag: String

        if let local = Config.localPayloadOverride {
            status = "Using local payload (GZH_LOCAL_PAYLOAD)…"
            zipURL = local
            tag = "local"
        } else {
            status = "Checking latest release…"
            let release = try await GitHubClient.fetchLatestRelease()
            guard let asset = release.asset(named: Config.assetName) else {
                throw LauncherError.assetMissing(name: Config.assetName, tag: release.tagName)
            }
            tag = release.tagName
            status = "Downloading \(Config.assetName) (\(tag))…"
            zipURL = try await download(from: URL(string: asset.browserDownloadURL)!)
        }

        status = "Extracting…"
        try installPayload(fromZip: zipURL, tag: tag)
        status = "Installed (\(tag))."
    }

    /// Downloads to a temp file, publishing progress on the main actor.
    private func download(from url: URL) async throws -> URL {
        progress = 0
        let downloader = Downloader { p in
            Task { @MainActor in self.progress = p }
        }
        let tmp = try await downloader.download(url)
        progress = 1.0
        return tmp
    }

    /// Extracts the zip, normalises layout into runtimeDir, clears quarantine.
    private func installPayload(fromZip zip: URL, tag: String) throws {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("gzh-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])

        // The payload zip keeps a parent folder; locate the dir holding the binary.
        guard let payloadDir = Self.findBinaryParent(in: extractDir, binary: Config.binaryName) else {
            throw LauncherError.binaryMissingAfterInstall
        }

        // Swap into place: support/ exists, replace runtime/ atomically-ish.
        try fm.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Config.runtimeDir.path) {
            try fm.removeItem(at: Config.runtimeDir)
        }
        try fm.moveItem(at: payloadDir, to: Config.runtimeDir)

        // Make executable + strip quarantine so Gatekeeper lets it run.
        _ = try? Shell.run("/bin/chmod", ["+x", Config.runtimeBinary.path])
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Config.runtimeDir.path])

        guard fm.fileExists(atPath: Config.runtimeBinary.path) else {
            throw LauncherError.binaryMissingAfterInstall
        }
        try? tag.write(to: Config.versionFile, atomically: true, encoding: .utf8)
    }

    private static func findBinaryParent(in root: URL, binary: String) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == binary {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Launch

    private func launchGame(dataDir: URL) throws {
        let proc = Process()
        proc.executableURL = Config.runtimeBinary
        proc.currentDirectoryURL = dataDir
        var env = ProcessInfo.processInfo.environment
        // Apply the mod via the engine's macOS env-var hooks (see GameEngine.cpp):
        // a file -> GEN_MOD (m_modBIG), a folder -> GEN_MOD_DIR (m_modDir).
        env.removeValue(forKey: "GEN_MOD")
        env.removeValue(forKey: "GEN_MOD_DIR")
        if willUseMod {
            env[modIsDirectory ? "GEN_MOD_DIR" : "GEN_MOD"] = modPath
        }
        proc.environment = env
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.gameRunning = false
                self?.status = "Game exited."
            }
        }
        try proc.run()
        gameProcess = proc
        gameRunning = true
    }
}

/// Tiny synchronous shell helper for the few CLI tools we invoke.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw LauncherError.toolFailed(
                tool: (tool as NSString).lastPathComponent,
                status: proc.terminationStatus,
                output: out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}

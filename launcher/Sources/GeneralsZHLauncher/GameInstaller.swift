import Foundation
import SwiftUI
import AppKit

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

    /// User-data directory (custom maps, saved games, Options.ini). Relocatable;
    /// passed to the engine via GEN_USER_DATA. Defaults to ~/Documents/<leaf>/.
    @Published var userDataDirPath: String =
        UserDefaults.standard.string(forKey: "userDataDirPath") ?? UserData.defaultDirectory.path {
        didSet { UserDefaults.standard.set(userDataDirPath, forKey: "userDataDirPath") }
    }

    /// Display resolution (written to Options.ini) and fullscreen (the -win flag).
    @Published var selectedResolution: GameResolution = GameResolution.match(w: 1024, h: 768)
    @Published var fullscreen: Bool =
        (UserDefaults.standard.object(forKey: "fullscreen") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(fullscreen, forKey: "fullscreen") }
    }

    // Update state (populated by checkForUpdates).
    @Published var latestEngineVersion: String? = nil
    @Published var latestLauncherVersion: String? = nil
    @Published var engineUpdateAvailable = false
    @Published var launcherUpdateAvailable = false

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

    var userDataURL: URL { URL(fileURLWithPath: userDataDirPath) }

    /// The launcher's own version (from Info.plist / CFBundleShortVersionString).
    var currentLauncherVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Installed engine version, parsed from the recorded release tag.
    var installedEngineVersion: SemVer? {
        guard let tag = try? String(contentsOf: Config.versionFile, encoding: .utf8) else { return nil }
        return SemVer(tag)
    }
    var installedEngineVersionDisplay: String {
        guard engineInstalled else { return "not installed" }
        if let v = installedEngineVersion { return v.description }
        return (try? String(contentsOf: Config.versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
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

    // MARK: - User-data folder

    func chooseUserDataDir() {
        let panel = NSOpenPanel()
        panel.title = "Choose the user-data folder (maps, saved games)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = userDataURL
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            userDataDirPath = url.path
            ensureUserDataDefaults()
            loadResolutionFromIni()
            status = "User-data folder set."
        }
    }

    /// Creates the user-data folder + standard sub-folders if missing. Idempotent.
    func ensureUserDataDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: userDataURL, withIntermediateDirectories: true)
        for name in UserData.subfolders {
            try? fm.createDirectory(
                at: userDataURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    func revealUserData() {
        ensureUserDataDefaults()
        NSWorkspace.shared.activateFileViewerSelecting([userDataURL])
    }

    // MARK: - Resolution

    /// Reads `Resolution` from Options.ini in the chosen user-data dir; falls
    /// back to the display's native resolution, then 1024×768.
    func loadResolutionFromIni() {
        let ini = OptionsIni.load(from: UserData.optionsIni(in: userDataURL))
        if let (w, h) = ini.resolution {
            selectedResolution = GameResolution.match(w: w, h: h)
        } else if let native = GameResolution.native() {
            selectedResolution = native
        } else {
            selectedResolution = GameResolution.match(w: 1024, h: 768)
        }
    }

    /// Picks the standard resolution whose aspect best matches the display, so
    /// fullscreen letterboxes (thin bars) instead of stretching. Uses only
    /// known-good standard resolutions — the display's exact size can be a
    /// non-standard resolution that triggers a 3D-render bug.
    func matchDisplayResolution() {
        guard let screen = NSScreen.main else {
            status = "Couldn't read the display."
            return
        }
        let target = Double(screen.frame.width / screen.frame.height)
        let nativeW = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let best = GameResolution.closestStandard(toAspect: target, maxWidth: nativeW)
        selectedResolution = best
        applyResolution()
        status = "Resolution set to \(best.label) — matches display aspect (letterboxed)."
    }

    /// Writes the selected resolution to Options.ini, preserving other keys.
    /// No-op while the game runs (it rewrites the file on exit).
    func applyResolution() {
        guard !gameRunning else { return }
        let url = UserData.optionsIni(in: userDataURL)
        var ini = OptionsIni.load(from: url)
        if let cur = ini.resolution, cur.w == selectedResolution.w, cur.h == selectedResolution.h {
            return  // already current
        }
        ini.setResolution(selectedResolution.w, selectedResolution.h)
        do {
            try ini.save(to: url)
            status = "Resolution set to \(selectedResolution.label)."
        } catch {
            fail(error)
        }
    }

    // MARK: - Stop

    /// Force-closes the running game: SIGTERM, then SIGKILL after a short grace.
    func stop() {
        guard let proc = gameProcess, proc.isRunning else { return }
        let pid = proc.processIdentifier
        status = "Stopping game…"
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Versions & updates

    /// Recomputes update-available flags from the last-known latest versions.
    func refreshInstalledVersions() { recomputeUpdateFlags() }

    private func recomputeUpdateFlags() {
        if let latest = latestLauncherVersion, let l = SemVer(latest),
           let cur = SemVer(currentLauncherVersion) {
            launcherUpdateAvailable = cur < l
        } else {
            launcherUpdateAvailable = false
        }
        if let latest = latestEngineVersion, let e = SemVer(latest) {
            engineUpdateAvailable = (installedEngineVersion.map { $0 < e } ?? true)
        } else {
            engineUpdateAvailable = false
        }
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        lastError = nil
        status = "Checking for updates…"
        Task {
            do {
                let releases = try await GitHubClient.listReleases()
                if let e = GitHubClient.latest(in: releases, prefix: Config.enginePrefix) {
                    latestEngineVersion = SemVer(e.tagName)?.description
                }
                if let l = GitHubClient.latest(in: releases, prefix: Config.launcherPrefix) {
                    latestLauncherVersion = SemVer(l.tagName)?.description
                }
                recomputeUpdateFlags()
                status = "Update check complete."
            } catch {
                fail(error)
            }
        }
    }

    /// Installs/updates the engine to the latest `engine-v*` release.
    func updateEngine() {
        guard !isBusy else { return }
        lastError = nil
        isBusy = true
        Task {
            do {
                try await installEngine()
                latestEngineVersion = installedEngineVersion?.description ?? latestEngineVersion
                recomputeUpdateFlags()
                status = "Engine updated (\(installedEngineVersionDisplay))."
            } catch {
                fail(error)
            }
            progress = nil
            isBusy = false
        }
    }

    /// Self-updates to the latest `launcher-v*` release: download + extract, then
    /// a detached helper swaps the bundle once we quit and relaunches us.
    func updateLauncher() {
        guard !isBusy else { return }
        lastError = nil
        isBusy = true
        Task {
            do {
                let release = try await GitHubClient.latestRelease(withPrefix: Config.launcherPrefix)
                guard let asset = release.asset(named: Config.launcherAssetName) else {
                    throw LauncherError.assetMissing(name: Config.launcherAssetName, tag: release.tagName)
                }
                status = "Downloading launcher \(release.tagName)…"
                let zip = try await download(from: URL(string: asset.browserDownloadURL)!)
                status = "Installing update — the launcher will restart…"
                try selfUpdateAndRelaunch(fromZip: zip)
                // selfUpdateAndRelaunch terminates the app; not normally reached.
            } catch {
                fail(error)
                isBusy = false
            }
            progress = nil
        }
    }

    private func selfUpdateAndRelaunch(fromZip zip: URL) throws {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("gzh-launcher-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])
        guard let newApp = Self.findApp(in: extractDir) else {
            throw LauncherError.binaryMissingAfterInstall
        }
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let currentApp = Bundle.main.bundleURL
        let parent = currentApp.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parent) else {
            throw LauncherError.launcherNotWritable(path: currentApp.path)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        # Wait for the launcher (pid \(pid)) to quit, swap the bundle, relaunch.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /bin/rm -rf "\(currentApp.path)"
        /usr/bin/ditto "\(newApp.path)" "\(currentApp.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(currentApp.path)" 2>/dev/null
        /usr/bin/open "\(currentApp.path)"
        """
        let scriptURL = extractDir.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? Shell.run("/bin/chmod", ["+x", scriptURL.path])

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path]
        try task.run()   // detached: survives our termination

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    private static func findApp(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.pathExtension == "app" {
            return url
        }
        return nil
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
            status = "Checking latest engine release…"
            let release = try await GitHubClient.latestRelease(withPrefix: Config.enginePrefix)
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
        ensureUserDataDefaults()

        let proc = Process()
        proc.executableURL = Config.runtimeBinary
        // The engine finds its .big archives relative to the working directory
        // (StdBIGFileSystem loads "*.big" from "."), so the game folder is passed
        // as the cwd, not a flag.
        proc.currentDirectoryURL = dataDir
        // Windowed mode is the engine's -win command-line flag; fullscreen is the
        // default (no flag).
        proc.arguments = fullscreen ? [] : ["-win"]
        var env = ProcessInfo.processInfo.environment
        // Apply the mod via the engine's macOS env-var hooks (see GameEngine.cpp):
        // a file -> GEN_MOD (m_modBIG), a folder -> GEN_MOD_DIR (m_modDir).
        env.removeValue(forKey: "GEN_MOD")
        env.removeValue(forKey: "GEN_MOD_DIR")
        if willUseMod {
            env[modIsDirectory ? "GEN_MOD_DIR" : "GEN_MOD"] = modPath
        }
        // Relocate the user-data dir (maps, saves, Options.ini) via GEN_USER_DATA
        // (the macOS hook in GlobalData.cpp::BuildUserDataPathFromRegistry).
        env["GEN_USER_DATA"] = userDataDirPath
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

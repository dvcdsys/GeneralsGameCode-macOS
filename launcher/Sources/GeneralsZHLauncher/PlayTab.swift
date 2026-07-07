import SwiftUI

/// The Play tab: pick folders (original game, mod, user data), set the display
/// resolution, launch/close the game, and check/apply updates.
struct PlayTab: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                dataFolderRow
                modRow
                userDataRow
                Divider()
                displaySection
                Divider()
                statusArea
                playRow
                Divider()
                updatesSection
                footer
            }
            .padding(20)
        }
        .onAppear {
            model.ensureUserDataDefaults()
            model.loadResolutionFromIni()
            model.refreshInstalledVersions()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Command & Conquer: Generals — Zero Hour")
                .font(.headline)
            Text("macOS Launcher (Apple Silicon)")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    // MARK: - Folders

    private var dataFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Original game folder (.big archives)").font(.caption).foregroundColor(.secondary)
            HStack {
                pathField(model.dataDirPath, placeholder: "— not selected —")
                Button("Choose…") { model.chooseFolder() }.disabled(model.isBusy)
            }
            if !model.dataDirPath.isEmpty && !model.dataDirIsValid {
                warn("No .big archives found in this folder — check the path.")
            }
            Button("Don't have the game? Get Zero Hour on Steam") {
                model.openURL(Config.buyGameURL)
            }
            .buttonStyle(.link).font(.caption2)
            .help("Opens the official store — Command & Conquer: The Ultimate Collection (includes Generals + Zero Hour).")
        }
    }

    private var modRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mod (optional)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("Launch with mod", isOn: $model.useMod)
                    .toggleStyle(.checkbox).font(.caption)
                    .disabled(model.isBusy || !model.modPathIsValid)
            }
            HStack {
                pathField(model.modPath, placeholder: "— none (original game) —")
                Button("Choose…") { model.chooseMod() }.disabled(model.isBusy)
                Button("Clear") { model.clearMod() }.disabled(model.isBusy || model.modPath.isEmpty)
            }
            if !model.modPath.isEmpty && !model.modPathIsValid {
                warn("Mod path not found — check it exists.")
            } else if model.modPathIsValid {
                Text(model.modIsDirectory ? "Folder of .big mods (GEN_MOD_DIR)."
                                          : "Single mod archive (GEN_MOD).")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var userDataRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("User data (custom maps, saved games)").font(.caption).foregroundColor(.secondary)
            HStack {
                pathField(model.userDataDirPath, placeholder: UserData.defaultDirectory.path)
                Button("Choose…") { model.chooseUserDataDir() }.disabled(model.isBusy)
                Button("Reveal") { model.revealUserData() }
            }
            Text("Maps/ and Save/ are created here. Passed to the engine via GEN_USER_DATA.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display").font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("Resolution", selection: $model.selectedResolution) {
                    ForEach(resolutionGroups) { group in
                        Section(header: Text(group.aspect.rawValue)) {
                            ForEach(group.items) { res in
                                Text(res.label).tag(res)
                            }
                        }
                    }
                }
                .frame(maxWidth: 260)
                .disabled(model.gameRunning)

                Toggle("Fullscreen", isOn: $model.fullscreen)
                    .toggleStyle(.checkbox)
                    .disabled(model.gameRunning)
                Button("Match display") { model.matchDisplayResolution() }
                    .disabled(model.gameRunning)
                    .help("Set a resolution matching your screen's aspect ratio (no fullscreen stretch)")
                Spacer()
            }
            HStack {
                Picker("Frame rate", selection: $model.frameRateCap) {
                    Text("30 FPS (Original)").tag(30)
                    Text("60 FPS (Smooth)").tag(60)
                    Text("120 FPS (ProMotion)").tag(120)
                }
                .frame(maxWidth: 260)
                .disabled(model.gameRunning)
                .help("Higher FPS renders motion smoother. Game speed stays correct — the simulation still runs at 30 Hz.")
                Spacer()
            }
            if model.gameRunning {
                Text("Quit the game to change display settings.")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("Tip: use “Match display” so fullscreen isn't stretched on non-16:9/16:10 panels.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .onChange(of: model.selectedResolution) { _ in model.applyResolution() }
    }

    /// Catalogue grouped by aspect, with the current selection injected if it is
    /// a non-standard resolution (so the picker can display it).
    private var resolutionGroups: [ResolutionGroup] {
        var groups = GameResolution.grouped()
        let sel = model.selectedResolution
        if !GameResolution.catalogue.contains(sel),
           let idx = groups.firstIndex(where: { $0.aspect == sel.aspect }) {
            groups[idx].items.append(sel)
        }
        return groups
    }

    // MARK: - Status + Play/Close

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isBusy && model.progress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.callout)
            }
            if let p = model.progress { ProgressView(value: p) }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var playRow: some View {
        HStack {
            Button("Close") { model.stop() }
                .disabled(!model.gameRunning)
            Spacer()
            Button(action: { model.start() }) {
                Text(playLabel).frame(minWidth: 150)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy || !model.dataDirIsValid || model.gameRunning)
        }
    }

    private var playLabel: String {
        let base = model.willUseMod ? "Play (mod)" : "Play"
        return model.engineInstalled ? base : "Download & \(base)"
    }

    // MARK: - Updates / About

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Launcher \(model.currentLauncherVersion)").font(.caption)
                if model.launcherUpdateAvailable, let l = model.latestLauncherVersion {
                    Text("→ \(l) available").font(.caption).foregroundColor(.orange)
                    Button("Update Launcher") { model.updateLauncher() }.disabled(model.isBusy)
                }
                Spacer()
                Button("Check for updates") { model.checkForUpdates() }.disabled(model.isBusy)
            }
            HStack(spacing: 8) {
                Text("Engine \(model.installedEngineVersionDisplay)").font(.caption)
                if model.engineInstalled {
                    if model.engineUpdateAvailable, let e = model.latestEngineVersion {
                        Text("→ \(e) available").font(.caption).foregroundColor(.orange)
                        Button("Update Engine") { model.updateEngine() }.disabled(model.isBusy)
                    }
                    Button("Reinstall") { model.reinstall() }.disabled(model.isBusy)
                } else {
                    Button("Install Engine") { model.updateEngine() }
                        .disabled(model.isBusy || !model.dataDirIsValid)
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        Text("The engine is downloaded from the project's GitHub releases. You must own a "
           + "legitimate copy of Zero Hour — the game data is not part of the release.")
            .font(.caption2).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Small helpers

    private func pathField(_ value: String, placeholder: String) -> some View {
        Text(value.isEmpty ? placeholder : value)
            .lineLimit(1).truncationMode(.middle)
            .foregroundColor(value.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
    }

    private func warn(_ text: String) -> some View {
        Text("⚠︎ " + text).font(.caption).foregroundColor(.orange)
    }
}

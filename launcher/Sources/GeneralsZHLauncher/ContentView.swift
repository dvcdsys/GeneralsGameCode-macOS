import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            instructions
            Divider()
            dataFolderRow
            modRow
            Divider()
            statusArea
            Spacer()
            startRow
            footer
        }
        .padding(20)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Command & Conquer: Generals — Zero Hour")
                .font(.headline)
            Text("macOS Launcher (Apple Silicon)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("1.", "Select the folder with your original game files (where the .big archives live).")
            label("2.", "Press Start. If the engine isn't installed yet, it downloads from the latest release.")
            label("3.", "The game launches from that folder. A legitimate copy of Zero Hour is required.")
        }
        .font(.callout)
    }

    private func label(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n).bold().frame(width: 16, alignment: .leading)
            Text(text)
        }
    }

    private var dataFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Original game folder").font(.caption).foregroundColor(.secondary)
            HStack {
                Text(model.dataDirPath.isEmpty ? "— not selected —" : model.dataDirPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(model.dataDirPath.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                Button("Choose…") { model.chooseFolder() }
                    .disabled(model.isBusy)
            }
            if !model.dataDirPath.isEmpty && !model.dataDirIsValid {
                Text("⚠︎ No .big archives found in this folder — check the path.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
    }

    private var modRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mod (optional)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("Launch with mod", isOn: $model.useMod)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(model.isBusy || !model.modPathIsValid)
            }
            HStack {
                Text(model.modPath.isEmpty ? "— none (original game) —" : model.modPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(model.modPath.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                Button("Choose…") { model.chooseMod() }
                    .disabled(model.isBusy)
                Button("Clear") { model.clearMod() }
                    .disabled(model.isBusy || model.modPath.isEmpty)
            }
            if !model.modPath.isEmpty && !model.modPathIsValid {
                Text("⚠︎ Mod path not found — check it exists.")
                    .font(.caption).foregroundColor(.orange)
            } else if model.modPathIsValid {
                Text(model.modIsDirectory
                     ? "Folder of .big mods (GEN_MOD_DIR)."
                     : "Single mod archive (GEN_MOD).")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isBusy && model.progress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.callout)
            }
            if let p = model.progress {
                ProgressView(value: p)
            }
            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.engineInstalled {
                Text("Engine installed: \(installedTag)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var startRow: some View {
        HStack {
            if model.engineInstalled {
                Button("Reinstall engine") { model.reinstall() }
                    .disabled(model.isBusy)
            }
            Spacer()
            Button(action: { model.start() }) {
                Text(startLabel).frame(minWidth: 160)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy || !model.dataDirIsValid)
        }
    }

    private var footer: some View {
        Text("The engine is downloaded from the project's GitHub releases. The game "
           + "needs your own legitimate Zero Hour data — it is not part of the release.")
            .font(.caption2)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var startLabel: String {
        let base = model.willUseMod ? "Start (mod)" : "Start"
        return model.engineInstalled ? base : "Download & \(base)"
    }

    private var installedTag: String {
        (try? String(contentsOf: Config.versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
}

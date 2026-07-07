import SwiftUI

/// The Extensions tab: browse optional add-ons from the repo and install/remove
/// them into the selected game-data folder with one click.
struct ExtensionsTab: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if !model.dataDirIsValid {
                    warn("Select your original game folder on the Play tab first — "
                       + "extensions install into it.")
                }
                statusArea
                catalog
                footer
            }
            .padding(20)
        }
        .onAppear { if !model.extensionsLoaded { model.loadExtensions() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mods & Extensions").font(.headline)
                Text("Third-party mods to download, and add-ons to install into your game folder")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            Button("Refresh") { model.loadExtensions() }
                .disabled(model.isBusy)
                .help("Reload the catalog from the repo and re-check what's installed in your game folder")
        }
    }

    // MARK: - Status

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isBusy && model.progress == nil { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout)
            }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Catalog

    @ViewBuilder private var catalog: some View {
        if !model.extensionsLoaded {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading catalog…") }
                .foregroundColor(.secondary)
        } else if model.extensionCatalog.isEmpty {
            Text("No extensions available (or the catalog couldn't be loaded).")
                .font(.callout).foregroundColor(.secondary)
        } else {
            let mods   = model.extensionCatalog.filter { $0.isModLink }
            let addons = model.extensionCatalog.filter { !$0.isModLink }
            VStack(alignment: .leading, spacing: 20) {
                if !mods.isEmpty {
                    section(title: "Mods",
                            subtitle: "Full third-party mods — get them from their official "
                                    + "page, then register the file here.",
                            items: mods)
                }
                if !addons.isEmpty {
                    section(title: "Extensions",
                            subtitle: "Optional add-ons installed straight into your game folder.",
                            items: addons)
                }
            }
        }
    }

    private func section(title: String, subtitle: String, items: [ExtensionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3).bold()
                Text(subtitle).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { ext in ExtensionCard(ext: ext) }
        }
    }

    private var footer: some View {
        Text("Mods are third-party — the launcher only links to their official download "
           + "and registers what you download; it never hosts or redistributes them. "
           + "Extensions are our own purely-additive files fetched from the project repo; "
           + "removing one deletes only its files and fully reverts it. See each entry's credits.")
            .font(.caption2).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ text: String) -> some View {
        Text("⚠︎ " + text).font(.caption).foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One extension entry, rendered as a card with an Install/Remove action.
private struct ExtensionCard: View {
    @EnvironmentObject var model: LauncherModel
    let ext: ExtensionEntry
    @State private var showDetails = false

    private var installed: Bool { model.installedExtensionIDs.contains(ext.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ext.name).font(.headline)
                        if let v = ext.version {
                            Text("v\(v)").font(.caption2).foregroundColor(.secondary)
                        }
                        if ext.isModLink {
                            Text("Third-party mod").font(.caption2).bold()
                                .foregroundColor(.orange)
                        } else if installed {
                            Text("Installed").font(.caption2).bold()
                                .foregroundColor(.green)
                        }
                    }
                    Text(ext.summary).font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let mod = ext.forMod {
                        Text("For: \(mod)").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if !ext.isModLink { fileActionButton }
            }

            if ext.isModLink { modLinkArea }

            if ext.description != nil || ext.credits != nil {
                Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .buttonStyle(.link).font(.caption)
                if showDetails {
                    if let d = ext.description {
                        Text(d).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let c = ext.credits {
                        Text("Credits: \(c)").font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // Loose-files extension: one-click install/remove into the game folder.
    @ViewBuilder private var fileActionButton: some View {
        if installed {
            Button("Remove") { model.removeExtension(ext) }
                .disabled(model.isBusy)
        } else {
            Button("Install") { model.installExtension(ext) }
                .disabled(model.isBusy || !model.dataDirIsValid)
                .keyboardShortcut(.defaultAction)
        }
    }

    // Third-party mod we don't host: link to the official download + let the user
    // register the file they downloaded (sets it as the launch mod → GEN_MOD).
    @ViewBuilder private var modLinkArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let instr = ext.instructions {
                Text(instr).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = ext.modFileHint {
                Text("After downloading, pick “\(hint)”.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                if let dl = ext.downloadURL {
                    Button("Download page…") { model.openURL(dl) }
                        .keyboardShortcut(.defaultAction)
                }
                if let hp = ext.homepageURL {
                    Button("Mod page") { model.openURL(hp) }
                }
                Button("Use downloaded mod…") { model.chooseMod() }
                    .disabled(model.isBusy)
                Spacer()
            }
            if model.useMod && model.modPathIsValid {
                Text("Current mod: \(model.modPath)")
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

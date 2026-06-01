# GeneralsZH Launcher

A small native macOS (SwiftUI, Apple Silicon) launcher for the Zero Hour
engine port. It lets a player pick their original game-data folder and press
**Start**; if the engine isn't installed it downloads the latest GitHub
release, then launches the game with the chosen folder as the working
directory.

## What it does

1. **Pick data folder** — `NSOpenPanel`, validated by the presence of
   `*.big` archives (a real Zero Hour install).
2. **Ensure engine installed** — if
   `~/Library/Application Support/GeneralsZH/runtime/generalszh` is missing,
   fetch the latest release from GitHub
   (`dvcdsys/GeneralsGameCode-macOS`), download `GeneralsZH-macOS-arm64.zip`,
   extract it into `runtime/`, `chmod +x`, strip the quarantine xattr.
3. **Launch** — run the engine binary with the data folder as `cwd`.

## Build

```bash
bash build-app.sh          # -> "<repo>/dist/GeneralsZH Launcher.app"
# OUT_DIR=/somewhere bash build-app.sh   # custom output dir
```

Requires the Swift toolchain (ships with Xcode / Command Line Tools).
The app is ad-hoc signed; on first run use right-click → **Open**.

## Local testing before a release exists

The repo must be **public** for anonymous release downloads. Until then (or
to test a freshly built engine), set `GZH_LOCAL_PAYLOAD` to a payload zip —
the launcher installs from it instead of the network:

```bash
# Build + package the engine first:
cmake --build ../build/apple-arm64 --config Release --target generalszh
bash ../scripts/package-macos-release.sh      # -> ../dist/GeneralsZH-macOS-arm64.zip

GZH_LOCAL_PAYLOAD="$(cd .. && pwd)/dist/GeneralsZH-macOS-arm64.zip" \
  open "../dist/GeneralsZH Launcher.app"
```

## Layout

| File | Role |
|---|---|
| `Sources/GeneralsZHLauncher/App.swift` | `@main` app + window/`AppDelegate` |
| `…/ContentView.swift` | UI (instructions, folder picker, Start) |
| `…/GameInstaller.swift` | `LauncherModel`: download / install / launch |
| `…/GitHubClient.swift` | latest-release lookup + error types |
| `…/Config.swift` | repo/asset names, install paths |
| `Info.plist` | bundle metadata (id, min macOS 12) |
| `build-app.sh` | compile + assemble + sign the `.app` |

# Generals Zero Hour — macOS (Apple Silicon)

> [!WARNING]
> ## 🚧 Under active development — I'm still setting up this repository
> **Work in progress.** Releases, CI and docs are being configured right now —
> things will move, break and change without notice. Not ready for general use yet.

Native **Metal** port of *Command & Conquer: Generals — Zero Hour* for Apple
Silicon. No Wine, no DXVK, no translation layer — the engine runs as a native
macOS binary through an in-tree D3D8 → Metal shim. Game logic, AI and data are
unchanged; only the platform layer is ported.

You must own a legitimate copy of Zero Hour — the proprietary EA game data is
**not** included.

## Install & play

1. Download **`GeneralsZH-Launcher.app.zip`** from the
   [latest release](https://github.com/dvcdsys/GeneralsGameCode-macOS/releases).
2. Unzip it and move **GeneralsZH Launcher.app** to `/Applications`.
3. First launch: right-click the app → **Open** (it's ad-hoc signed, not notarized).
4. In the launcher, pick the folder with your original Zero Hour data (the
   `.big` archives), then press **Play**.

That's it — the launcher downloads the game engine for you, keeps it updated,
and can update itself. No terminal, no compiling.

## Build from source (developers)

```bash
# Engine
cmake --preset apple-arm64
cmake --build build/apple-arm64 --config Release --target z_generals

# Launcher
bash launcher/build-app.sh            # -> "dist/GeneralsZH Launcher.app"
```

The launcher installs the engine to `~/Library/Application Support/GeneralsZH/`.
To run a local engine build without a release, point the launcher at a payload zip:

```bash
GZH_LOCAL_PAYLOAD="$(pwd)/dist/GeneralsZH-macOS-arm64.zip" \
  open "dist/GeneralsZH Launcher.app"
```

## Acknowledgments

- **[Electronic Arts](https://www.ea.com/)** — for releasing the *Generals —
  Zero Hour* engine source under **GPL-3.0**. None of this would be possible
  without it. Thank you.
- **[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode)**
  — the upstream project this repository is forked from; their modernized C++
  baseline is the foundation every macOS-specific change sits on.
- **Westwood Studios** — for the original *Command & Conquer: Generals*.

## License

GPL-3.0-or-later, with EA's additional terms — see [`LICENSE.md`](LICENSE.md).
EA has not endorsed and does not support this project. All trademarks are the
property of their respective owners.

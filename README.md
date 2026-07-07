# Generals Zero Hour — macOS (Apple Silicon)

Native **Metal** port of *Command & Conquer: Generals — Zero Hour* for Apple
Silicon. No Wine, no DXVK, no translation layer — the engine runs as a native
macOS binary through an in-tree D3D8 → Metal shim. Game logic, AI and data are
unchanged; only the platform layer is ported.

> ## ▶ Playable now — with a couple of caveats
> The game **runs and is playable**: **skirmish** and **singleplayer** both work.
> **Networked multiplayer isn't in yet** — there's no online (or LAN) play for
> the moment.
>
> **On the roadmap:** graphics-quality improvements, and **multiplayer built
> straight for online play over the internet** (skipping LAN, which isn't really
> relevant today).
>
> And a heartfelt nod to **[Cold War Crisis](https://www.moddb.com/mods/cold-war-crisis)** —
> a brilliant total-conversion and a personal favourite. The launcher has
> one-click helpers for it (see the **Mods & Extensions** tab).

You must own a legitimate copy of Zero Hour — the proprietary EA game data is
**not** included. The easiest way to get it is *Command & Conquer: The Ultimate
Collection* on **[Steam](https://store.steampowered.com/bundle/39394)** (it
includes both *Generals* and *Zero Hour*).

## Install & play

1. Download **`GeneralsZH-Launcher.dmg`** from the
   [latest release](https://github.com/dvcdsys/GeneralsGameCode-macOS/releases).
2. Open it and drag **GeneralsZH Launcher.app** onto the **Applications** folder.
3. The app is ad-hoc signed (not notarized), so on first launch macOS Gatekeeper
   blocks it — you'll see *"…is damaged and can't be opened"* or *"…can't be
   opened because Apple cannot check it for malicious software."* This is
   expected. Clear it **once** with either method:

   - **Terminal (most reliable):** strip the quarantine flag, then open the app
     normally from Launchpad / Applications.
     ```bash
     xattr -dr com.apple.quarantine "/Applications/GeneralsZH Launcher.app"
     ```
   - **No Terminal:** double-click the app once (it gets blocked), then open
     **System Settings → Privacy & Security**, scroll to the *Security* section,
     and click **Open Anyway** next to *GeneralsZH Launcher*. (On macOS 13–14 you
     can instead right-click the app → **Open** → **Open**.)

   If the **.dmg** itself is flagged, clear it the same way first:
   `xattr -dr com.apple.quarantine ~/Downloads/GeneralsZH-Launcher.dmg`.
4. In the launcher, pick the folder with your original Zero Hour data (the
   `.big` archives), then press **Play**.

That's it — the launcher downloads the game engine for you, keeps it updated,
and can update itself (the only manual step is clearing Gatekeeper once, above).

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
- **[Cold War Crisis](https://www.moddb.com/mods/cold-war-crisis)** and its authors
  — a superb mod this project is a fan of; the launcher ships optional one-click
  helpers for it (which contain only our own additive overrides, never CWC's assets).

## License

GPL-3.0-or-later, with EA's additional terms — see [`LICENSE.md`](LICENSE.md).
EA has not endorsed and does not support this project. All trademarks are the
property of their respective owners.

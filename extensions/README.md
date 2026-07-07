# Extensions

Optional, purely-additive **add-ons** for the macOS port. Each extension is a set
of loose game files (usually `Data/INI/Override*` INIs) that the engine chains on
top of the base game / a mod at runtime — no engine rebuild, no archive editing.

The **GeneralsZH Launcher** reads [`manifest.json`](manifest.json), lists every
extension on its **Extensions** tab, and installs/removes them with one click by
copying the listed files into your selected game-data folder (and deleting them to
uninstall). The files are fetched straight from this repo, so an extension update
is just a repo change.

## Layout

```
extensions/
  manifest.json              ← the launcher reads this
  <extension-id>/
    README.md                ← what it does + credits
    Data/INI/…               ← the loose files, laid out under their in-game path
```

Each `manifest.json` entry lists `files: [{ src, dest }]` — `src` is the path in
this repo, `dest` is where it lands under the game-data folder.

## Available extensions

- **[vehicle-dual-guard](vehicle-dual-guard/)** — Guard-From-Position ("dual
  guard") on all Cold War Crisis combat vehicles & aircraft.

## Credits & third-party mods

Some extensions target **third-party mods** (e.g. Cold War Crisis). An extension
here contains only *our own* additive overrides — never a mod's own assets — and
each extension's `README.md` credits the mod it builds on. If you maintain one of
those mods and want different wording or attribution, please open an issue.

## Adding an extension

1. Drop its loose files under `extensions/<id>/` mirroring their in-game path.
2. Add an entry to `manifest.json` (`id`, `name`, `summary`, `files[]`, `credits`).
3. The launcher picks it up automatically — no launcher rebuild needed.

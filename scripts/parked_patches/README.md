# Parked patches

Hunks intentionally kept out of the working tree but worth keeping around.
Apply with `git apply scripts/parked_patches/<file>.patch` from repo root.

## metal_backend_explicit_vsync.patch

Adds explicit `layer.displaySyncEnabled = YES` and caps
`layer.maximumDrawableCount = 2` (default is 3) in `cmake/dx8_stub/metal_backend.mm`.

**Why parked:** introduced to fix the 40↔120 FPS jitter we saw in the main
menu cutscene, but suspected of causing the new map-scroll judder /
microfreezes that surfaced after that session. The 30 FPS cap in
`FramePacer::getActualFramesPerSecondLimit` (Apple) already covers the
original jitter case, so we run on Apple-default VSync (drawables=3,
displaySync implicitly YES) by default.

**Re-apply** if a future change benefits from the tighter pacing:
```
git apply scripts/parked_patches/metal_backend_explicit_vsync.patch
```

**Env-var override at runtime** (without re-applying):
- `MTL_NO_VSYNC=1` — disable VSync (only meaningful with the patch applied)
- `MTL_DRAWABLES=N` (1–3) — A/B different pool sizes (only meaningful with the patch applied)

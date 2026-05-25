// Metal backend for the macOS DirectX8 -> Metal renderer.
//
// This header is the C++<->Objective-C boundary. The DX8 device class
// (pure C++, dx8_device.cpp) calls these plain C entry points; the bodies live
// in metal_backend.mm and use Cocoa / Metal / QuartzCore. Keeping the boundary
// free of any Objective-C type lets the rest of the d3d8 target compile as
// ordinary C++.
//
// macOS-only. Never compiled on Windows.

#ifndef METAL_BACKEND_H
#define METAL_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to the Cocoa window + Metal device/queue/layer.
typedef struct MetalContext MetalContext;

// Create an NSWindow with a CAMetalLayer-backed view, an MTLDevice and an
// MTLCommandQueue. Returns null on failure (no Metal device, etc.).
MetalContext* MetalContext_Create(int width, int height, int windowed);

// Tear down the window and release Metal objects.
void MetalContext_Destroy(MetalContext* ctx);

// Store the clear color (RGBA, 0..1). Applied as the load action of the next
// frame's render pass.
void MetalContext_SetClearColor(MetalContext* ctx, double r, double g, double b, double a);

// Begin/end frame bookkeeping.
void MetalContext_BeginFrame(MetalContext* ctx);
void MetalContext_EndFrame(MetalContext* ctx);

// End the current render encoder (if any; clearing if no draws happened),
// present the drawable, commit, and pump Cocoa events.
void MetalContext_Present(MetalContext* ctx);

// Resize the drawable / layer.
void MetalContext_Resize(MetalContext* ctx, int width, int height);

// Pump pending NSEvents without presenting (used outside the draw loop).
void MetalContext_PumpEvents(MetalContext* ctx);

// Debug: write a BGRA8 image to /tmp/<name>.png (alpha as luminance). No-op
// unless MTL_DUMP is set. Used to inspect intermediate surfaces.
void  MetalDebug_DumpBGRA(const char* name, int width, int height, const void* bgra8, int bytesPerRow);

// Allocate a private GPU texture (for IDirect3DTexture8). Always BGRA8Unorm so
// that D3DFMT_*8R8G8B8 (BGRA-in-memory) data uploads with no swizzle.
void* MetalContext_CreateTexture(MetalContext* ctx, int width, int height);
void  MetalContext_ReleaseTexture(void* texture);

// Allocate a GPU texture of the given pixel-format kind:
//   0 => BGRA8Unorm (same as MetalContext_CreateTexture)
//   1 => BC1_RGBA   (DXT1)   2 => BC2_RGBA (DXT2/3)   3 => BC3_RGBA (DXT4/5)
// Apple Silicon supports BC compression natively, so DDS data is uploaded as
// compressed blocks (no CPU decode). width/height are in pixels.
void* MetalContext_CreateTextureFmt(MetalContext* ctx, int width, int height, int bcKind);

// Upload a tightly/pitch-packed BGRA8 image into an MTLTexture (replaceRegion).
void  MetalContext_UploadTextureBGRA8(void* texture, int width, int height,
                                      const void* bgra8, int bytesPerRow);

// Upload raw bytes (e.g. BC blocks) into an MTLTexture with no conversion.
// bytesPerRow is the block-row pitch for compressed formats. region is the full
// level (0,0,width,height) in pixels; Metal derives block counts from the format.
void  MetalContext_UploadTextureRaw(void* texture, int width, int height,
                                    const void* bytes, int bytesPerRow);

// Allocate a shared MTLBuffer (for vertex/index buffers). Returns opaque MTLBuffer*.
// MetalContext_BufferContents returns the CPU-visible pointer.
void* MetalContext_CreateBuffer(MetalContext* ctx, unsigned length);
void* MetalContext_BufferContents(void* buffer);
void  MetalContext_ReleaseBuffer(void* buffer);

// One fixed-function light (Stage 4). Layout is private to the shim (repacked
// into the GPU uniform struct by the backend), so no MSL alignment needed.
typedef struct MetalLight {
    int   type;            // D3DLIGHT_POINT(1)/SPOT(2)/DIRECTIONAL(3)
    float diffuse[4];      // RGBA (rgb used)
    float ambient[4];      // RGBA (rgb used)
    float position[3];     // world space (point/spot)
    float direction[3];    // world space (directional/spot)
    float atten[3];        // a0,a1,a2 (point/spot attenuation)
} MetalLight;

// One draw. All resource handles are opaque (MTLBuffer*/MTLTexture*).
// Offsets/strides are bytes. mvp is column-major (already transposed from the
// D3D row-vector convention). The backend lazily begins the frame's render
// encoder (clearing to the stored clear color) on the first draw.
typedef struct MetalDrawCall {
    void*    vertexBuffer;     // MTLBuffer* (stream 0)
    unsigned stride;           // vertex stride in bytes
    void*    indexBuffer;      // MTLBuffer* (null => non-indexed)
    unsigned indexOffsetBytes; // byte offset of the first index
    unsigned indexCount;       // index count (indexed draws)
    unsigned vertexStart;      // first vertex (non-indexed draws)
    unsigned vertexCount;      // vertex count (non-indexed draws)
    int      baseVertex;       // added to each index (indexed draws)
    unsigned primType;         // D3DPRIMITIVETYPE
    void*    texture;          // MTLTexture* for stage 0 (null => 1x1 white)
    unsigned fvf;              // FVF (part of pipeline key)
    int      posOffset;        // byte offset of POSITION (>=0 required)
    int      posFloats;        // 3 (XYZ) or 4 (XYZRHW)
    int      normalOffset;     // byte offset of NORMAL (<0 => absent)
    int      diffuseOffset;    // byte offset of DIFFUSE (<0 => absent)
    int      tex0Offset;       // byte offset of TEX0 uv (<0 => absent)
    int      tex1Offset;       // byte offset of TEX1 uv (<0 => absent; from TEX2+ FVF)
    int      texCoordIndex;    // D3DTSS_TEXCOORDINDEX low 16 bits for stage 0: 0=>TEX0, 1=>TEX1
    // D3DTSS_TEXCOORDINDEX HIGH 16 bits (TCI_*): 0=PASSTHRU (use the vertex UV
    // selected by texCoordIndex), 2=CAMERASPACEPOSITION — the shroud overlay's
    // TerrainShader2Stage uses this to project a small shroud texture onto the
    // terrain mesh based on each vertex's camera-space position rather than its
    // per-vertex UV (terrain UVs are atlas coords for the BASE texture, not the
    // shroud). Without this the shroud sampler hit terrain-atlas UVs and
    // produced solid black quads on every high-elevation vertex (rock peaks /
    // cliff tops). 1/3 (CAMERASPACENORMAL / REFLECTIONVECTOR) are stubbed.
    int      tciMode;
    // D3DTSS_TEXTURETRANSFORMFLAGS for stage 0. 0=DISABLE (no transform),
    // 2=COUNT2 (use .xy of texXform-multiplied texcoord) — the shroud uses this.
    int      texXformCount;
    // D3DTS_VIEW (column-major). Needed when tciMode==CAMERASPACEPOSITION to
    // produce the camera-space position the texture transform multiplies against.
    float    view[16];
    // D3DTS_TEXTURE0 (column-major). Stage-0 texture-transform matrix,
    // multiplied against the TCI-generated input texcoord.
    float    texXform[16];
    int      blendEnable;
    int      srcBlend;         // D3DBLEND
    int      destBlend;        // D3DBLEND
    int      alphaTestEnable;
    float    alphaRef;         // 0..1
    // Stage-0 texture addressing: D3DTADDRESS_WRAP(1)/CLAMP(3)/MIRROR(2)/BORDER(4)/MIRRORONCE(5).
    // 0 maps to default (WRAP), matching legacy behavior. Mapped to MTLSamplerAddressMode.
    int      addressU;
    int      addressV;
    // Stage-0 texture filter: D3DTEXF_NONE(0)/POINT(1)/LINEAR(2)/ANISOTROPIC(3). 0 falls
    // back to the legacy default (LINEAR). Mapped to MTLSamplerMinMagFilter.
    int      magFilter;
    int      minFilter;
    int      mipFilter;
    // Stage-0 D3DTSS_MAXANISOTROPY (1..16). Engine's TextureFilterClass::_Set_Max_Anisotropy
    // writes this per-stage when "Anisotropic Filtering" is enabled in the
    // graphics options (texturefilter.cpp:301). Previously we silently downgraded
    // ANISOTROPIC → linear; this carries the engine value through to
    // MTLSamplerDescriptor.maxAnisotropy. Clamped to [1,16] in the backend.
    // Reference: DXMT src/d3d11/d3d11_state_object.cpp:730-735 (same clamp).
    // 0 (unset by engine) → 1 (no anisotropy), matching Metal's default.
    int      maxAnisotropy;
    // Stage-0 D3DTSS_BORDERCOLOR (ARGB packed). Only consulted when addressU or
    // addressV is D3DTADDRESS_BORDER (4); otherwise ignored. Metal can only
    // pick from 3 presets (TransparentBlack/OpaqueBlack/OpaqueWhite), so the
    // backend snaps the engine's RGBA to the nearest preset. Reference:
    // DXMT src/d3d11/d3d11_state_object.cpp:758-777.
    unsigned borderColor;
    // Stage-0 FF colour/alpha combiner (D3DTSS_COLOROP / D3DTSS_ALPHAOP +
    // arg1/arg2). Modelled after DXVK's d3d9_fixed_function pixel-shader
    // synthesiser: separate paths for COLOR (.rgb) and ALPHA (.a) so a stage can,
    // e.g., MODULATE colour but ADD alpha (the trapezoid water case, which is
    // what makes the water look like a darker grid on macOS — MODULATE alpha
    // dropped to 0 wherever the water texture had low alpha). 0 in any field
    // means "use legacy default" (MODULATE for COLOROP, TEXTURE for ARG1,
    // DIFFUSE for ARG2). See D3DTSS_COLOROP / D3DTOP_* / D3DTA_*.
    int      colorOp;     // D3DTOP_*  (DISABLE/SELECTARG1/2/MODULATE/ADD/...)
    int      colorArg1;   // D3DTA_*   (TEXTURE/DIFFUSE/CURRENT/TFACTOR/...)
    int      colorArg2;
    int      alphaOp;
    int      alphaArg1;
    int      alphaArg2;
    unsigned tfactor;     // D3DRS_TEXTUREFACTOR (BGRA)
    float    mvp[16];          // column-major
    int      vpX, vpY, vpW, vpH;

    // ---- Stage 4: depth / culling ----
    int      cullMode;         // D3DCULL_NONE(1)/CW(2)/CCW(3); 0 => none
    int      zEnable;          // D3DRS_ZENABLE (0 => no depth test/write)
    int      zWriteEnable;     // D3DRS_ZWRITEENABLE
    int      zFunc;            // D3DCMPFUNC (0 => LessEqual default)

    // ---- Stage 5: color write mask ----
    // D3DRS_COLORWRITEENABLE bit mask (RGBA). 0xF (all on) is the engine
    // default. Volumetric shadow rendering disables color writes for the
    // stencil-fill passes (front-face INCR + back-face DECR) so only stencil
    // changes; without honouring this, those passes paint visible garbage
    // over the scene and the shadow effect breaks. Mapped to
    // MTLColorWriteMask: 0 => None, anything else => All.
    int      colorWriteMask;

    // ---- Stage 5: stencil ----
    // The Metal pipeline binds a Depth32Float_Stencil8 attachment and a render
    // pass clears stencil to 0 at frame start. Per-draw stencil state goes into
    // the MTLDepthStencilState (cached together with depth state) plus a
    // setStencilReferenceValue: call. Used by RTS3DScene::flushOccludedObjects-
    // IntoStencil (the "occluded buildings X-ray" tint) and stencil shadow
    // volumes (W3DVolumetricShadow). When stencilEnable==0, the depth-stencil
    // descriptor has no stencil descriptor attached (== always-pass / no-op),
    // matching the legacy DX path with D3DRS_STENCILENABLE=FALSE.
    int      stencilEnable;    // D3DRS_STENCILENABLE
    int      stencilFunc;      // D3DCMPFUNC (D3DRS_STENCILFUNC; 0 => ALWAYS default)
    int      stencilRef;       // D3DRS_STENCILREF (set via setStencilReferenceValue:)
    int      stencilMask;      // D3DRS_STENCILMASK (read mask)
    int      stencilWriteMask; // D3DRS_STENCILWRITEMASK
    int      stencilFail;      // D3DSTENCILOP (D3DRS_STENCILFAIL; 0 => KEEP)
    int      stencilZFail;     // D3DSTENCILOP (D3DRS_STENCILZFAIL; 0 => KEEP)
    int      stencilPass;      // D3DSTENCILOP (D3DRS_STENCILPASS; 0 => KEEP)

    // ---- Stage 4: fixed-function lighting ----
    int      lightingEnable;   // D3DRS_LIGHTING
    int      numLights;        // count of valid entries in lights[]
    int      diffuseSource;    // D3DMCS_* for DIFFUSEMATERIALSOURCE
    int      ambientSource;    // D3DMCS_* for AMBIENTMATERIALSOURCE
    int      emissiveSource;   // D3DMCS_* for EMISSIVEMATERIALSOURCE
    float    matDiffuse[4];
    float    matAmbient[4];
    float    matEmissive[4];
    float    globalAmbient[4]; // D3DRS_AMBIENT unpacked
    float    world[16];        // column-major world matrix (normal/pos lighting)
    MetalLight lights[8];
} MetalDrawCall;

void MetalContext_Draw(MetalContext* ctx, const MetalDrawCall* dc);

// ---------------------------------------------------------------------------
// Stage 6: shadow mapping. A depth-only render pass from the sun's POV is
// captured into a private shadow texture, then sampled+compared in the main
// fragment shader to darken shadowed pixels. Replaces the engine's stencil
// shadow volume system on macOS — works for skinned meshes (infantry) too,
// which the original stencil path explicitly skipped.
//
// Lifecycle per frame:
//   1) MetalContext_BeginShadowPass(ctx, lvp)  -- start a depth-only encoder
//      bound to the shadow map, draws use `lvp * world` as MVP.
//   2) (engine issues normal scene draws — they go into the shadow pass)
//   3) MetalContext_EndShadowPass(ctx)         -- finish shadow encoder.
//   4) (engine issues main draws — they bind shadowMap at texture(2), the
//      fragment shader samples + compares to darken shadowed fragments.)
// ---------------------------------------------------------------------------

// Enable/disable shadow sampling in the main fragment shader. When 0, the
// shadow-map binding + lightVP are ignored even if a shadow pass ran.
void MetalContext_SetShadowsEnabled(MetalContext* ctx, int enabled);

// Set MSAA sample count (1/2/4/8). Triggers a pipeline-cache rebuild +
// MSAA/depth texture realloc on the next Draw. Suppressed when MTL_MSAA
// env var is set (env override locks in at MetalContext_Create time).
void MetalContext_SetMSAA(MetalContext* ctx, int samples);

// Begin a depth-only render pass into the shadow map. `lvp` is the light's
// view*projection matrix (column-major, same convention as `MetalDrawCall::mvp`).
void MetalContext_BeginShadowPass(MetalContext* ctx, const float lvp[16]);

// Finish the shadow pass. Subsequent draws go to the main render pass and
// sample the captured shadow map.
void MetalContext_EndShadowPass(MetalContext* ctx);

// Engine-side convenience wrappers that use the active (single) MetalContext
// without needing the caller to plumb it. Set by MetalContext_Create.
void MetalShim_SetShadowsEnabled(int enabled);
void MetalShim_SetMSAA(int samples);
void MetalShim_BeginShadowPass(const float lvp[16]);
void MetalShim_EndShadowPass(void);

// One-stop "Metal Optimised" preset toggle. Enables/disables the set of
// QA-passed macOS-shim graphical features as a group — see the long
// comment above the definition in metal_backend.mm for the current list.
// Called by GameLOD.cpp applyStaticLODLevel when the user picks the
// "Metal Optimised" entry in Options → Graphics → Detail.
void MetalShim_ApplyMacOptimised(int on);

// ---------------------------------------------------------------------------
// Input (Stage 3). The single game window feeds global mouse/key queues from
// its NSEvent stream. These are global (no ctx) so the engine's message pump
// can drain them without holding the MetalContext.
// ---------------------------------------------------------------------------
enum MetalMouseEventType {
    METAL_MOUSE_MOVE  = 1,
    METAL_MOUSE_LDOWN = 2, METAL_MOUSE_LUP = 3, METAL_MOUSE_LDBL = 4,
    METAL_MOUSE_RDOWN = 5, METAL_MOUSE_RUP = 6,
    METAL_MOUSE_MDOWN = 7, METAL_MOUSE_MUP = 8,
    METAL_MOUSE_WHEEL = 9,
};

// Dequeue one mouse event. Returns 1 and fills out-params, or 0 if empty.
// x/y are content-view pixels, top-left origin (match the back-buffer). For
// METAL_MOUSE_WHEEL, delta is the signed wheel amount (WHEEL_DELTA units).
int MetalInput_PollMouse(int* type, int* x, int* y, int* delta);

// Dequeue one key event. Returns 1 and fills out-params, or 0 if empty.
// macKeyCode is the macOS virtual key code (kVK_*); down is 1 (press) / 0 (release).
int MetalInput_PollKey(int* macKeyCode, int* down);

// Current caps-lock state (1 on).
int MetalInput_CapsOn(void);

// ---------------------------------------------------------------------------
// Cursor visibility / positioning. The Generals engine controls cursor shape +
// visibility via Win32 SetCursor/ShowCursor; on macOS we forward those to
// NSCursor here. Without this, the system cursor stays visible at the user's
// mouse position WHILE the engine renders its own software-cursor sprite at
// the engine's internal mouse position — same place when in sync, but the
// engine NEVER hid the system cursor, so user sees both (a dual-cursor effect).
// Also, SetCursor(nullptr) is the engine's "use software cursor only" signal;
// any non-null HCURSOR means "show some system cursor shape".
// ---------------------------------------------------------------------------
//
// Counter-based hide (matches Win32 ShowCursor semantics): each Hide(true)
// decrements; each Hide(false) increments; cursor is hidden whenever the
// internal counter is < 0. Returns the new counter value (mirrors Win32).
int  MetalCursor_Show(int show);  // show!=0 => increment; show==0 => decrement

// Convert client (content-view, top-left origin, pixels) coords to global
// screen coords and warp the system cursor there. Returns 1 on success.
int  MetalCursor_WarpClient(int clientX, int clientY);

#ifdef __cplusplus
}
#endif

#endif // METAL_BACKEND_H

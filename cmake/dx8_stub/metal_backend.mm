// Metal backend implementation (Objective-C++). See metal_backend.h.
//
// Milestone 2: real 2D rendering. Open a window + device/queue/CAMetalLayer,
// upload textures, and draw textured/coloured triangle lists for the UI through
// a small cached pipeline. The clear is the load-action of the frame's single
// render pass; draws are encoded into that pass; Present ends + commits it.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "metal_backend.h"

#include <cstring>
#include <strings.h>   // strcasecmp for env-var parsing
#include <unordered_map>
#include <atomic>
#include <execinfo.h>
#include <mutex>
#include <deque>

// ---------------------------------------------------------------------------
// Input capture (Stage 3): global queues filled from the window's NSEvent
// stream in DrainEvents, drained by the engine via MetalInput_Poll*.
// ---------------------------------------------------------------------------
namespace {
struct MouseEv { int type, x, y, delta; };
struct KeyEv   { int macKeyCode, down; };
std::deque<MouseEv> g_mouseQ;
std::deque<KeyEv>   g_keyQ;
std::deque<unsigned int> g_charQ;   // NSEvent-composed typed chars for text fields
bool                g_capsOn = false;
unsigned long       g_prevModFlags = 0;
NSView*             g_inputView = nil;   // active content view, for coord conversion
// Engine-side render resolution in PIXELS (what the game thinks the screen is).
// Set by MetalContext_Create / MetalContext_Resize. The NSView's bounds are in
// POINTS and may be smaller than this (HiDPI: 2x scale; or screen-fit clamp at
// 2K+ on a smaller display). EventPoint linearly maps view-points → engine-pixels.
int                 g_engineW = 0;
int                 g_engineH = 0;
} // namespace

extern "C" void MetalInput_SetEngineSize(int w, int h)
{
    g_engineW = (w > 0) ? w : 0;
    g_engineH = (h > 0) ? h : 0;
}

namespace {
// Convert an NSEvent window location to engine pixel coords, top-left origin.
// Returns false if the point is outside the view's bounds — caller should
// DROP the mouse event in that case. This matters for screen-edge scroll
// (LookAtXlat.cpp:349-360): the engine treats `m_currentPos.x >= width - 3`
// as "scroll right". With `setAcceptsMouseMovedEvents:YES` Cocoa keeps
// firing mouseMoved events while the foreground app's window is on screen
// but the cursor is outside the window — `locationInWindow` then carries
// out-of-bounds coords (e.g. x=1300 in a 1280-wide window) which the
// engine sees as "always at the screen edge" → permanent edge scroll
// following whichever screen corner the cursor wandered into. Previously
// we clamped low-side (x<0 → 0) but not high-side, so the right/bottom
// over-shoot leaked through.
//
// HiDPI / high-resolution scaling: the NSView's bounds are in POINTS, but the
// engine's UI coordinate system is in PIXELS (whatever resolution the user
// picked in Options → Display). At 2K+ on a Retina display the window
// content rect is also clamped to the screen (in points), so view.bounds.width
// is e.g. 1280 while the engine expects 2560. We linearly remap so clicking
// the right edge of the visible window registers as the right edge of the
// engine's UI grid regardless of the physical window size.
inline bool EventPoint(NSEvent* e, int* outX, int* outY)
{
    *outX = 0; *outY = 0;
    if (!g_inputView) return false;
    NSPoint p = [g_inputView convertPoint:e.locationInWindow fromView:nil];
    CGFloat w = g_inputView.bounds.size.width;
    CGFloat h = g_inputView.bounds.size.height;
    if (w <= 0.0 || h <= 0.0) return false;
    // Reject coords clearly outside the view (with a 1-point tolerance so
    // an event with p.x == bounds.width still counts as the last interior
    // column rather than being dropped).
    if (p.x < 0.0 || p.x > w || p.y < 0.0 || p.y > h) return false;
    // Map view-points → engine-pixels. If the engine size hasn't been published
    // yet (very early boot before MetalContext_Create finishes), fall back to
    // 1:1 — that path is short enough that no UI exists to click on anyway.
    int engineW = (g_engineW > 0) ? g_engineW : (int)w;
    int engineH = (g_engineH > 0) ? g_engineH : (int)h;
    double sx = (double)engineW / (double)w;
    double sy = (double)engineH / (double)h;
    // Round (not truncate) so the engine-pixel chosen for view-point P is the
    // pixel whose centre is nearest P. Truncation biases every coord toward 0
    // and shifts the engine-side cursor up-and-left by ~0.5 engine-pixels per
    // axis vs. the OS cursor visually drawn at P. At low resolutions that's
    // imperceptible; at 2K via screen-fit downscale, sx can be ~1.7 so each
    // view-point covers ~1.7 engine-pixels and the half-pixel bias becomes
    // ~1 engine-pixel — enough to cause a small but visible "drift" between
    // the OS cursor and the engine pick point, magnified by camera depth into
    // a multi-tile world-space offset when zoomed out. Rounding centres the
    // mapping and the drift disappears.
    int x = (int)(p.x * sx + 0.5);
    int y = (int)((h - p.y) * sy + 0.5);   // flip: Cocoa bottom-left → engine top-left
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > engineW - 1) x = engineW - 1;
    if (y > engineH - 1) y = engineH - 1;
    *outX = x; *outY = y;
    return true;
}
} // namespace

// --- D3D enum values we map (kept local so this file stays free of d3d8.h) ---
enum {
    D3DPT_TRIANGLELIST  = 4,
    D3DPT_TRIANGLESTRIP = 5,
    D3DPT_TRIANGLEFAN   = 6,
};
enum {
    D3DBLEND_ZERO            = 1,  D3DBLEND_ONE             = 2,
    D3DBLEND_SRCCOLOR        = 3,  D3DBLEND_INVSRCCOLOR     = 4,
    D3DBLEND_SRCALPHA        = 5,  D3DBLEND_INVSRCALPHA     = 6,
    D3DBLEND_DESTALPHA       = 7,  D3DBLEND_INVDESTALPHA    = 8,
    D3DBLEND_DESTCOLOR       = 9,  D3DBLEND_INVDESTCOLOR    = 10,
    D3DBLEND_SRCALPHASAT     = 11,
};

// ---------------------------------------------------------------------------
// Embedded MSL: one pipeline family covering both the 2D FVF (pos+diffuse+uv)
// and the 3D mesh FVFs (pos[+normal][+diffuse]+uv) with D3D fixed-function
// vertex lighting. Missing attributes are flagged off via the uniforms.
// ---------------------------------------------------------------------------
static NSString* const kShaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VSIn {
    // float4 so XYZRHW pre-transformed vertices (D3DFVF_XYZRHW, posFloats==4)
    // can read the RHW component. When the vertex buffer attribute is
    // declared MTLVertexFormatFloat3 (untransformed XYZ, posFloats==3),
    // Metal pads the missing w to 1.0 on read — verified on Apple Silicon.
    float4 pos    [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float4 color  [[attribute(2)]];   // uchar4 normalized -> (B,G,R,A)
    float2 uv     [[attribute(3)]];
};
struct VSOut {
    float4 pos [[position]];
    float4 color;
    float2 uv;
    // Light-space clip-space position for shadow sampling. The vs computes
    // this from `u.lightVP * world * pos` when u.shadowEnable!=0; the fs
    // performs perspective divide → NDC → tex coords → depth compare against
    // shadowMap. When u.shadowEnable==0, the varying is unused.
    float4 lpos;
};

struct GpuLight {
    float4 diffuse;     // rgb used
    float4 ambient;     // rgb used
    float4 position;    // xyz world
    float4 direction;   // xyz world (direction the light travels)
    float4 atten;       // x=a0 y=a1 z=a2 w=type(1 point,2 spot,3 directional)
};

struct Uniforms {
    float4x4 mvp;
    float4x4 world;
    // view + texXform are used by TCI_CAMERASPACEPOSITION: the shroud overlay
    // generates UV from each vertex's camera-space position rather than from
    // the vertex's TEX0 attribute. UV = (texXform * view * world * pos).xy
    // when tciMode==2 and texXformCount==2. For all other passes view/texXform
    // are unused and UV comes straight from `in.uv` (the vertex attribute).
    float4x4 view;
    float4x4 texXform;
    // Light view*projection. Used by:
    //   * shadow pass (when u.shadowPass!=0) — vs OUTPUTS `lvp * world * pos`
    //     as the clip-space position so the rasterizer fills the shadow map
    //     with light-space depth.
    //   * main pass (when u.shadowEnable!=0) — vs computes a varying
    //     `lpos = lvp * world * pos` so the fs can sample the shadow map.
    float4x4 lightVP;
    float4   matDiffuse;
    float4   matAmbient;
    float4   matEmissive;
    float4   globalAmbient;   // rgb
    int      lightingEnable;
    int      hasDiffuse;
    int      hasNormal;
    int      numLights;
    int      diffuseSource;   // 0=material, 1=vertex color1
    int      ambientSource;
    int      emissiveSource;
    int      tciMode;         // 0=PASSTHRU, 2=CAMERASPACEPOSITION
    int      texXformCount;   // 0=DISABLE, 2=COUNT2 (use .xy)
    int      posFloats;       // 3=XYZ untransformed, 4=XYZRHW pre-transformed
    int      shadowPass;      // 1 => emit lightVP*world*pos as clip pos (depth-only)
    int      shadowEnable;    // 1 => compute lpos varying for main-pass sampling
    // Pad the int block to 16 ints (64 bytes) so the float4-aligned `lights[]`
    // that follows starts on a 16-byte boundary. MSL aligns float4 to 16; CPU
    // C++ does not auto-pad, so without these explicit pads the CPU `lights`
    // offset is 8 bytes less than the MSL one, and the GPU reads light data
    // shifted into the int block — visually surfaces as broken lighting
    // (buildings/units become near-black).
    int      _pad0;
    int      _pad1;
    int      _pad2;
    int      _pad3;
    // Viewport pixel dimensions, used by the XYZRHW path to convert pre-
    // transformed screen-space coords → NDC. The full int block above is
    // exactly 16 ints (64 B), so this float2 starts at offset 384 and the
    // float4-aligned lights[] that follows is shifted accordingly. CPU side
    // must mirror this exact layout (see UniformsCPU).
    float2   viewportSize;
    float2   _padVP;
    GpuLight lights[8];
};

vertex VSOut vs_main(VSIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    VSOut o;
    // XYZRHW pre-transformed path. The engine writes pixel-space coords
    // (pos.xy in viewport pixels, pos.z in [0..1], pos.w = RHW = 1/w).
    // D3D8 drivers detect D3DFVF_XYZRHW and bypass world/view/projection;
    // we have to do the same here or the renderStencilShadows full-screen
    // quad (W3DVolumetricShadow.cpp:3340) lands somewhere off-screen and
    // the shadow darkening never appears. Formula matches DXVK's
    // d3d9_fixed_function.cpp pre-transform path: `NDC = pos * invExtent
    // + invOffset`, then perspective divide. Metal NDC is Y-up, D3D
    // screen is Y-down, hence the -2/H + 1 in the Y term.
    if (u.posFloats == 4) {
        float w   = (in.pos.w != 0.0) ? in.pos.w : 1.0;
        float invW = 1.0 / w;
        // Apply RHW perspective divide on XYZ (engine typically writes
        // RHW=1 for 2D quads → no-op, but be correct for tools that
        // bake real RHW).
        float3 sxyz = in.pos.xyz * invW;
        float4 ndc;
        ndc.x = sxyz.x * (2.0 / u.viewportSize.x) - 1.0;
        ndc.y = 1.0 - sxyz.y * (2.0 / u.viewportSize.y);
        ndc.z = sxyz.z;
        ndc.w = 1.0;
        o.pos   = ndc;
        o.color = (u.hasDiffuse != 0) ? in.color.bgra : float4(1.0);
        o.uv    = in.uv;
        o.lpos  = float4(0.0);
        return o;
    }

    // Shadow pass: clip-space position IS the light-space transform, so the
    // depth attachment is filled with light-space z. Color attachment is
    // disabled in that pipeline, so o.color/uv are irrelevant — but we still
    // assign them (Metal vs must populate the [[position]] varying).
    if (u.shadowPass != 0) {
        o.pos   = u.lightVP * u.world * float4(in.pos.xyz, 1.0);
        o.color = float4(1.0);
        o.uv    = float2(0.0);
        o.lpos  = float4(0.0);
        return o;
    }
    o.pos = u.mvp * float4(in.pos.xyz, 1.0);
    // Main pass: pre-compute light-space position for the fs shadow lookup.
    // Only meaningful when u.shadowEnable!=0 (we still compute to keep the
    // varying interface stable so Metal doesn't optimise it away mid-frame).
    o.lpos = u.lightVP * u.world * float4(in.pos.xyz, 1.0);

    // ---- UV: pass-through OR D3D fixed-function texcoord generation ----
    // The shroud overlay pass sets D3DTSS_TEXCOORDINDEX = TCI_CAMERASPACEPOSITION
    // and D3DTSS_TEXTURETRANSFORMFLAGS = COUNT2, with a custom D3DTS_TEXTURE0
    // matrix that includes inverse-view × cell-scale. D3D's spec for that
    // combination: input texcoord = camera-space vertex position (world*view*pos),
    // output texcoord = texXform * input, final UV = output.xy.
    //
    // DEFENSIVE GATE: TerrainShader2Stage doesn't always reset TEXCOORDINDEX
    // after the shroud pass, so this enum-tag leaks to subsequent draws (HUD,
    // 2D glyphs, units). Treat TCI as ACTIVE only when ALL three are true:
    //   1) tciMode == CAMERASPACEPOSITION  (high bits of TEXCOORDINDEX)
    //   2) texXformCount >= 2              (texture transform actually enabled)
    //   3) input is untransformed XYZ      (TCI is meaningless for XYZRHW 2D)
    // This matches what real D3D8 effectively does (TCI is a no-op for pre-
    // transformed vertices, and `TTFF=DISABLE` cancels TCI in practice). With
    // these gates, every non-shroud draw falls back to vertex UV regardless of
    // whatever stale state the engine left in m_tss.
    // TCI path (defensive triple-gate). Bisect 2026-05-23 confirmed this is
    // NOT the cause of menu corruption or in-game green rect; reinstating to
    // keep shroud overlay rendering correctly on cliff peaks.
    bool tciActive = (u.tciMode == 2 /* CAMERASPACEPOSITION */)
                  && (u.texXformCount >= 2)
                  && (u.posFloats == 3); /* XYZ untransformed; XYZRHW=4 skips TCI */
    if (tciActive) {
        float4 wpos   = u.world * float4(in.pos.xyz, 1.0);
        float4 cspos  = u.view  * wpos;
        float4 transf = u.texXform * cspos;
        o.uv = transf.xy;
    } else {
        o.uv = in.uv;
    }

    float4 vcol = (u.hasDiffuse != 0) ? in.color.bgra : float4(1.0);

    if (u.lightingEnable == 0) {
        o.color = vcol;               // unlit: vertex diffuse (or white)
        return o;
    }

    // Pick effective material colours per D3DMCS_* source.
    float4 md = (u.diffuseSource  == 1 && u.hasDiffuse != 0) ? vcol : u.matDiffuse;
    float4 ma = (u.ambientSource  == 1 && u.hasDiffuse != 0) ? vcol : u.matAmbient;
    float4 me = (u.emissiveSource == 1 && u.hasDiffuse != 0) ? vcol : u.matEmissive;

    // D3D fixed-function lighting needs a vertex normal for the per-light
    // diffuse (N·L) term. Geometry without a normal in its FVF (e.g. terrain,
    // which bakes its lighting into the vertex diffuse colour) gets only the
    // ambient/emissive terms — applying a fake normal would wash it out.
    float3 col = me.rgb + ma.rgb * u.globalAmbient.rgb;
    if (u.hasNormal != 0) {
        float3 N = normalize((u.world * float4(in.normal, 0.0)).xyz);
        float3 worldPos = (u.world * float4(in.pos.xyz, 1.0)).xyz;
        int n = min(u.numLights, 8);
        for (int i = 0; i < n; ++i) {
            GpuLight L = u.lights[i];
            col += ma.rgb * L.ambient.rgb;
            float3 Ldir;
            float atten = 1.0;
            if (L.atten.w == 3.0) {                 // directional
                Ldir = normalize(-L.direction.xyz);
            } else {                                // point/spot (spot treated as point)
                float3 d = L.position.xyz - worldPos;
                float dist = length(d);
                Ldir = (dist > 0.0) ? d / dist : float3(0.0, 0.0, 1.0);
                float den = L.atten.x + L.atten.y * dist + L.atten.z * dist * dist;
                atten = (den > 0.0) ? (1.0 / den) : 1.0;
            }
            float ndotl = max(0.0, dot(N, Ldir));
            col += md.rgb * L.diffuse.rgb * ndotl * atten;
        }
    } else {
        // No normal: D3D would still fold light ambient into the result.
        int n = min(u.numLights, 8);
        for (int i = 0; i < n; ++i) col += ma.rgb * u.lights[i].ambient.rgb;
    }
    o.color = float4(col, md.a);
    return o;
}

// D3DTOP_* (D3DTEXTUREOP) values, see d3d8types.h.
//   1=DISABLE 2=SELECTARG1 3=SELECTARG2 4=MODULATE 5=MODULATE2X 6=MODULATE4X
//   7=ADD 8=ADDSIGNED 9=ADDSIGNED2X 10=SUBTRACT 11=ADDSMOOTH
//   12=BLENDDIFFUSEALPHA 13=BLENDTEXTUREALPHA 14=BLENDFACTORALPHA 15=BLENDTEXTUREALPHAPM
//   16=BLENDCURRENTALPHA 17=PREMODULATE 18..21=MODULATE_*_ADD_*
//   22=BUMPENVMAP 23=BUMPENVMAPLUMINANCE 24=DOTPRODUCT3 25=MULTIPLYADD 26=LERP
// D3DTA_* (arg selectors): 0=DIFFUSE 1=CURRENT 2=TEXTURE 3=TFACTOR
//   4=SPECULAR 5=TEMP 6=CONSTANT  |  D3DTA_COMPLEMENT=0x10  D3DTA_ALPHAREPLICATE=0x20

struct FSParams {
    float alphaRef;
    int   alphaTestEnable;
    int   dbgTexOnly;
    // Stage-0 FF colour/alpha combiner state. 0 in any slot means "use legacy default":
    // colorOp/alphaOp -> MODULATE, colorArg1/alphaArg1 -> TEXTURE, colorArg2/alphaArg2 -> DIFFUSE.
    // tfactor is BGRA pre-multiplied to float4 by the backend.
    int   colorOp;
    int   colorArg1;
    int   colorArg2;
    int   alphaOp;
    int   alphaArg1;
    int   alphaArg2;
    int   shadowEnable;   // 1 => sample shadowTex; <=0 => skip shadow path entirely
    float shadowBias;     // depth bias to avoid self-shadow acne (default ~0.001)
    float shadowDarken;   // multiplier applied to fragment color in shadow (e.g. 0.5)
    float shadowTexelSize;// 1.0 / SHADOW_MAP_SIZE — PCF kernel uses it to step
                          // by one texel between samples for soft edges.
    // 3 trailing pads round the leading scalar block to 16 ints (=64 bytes)
    // so the float4-aligned `tfactor` lands at offset 64 on both CPU and MSL.
    int   _pad1;
    int   _pad2;
    int   _pad3;
    float4 tfactor;
};

// Depth-only fragment for the shadow pass. The pipeline has no color
// attachment, so a void return is correct — only depth gets written.
fragment void shadow_fs() {}

// FF arg fetch — mirrors DXVK's GetArg in d3d9_fixed_function.cpp::compilePS.
// `current` starts as `diffuse` for stage 0 and accumulates per stage; we only
// emulate stage 0 here so current==diffuse and SPECULAR/TEMP/CONSTANT are
// effectively unused, but the masks/handling stay consistent with D3D's spec.
static inline float4 FFGetArg(int arg, float4 tex, float4 diffuse, float4 tfactor) {
    int sel = arg & 0xF;  // D3DTA_SELECTMASK
    float4 r;
    if      (sel == 2) r = tex;
    else if (sel == 0) r = diffuse;
    else if (sel == 1) r = diffuse;  // CURRENT==DIFFUSE for stage 0
    else if (sel == 3) r = tfactor;
    else if (sel == 4) r = diffuse;  // SPECULAR: not separately plumbed → fallback
    else               r = float4(1.0);
    if (arg & 0x10) r = 1.0 - r;     // D3DTA_COMPLEMENT
    if (arg & 0x20) r = float4(r.a); // D3DTA_ALPHAREPLICATE
    return r;
}

// DoOp for the .rgb subset of the combiner; alpha is computed separately so
// that a stage can MODULATE colour but ADD alpha (the trapezoid-water case).
static inline float3 FFDoOp3(int op, float3 a1, float3 a2) {
    if (op == 4)  return a1 * a2;                                // MODULATE
    if (op == 5)  return saturate(a1 * a2 * 2.0);                // MODULATE2X
    if (op == 6)  return saturate(a1 * a2 * 4.0);                // MODULATE4X
    if (op == 2)  return a1;                                     // SELECTARG1
    if (op == 3)  return a2;                                     // SELECTARG2
    if (op == 7)  return saturate(a1 + a2);                      // ADD
    if (op == 8)  return saturate(a1 + a2 - 0.5);                // ADDSIGNED
    if (op == 9)  return saturate((a1 + a2 - 0.5) * 2.0);        // ADDSIGNED2X
    if (op == 10) return saturate(a1 - a2);                      // SUBTRACT
    if (op == 11) return saturate(a1 + a2 - a1 * a2);            // ADDSMOOTH
    if (op == 25) return saturate(a1 + a2);                      // MULTIPLYADD(stub→ADD)
    return a1 * a2;                                              // default → MODULATE
}
static inline float FFDoOp1(int op, float a1, float a2) {
    if (op == 4)  return a1 * a2;
    if (op == 5)  return saturate(a1 * a2 * 2.0);
    if (op == 6)  return saturate(a1 * a2 * 4.0);
    if (op == 2)  return a1;
    if (op == 3)  return a2;
    if (op == 7)  return saturate(a1 + a2);
    if (op == 8)  return saturate(a1 + a2 - 0.5);
    if (op == 9)  return saturate((a1 + a2 - 0.5) * 2.0);
    if (op == 10) return saturate(a1 - a2);
    if (op == 11) return saturate(a1 + a2 - a1 * a2);
    return a1 * a2;
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        texture2d<float> tex          [[texture(0)]],
                        depth2d<float>   shadowTex    [[texture(2)]],
                        sampler smp                   [[sampler(0)]],
                        sampler shadowSmp             [[sampler(2)]],
                        constant FSParams& p          [[buffer(0)]]) {
    float4 t = tex.sample(smp, in.uv);
    // dbgTexOnly returns the raw texture sample BEFORE alpha test/combiner so a
    // black frame in TEXONLY mode means UVs are wrong or the draw is dropped,
    // and a white frame means the missing-texture sentinel is bound.
    if (p.dbgTexOnly != 0) return float4(t.rgb, 1.0);

    // Stage-0 combiner. 0/unset → legacy: COLOR=t*in.color, ALPHA=t.a*in.color.a
    // (same as the old `c = t * in.color`). Real values plumbed by FillCommon
    // (e.g. water sets ALPHAOP=ADD → alpha = t.a + in.color.a, hiding the
    // per-tile alpha seams that previously showed as a darker grid on water).
    int colorOp = p.colorOp;
    int alphaOp = p.alphaOp;
    if (colorOp == 0 || colorOp == 1) colorOp = 4; // 0/DISABLE both fall back to MODULATE for stage 0
    if (alphaOp == 0 || alphaOp == 1) alphaOp = 4;
    int colorA1 = p.colorArg1 ? p.colorArg1 : 2; // default TEXTURE
    int colorA2 = p.colorArg2 ? p.colorArg2 : 0; // default DIFFUSE
    int alphaA1 = p.alphaArg1 ? p.alphaArg1 : 2;
    int alphaA2 = p.alphaArg2 ? p.alphaArg2 : 0;

    float4 ca1 = FFGetArg(colorA1, t, in.color, p.tfactor);
    float4 ca2 = FFGetArg(colorA2, t, in.color, p.tfactor);
    float4 aa1 = FFGetArg(alphaA1, t, in.color, p.tfactor);
    float4 aa2 = FFGetArg(alphaA2, t, in.color, p.tfactor);

    float3 rgb = FFDoOp3(colorOp, ca1.rgb, ca2.rgb);
    float  a   = FFDoOp1(alphaOp, aa1.a,   aa2.a);
    float4 c = float4(rgb, a);

    if (p.alphaTestEnable != 0 && c.a < p.alphaRef) discard_fragment();

    // Stage 6: shadow mapping with 3×3 PCF (Percentage-Closer Filtering).
    // Perspective divide light-space pos to NDC, flip Y (Metal top-left vs
    // NDC bottom-left), then sample shadowTex 9 times in a 3×3 kernel around
    // the projected UV. Each tap contributes 1/9th of a shadow factor; the
    // average gives a soft 0..1 gradient at silhouette edges instead of the
    // hard 0/1 of single-tap sampling.
    //
    // 9-tap (3×3) is the cheap soft-shadow sweet spot — visible softening,
    // ~0% measurable perf cost on Apple Silicon. Quality follows the
    // shadowTexelSize: smaller texelSize (= larger shadow map) → tighter
    // softening; larger texel = blockier softening.
    if (p.shadowEnable != 0) {
        float3 lp = in.lpos.xyz / max(in.lpos.w, 1e-6);
        float2 suv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
        // DIAG: when shadowDebug bit (bit1 of shadowEnable) is set, return
        // the light-space coordinates as RGB so we can visualise the frustum:
        //   R = suv.x (sideways across light frustum, 0..1 in-bounds)
        //   G = suv.y (vertical across light frustum)
        //   B = lp.z  (depth, 0=near to light, 1=far)
        // Anything outside light frustum gets out-of-range colour (black or
        // overbright). Toggle with MTL_SHADOW_VIZ env var (sets bit1 in shim).
        if ((p.shadowEnable & 2) != 0) {
            return float4(saturate(suv.x), saturate(suv.y), saturate(lp.z), 1.0);
        }
        if (suv.x >= 0.0 && suv.x <= 1.0 && suv.y >= 0.0 && suv.y <= 1.0 &&
            lp.z >= 0.0 && lp.z <= 1.0)
        {
            float refZ = lp.z - p.shadowBias;
            float occluded = 0.0;
            // Unrolled 3×3 PCF kernel — Metal compiler auto-unrolls but writing
            // it out gets best constant-folding for the offsets.
            float2 ts = float2(p.shadowTexelSize);
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2(-1.0,-1.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2( 0.0,-1.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2( 1.0,-1.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2(-1.0, 0.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv                       )) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2( 1.0, 0.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2(-1.0, 1.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2( 0.0, 1.0)*ts)) ? 1.0 : 0.0;
            occluded += (refZ > shadowTex.sample(shadowSmp, suv + float2( 1.0, 1.0)*ts)) ? 1.0 : 0.0;
            float shadowFactor = occluded / 9.0;   // 0=lit, 1=fully shadowed
            // Lerp colour between fully-lit and fully-darkened by shadowFactor.
            // shadowDarken=1.0 → no shadow; 0.0 → fully black.
            c.rgb = mix(c.rgb, c.rgb * p.shadowDarken, shadowFactor);
        }
    }
    return c;
}
)METAL";

// CPU mirror of the MSL `Uniforms` struct (must match field order + size).
namespace {
struct GpuLightCPU { float diffuse[4]; float ambient[4]; float position[4]; float direction[4]; float atten[4]; };
struct UniformsCPU {
    float mvp[16];
    float world[16];
    float view[16];          // D3DTS_VIEW (used by TCI_CAMERASPACEPOSITION)
    float texXform[16];      // D3DTS_TEXTURE0 (stage-0 texture transform)
    float lightVP[16];       // light view*projection for shadow pass + main-pass sample
    float matDiffuse[4];
    float matAmbient[4];
    float matEmissive[4];
    float globalAmbient[4];
    int   lightingEnable, hasDiffuse, hasNormal, numLights;
    int   diffuseSource, ambientSource, emissiveSource, tciMode;
    int   texXformCount, posFloats, shadowPass, shadowEnable;
    // 4 trailing pad ints round the int block out to 16 (=64 bytes) so the
    // float4-aligned MSL `lights[]` lands on the same offset on CPU. See note
    // on the MSL Uniforms struct above.
    int   _pad0, _pad1, _pad2, _pad3;
    // Viewport pixel dimensions, mirrored from MSL Uniforms.viewportSize.
    // Drives the XYZRHW screen→NDC formula in vs_main. Filled per draw from
    // ctx->width / ctx->height.
    float viewportSize[2];
    float _padVP[2];
    GpuLightCPU lights[8];
};
} // namespace

// ---------------------------------------------------------------------------
// Window plumbing
// ---------------------------------------------------------------------------
// Forward decl so the view's keyDown:/keyUp:/flagsChanged: can push to the
// shared input queues defined above.
namespace { struct KeyEv; }
extern "C" void MetalView_PushKeyEvent(int keyCode, int down);
extern "C" void MetalView_PushFlagsChanged(unsigned long modFlags, int keyCode);
extern "C" void MetalView_PushChar(unsigned int ch);

@interface MetalView : NSView
@end
@implementation MetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer*)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstResponder { return YES; }

// Key events: NSEventMaskAny + nextEventMatchingMask does NOT reliably surface
// keyDown/keyUp NSEvents to our drain — they go straight to the responder
// chain and AppKit consumes them at NSWindow (specifically ESC, which AppKit
// treats as -cancelOperation:). Verified empirically: with MTL_INPUT_LOG=1
// over an interactive session, only NSEventTypeFlagsChanged events appeared
// via DrainEvents; every keyDown/keyUp was lost. Capture them here at the
// view's NSResponder layer instead — first responder is already set to this
// view in MetalContext_Create, and acceptsFirstResponder returns YES above.
// NOTE: do NOT call [super keyDown:] / [super keyUp:] — the default impl
// forwards up the chain to NSWindow, which beeps on unhandled ESC.
- (void)keyDown:(NSEvent*)e {
    if (!e.isARepeat) {
        MetalView_PushKeyEvent((int)e.keyCode, 1);
        // TheSuperHackers @port macOS @bugfix: macOS does NOT deliver -keyUp: for a
        // key released while Command (Cmd) is held. Without the matching up the
        // engine thinks the key stays down and auto-repeats it forever — e.g. with
        // GEN_WASD_CAMERA, Cmd+W fires "select all aircraft" but W then sticks and
        // the camera scrolls up endlessly; likewise Cmd+A/Cmd+D never fire because
        // the command-bar hotkey triggers on key-up. A Cmd+key can't be held-repeated
        // on macOS anyway, so treat it as a tap: synthesize the up immediately.
        if (e.modifierFlags & NSEventModifierFlagCommand)
            MetalView_PushKeyEvent((int)e.keyCode, 0);
    }
    // Text-entry input: NSEvent has already applied the live system keyboard
    // layout + shift/caps/option/dead-keys, so -characters is the correct typed
    // character (unlike the raw keyCode path, which only knows a handful of
    // hardcoded layouts). Queue them for the engine to hand to focused text
    // fields as GWM_IME_CHAR — the macOS stand-in for the Win32 WM_CHAR pump.
    // Repeats are included on purpose (held-key auto-repeat, like WM_CHAR).
    NSString* chars = [e characters];
    for (NSUInteger i = 0; i < chars.length; ++i)
        MetalView_PushChar((unsigned int)[chars characterAtIndex:i]);
}
- (void)keyUp:(NSEvent*)e {
    MetalView_PushKeyEvent((int)e.keyCode, 0);
}
- (void)flagsChanged:(NSEvent*)e {
    MetalView_PushFlagsChanged((unsigned long)e.modifierFlags, (int)e.keyCode);
}
// AppKit's default cancelOperation: handler swallows ESC at the window level
// and triggers system beep. We need ESC to reach the game (open in-game menu),
// so override to no-op — the keyDown: above has already enqueued the event.
- (void)cancelOperation:(id)sender { (void)sender; /* eaten on purpose */ }
@end

// Letterbox container: hosts the MetalView as an aspect-fit subview. When the
// window is resized or — the case that matters — taken FULLSCREEN to a screen
// whose aspect differs from the game resolution (e.g. a 16:10 game on a 16"
// MacBook Pro's ~1.547 panel), the render surface keeps the game's aspect ratio
// and black bars fill the remainder, instead of the CAMetalLayer stretching the
// drawable to fill (which looks vertically/horizontally stretched). In windowed
// mode the window is already sized to the game aspect, so the child fills the
// container exactly (no bars) and behaviour is identical to hosting the MetalView
// directly. Input stays correct: EventPoint() maps within g_inputView (the child)
// and rejects coords outside its bounds, so clicks in the bars are ignored.
// Escape hatch: GEN_LETTERBOX=0 falls back to the old stretch-to-fill path.
@interface AspectFitView : NSView
@property (nonatomic, assign) NSView* child;    // the MetalView subview (unretained; ARC is off)
@property (nonatomic, assign) CGFloat aspect;   // game width / height
- (void)layoutChild;
@end
@implementation AspectFitView
- (BOOL)isFlipped { return NO; }
- (void)layoutChild {
    NSView* c = self.child;
    if (!c || self.aspect <= 0.0) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W <= 0.0 || H <= 0.0) return;
    CGFloat va = W / H;
    CGFloat cw, ch;
    if (fabs(va - self.aspect) < 0.001) {   // aspects match → fill, no bars
        cw = W; ch = H;
    } else if (va > self.aspect) {          // container wider → pillarbox (side bars)
        ch = H; cw = H * self.aspect;
    } else {                                // container taller → letterbox (top/bottom bars)
        cw = W; ch = W / self.aspect;
    }
    CGFloat x = (W - cw) * 0.5, y = (H - ch) * 0.5;
    [c setFrame:NSMakeRect(round(x), round(y), round(cw), round(ch))];
}
// AppKit calls this instead of the default autoresize when the container's frame
// changes (fullscreen enter/exit, live resize) — do the aspect-fit here.
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize { (void)oldSize; [self layoutChild]; }
- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; [self layoutChild]; }
@end

// CPU mirror of the MSL FSParams. Must match the MSL declaration above exactly
// (size + field order). Padded so float4 (tfactor) lands on a 16-byte boundary
// as Metal requires for buffer arguments.
struct FSParams {
    float alphaRef;
    int   alphaTestEnable;
    int   dbgTexOnly;
    int   colorOp;
    int   colorArg1;
    int   colorArg2;
    int   alphaOp;
    int   alphaArg1;
    int   alphaArg2;
    int   shadowEnable;
    float shadowBias;
    float shadowDarken;
    float shadowTexelSize; // 1/SHADOW_MAP_SIZE for PCF kernel step
    int   _pad1;     // round leading block to 16 floats / 64 bytes so the
    int   _pad2;     // 16-aligned MSL `float4 tfactor` lands at the same
    int   _pad3;     // offset on CPU + GPU.
    float tfactor[4];
};

struct MetalContext {
    NSWindow*            window;
    MetalView*           view;
    CAMetalLayer*        layer;
    id<MTLDevice>        device;
    id<MTLCommandQueue>  queue;
    MTLClearColor        clearColor;
    int                  width;
    int                  height;

    // Shader functions + pipeline cache (keyed by fvf/blend state).
    id<MTLLibrary>       shaderLib;   // owns vs_main, fs_main, shadow_fs
    id<MTLFunction>      vsFn;
    id<MTLFunction>      fsFn;
    id<MTLFunction>      shadowFsFn;  // void fragment for shadow pass (lazy)
    id<MTLSamplerState>  sampler;   // legacy global sampler (WRAP, bilinear) — kept as the cache's seed entry.
    id<MTLTexture>       whiteTex;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipelines;
    // Sampler cache keyed on (addressU << 0) | (addressV << 4).
    // Key promoted uint16→uint32 to fit anisotropy + border-color buckets
    // added per DXMT pattern (see GetSampler).
    std::unordered_map<uint32_t, id<MTLSamplerState>> samplers;

    // Depth buffer (Stage 4) + depth-stencil state cache (keyed by z state).
    id<MTLTexture>       depthTex;
    int                  depthW;
    int                  depthH;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> depthStates;

    // Currently-applied MTLViewport (in framebuffer pixels). Tracked so per-draw
    // viewport changes from the engine (DX8Wrapper::Set_Viewport → our
    // dx8_device.cpp SetViewport which populates DrawCommand.vpX/Y/W/H) actually
    // reach Metal. Without this the encoder kept the boot-time full-screen
    // viewport for the entire frame and any reduced-area pass (e.g. a tactical
    // view that excludes the control-bar strip, or render2d's full-screen reset)
    // got rasterised into the wrong pixel range — causing world-space 3D draws
    // (units) and CPU-projected 2D HUD overlays (health bars, selection rings)
    // to land at different screen Y for the same world point, growing with
    // camera tilt.
    int                  appliedVpX, appliedVpY, appliedVpW, appliedVpH;

    // Stage 7: MSAA. On Apple Silicon (TBDR) both the MSAA color and MSAA depth
    // attachments are MTLStorageModeMemoryless — they live entirely in tile
    // memory, are resolved into ctx->drawable.texture at storeAction time and
    // never roundtrip to system RAM. Cost on M-series ~0% perf, ~0 bytes
    // off-tile. msaaSamples is captured from MTL_MSAA at Create time
    // (default 4; values 1/2/4/8). Shadow pipelines + shadowMap stay
    // sampleCount=1 — the shadow map is depth-only sampled by the main fs.
    id<MTLTexture>       msaaColor;
    int                  msaaW;
    int                  msaaH;
    int                  msaaSamples;

    // TheSuperHackers @port macOS @bugfix: textures uploaded this frame that need
    // their mip chain (re)generated. Batched into ONE blit command buffer at
    // Present instead of committing a fresh command buffer per upload — see
    // GenerateMips / FlushPendingMips. The set retains its members so a texture
    // released mid-frame stays valid until the flush. Was a per-upload command
    // buffer, which flooded the shared render queue (dynamic font/UI textures
    // re-upload every frame) → IOGPU submission saturation → main thread hangs
    // in [queue commandBuffer] on the in-flight semaphore after ~25 min.
    NSMutableSet*        pendingMips;

    // TheSuperHackers @port macOS @perf: per-encoder bound-state cache for
    // redundant-set elimination in MetalContext_Draw. Every state-setter on
    // ctx->enc goes through MetalContext_Draw, and a new encoder resets all
    // GPU state — so caching the last-bound object/value and skipping unchanged
    // set* calls is safe as long as these are reset in EnsureEncoder. Skipping
    // redundant binds lets Metal skip re-emitting the pipeline argument tables
    // (encodeAndEmitRenderState) — the dominant per-draw cost when the sorting
    // renderer / stencil shadow-volume passes flush tens of thousands of
    // state-coherent draws in a heavy battle (the >4-min freeze at 120 FPS).
    id<MTLRenderPipelineState> boundPS;
    id<MTLBuffer>              boundVB;
    id<MTLDepthStencilState>   boundDSS;
    id<MTLTexture>             boundTex0;
    id<MTLSamplerState>        boundSmp0;
    int                        boundCull;        // -1 = none set this encoder
    long long                  boundStencilRef;  // -1 = none set this encoder
    bool                       boundShadowSlot;  // shadow tex+smp bound this encoder

    // TheSuperHackers @port macOS @bugfix: dynamic-buffer recycle pool. Every
    // D3DLOCK_DISCARD (MetalVertexBuffer8/IndexBuffer8::Lock) and every
    // DrawPrimitiveUP/DrawIndexedPrimitiveUP hands a draw a FRESH MTLBuffer that
    // the GPU keeps alive until its command buffer completes. Allocating one per
    // operation floods the IOGPU allocator in heavy battles (thousands/frame ×
    // up to 64 in-flight frames) → resource exhaustion → the main thread wedges
    // in [queue commandBuffer]/IOGPUResourceCreate after a few minutes. Instead,
    // MetalContext_RetireBuffer parks the buffer tagged with the render frame it
    // was used on; once the GPU signals that frame complete (bufCompletedFrame,
    // set from the command-buffer completion handler), SweepRetiredBuffers moves
    // it into bufFree (keyed by allocated length) and MetalContext_CreateBuffer
    // reuses it — bounding live buffers to the working set. bufFree/bufRetired are
    // touched only on the render thread; bufCompletedFrame is the sole cross-thread
    // value (atomic, written by the completion handler).
    std::unordered_map<unsigned, std::vector<void*> > bufFree;      // bucketSize -> CF-retained buffers
    std::vector<std::pair<void*, uint64_t> >          bufRetired;   // (CF-retained buffer, frame used)
    uint64_t                   bufFrameId;        // monotonic render-frame counter
    std::atomic<uint64_t>      bufCompletedFrame; // highest frame the GPU finished

    // TheSuperHackers @port macOS @bugfix: command-buffer backpressure. The
    // engine's synchronous map load pumps LoadScreen draw/Present ticks
    // without ever returning to the runloop, and the committed command
    // buffers' completions fall behind — thousands end up in flight at once.
    // IOGPU sizes its per-device command-storage shmem pool to that PEAK and
    // never shrinks it: ~3000 live 32 KB storages (~200 MB, malloc_history-
    // verified) stayed resident for the rest of the process. Cap the
    // uncompleted count: every committed cb (frame + mip-flush) bumps
    // cbInFlight and decrements it in its completed-handler; commit sites
    // block with waitUntilCompleted once the cap is exceeded (never hit
    // during normal gameplay — in-flight stays ~2-3; only bursty loads
    // throttle, bounding the pool instead of the pool absorbing the burst).
    std::atomic<int>           cbInFlight;
    // MTL_POOL_LOG diagnostics: lifetime command-buffer / presentation tallies
    // (created at commit sites; completed/presented from their handlers).
    std::atomic<long>          cbCreated;
    std::atomic<long>          cbCompleted;
    std::atomic<long>          cbPresented;
    // MTL_POOL_LOG diagnostics: live shim-created GPU resources (count/bytes),
    // updated at every create/CFRelease site. RSS growth NOT reflected here is
    // outside the shim (driver pools, engine CPU heap).
    std::atomic<long>          bufLiveN;
    std::atomic<long>          bufLiveBytes;
    std::atomic<long>          texLiveN;
    std::atomic<long>          texLiveBytes;
    // Pool flow tallies (MTL_POOL_LOG): pulls/misses per create path, pushes,
    // overflow releases — a bucket pinned at cap means pushes chronically
    // exceed pulls; these tell WHICH path is unbalanced.
    std::atomic<long>          texPullCreate;   // CreateTextureFmt pool hits
    std::atomic<long>          texMissCreate;   // CreateTextureFmt fresh allocs (poolable only)
    std::atomic<long>          texPullRename;   // RenameTexture pool hits
    std::atomic<long>          texMissRename;   // RenameTexture fresh allocs
    std::atomic<long>          texPushRelease;  // ReleaseTexture -> retire
    std::atomic<long>          texPushRename;   // RenameTexture old -> retire
    std::atomic<long>          texOverflow;     // sweep cap overflows (CFReleased)
    std::atomic<long>          bufOverflow;     // buffer sweep cap overflows

    // TheSuperHackers @port macOS @bugfix: dynamic-TEXTURE rename pool — same
    // recycle discipline as the buffer pool above, for a different race.
    // UnlockRect/flushToTexture upload with [tex replaceRegion:...], which
    // writes texture memory immediately on the CPU while the PREVIOUS frame's
    // committed command buffer may still be sampling that very texture on the
    // GPU — a documented data race ("you must not call replaceRegion while the
    // GPU is reading or writing the texture"). On Apple Silicon the visible
    // symptom is transient BLACK rectangles / torn line patterns exactly where
    // a re-uploaded texture (scrolling shell-map terrain pages, font/sentence
    // atlases, video frames, radar) is drawn — the menu "black texture
    // flicker". Fix: a texture that has been uploaded once never gets an
    // in-place re-upload; MetalContext_RenameTexture hands the wrapper a fresh
    // (pooled) MTLTexture for the new contents while in-flight frames keep the
    // old one alive via the command buffer's retained references. The old
    // texture is parked in texRetired tagged with the current render frame and
    // moved to texFree (keyed by w/h/format/mips/usage) once the GPU completes
    // that frame — steady state re-uses 2-3 textures per dynamic surface.
    std::unordered_map<uint64_t, std::vector<void*> > texFree;      // TexPoolKey -> CF-retained textures
    std::vector<std::pair<void*, uint64_t> >          texRetired;   // (CF-retained texture, frame retired)
    // Private-texture staged uploads (see StageUpload): each entry owns a CF
    // ref on the texture and a pooled staging buffer; flushed into one blit
    // command buffer per Present (or inline every 64 during load bursts).
    struct PendingUpload { void* tex; void* buf; int w, h, rowBytes; };
    std::vector<PendingUpload> pendingUploads;   // guarded by poolMutex (loader thread pushes)
    // Per-texture upload history for the churn throttle (see StageUpload):
    // tex -> (last upload frame, consecutive-frame streak). poolMutex-guarded.
    std::unordered_map<void*, std::pair<uint64_t, uint32_t> > upHist;

    // Guards ALL four pool containers above. The engine loads textures from a
    // background loader thread (async TextureLoadTask), so CreateTextureFmt /
    // ReleaseTexture race the render thread's Sweep*/Rename pool access — an
    // unguarded unordered_map intermittently FAILS find() on keys it contains
    // (observed: rename misses with 1024 same-key entries pooled → every miss
    // leaked one texture generation; 29k pooled orphans in one session).
    std::mutex                 poolMutex;

    // Stage 6: shadow mapping. shadowMap is a private depth-only texture
    // (2048×2048 Depth32Float). The shim watches every 3D opaque Draw() during
    // the main render pass, snapshotting just enough state to replay it as a
    // depth-only draw from the sun's POV at Present time. The next frame's
    // main pass samples this map at texture(2) for shadow comparison. 1-frame
    // latency, 2× geometry rasterisation per frame. Engine code untouched.
    id<MTLTexture>             shadowMap;
    id<MTLRenderCommandEncoder> shadowEnc;
    id<MTLDepthStencilState>   shadowDS;     // depth-write on, LESS, no stencil
    id<MTLSamplerState>        shadowSmp;    // clamp-to-edge, linear
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> shadowPipelines;
    int                        shadowsEnabled;  // global enable for main-pass sampling
    bool                       shadowPassActive;
    float                      lightVP[16];     // light view*projection used by NEXT frame's main fs

    // Capture+replay state for the shim-only shadow path. shadowCaptures grows
    // through the frame; replayed + cleared in MetalContext_Present.
    struct CapturedDraw {
        id<MTLBuffer> vb;           // retained from the live VB pool
        id<MTLBuffer> ib;           // retained; nil for non-indexed
        unsigned      stride;
        unsigned      indexOffsetBytes;
        unsigned      indexCount;
        unsigned      vertexStart;
        unsigned      vertexCount;
        int           baseVertex;
        unsigned      fvf;
        int           primType;
        int           cullMode;
        int           posOffset;
        int           posFloats;
        int           normalOffset;
        int           diffuseOffset;
        int           tex0Offset;
        int           tex1Offset;
        int           texCoordIndex;
        float         world[16];
    };
    std::vector<CapturedDraw> shadowCaptures;
    // Last seen lighting/view state — derived by majority vote at the end of
    // each frame (see ViewBucket below + RunShadowReplay). Single-snapshot
    // approaches pick up the WRONG view when side passes (mini-map render-
    // to-texture, post-effect quads, UI billboards) submit their own draws
    // with a different D3DTS_VIEW than the tactical camera.
    float                lastView[16];
    MetalLight           lastLights[8];
    int                  lastNumLights;
    bool                 haveCaptureSnapshot;

    // Per-frame view-matrix tally. Each captured 3D draw bumps the count of
    // the bucket whose view matrix matches exactly. At Present time we pick
    // the bucket with the most captures — that's almost always the main
    // scene's tactical camera view (~hundreds of draws), and mini-map /
    // post-FX views (~tens of draws) get outvoted.
    struct ViewBucket {
        float       view[16];
        MetalLight  lights[8];
        int         numLights;
        int         count;
    };
    std::vector<ViewBucket> viewBuckets;

    // MTL_SHADOW_DBG diagnostic counters (per frame).
    int                  dbgRejPosFloats;
    int                  dbgRejBlend;
    int                  dbgRejColorWrite;
    int                  dbgRejAccepted;
    int                  dbgTotalDraws;
    uint64_t             dbgFvfMask;

    // Per-frame render state (lazily created on first draw / present).
    id<CAMetalDrawable>          drawable;
    id<MTLCommandBuffer>         cmd;
    id<MTLRenderCommandEncoder>  enc;

    // Lightweight draw instrumentation (enabled by MTL_DEBUG env var).
    int   dbg;            // -1 = uninitialised, 0 = off, 1 = on
    long  frameIndex;
    int   drawsThisFrame;
    int   texturedThisFrame;
};

static void EnsureAppInitialized()
{
    static bool initialized = false;
    if (initialized) return;
    initialized = true;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
}

// Optional input-flow diagnostic (env MTL_INPUT_LOG=1): logs every captured
// NSEvent + the converted (x,y) the engine will see. Helps diagnose:
//  - cursor coord offset (visual cursor at one place, engine click at another)
//  - missed keys (e.g. ESC not opening in-game menu)
//  - mouse-outside-window edge-scroll churn
// One stderr line per event, capped after the first 200 so the log isn't
// unreadable. Reset cap on each MetalContext_Create.
static int  g_inputLog = -1;
static int  g_inputLogCount = 0;
static const int kInputLogMax = 200;
static inline int InputLogOn(void) {
    if (g_inputLog < 0) { const char* e = getenv("MTL_INPUT_LOG"); g_inputLog = (e && atoi(e) != 0) ? 1 : 0; }
    return g_inputLog;
}

static void CaptureInputEvent(NSEvent* event)
{
    if (InputLogOn() && g_inputLogCount < kInputLogMax) {
        // Inside-window flag + raw locationInWindow for diagnosing coord-offset bugs.
        NSPoint raw = event.locationInWindow;
        const char* tag = "";
        switch (event.type) {
            case NSEventTypeMouseMoved:        tag = "MOVE";   break;
            case NSEventTypeLeftMouseDown:     tag = "LDOWN";  break;
            case NSEventTypeLeftMouseUp:       tag = "LUP";    break;
            case NSEventTypeRightMouseDown:    tag = "RDOWN";  break;
            case NSEventTypeRightMouseUp:      tag = "RUP";    break;
            case NSEventTypeLeftMouseDragged:  tag = "LDRAG";  break;
            case NSEventTypeRightMouseDragged: tag = "RDRAG";  break;
            case NSEventTypeScrollWheel:       tag = "WHEEL";  break;
            case NSEventTypeKeyDown:           tag = "KDOWN";  break;
            case NSEventTypeKeyUp:             tag = "KUP";    break;
            case NSEventTypeFlagsChanged:      tag = "FLAGS";  break;
            default: break;
        }
        if (tag[0]) {
            if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp ||
                event.type == NSEventTypeFlagsChanged) {
                fprintf(stderr, "[mtl-in] %s keyCode=0x%02X mod=0x%lX repeat=%d\n",
                        tag, (unsigned)event.keyCode,
                        (unsigned long)event.modifierFlags,
                        (event.type == NSEventTypeKeyDown ? (int)event.isARepeat : 0));
            } else {
                CGFloat vw = g_inputView ? g_inputView.bounds.size.width  : 0;
                CGFloat vh = g_inputView ? g_inputView.bounds.size.height : 0;
                bool inside = g_inputView && raw.x >= 0 && raw.x <= vw &&
                                            raw.y >= 0 && raw.y <= vh;
                fprintf(stderr, "[mtl-in] %s rawWin=(%.1f,%.1f) view=%.0fx%.0f inside=%d\n",
                        tag, raw.x, raw.y, vw, vh, inside ? 1 : 0);
            }
            ++g_inputLogCount;
            if (g_inputLogCount == kInputLogMax)
                fprintf(stderr, "[mtl-in] (log capped at %d events)\n", kInputLogMax);
        }
    }
    switch (event.type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: {
            MouseEv m; m.type = METAL_MOUSE_MOVE; m.delta = 0;
            // Drop motion events that arrive while the cursor is outside the
            // window — see EventPoint() comment. Without this, the engine's
            // screen-edge scroll latches on whichever direction the cursor
            // wandered off-window.
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeLeftMouseDown: {
            MouseEv m; m.type = (event.clickCount >= 2) ? METAL_MOUSE_LDBL : METAL_MOUSE_LDOWN;
            m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeLeftMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_LUP; m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeRightMouseDown: {
            MouseEv m; m.type = METAL_MOUSE_RDOWN; m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeRightMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_RUP; m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeOtherMouseDown: {
            MouseEv m; m.type = METAL_MOUSE_MDOWN; m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeOtherMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_MUP; m.delta = 0;
            if (!EventPoint(event, &m.x, &m.y)) break;
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeScrollWheel: {
            MouseEv m; m.type = METAL_MOUSE_WHEEL;
            if (!EventPoint(event, &m.x, &m.y)) break;
            // One detent ~= 120 (WHEEL_DELTA). scrollingDeltaY is points; sign matters.
            double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY;
            m.delta = (int)(dy * 120.0);
            if (m.delta == 0 && dy != 0.0) m.delta = (dy > 0 ? 120 : -120);
            g_mouseQ.push_back(m);
            break;
        }
        // Key events (KeyDown/KeyUp/FlagsChanged) are now captured at the
        // MetalView responder layer — see the view's keyDown:/keyUp:/
        // flagsChanged: above. They DO appear here too occasionally
        // (e.g. arrow keys with Function modifier flag come through
        // nextEventMatchingMask in some configurations), but the view
        // path always fires. Drop them here to avoid double-enqueue.
        case NSEventTypeKeyDown:
        case NSEventTypeKeyUp:
        case NSEventTypeFlagsChanged:
            break;
        default: break;
    }
}

// View-responder→shared-queue bridge for KeyDown/KeyUp/FlagsChanged. Plain C
// linkage so the @implementation block can call into the C++ deque without
// pulling Cocoa includes into the rest of the TU.
extern "C" void MetalView_PushKeyEvent(int keyCode, int down)
{
    if (InputLogOn() && g_inputLogCount < kInputLogMax) {
        fprintf(stderr, "[mtl-in] %s keyCode=0x%02X (via NSView responder)\n",
                down ? "KDOWN" : "KUP", (unsigned)keyCode);
        ++g_inputLogCount;
    }
    KeyEv k; k.macKeyCode = keyCode; k.down = down;
    g_keyQ.push_back(k);
}

extern "C" void MetalView_PushFlagsChanged(unsigned long modFlags, int keyCode)
{
    if (InputLogOn() && g_inputLogCount < kInputLogMax) {
        fprintf(stderr, "[mtl-in] FLAGS keyCode=0x%02X mod=0x%lX (via NSView responder)\n",
                (unsigned)keyCode, modFlags);
        ++g_inputLogCount;
    }
    g_capsOn = (modFlags & NSEventModifierFlagCapsLock) != 0;
    unsigned long changed = modFlags ^ g_prevModFlags;
    struct { unsigned long mask; } mods[] = {
        { NSEventModifierFlagShift }, { NSEventModifierFlagControl },
        { NSEventModifierFlagOption }, { NSEventModifierFlagCommand },
    };
    for (auto& md : mods) {
        if (changed & md.mask) {
            KeyEv k; k.macKeyCode = keyCode; k.down = (modFlags & md.mask) ? 1 : 0;
            g_keyQ.push_back(k);
        }
    }
    g_prevModFlags = modFlags;
}

extern "C" void MetalView_PushChar(unsigned int ch)
{
    // Mirror Win32 WM_CHAR semantics: only printable characters (and Return)
    // ever reach text fields. Everything else — backspace, tab, escape, the
    // arrow / function keys (Cocoa maps these to the 0xF700–0xF8FF private-use
    // range) and DEL — is already delivered via the raw-scancode path and must
    // NOT be duplicated here, or it would be inserted as literal garbage text.
    if (ch == 0x0D || ch == 0x03)          // Return / keypad-Enter -> VK_RETURN
        ch = 0x0D;
    else if (ch < 0x20 || ch == 0x7F)      // control chars + DEL
        return;
    else if (ch >= 0xF700 && ch <= 0xF8FF) // arrows / F-keys (NSEvent private use)
        return;
    if (InputLogOn() && g_inputLogCount < kInputLogMax) {
        fprintf(stderr, "[mtl-in] CHAR U+%04X\n", ch);
        ++g_inputLogCount;
    }
    g_charQ.push_back(ch);
}

static void DrainEvents()
{
    @autoreleasepool {
        NSEvent* event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:[NSDate distantPast]
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES]) != nil) {
            CaptureInputEvent(event);
            [NSApp sendEvent:event];
        }
    }
}

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------
static void BuildShadersAndStaticState(MetalContext* ctx)
{
    NSError* err = nil;
    id<MTLLibrary> lib = [ctx->device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&err];
    if (!lib) {
        NSLog(@"[metal] shader compile failed: %@", err);
        return;
    }
    ctx->shaderLib  = [lib retain];
    ctx->vsFn       = [lib newFunctionWithName:@"vs_main"];
    ctx->fsFn       = [lib newFunctionWithName:@"fs_main"];
    ctx->shadowFsFn = [lib newFunctionWithName:@"shadow_fs"];

    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeRepeat;
    ctx->sampler = [ctx->device newSamplerStateWithDescriptor:sd];

    // 1x1 white texture for untextured (solid colour) draws.
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    ctx->whiteTex = [ctx->device newTextureWithDescriptor:td];
    uint8_t white[4] = { 255, 255, 255, 255 };
    [ctx->whiteTex replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                     mipmapLevel:0 withBytes:white bytesPerRow:4];
}

static MTLBlendFactor MapBlend(int b)
{
    switch (b) {
        case D3DBLEND_ZERO:         return MTLBlendFactorZero;
        case D3DBLEND_ONE:          return MTLBlendFactorOne;
        case D3DBLEND_SRCCOLOR:     return MTLBlendFactorSourceColor;
        case D3DBLEND_INVSRCCOLOR:  return MTLBlendFactorOneMinusSourceColor;
        case D3DBLEND_SRCALPHA:     return MTLBlendFactorSourceAlpha;
        case D3DBLEND_INVSRCALPHA:  return MTLBlendFactorOneMinusSourceAlpha;
        case D3DBLEND_DESTALPHA:    return MTLBlendFactorDestinationAlpha;
        case D3DBLEND_INVDESTALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case D3DBLEND_DESTCOLOR:    return MTLBlendFactorDestinationColor;
        case D3DBLEND_INVDESTCOLOR: return MTLBlendFactorOneMinusDestinationColor;
        case D3DBLEND_SRCALPHASAT:  return MTLBlendFactorSourceAlphaSaturated;
        default:                    return MTLBlendFactorOne;
    }
}

static id<MTLRenderPipelineState> GetPipeline(MetalContext* ctx, const MetalDrawCall* dc)
{
    // Pick the UV byte offset for sampler stage 0 based on D3DTSS_TEXCOORDINDEX.
    // Pass 1 of the FF terrain shader (`TerrainShader2Stage::set(1)`) sets
    // D3DTSS_TEXCOORDINDEX=1 so the alpha-edge blend pass samples with the
    // SECOND vertex UV set (offset+8). Without this branch every draw would
    // sample TEX0 — terrain's alpha edges land at the wrong atlas position →
    // visible dark seams between adjacent terrain tile types.
    int uvOff = (dc->texCoordIndex == 1 && dc->tex1Offset >= 0)
              ? dc->tex1Offset
              : (dc->tex0Offset < 0 ? 0 : dc->tex0Offset);
    // colorWriteMask occupies 4 bits in the key — the full per-channel D3D RGBA
    // mask (R=1,G=2,B=4,A=8). The soft-water-edge feature is the one place the
    // engine uses partial masks: the shoreline pass writes ALPHA only (8) to lay
    // a depth gradient into dest-alpha without touching terrain RGB, while normal
    // passes write RGB only (7) so they don't pollute that alpha. Collapsing this
    // to binary on/off broke soft water (white shore squares + patchy water that
    // reveals the seabed). 0 (None) and 0xF (All) still map straight through.
    int  writeBits = dc->colorWriteMask & 0xF;
    uint64_t key = (uint64_t)dc->fvf
                 | ((uint64_t)(dc->blendEnable ? 1 : 0) << 32)
                 | ((uint64_t)(dc->srcBlend  & 0xFF)    << 33)
                 | ((uint64_t)(dc->destBlend & 0xFF)    << 41)
                 | ((uint64_t)(dc->posFloats & 0x7)     << 49)
                 | ((uint64_t)(uvOff & 0xFF)            << 52)
                 | ((uint64_t)writeBits                 << 60);
    auto it = ctx->pipelines.find(key);
    if (it != ctx->pipelines.end()) return it->second;

    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    // attribute 0: position
    vd.attributes[0].format = (dc->posFloats == 4) ? MTLVertexFormatFloat4
                                                    : MTLVertexFormatFloat3;
    vd.attributes[0].offset = (NSUInteger)(dc->posOffset < 0 ? 0 : dc->posOffset);
    vd.attributes[0].bufferIndex = 0;
    // attribute 1: normal (read garbage from offset 0 when absent; ignored via uniform)
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = (NSUInteger)(dc->normalOffset < 0 ? 0 : dc->normalOffset);
    vd.attributes[1].bufferIndex = 0;
    // attribute 2: diffuse colour (uchar4 normalized, BGRA in memory)
    vd.attributes[2].format = MTLVertexFormatUChar4Normalized;
    vd.attributes[2].offset = (NSUInteger)(dc->diffuseOffset < 0 ? 0 : dc->diffuseOffset);
    vd.attributes[2].bufferIndex = 0;
    // attribute 3: stage-0 uv (TEX0 or TEX1 depending on D3DTSS_TEXCOORDINDEX)
    vd.attributes[3].format = MTLVertexFormatFloat2;
    vd.attributes[3].offset = (NSUInteger)uvOff;
    vd.attributes[3].bufferIndex = 0;
    vd.layouts[0].stride = dc->stride;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction   = ctx->vsFn;
    pd.fragmentFunction = ctx->fsFn;
    pd.vertexDescriptor = vd;
    // Stage 7: MSAA — pipeline must match the render-pass attachment sample
    // count. ctx->msaaSamples is captured from MTL_MSAA once at Create time,
    // so every main-pass pipeline shares the same count and the FVF/blend
    // cache key stays valid (no extra dimension needed).
    pd.rasterSampleCount = (NSUInteger)(ctx->msaaSamples > 0 ? ctx->msaaSamples : 1);
    // The depth attachment also carries an 8-bit stencil so the FF stencil
    // emulation (occlusion X-ray, shadow volumes) sees a real stencil buffer.
    pd.depthAttachmentPixelFormat   = MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    MTLRenderPipelineColorAttachmentDescriptor* ca = pd.colorAttachments[0];
    ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Per-channel color write mask. D3DRS_COLORWRITEENABLE = 0 (stencil-only
    // passes during volumetric shadow rendering) disables the attachment so the
    // front/back-face passes write only stencil, not the framebuffer. The
    // soft-water-edge feature relies on partial masks: ALPHA-only (8) for the
    // shoreline dest-alpha gradient, RGB-only (7) for everything else so it
    // doesn't clobber that gradient. D3D bits (R=1,G=2,B=4,A=8) map onto the
    // Metal mask bits one-for-one.
    MTLColorWriteMask wm = MTLColorWriteMaskNone;
    if (writeBits & 1) wm |= MTLColorWriteMaskRed;
    if (writeBits & 2) wm |= MTLColorWriteMaskGreen;
    if (writeBits & 4) wm |= MTLColorWriteMaskBlue;
    if (writeBits & 8) wm |= MTLColorWriteMaskAlpha;
    ca.writeMask = wm;
    if (dc->blendEnable) {
        ca.blendingEnabled             = YES;
        ca.sourceRGBBlendFactor        = MapBlend(dc->srcBlend);
        ca.destinationRGBBlendFactor   = MapBlend(dc->destBlend);
        ca.sourceAlphaBlendFactor      = MapBlend(dc->srcBlend);
        ca.destinationAlphaBlendFactor = MapBlend(dc->destBlend);
        ca.rgbBlendOperation           = MTLBlendOperationAdd;
        ca.alphaBlendOperation         = MTLBlendOperationAdd;
    }

    NSError* err = nil;
    id<MTLRenderPipelineState> ps =
        [ctx->device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { NSLog(@"[metal] pipeline failed: %@", err); }
    ctx->pipelines[key] = ps;
    return ps;
}

static MTLCompareFunction MapCompare(int f)
{
    switch (f) {
        case 1:  return MTLCompareFunctionNever;
        case 2:  return MTLCompareFunctionLess;
        case 3:  return MTLCompareFunctionEqual;
        case 4:  return MTLCompareFunctionLessEqual;
        case 5:  return MTLCompareFunctionGreater;
        case 6:  return MTLCompareFunctionNotEqual;
        case 7:  return MTLCompareFunctionGreaterEqual;
        case 8:  return MTLCompareFunctionAlways;
        default: return MTLCompareFunctionLessEqual;  // D3D default ZFUNC
    }
}

// D3DSTENCILOP -> MTLStencilOperation. 0 (unset) treated as KEEP. The codes
// follow D3DSTENCILOP_KEEP=1 ... DECR=8.
static MTLStencilOperation MapStencilOp(int op)
{
    switch (op) {
        case 1:  return MTLStencilOperationKeep;
        case 2:  return MTLStencilOperationZero;
        case 3:  return MTLStencilOperationReplace;
        case 4:  return MTLStencilOperationIncrementClamp;
        case 5:  return MTLStencilOperationDecrementClamp;
        case 6:  return MTLStencilOperationInvert;
        case 7:  return MTLStencilOperationIncrementWrap;
        case 8:  return MTLStencilOperationDecrementWrap;
        default: return MTLStencilOperationKeep;
    }
}

// Combined depth-stencil state cache. Key encodes z-test/write/func + the full
// stencil state (enable/func/ops/masks). Both faces share the same descriptor
// — D3D8 only has single-sided stencil (the two-sided forms are D3D9-era).
struct DSKey {
    uint8_t  zTest;    // bool
    uint8_t  zWrite;   // bool
    uint8_t  zFunc;    // D3DCMPFUNC (0..8)
    uint8_t  sEn;      // bool
    uint8_t  sFunc;    // D3DCMPFUNC
    uint8_t  sFail;    // D3DSTENCILOP
    uint8_t  sZFail;   // D3DSTENCILOP
    uint8_t  sPass;    // D3DSTENCILOP
    uint32_t sReadMask;
    uint32_t sWriteMask;
};
static inline uint64_t MakeDSHash(const DSKey& k)
{
    // FNV-1a 64-bit over the packed fields.
    uint64_t h = 0xcbf29ce484222325ull;
    const uint8_t* p = (const uint8_t*)&k;
    for (size_t i = 0; i < sizeof(k); ++i) { h ^= p[i]; h *= 0x100000001b3ull; }
    return h;
}

// Depth-stencil state for a draw. zEnable==0 => no depth test/write (2D / UI).
// stencilEnable==0 => no stencil descriptor attached (always-pass / no-op).
static id<MTLDepthStencilState> GetDepthState(MetalContext* ctx, const MetalDrawCall* dc)
{
    DSKey k;
    memset(&k, 0, sizeof(k));
    bool zTestOn  = dc->zEnable != 0;
    bool zWriteOn = zTestOn && (dc->zWriteEnable != 0);
    k.zTest  = zTestOn  ? 1 : 0;
    k.zWrite = zWriteOn ? 1 : 0;
    k.zFunc  = (uint8_t)(zTestOn ? (dc->zFunc & 0x0F) : 8 /*ALWAYS*/);
    k.sEn    = dc->stencilEnable ? 1 : 0;
    if (k.sEn) {
        k.sFunc     = (uint8_t)(dc->stencilFunc ? (dc->stencilFunc & 0x0F) : 8);
        k.sFail     = (uint8_t)(dc->stencilFail  ? dc->stencilFail  : 1);
        // Default stencilZFail to KEEP (=1) when engine sent 0 (unset) so
        // the Z-Pass→Z-Fail detector below recognises the engine's pattern
        // (engine explicitly sets KEEP=1 for both fail slots when emitting
        // its Z-Pass volumes; the !=0 guard guarantees we don't accidentally
        // treat an unset state as "engine Z-Pass").
        k.sZFail    = (uint8_t)(dc->stencilZFail ? dc->stencilZFail : 1);
        k.sPass     = (uint8_t)(dc->stencilPass  ? dc->stencilPass  : 1);
        k.sReadMask  = (uint32_t)dc->stencilMask;
        k.sWriteMask = (uint32_t)dc->stencilWriteMask;

        // ---- Optional Z-Pass → Z-Fail (Carmack's Reverse) rewrite --------
        // OFF BY DEFAULT. Opt in with MTL_SHADOW_ZFAIL=1.
        //
        // Initially we landed this as a "fix" for what looked like wide
        // shadow streaks on the shellmap. The engine-side stencil
        // visualisation (MTL_STENCIL_VIZ=1 + viz palette pass in
        // W3DVolumetricShadowManager::renderStencilShadows) showed the
        // opposite was true:
        //
        //   Z-Pass (engine native):  stencil = 1-2 localised under casters,
        //                            i.e. *correct* shadow distribution.
        //   Z-Fail (our rewrite):    stencil >= 8 (white in the heatmap)
        //                            across huge swaths of terrain and
        //                            water — massive over-increment.
        //
        // Root cause of the over-increment: Generals' W3D shadow-volume
        // meshes are open extrusions (silhouette + extruded silhouette +
        // side walls; no real front/back caps), and Z-Fail counts back-face
        // depth-fails as INCR. With an open mesh the back-side polygons
        // sweep huge regions which routinely Z-fail against terrain → the
        // INCR runs away. Z-Pass is correct for this engine because the
        // mesh is *designed* for the depth-pass-counting algorithm.
        //
        // We keep the rewrite under an env opt-in for two reasons:
        //   1. Curiosity — a future caller may build closed-cap volumes
        //      and want Z-Fail's camera-inside-volume robustness.
        //   2. Documentation — preserves the why-it-doesn't-work trail.
        //
        // Translation rules when ON:
        //   Engine pass 1: cull=CW, sZFail=KEEP, sPass=INCR/SAT
        //   Z-Fail   →    cull=CW, sZFail=DECR/SAT, sPass=KEEP
        //   Engine pass 2: cull=CCW, sZFail=KEEP, sPass=DECR/SAT
        //   Z-Fail   →    cull=CCW, sZFail=INCR/SAT, sPass=KEEP
        static int s_useZFail = -1;
        if (s_useZFail < 0) {
            const char* envZF = getenv("MTL_SHADOW_ZFAIL");
            s_useZFail = (envZF && atoi(envZF) != 0) ? 1 : 0;
        }
        if (s_useZFail
            && k.sFail == 1  /*KEEP*/
            && k.sZFail == 1 /*KEEP*/
            && (k.sPass == 4 /*INCRSAT*/ || k.sPass == 5 /*DECRSAT*/ ||
                k.sPass == 7 /*INCR*/    || k.sPass == 8 /*DECR*/))
        {
            uint8_t flipped = k.sPass;
            switch (k.sPass) {
                case 4: flipped = 5; break;  // INCRSAT → DECRSAT
                case 5: flipped = 4; break;  // DECRSAT → INCRSAT
                case 7: flipped = 8; break;  // INCR    → DECR
                case 8: flipped = 7; break;  // DECR    → INCR
            }
            k.sZFail = flipped;
            k.sPass  = 1; /*KEEP*/
        }
    }

    uint64_t hashKey = MakeDSHash(k);
    uint32_t key32   = (uint32_t)(hashKey ^ (hashKey >> 32));
    auto it = ctx->depthStates.find(key32);
    if (it != ctx->depthStates.end()) return it->second;

    MTLDepthStencilDescriptor* dd = [[MTLDepthStencilDescriptor alloc] init];
    dd.depthCompareFunction = zTestOn ? MapCompare(k.zFunc) : MTLCompareFunctionAlways;
    dd.depthWriteEnabled    = zWriteOn ? YES : NO;
    if (k.sEn) {
        MTLStencilDescriptor* sd = [[MTLStencilDescriptor alloc] init];
        sd.stencilCompareFunction    = MapCompare(k.sFunc);
        sd.stencilFailureOperation   = MapStencilOp(k.sFail);
        sd.depthFailureOperation     = MapStencilOp(k.sZFail);
        sd.depthStencilPassOperation = MapStencilOp(k.sPass);
        sd.readMask  = (uint32_t)k.sReadMask;
        sd.writeMask = (uint32_t)k.sWriteMask;
        dd.frontFaceStencil = sd;
        dd.backFaceStencil  = sd;
        [sd release];
    }
    id<MTLDepthStencilState> st = [ctx->device newDepthStencilStateWithDescriptor:dd];
    [dd release];
    ctx->depthStates[key32] = st;
    return st;
}

// Create (or recreate on resize) the combined depth-stencil texture matching
// the drawable. Depth32Float_Stencil8: 32-bit depth + 8-bit stencil in a single
// attachment (Apple Silicon supports this natively).
// When MSAA is on (ctx->msaaSamples > 1) the depth texture becomes a
// textureType2DMultisample with matching sampleCount, and storage flips to
// Memoryless — depth never leaves tile memory on TBDR (resolve action is
// DontCare for the main pass).
static void EnsureDepthTexture(MetalContext* ctx)
{
    if (ctx->depthTex && ctx->depthW == ctx->width && ctx->depthH == ctx->height) return;
    if (ctx->depthTex) { [ctx->depthTex release]; ctx->depthTex = nil; }
    const int s = ctx->msaaSamples > 0 ? ctx->msaaSamples : 1;
    MTLTextureDescriptor* dd = [[MTLTextureDescriptor alloc] init];
    dd.pixelFormat   = MTLPixelFormatDepth32Float_Stencil8;
    dd.width         = (NSUInteger)(ctx->width  > 0 ? ctx->width  : 1);
    dd.height        = (NSUInteger)(ctx->height > 0 ? ctx->height : 1);
    dd.mipmapLevelCount = 1;
    dd.usage         = MTLTextureUsageRenderTarget;
    if (s > 1) {
        dd.textureType = MTLTextureType2DMultisample;
        dd.sampleCount = (NSUInteger)s;
        // Memoryless storage on Apple Silicon — tile-resident depth, ~0 bytes
        // off-tile, ~0 perf cost. depth storeAction is DontCare so we never
        // need a resolve target.
        dd.storageMode = MTLStorageModeMemoryless;
    } else {
        dd.textureType = MTLTextureType2D;
        dd.sampleCount = 1;
        dd.storageMode = MTLStorageModePrivate;
    }
    ctx->depthTex = [[ctx->device newTextureWithDescriptor:dd] retain];
    [dd release];
    ctx->depthW = ctx->width;
    ctx->depthH = ctx->height;
}

// Stage 7: MSAA color attachment. Memoryless multisampled BGRA8 — lives in
// tile memory only, resolves into ctx->drawable.texture via the main pass'
// storeAction=MultisampleResolve. Skipped (and torn down) when MSAA disabled
// (msaaSamples <= 1) — the main pass attaches the drawable directly.
static void EnsureMSAAColor(MetalContext* ctx)
{
    const int s = ctx->msaaSamples > 0 ? ctx->msaaSamples : 1;
    if (s <= 1) {
        if (ctx->msaaColor) { [ctx->msaaColor release]; ctx->msaaColor = nil; }
        return;
    }
    if (ctx->msaaColor && ctx->msaaW == ctx->width && ctx->msaaH == ctx->height) return;
    if (ctx->msaaColor) { [ctx->msaaColor release]; ctx->msaaColor = nil; }
    MTLTextureDescriptor* cd = [[MTLTextureDescriptor alloc] init];
    cd.pixelFormat   = MTLPixelFormatBGRA8Unorm;
    cd.width         = (NSUInteger)(ctx->width  > 0 ? ctx->width  : 1);
    cd.height        = (NSUInteger)(ctx->height > 0 ? ctx->height : 1);
    cd.mipmapLevelCount = 1;
    cd.textureType   = MTLTextureType2DMultisample;
    cd.sampleCount   = (NSUInteger)s;
    cd.usage         = MTLTextureUsageRenderTarget;
    cd.storageMode   = MTLStorageModeMemoryless;
    ctx->msaaColor = [[ctx->device newTextureWithDescriptor:cd] retain];
    [cd release];
    ctx->msaaW = ctx->width;
    ctx->msaaH = ctx->height;
}

// Stage 6: shadow mapping. Lazy-allocate the shadow map texture, depth-stencil
// state (depth write on / depth read LESS / no stencil), and sampler. Called
// from BeginShadowPass; reuses on subsequent frames.
// 4096² Depth32Float ≈ 64 MB GPU memory — fine on Apple Silicon, gives
// ~1 world-unit-per-texel coverage when halfExt=2000 (vs ~3.4 at 2048/3500).
// Override at runtime via MTL_SHADOW_MAP_SIZE if you want to A/B vs 2048.
#define METAL_SHADOWMAP_SIZE 4096
static void EnsureShadowResources(MetalContext* ctx)
{
    if (!ctx->shadowMap) {
        MTLTextureDescriptor* dd =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                               width:METAL_SHADOWMAP_SIZE
                                                              height:METAL_SHADOWMAP_SIZE
                                                           mipmapped:NO];
        dd.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        dd.storageMode = MTLStorageModePrivate;
        ctx->shadowMap = [[ctx->device newTextureWithDescriptor:dd] retain];
    }
    if (!ctx->shadowDS) {
        MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled    = YES;
        ctx->shadowDS = [[ctx->device newDepthStencilStateWithDescriptor:dsd] retain];
        [dsd release];
    }
    if (!ctx->shadowSmp) {
        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        ctx->shadowSmp = [[ctx->device newSamplerStateWithDescriptor:sd] retain];
        [sd release];
    }
}

// Build (or cache) a depth-only pipeline for the shadow pass. Shares the same
// vertex descriptor logic as the main pipeline but with no color attachment
// and the void `shadow_fs` fragment. Cache key matches the vertex layout
// fields that affect the descriptor (FVF + posFloats + offsets).
static id<MTLRenderPipelineState> GetShadowPipeline(MetalContext* ctx, const MetalDrawCall* dc)
{
    int uvOff = (dc->texCoordIndex == 1 && dc->tex1Offset >= 0)
              ? dc->tex1Offset
              : (dc->tex0Offset < 0 ? 0 : dc->tex0Offset);
    uint64_t key = (uint64_t)dc->fvf
                 | ((uint64_t)(dc->posFloats & 0x7)  << 32)
                 | ((uint64_t)(uvOff & 0xFF)         << 36)
                 | ((uint64_t)(dc->stride & 0xFF)    << 44);
    auto it = ctx->shadowPipelines.find(key);
    if (it != ctx->shadowPipelines.end()) return it->second;

    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = (dc->posFloats == 4) ? MTLVertexFormatFloat4 : MTLVertexFormatFloat3;
    vd.attributes[0].offset = (NSUInteger)(dc->posOffset < 0 ? 0 : dc->posOffset);
    vd.attributes[0].bufferIndex = 0;
    // Normal/diffuse/uv unused in shadow_fs but the [[stage_in]] layout must
    // still match VSIn so vs_main's stage-input fetch is well-defined.
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = (NSUInteger)(dc->normalOffset < 0 ? 0 : dc->normalOffset);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatUChar4Normalized;
    vd.attributes[2].offset = (NSUInteger)(dc->diffuseOffset < 0 ? 0 : dc->diffuseOffset);
    vd.attributes[2].bufferIndex = 0;
    vd.attributes[3].format = MTLVertexFormatFloat2;
    vd.attributes[3].offset = (NSUInteger)uvOff;
    vd.attributes[3].bufferIndex = 0;
    vd.layouts[0].stride = dc->stride;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction             = ctx->vsFn;
    pd.fragmentFunction           = ctx->shadowFsFn;
    pd.vertexDescriptor           = vd;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    // Stage 7: shadow pass renders into the plain Depth32Float 4096² shadowMap
    // (non-MSAA, sampled by the main fragment shader). Pipeline sampleCount
    // MUST stay 1 regardless of ctx->msaaSamples or Metal will reject the
    // render pass at encoder creation time.
    pd.rasterSampleCount          = 1;
    // No color attachment — depth-only render.

    NSError* err = nil;
    id<MTLRenderPipelineState> ps =
        [ctx->device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) NSLog(@"[metal] shadow pipeline failed: %@", err);
    [pd release];
    ctx->shadowPipelines[key] = ps;
    return ps;
}

// Begin the frame's render pass (clearing) if not already started. Returns false
// if no drawable is available.
static bool EnsureEncoder(MetalContext* ctx)
{
    // ARC is OFF for this target, so the autoreleased per-frame objects must be
    // retained to survive past this function's autorelease pool (they live until
    // Present). They are released in MetalContext_Present / _Destroy.
    if (ctx->enc) return true;
    if (!ctx->drawable) {
        ctx->drawable = [[ctx->layer nextDrawable] retain];
        if (!ctx->drawable) return false;
    }
    if (!ctx->cmd) ctx->cmd = [[ctx->queue commandBuffer] retain];

    EnsureDepthTexture(ctx);
    EnsureMSAAColor(ctx);

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (ctx->msaaSamples > 1 && ctx->msaaColor) {
        // MSAA path: render into memoryless multisampled tile target, resolve
        // into the drawable at storeAction time. resolveTexture *must* be the
        // non-MSAA drawable (sampleCount=1), formats must match (BGRA8Unorm).
        pass.colorAttachments[0].texture        = ctx->msaaColor;
        pass.colorAttachments[0].resolveTexture = ctx->drawable.texture;
        pass.colorAttachments[0].loadAction     = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction    = MTLStoreActionMultisampleResolve;
    } else {
        pass.colorAttachments[0].texture        = ctx->drawable.texture;
        pass.colorAttachments[0].loadAction     = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction    = MTLStoreActionStore;
    }
    pass.colorAttachments[0].clearColor  = ctx->clearColor;
    if (getenv("MTL_TESTCLEAR")) pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.6, 1.0);
    pass.depthAttachment.texture     = ctx->depthTex;
    pass.depthAttachment.loadAction  = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    pass.depthAttachment.clearDepth  = 1.0;
    // Stencil shares the depth attachment (Depth32Float_Stencil8). The
    // RTS3DScene occlusion pass + stencil shadow volumes expect the buffer
    // cleared to 0 at the start of each frame, matching the engine's
    // D3DCLEAR_STENCIL on the legacy DX path.
    pass.stencilAttachment.texture     = ctx->depthTex;
    pass.stencilAttachment.loadAction  = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionDontCare;
    pass.stencilAttachment.clearStencil = 0;
    ctx->enc = [[ctx->cmd renderCommandEncoderWithDescriptor:pass] retain];

    MTLViewport vp = { 0.0, 0.0, (double)ctx->width, (double)ctx->height, 0.0, 1.0 };
    [ctx->enc setViewport:vp];
    // Track what we just applied so the per-draw viewport-change check (see
    // ApplyViewportIfChanged) doesn't issue a redundant setViewport: on the
    // very first draw of the frame.
    ctx->appliedVpX = 0; ctx->appliedVpY = 0;
    ctx->appliedVpW = ctx->width; ctx->appliedVpH = ctx->height;

    // Fresh encoder → all GPU state is cleared. Reset the bound-state cache
    // (see MetalContext_Draw) and set the state that is constant for every draw
    // once, here, instead of per draw: the D3D front face is always CW.
    ctx->boundPS = nil; ctx->boundVB = nil; ctx->boundDSS = nil;
    ctx->boundTex0 = nil; ctx->boundSmp0 = nil;
    ctx->boundCull = -1; ctx->boundStencilRef = -1; ctx->boundShadowSlot = false;
    [ctx->enc setFrontFacingWinding:MTLWindingClockwise];   // D3D front face = CW
    return true;
}

// Apply a per-draw viewport change if it differs from what's currently bound on
// the encoder. The engine routinely calls D3D's SetViewport between draw passes
// — see CameraClass::Apply (camera.cpp:748) for the 3D scene viewport and
// Render2DClass::Render (render2d.cpp:625) for the 2D HUD reset to full screen.
// In real D3D those calls take effect for the next draw; we have to forward
// them to Metal explicitly, otherwise units (rasterised at the last applied
// viewport) and CPU-projected HUD overlays (computed from the engine's View
// dimensions, which assume whatever the engine just set) diverge in pixel Y.
namespace {
inline void ApplyViewportIfChanged(MetalContext* ctx, int x, int y, int w, int h)
{
    if (!ctx || !ctx->enc) return;
    if (w <= 0) w = ctx->width;
    if (h <= 0) h = ctx->height;
    if (x == ctx->appliedVpX && y == ctx->appliedVpY &&
        w == ctx->appliedVpW && h == ctx->appliedVpH) return;
    MTLViewport vp = { (double)x, (double)y, (double)w, (double)h, 0.0, 1.0 };
    [ctx->enc setViewport:vp];
    ctx->appliedVpX = x; ctx->appliedVpY = y;
    ctx->appliedVpW = w; ctx->appliedVpH = h;
}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// TheSuperHackers @port macOS: shared context pointer so the texture-upload
// entrypoints (MetalContext_UploadTexture*), which only receive the MTLTexture,
// can reach a command queue to GPU-generate mipmaps after a level-0 upload.
// There is exactly one MetalContext per process (single device/queue).
static MetalContext* s_uploadCtx = nullptr;

// Texture-pool bucket key from raw descriptor fields (shared by the rename pool
// and the create/release recycling pool below). Two textures are interchangeable
// iff every field here matches. Keep in lockstep with TexPoolKey(id<MTLTexture>).
static inline uint64_t TexKeyFields(NSUInteger w, NSUInteger h, unsigned pf,
                                    NSUInteger mip, unsigned usage) {
    return  ((uint64_t)(w   & 0x3FFF))
         |  ((uint64_t)(h   & 0x3FFF) << 14)
         |  ((uint64_t)(pf  & 0xFFFF) << 28)
         |  ((uint64_t)(mip & 0xFF)   << 44)
         |  ((uint64_t)(usage & 0xFF) << 52);
}

// Should this texture (by descriptor) be routed through the create/release
// recycling pool? Targets the small uncompressed textures that churn every
// frame — the font/text glyph atlases from Render2DSentenceClass::Build_Textures
// (~1.3 created+destroyed per frame, whose freed Metal memory the allocator does
// not reclaim promptly → a steady multi-MB/s IOAccelerator leak). Large / BC
// textures are created once and kept, so they keep the plain alloc + immediate-
// free path (no pool hoarding). MTL_NO_TEXPOOL=1 disables (A/B).
static inline bool TexPoolable(NSUInteger w, NSUInteger h, MTLPixelFormat pf) {
    static int off = -1;
    if (off < 0) off = getenv("MTL_NO_TEXPOOL") ? 1 : 0;
    return !off && pf == MTLPixelFormatBGRA8Unorm && w <= 256 && h <= 256;
}

// Textures default to MTLStorageModePrivate, uploaded via pooled staging
// buffers + blit (FlushPendingUploads). The old Shared + replaceRegion path
// (MTL_SHARED_TEX=1 reverts to it) leaks driver-side memory on macOS 26.x:
// every modify-then-draw cycle of a Shared texture costs ~15 KB of service
// memory the driver never returns (~130 MB/min on the CWC shell-map menu,
// which re-bakes ~140 terrain pages/s — steady-state A/B matrix: disabling
// mips, renames or uploads individually changed nothing; only stopping the
// modify+draw combination did). Private textures take the driver's optimal
// layout up front, so re-uploads are plain blits with no shadow copies.
static inline bool PrivateTexEnabled() {
    // Default OFF: the staged-upload experiment held load-burst staging
    // buffers in the pool (multi-GB at map load). Opt-in for future work.
    static int on = -1;
    if (on < 0) on = getenv("MTL_PRIVATE_TEX") ? 1 : 0;
    return on;
}

// MTL_POOL_LOG live-resource accounting (bufLiveN/... in MetalContext). Called
// at EVERY shim create / CFRelease site so the pool log can split "our live
// bytes" from driver-side growth. Approximate texture bytes (BC ~1 or 0.5
// byte/px, else 4) — this is a diagnostic, not an allocator.
static inline size_t TexApproxBytes(id<MTLTexture> t) {
    size_t px = (size_t)t.width * t.height;
    size_t base;
    switch (t.pixelFormat) {
        case MTLPixelFormatBC1_RGBA: base = px / 2; break;
        case MTLPixelFormatBC2_RGBA:
        case MTLPixelFormatBC3_RGBA: base = px;     break;
        default:                     base = px * 4; break;
    }
    return t.mipmapLevelCount > 1 ? base + base / 3 : base;
}
static inline void DiagBufAlloc(MetalContext* c, unsigned bytes) {
    if (!c) return;
    c->bufLiveN.fetch_add(1, std::memory_order_relaxed);
    c->bufLiveBytes.fetch_add((long)bytes, std::memory_order_relaxed);
}
static inline void DiagBufFree(void* b) {
    MetalContext* c = s_uploadCtx;
    if (!c || !b) return;
    c->bufLiveN.fetch_sub(1, std::memory_order_relaxed);
    c->bufLiveBytes.fetch_sub((long)[(__bridge id<MTLBuffer>)b length], std::memory_order_relaxed);
}
static inline void DiagTexAlloc(MetalContext* c, id<MTLTexture> t) {
    if (!c || !t) return;
    c->texLiveN.fetch_add(1, std::memory_order_relaxed);
    c->texLiveBytes.fetch_add((long)TexApproxBytes(t), std::memory_order_relaxed);
}
static inline void DiagTexFree(void* tp) {
    MetalContext* c = s_uploadCtx;
    if (!c || !tp) return;
    c->texLiveN.fetch_sub(1, std::memory_order_relaxed);
    c->texLiveBytes.fetch_sub((long)TexApproxBytes((__bridge id<MTLTexture>)tp), std::memory_order_relaxed);
}

extern "C" MetalContext* MetalContext_Create(int width, int height, int /*windowed*/)
{
    @autoreleasepool {
        EnsureAppInitialized();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) { NSLog(@"[metal] no system default Metal device"); return nullptr; }

        MetalContext* ctx = new MetalContext();
        ctx->device = device;
        ctx->queue  = [device newCommandQueue];
        s_uploadCtx = ctx;   // for GPU mipmap generation on texture upload
        ctx->width  = width;
        ctx->height = height;
        ctx->clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        ctx->dbg = -1;
        // Stage 7: MSAA. Boot default = 4x. On Apple Silicon (TBDR) the MSAA
        // color + depth attachments are MTLStorageModeMemoryless — they live
        // entirely in tile memory and resolve into the drawable at storeAction
        // time, so 4x costs ~0 extra bandwidth/perf while removing the jagged
        // "staircase" edges (aliasing) on building/unit silhouettes as the
        // camera moves. MSAA is fully decoupled from shadows (SetShadowsEnabled
        // does not touch msaaSamples). Set MTL_MSAA=0 or =1 to disable (A/B),
        // or =2/=8 to change the sample count; the env var always overrides.
        ctx->msaaSamples = 4;
        if (const char* m = getenv("MTL_MSAA")) {
            int v = atoi(m);
            if (v == 0 || v == 1) ctx->msaaSamples = 1;
            else if (v == 2)      ctx->msaaSamples = 2;
            else if (v == 4)      ctx->msaaSamples = 4;
            else if (v == 8)      ctx->msaaSamples = 8;
            else                  ctx->msaaSamples = 1;
        }
        // Verify the device actually supports the requested sample count for
        // BGRA8Unorm (M-series supports 1/2/4/8; the API still returns NO
        // for unsupported counts e.g. on older hardware).
        if (ctx->msaaSamples > 1 &&
            ![device supportsTextureSampleCount:(NSUInteger)ctx->msaaSamples]) {
            fprintf(stderr, "[metal] MSAA x%d not supported, falling back to off\n",
                    ctx->msaaSamples);
            ctx->msaaSamples = 1;
        }
        ctx->msaaColor = nil;
        ctx->msaaW = 0;
        ctx->msaaH = 0;
        ctx->pendingMips = nil;   // lazily allocated on first mipped-texture upload
        ctx->bufFrameId = 0;
        ctx->bufCompletedFrame.store(0, std::memory_order_relaxed);
        ctx->cbInFlight.store(0, std::memory_order_relaxed);
        ctx->cbCreated.store(0, std::memory_order_relaxed);
        ctx->cbCompleted.store(0, std::memory_order_relaxed);
        ctx->cbPresented.store(0, std::memory_order_relaxed);
        ctx->bufLiveN.store(0, std::memory_order_relaxed);
        ctx->bufLiveBytes.store(0, std::memory_order_relaxed);
        ctx->texLiveN.store(0, std::memory_order_relaxed);
        ctx->texLiveBytes.store(0, std::memory_order_relaxed);
        ctx->texPullCreate.store(0, std::memory_order_relaxed);
        ctx->texMissCreate.store(0, std::memory_order_relaxed);
        ctx->texPullRename.store(0, std::memory_order_relaxed);
        ctx->texMissRename.store(0, std::memory_order_relaxed);
        ctx->texPushRelease.store(0, std::memory_order_relaxed);
        ctx->texPushRename.store(0, std::memory_order_relaxed);
        ctx->texOverflow.store(0, std::memory_order_relaxed);
        ctx->bufOverflow.store(0, std::memory_order_relaxed);

        // Startup banner. The msaa here is the boot default — set by
        // MTL_MSAA env override or 1 (clean baseline). The "Metal Optimised"
        // preset (Options → Graphics → Detail) hands off to
        // MetalShim_ApplyMacOptimised, which currently does nothing — the
        // preset list grows as Stage-N features pass QA (see metal_backend.mm).
        fprintf(stderr,
                "[metal] boot: msaa=%dx (override: MTL_MSAA=0/1/2/4/8).\n",
                ctx->msaaSamples);
        // Stage 6 shadow defaults: identity lightVP (harmless when shadowsEnabled=0),
        // shadowsEnabled stays 0 until the engine flips it via MetalContext_SetShadowsEnabled.
        std::memset(ctx->lightVP, 0, sizeof(ctx->lightVP));
        ctx->lightVP[0] = 1.0f; ctx->lightVP[5] = 1.0f; ctx->lightVP[10] = 1.0f; ctx->lightVP[15] = 1.0f;
        ctx->shadowsEnabled   = 0;
        ctx->shadowPassActive = false;
        ctx->lastNumLights        = 0;
        ctx->haveCaptureSnapshot  = false;
        // Pre-allocate the shadow map so the main pipeline's texture(2) binding
        // is always valid even before any shadow replay has run (frame 1, or
        // when MTL_SHADOW is off — the fs gates sampling on p.shadowEnable, but
        // Metal still validates the binding).
        EnsureShadowResources(ctx);
        // Single active context for the engine wrappers (the engine never
        // creates more than one MetalContext in practice).
        extern MetalContext* g_activeMetalCtx;
        g_activeMetalCtx = ctx;

        // Engine resolution is in PIXELS; NSWindow content rect is in POINTS.
        // On a Retina display a 2560x1440 game resolution would request a
        // 2560x1440-POINT window — which is 5120x2880 PIXELS and won't fit on
        // any laptop screen. Cocoa then clamps the window to the visible
        // screen frame, but the view's bounds end up smaller than the engine
        // expects, breaking input mapping. Instead: size the window to fit
        // within the screen's visibleFrame (in points), preserving aspect
        // ratio, and let the CAMetalLayer up-render at the requested
        // engine-pixel resolution via drawableSize. EventPoint linearly remaps
        // mouse coords from view-points to engine-pixels so the cursor stays
        // pixel-accurate regardless of how Cocoa actually sized the window.
        NSScreen* screen = [NSScreen mainScreen];
        NSRect visible = screen ? screen.visibleFrame
                                : NSMakeRect(0, 0, (CGFloat)width, (CGFloat)height);
        // Leave a small margin so the titlebar and screen edges stay clear.
        CGFloat maxW = visible.size.width  - 32.0;
        CGFloat maxH = visible.size.height - 64.0;   // leave room for titlebar
        if (maxW < 320.0) maxW = visible.size.width;
        if (maxH < 240.0) maxH = visible.size.height;
        CGFloat winW = (CGFloat)width;
        CGFloat winH = (CGFloat)height;
        if (winW > maxW || winH > maxH) {
            double sx = (double)maxW / (double)winW;
            double sy = (double)maxH / (double)winH;
            double s  = (sx < sy) ? sx : sy;
            winW = (CGFloat)((double)winW * s);
            winH = (CGFloat)((double)winH * s);
        }
        NSRect frame = NSMakeRect(0, 0, winW, winH);
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:style
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Generals Zero Hour (Metal)"];
        [window center];

        MetalView* view = [[MetalView alloc] initWithFrame:frame];
        [view setWantsLayer:YES];

        CAMetalLayer* layer = (CAMetalLayer*)view.layer;
        layer.device          = device;
        layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        // The game back buffer is opaque (X8R8G8B8); many opaque 3D draws leave
        // dest alpha at 0, so treat the layer as opaque to avoid a see-through
        // window where the terrain/3D writes zero alpha.
        layer.opaque          = YES;
        // framebufferOnly NO when MTL_DUMP is set so we can read back the drawable
        // for offscreen PNG captures (debug only; YES is the fast default).
        layer.framebufferOnly = getenv("MTL_DUMP") ? NO : YES;
        layer.drawableSize    = CGSizeMake(width, height);

        // Host the MetalView inside an aspect-fit container so fullscreen keeps
        // the game's aspect ratio (letterbox) instead of stretching. In windowed
        // mode the container equals the view (aspects match) — no visible change.
        // GEN_LETTERBOX=0 restores the old stretch-to-fill behaviour.
        const char* lbEnv = ::getenv("GEN_LETTERBOX");
        const bool  letterbox = !(lbEnv && lbEnv[0] == '0');
        if (letterbox) {
            AspectFitView* container = [[AspectFitView alloc] initWithFrame:frame];
            [container setWantsLayer:YES];
            container.layer.backgroundColor = [[NSColor blackColor] CGColor];
            container.aspect = (height > 0) ? (CGFloat)width / (CGFloat)height : 1.0;
            container.child  = view;
            [container addSubview:view];
            [container layoutChild];
            [window setContentView:container];
        } else {
            [window setContentView:view];
        }
        [window makeFirstResponder:view];
        [window setAcceptsMouseMovedEvents:YES];
        [window makeKeyAndOrderFront:nil];

        ctx->window = window;
        ctx->view   = view;
        ctx->layer  = layer;
        g_inputView = view;  // for input coordinate conversion (the MetalView)
        // Publish the engine pixel resolution so EventPoint can scale view-points
        // → engine-pixels (HiDPI + screen-fit clamp).
        g_engineW = width;
        g_engineH = height;
        fprintf(stderr,
                "[metal] window: engine=%dx%dpx, content=%.0fx%.0fpt, drawable=%dx%dpx\n",
                width, height, (double)winW, (double)winH, width, height);

        BuildShadersAndStaticState(ctx);

        DrainEvents();
        return ctx;
    }
}

extern "C" void MetalContext_Destroy(MetalContext* ctx)
{
    if (!ctx) return;
    @autoreleasepool {
        ctx->pipelines.clear();
        ctx->depthStates.clear();
        if (ctx->depthTex) { [ctx->depthTex release]; ctx->depthTex = nil; }
        if (ctx->msaaColor) { [ctx->msaaColor release]; ctx->msaaColor = nil; }
        ctx->sampler  = nil;
        ctx->whiteTex = nil;
        ctx->vsFn = nil; ctx->fsFn = nil;
        if (ctx->enc) { [ctx->enc endEncoding]; [ctx->enc release]; ctx->enc = nil; }
        if (ctx->cmd) { [ctx->cmd release]; ctx->cmd = nil; }
        if (ctx->drawable) { [ctx->drawable release]; ctx->drawable = nil; }
        if (ctx->pendingMips) { [ctx->pendingMips release]; ctx->pendingMips = nil; }
        // Release the dynamic-buffer recycle pool (free list + not-yet-recycled).
        for (std::unordered_map<unsigned, std::vector<void*> >::iterator it = ctx->bufFree.begin(); it != ctx->bufFree.end(); ++it)
            for (size_t i = 0; i < it->second.size(); ++i) CFRelease(it->second[i]);
        ctx->bufFree.clear();
        for (size_t i = 0; i < ctx->bufRetired.size(); ++i) CFRelease(ctx->bufRetired[i].first);
        ctx->bufRetired.clear();
        // Release the dynamic-texture rename pool (free list + not-yet-recycled).
        for (std::unordered_map<uint64_t, std::vector<void*> >::iterator it = ctx->texFree.begin(); it != ctx->texFree.end(); ++it)
            for (size_t i = 0; i < it->second.size(); ++i) CFRelease(it->second[i]);
        ctx->texFree.clear();
        for (size_t i = 0; i < ctx->texRetired.size(); ++i) CFRelease(ctx->texRetired[i].first);
        ctx->texRetired.clear();
        [ctx->window close];
        ctx->window = nil;
        ctx->view   = nil;
        ctx->layer  = nil;
        ctx->queue  = nil;
        ctx->device = nil;
    }
    if (s_uploadCtx == ctx) s_uploadCtx = nullptr;
    delete ctx;
}

extern "C" void MetalContext_SetClearColor(MetalContext* ctx, double r, double g, double b, double a)
{
    if (!ctx) return;
    ctx->clearColor = MTLClearColorMake(r, g, b, a);
}

extern "C" void MetalContext_BeginFrame(MetalContext* /*ctx*/) {}
extern "C" void MetalContext_EndFrame(MetalContext* /*ctx*/) {}

// --- Stage 6: shadow mapping public API -----------------------------------

extern "C" void MetalContext_SetShadowsEnabled(MetalContext* ctx, int enabled)
{
    if (!ctx) return;
    ctx->shadowsEnabled = enabled ? 1 : 0;
}

// Internal helper: flush all main-pass MTLRenderPipelineState (they bake
// rasterSampleCount at creation) and drop the MSAA color + depth textures
// so the next EnsureEncoder reallocates them at the new sample count. Used
// by MetalContext_SetMSAA to make the change effective on the next frame.
// Shadow pipelines (separate cache, always sampleCount=1) are untouched.
static void RebuildPipelinesForMSAA(MetalContext* ctx)
{
    for (auto& kv : ctx->pipelines) { if (kv.second) [kv.second release]; }
    ctx->pipelines.clear();
    if (ctx->msaaColor) { [ctx->msaaColor release]; ctx->msaaColor = nil; }
    ctx->msaaW = 0; ctx->msaaH = 0;
    if (ctx->depthTex) { [ctx->depthTex release]; ctx->depthTex = nil; }
    ctx->depthW = 0; ctx->depthH = 0;
}

// Runtime MSAA toggle. MSAA bakes into MTLRenderPipelineState at creation
// (rasterSampleCount), so changing it means a full pipeline-cache rebuild +
// texture realloc — done lazily on the next Draw via RebuildPipelinesForMSAA.
// A 1-frame user-visible hitch is fine here; this is only invoked from the
// Options menu hookup. MTL_MSAA env override (set once at Create) wins.
extern "C" void MetalContext_SetMSAA(MetalContext* ctx, int samples)
{
    if (!ctx) return;
    if (getenv("MTL_MSAA")) return;  // env override locked in at Create
    int s = samples;
    if (s != 1 && s != 2 && s != 4 && s != 8) s = 1;
    if (s > 1 && ![ctx->device supportsTextureSampleCount:(NSUInteger)s]) {
        fprintf(stderr, "[metal] MSAA x%d unsupported, leaving at %dx\n",
                s, ctx->msaaSamples);
        return;
    }
    if (s == ctx->msaaSamples) return;
    fprintf(stderr, "[metal] MSAA %dx → %dx (rebuilding pipelines)\n",
            ctx->msaaSamples, s);
    ctx->msaaSamples = s;
    RebuildPipelinesForMSAA(ctx);
}

extern "C" void MetalContext_BeginShadowPass(MetalContext* ctx, const float lvp[16])
{
    if (!ctx || !lvp) return;
    @autoreleasepool {
        EnsureShadowResources(ctx);

        // We may already have the main encoder running — end it first; the
        // shadow pass runs as its own encoder against the shadow map texture.
        if (ctx->enc) { [ctx->enc endEncoding]; [ctx->enc release]; ctx->enc = nil; }
        if (!ctx->cmd) ctx->cmd = [[ctx->queue commandBuffer] retain];

        std::memcpy(ctx->lightVP, lvp, sizeof(float) * 16);
        ctx->shadowPassActive = true;

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        // No color attachment — depth-only render.
        pass.depthAttachment.texture     = ctx->shadowMap;
        pass.depthAttachment.loadAction  = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;  // keep for sampling in main pass
        pass.depthAttachment.clearDepth  = 1.0;
        ctx->shadowEnc = [[ctx->cmd renderCommandEncoderWithDescriptor:pass] retain];

        MTLViewport vp = { 0.0, 0.0, (double)METAL_SHADOWMAP_SIZE, (double)METAL_SHADOWMAP_SIZE, 0.0, 1.0 };
        [ctx->shadowEnc setViewport:vp];
    }
}

extern "C" void MetalContext_EndShadowPass(MetalContext* ctx)
{
    if (!ctx) return;
    @autoreleasepool {
        if (ctx->shadowEnc) {
            [ctx->shadowEnc endEncoding];
            [ctx->shadowEnc release];
            ctx->shadowEnc = nil;
        }
        ctx->shadowPassActive = false;
    }
}

// Engine-side wrappers. `g_activeMetalCtx` is set by MetalContext_Create so
// the engine can talk to the shadow API without plumbing the context through.
MetalContext* g_activeMetalCtx = nullptr;
extern "C" void MetalShim_SetShadowsEnabled(int enabled) { if (g_activeMetalCtx) MetalContext_SetShadowsEnabled(g_activeMetalCtx, enabled); }
extern "C" void MetalShim_SetMSAA(int samples)            { if (g_activeMetalCtx) MetalContext_SetMSAA(g_activeMetalCtx, samples); }
extern "C" void MetalShim_BeginShadowPass(const float lvp[16]) { if (g_activeMetalCtx) MetalContext_BeginShadowPass(g_activeMetalCtx, lvp); }
extern "C" void MetalShim_EndShadowPass(void) { if (g_activeMetalCtx) MetalContext_EndShadowPass(g_activeMetalCtx); }

// =============================================================================
// "Metal Optimised" preset — one-stop hook.
//
// Called by the engine (GameLOD.cpp applyStaticLODLevel) whenever the user
// switches the Options → Graphics → Detail dropdown into / out of the
// "Metal Optimised" slot. This is the SINGLE place where the macOS port's
// QA-passed graphical features are enabled together.
//
// Roadmap: features land here one at a time as they pass QA. Today the list
// is intentionally empty — Metal Optimised behaves identically to Low. When
// a feature is fully polished (matches the original game's visual intent
// across shellmap + skirmish + edge cases) it gets a line below.
//
// Suggested order (uncomment + verify visually as each ships):
//   MetalShim_SetShadowsEnabled(on);  // Stage 6 — shadow mapping
//   MetalShim_SetMSAA(on ? 4 : 1);    // Stage 7 — 4x MSAA
//   // Stage 1 multitexturing (cloud map + light map)
//   // Stage 3 anisotropic / trilinear sampling
//   // Stage 4 render-to-texture infrastructure → water reflection
//   // Stage 5 pixel shader emulation
//
// Don't add a feature here until its standalone toggle has been verified
// in real gameplay — the whole point of this preset is that the user can
// trust everything inside it to "just work".
// =============================================================================
extern "C" void MetalShim_ApplyMacOptimised(int on)
{
    (void)on;
    // Intentionally empty. Add polished features above this line, then
    // uncomment / add their toggle calls here.
}

extern "C" void MetalContext_PumpEvents(MetalContext* /*ctx*/) { DrainEvents(); }

extern "C" void MetalContext_Resize(MetalContext* ctx, int width, int height)
{
    if (!ctx) return;
    @autoreleasepool {
        ctx->width  = width;
        ctx->height = height;
        ctx->layer.drawableSize = CGSizeMake(width, height);
        // Re-fit the letterbox container to the new game aspect (Options →
        // Display → Apply can change the resolution at runtime).
        if ([ctx->view.superview isKindOfClass:[AspectFitView class]]) {
            AspectFitView* container = (AspectFitView*)ctx->view.superview;
            container.aspect = (height > 0) ? (CGFloat)width / (CGFloat)height : container.aspect;
            [container layoutChild];
        }
        // Keep input-mapper in sync when the engine switches resolution at
        // runtime (Options → Display → Apply).
        g_engineW = width;
        g_engineH = height;
    }
}

// ---------------------------------------------------------------------------
// Stage 6: end-of-frame shadow-map replay.
//
// Walks ctx->shadowCaptures (filled by MetalContext_Draw), derives the sun
// direction from ctx->lastLights + camera focus from invert(lastView), builds
// an orthographic light view+projection, and re-renders every captured
// (opaque, 3D, colour-writing) draw into the shadow map texture as depth-only.
// The NEXT frame's main fragment shader samples this shadow map.
//
// Memory: every captured draw retained its VB (+IB), so the underlying
// MTLBuffer pool isn't reused until we release at the end of replay. This
// works because the shim's per-draw buffers are themselves command-buffer-
// tracked — Metal won't reuse them while a command buffer references them.
// ---------------------------------------------------------------------------
static void RunShadowReplay(MetalContext* ctx)
{
    // Gating: runtime ctx->shadowsEnabled (flipped by the engine through
    // MetalShim_SetShadowsEnabled when the user picks "Metal Optimised" in
    // Options → Graphics → Detail) is the source of truth. The MTL_SHADOW
    // env var stays as a diagnostic override — set MTL_SHADOW=1 to force
    // shadows on regardless of preset (useful when launching directly into
    // a saved skirmish), MTL_SHADOW=0 to force off for A/B comparisons.
    int enabled = ctx->shadowsEnabled;
    if (const char* e = getenv("MTL_SHADOW")) enabled = atoi(e) ? 1 : 0;

    // Disabled or empty capture list → just clean up and signal "no shadows".
    if (!enabled || ctx->shadowCaptures.empty() || !ctx->cmd || !ctx->haveCaptureSnapshot) {
        for (auto& c : ctx->shadowCaptures) {
            if (c.vb) [c.vb release];
            if (c.ib) [c.ib release];
        }
        ctx->shadowCaptures.clear();
        ctx->viewBuckets.clear();
        ctx->haveCaptureSnapshot = false;
        // Note: do NOT clear ctx->shadowsEnabled here — that flag is the
        // engine's request ("I want shadows"), independent of whether this
        // particular frame had enough geometry captured to produce them.
        // Clearing it on an empty-capture frame would deadlock the main
        // fragment shader's sampling path on the next frame.
        return;
    }

    // Majority-vote winner: the view that the most captures used. This is
    // almost always the main scene's tactical camera view; mini-map render-
    // to-texture passes and post-effect quads use different views with far
    // fewer associated draws and get outvoted.
    if (!ctx->viewBuckets.empty()) {
        int bestIdx = 0;
        for (size_t i = 1; i < ctx->viewBuckets.size(); ++i) {
            if (ctx->viewBuckets[i].count > ctx->viewBuckets[bestIdx].count) bestIdx = (int)i;
        }
        const auto& best = ctx->viewBuckets[bestIdx];
        std::memcpy(ctx->lastView,   best.view,   sizeof(float) * 16);
        std::memcpy(ctx->lastLights, best.lights, sizeof(MetalLight) * 8);
        ctx->lastNumLights = best.numLights;
        // Log on first few frames + periodically so we can see the
        // distribution (e.g. one frame had 3 view buckets with counts
        // [180, 25, 4] → main scene wins by ~7×).
        static int s_logBuckets = -1;
        if (s_logBuckets < 0) s_logBuckets = getenv("MTL_SHADOW_DBG") ? 1 : 0;
        if (s_logBuckets && (ctx->frameIndex < 5 || (ctx->frameIndex % 300) == 0)) {
            fprintf(stderr, "[shadow-vote] f%ld: %zu buckets [", ctx->frameIndex, ctx->viewBuckets.size());
            for (size_t i = 0; i < ctx->viewBuckets.size(); ++i) {
                fprintf(stderr, "%s%d%s", i?",":"", ctx->viewBuckets[i].count, i==(size_t)bestIdx?"*":"");
            }
            fprintf(stderr, "]\n"); fflush(stderr);
        }
    }
    ctx->viewBuckets.clear();

    EnsureShadowResources(ctx);

    // -- 1. Sun direction. Default: first directional light from the engine
    //       snapshot, otherwise a reasonable overhead-from-NW sun. Two env
    //       knobs:
    //         MTL_SHADOW_SUN_DIR="x,y,z"      override entirely (raw, normalised)
    //         MTL_SHADOW_FORCE_LOW_SUN=1      replace engine's sun with a low-
    //                                          angle (-1,-1,-0.5) for dramatic
    //                                          tests; useful because Generals'
    //                                          maps usually configure a
    //                                          near-vertical noon sun → short
    //                                          shadows by design.
    // Fallback sun: late-afternoon angle ~31° elevation. Generates shadows
    // ~1.7× the caster's height in horizontal extent — comfortably visible
    // from the tactical iso-view and matches the look of the original game's
    // projected blob shadows (which are also long-ish).
    // (Was 57° → invisible-short, then 38° → still too subtle.)
    float sunDx = -0.61f, sunDy = -0.61f, sunDz = -0.50f;
    bool sourceFromEngine = false;
    for (int i = 0; i < ctx->lastNumLights && i < 8; ++i) {
        const MetalLight& L = ctx->lastLights[i];
        if (L.type == 3 /*DIRECTIONAL*/) {
            sunDx = L.direction[0]; sunDy = L.direction[1]; sunDz = L.direction[2];
            sourceFromEngine = true;
            break;
        }
    }
    // Diag: at startup + occasionally, dump every light the engine captured
    // so we can tell whether the scene's actual sun (W3DLightManager →
    // SetLight) is reaching us. If yes, we should be using it instead of the
    // fallback. Currently engine often passes only point/ambient lights.
    if (ctx->frameIndex < 3 || (ctx->frameIndex % 600) == 0) {
        fprintf(stderr, "[lights] f%ld n=%d:", ctx->frameIndex, ctx->lastNumLights);
        for (int i = 0; i < ctx->lastNumLights && i < 4; ++i) {
            const MetalLight& L = ctx->lastLights[i];
            const char* tname = (L.type==1?"PT":L.type==2?"SP":L.type==3?"DIR":"?");
            fprintf(stderr, " [%d:%s d=(%.2f,%.2f,%.2f) p=(%.0f,%.0f,%.0f) col=(%.2f,%.2f,%.2f)]",
                    i, tname, L.direction[0],L.direction[1],L.direction[2],
                    L.position[0],L.position[1],L.position[2],
                    L.diffuse[0],L.diffuse[1],L.diffuse[2]);
        }
        fprintf(stderr, "\n"); fflush(stderr);
    }
    static int s_forceLow = -1;
    if (s_forceLow < 0) s_forceLow = getenv("MTL_SHADOW_FORCE_LOW_SUN") ? 1 : 0;
    if (s_forceLow) { sunDx = -1.0f; sunDy = -1.0f; sunDz = -0.5f; sourceFromEngine = false; }
    if (const char* ovr = getenv("MTL_SHADOW_SUN_DIR")) {
        float ox, oy, oz;
        if (sscanf(ovr, "%f,%f,%f", &ox, &oy, &oz) == 3) {
            sunDx = ox; sunDy = oy; sunDz = oz; sourceFromEngine = false;
        }
    }
    {
        float n = sqrtf(sunDx*sunDx + sunDy*sunDy + sunDz*sunDz);
        if (n < 1e-4f) { sunDx = -0.45f; sunDy = -0.45f; sunDz = -1.0f; n = sqrtf(0.45f*0.45f + 0.45f*0.45f + 1.0f); }
        sunDx /= n; sunDy /= n; sunDz /= n;
    }
    // Log the resolved sun direction once + every ~600 frames so we can see
    // what the engine actually fed us vs. our override. Tracks frameIndex.
    if (ctx->frameIndex < 3 || (ctx->frameIndex % 600) == 0) {
        fprintf(stderr, "[shadow] sun=(%.3f,%.3f,%.3f) src=%s elev=%.1f° (90=overhead, 0=horizon)\n",
                sunDx, sunDy, sunDz, sourceFromEngine ? "engine" : "fallback",
                asinf(-sunDz) * 180.0f / 3.14159265f);
        fflush(stderr);
    }

    // -- 2. Camera focus: invert the view matrix to get the camera's eye, then
    //       step forward along its -Z axis by a heuristic distance. The view
    //       matrix is stored column-major (matches D3D's GpuLight uniform).
    float camEyeX = 0.0f, camEyeY = 0.0f, camEyeZ = 0.0f;
    float camFwdX = 0.0f, camFwdY = 0.0f, camFwdZ = -1.0f;
    {
        const float* V = ctx->lastView;
        // For an orthonormal view matrix M (rotation + translation), the eye
        // position in world space is `-(R^T * t)`, where R is the 3×3 rotation
        // (cols 0..2) and t is the translation (col 3, rows 0..2). Column-major
        // storage: V[c*4 + r] = M[r][c].
        float tx = V[12], ty = V[13], tz = V[14];
        camEyeX = -(V[0]*tx + V[1]*ty + V[2]*tz);
        camEyeY = -(V[4]*tx + V[5]*ty + V[6]*tz);
        camEyeZ = -(V[8]*tx + V[9]*ty + V[10]*tz);
        // Camera forward in world. Generals uses a RIGHT-HANDED view matrix
        // (camera looks down -Z in view space) — empirically verified: with
        // fwd = -(V[2], V[6], V[10]) the focus point lands BELOW the camera
        // on the terrain (eye=Z~700, focus=Z~330) instead of above it in
        // empty sky. MTL_SHADOW_FWD_FLIP=1 flips back to LH for diagnostics.
        static int s_fwdFlip = -1;
        if (s_fwdFlip < 0) s_fwdFlip = getenv("MTL_SHADOW_FWD_FLIP") ? 1 : 0;
        float sgn = s_fwdFlip ? +1.0f : -1.0f;
        camFwdX = sgn * V[2]; camFwdY = sgn * V[6]; camFwdZ = sgn * V[10];
    }
    // Focus point = where the camera's forward ray hits the ground plane (Z=0).
    // Previously we used a fixed 600u step along forward, which placed focus
    // mid-air whenever the camera was high (max zoom-out: camera at Z>2000,
    // 600u down still ~1500u above ground). The shadow map then centred on a
    // sky point while the visible terrain lived OUTSIDE the light frustum,
    // producing wildly-aliased "line" shadows that snapped to a different
    // texel grid every frame as the camera drifted. Intersecting with Z=0
    // keeps focus on the actually-visible ground at every zoom level, which
    // makes the texel-grid snap below produce frame-stable results.
    float focusX, focusY, focusZ;
    if (fabsf(camFwdZ) > 1e-3f && (camEyeZ * camFwdZ) < 0.0f) {
        // Camera above ground and looking down — ray hits Z=0 at positive t.
        float t = -camEyeZ / camFwdZ;
        focusX = camEyeX + camFwdX * t;
        focusY = camEyeY + camFwdY * t;
        focusZ = 0.0f;
    } else {
        // Degenerate / looking-up case (cinematic, debug) — fall back to a
        // forward step so we always produce SOME usable focus.
        const float kFocusDist = 600.0f;
        focusX = camEyeX + camFwdX * kFocusDist;
        focusY = camEyeY + camFwdY * kFocusDist;
        focusZ = camEyeZ + camFwdZ * kFocusDist;
    }
    // Debug — print eye/fwd/focus once at startup + every 600 frames so we can
    // sanity-check the camera math against the actual scene (terrain is at
    // Z≈0..few hundred, tactical eye is at Z≈200..500 looking down).
    if (ctx->frameIndex < 3 || (ctx->frameIndex % 600) == 0) {
        fprintf(stderr, "[shadow-cam] f%ld eye=(%.1f,%.1f,%.1f) fwd=(%.2f,%.2f,%.2f) focus=(%.1f,%.1f,%.1f)\n",
                ctx->frameIndex, camEyeX, camEyeY, camEyeZ,
                camFwdX, camFwdY, camFwdZ, focusX, focusY, focusZ);
        fflush(stderr);
    }

    // -- 3. Build light view. Light "eye" sits along -sunDir from focus at
    //       `farRange` units away. Ortho's far plane (built below) is 2*farRange
    //       so the focus point lands at NDC ≈ 0.5, with casters above/below
    //       covering the [0,1] range.
    //       Adaptive to camera height: at max zoom-out the camera can be
    //       2000-4000u above ground, and the visible terrain stretches far
    //       enough that a fixed farRange would clip out casters / receivers
    //       and a fixed halfExt would miss whole edges of the visible scene.
    //       Both grow linearly with |camEyeZ| with floors that match the
    //       previous fixed defaults so close-zoom quality is unchanged.
    static float s_farRangeBase = -1.0f;
    if (s_farRangeBase < 0.0f) {
        const char* e = getenv("MTL_SHADOW_LIGHT_DIST");
        s_farRangeBase = e ? (float)atof(e) : 4000.0f;
    }
    const float camHeightAbs = fabsf(camEyeZ);
    // farRange grows so the light eye stays comfortably above the tallest
    // caster even as the camera rises. 2× camera height is a safe envelope.
    const float farRange = fmaxf(s_farRangeBase, camHeightAbs * 2.0f);
    float lightEyeX = focusX - sunDx * farRange;
    float lightEyeY = focusY - sunDy * farRange;
    float lightEyeZ = focusZ - sunDz * farRange;

    float fwdX = sunDx, fwdY = sunDy, fwdZ = sunDz;
    float upRefX = 0.0f, upRefY = 0.0f, upRefZ = 1.0f;     // Z-up world
    if (fabsf(fwdX*upRefX + fwdY*upRefY + fwdZ*upRefZ) > 0.99f) { upRefX = 0.0f; upRefY = 1.0f; upRefZ = 0.0f; }
    // right = upRef × fwd
    float rightX = upRefY*fwdZ - upRefZ*fwdY;
    float rightY = upRefZ*fwdX - upRefX*fwdZ;
    float rightZ = upRefX*fwdY - upRefY*fwdX;
    { float rn = sqrtf(rightX*rightX+rightY*rightY+rightZ*rightZ); if (rn>1e-6f){rightX/=rn;rightY/=rn;rightZ/=rn;} }
    // up = fwd × right
    float upX = fwdY*rightZ - fwdZ*rightY;
    float upY = fwdZ*rightX - fwdX*rightZ;
    float upZ = fwdX*rightY - fwdY*rightX;
    { float un = sqrtf(upX*upX+upY*upY+upZ*upZ); if (un>1e-6f){upX/=un;upY/=un;upZ/=un;} }

    // -- 3a. Stable shadow maps: snap the focus point to a texel grid in the
    //        light's right/up basis. Without this, the slightest camera move
    //        slides the light frustum by sub-texel amounts → every visible
    //        edge in the shadow map shifts each frame → shadows "swim".
    //        Snapping pins texel boundaries to world-space positions, so as
    //        long as the camera moves less than texelSize between frames,
    //        the shadow map texels stay on the same world coords.
    static float s_halfExtBase = -1.0f;
    if (s_halfExtBase < 0.0f) {
        const char* e = getenv("MTL_SHADOW_HALF_EXT");
        s_halfExtBase = e ? (float)atof(e) : 2000.0f;
    }
    // halfExt grows with camera altitude so the orthographic light frustum
    // covers the visible terrain at every zoom level. Generals' tactical
    // camera tilts ~45° and uses ~50° h-FOV, so the visible ground patch is
    // roughly camHeight wide in each axis from the focus point. We use 0.9×
    // as a safety multiplier so casters near the screen edge still land
    // inside the shadow map. Capped from below by the legacy 2000u default
    // so close-zoom shadow texel density matches the previous behaviour.
    const float halfExt   = fmaxf(s_halfExtBase, camHeightAbs * 0.9f);
    const float texelSize = (2.0f * halfExt) / (float)METAL_SHADOWMAP_SIZE;
    // Project focus onto light's right/up axes, snap, reconstruct.
    {
        float r = focusX*rightX + focusY*rightY + focusZ*rightZ;
        float u = focusX*upX    + focusY*upY    + focusZ*upZ;
        float f = focusX*fwdX   + focusY*fwdY   + focusZ*fwdZ;
        r = roundf(r / texelSize) * texelSize;
        u = roundf(u / texelSize) * texelSize;
        focusX = rightX*r + upX*u + fwdX*f;
        focusY = rightY*r + upY*u + fwdY*f;
        focusZ = rightZ*r + upZ*u + fwdZ*f;
        // Recompute light eye now that focus is snapped.
        lightEyeX = focusX - sunDx * farRange;
        lightEyeY = focusY - sunDy * farRange;
        lightEyeZ = focusZ - sunDz * farRange;
    }

    float view[16] = {
        rightX, upX, fwdX, 0.0f,
        rightY, upY, fwdY, 0.0f,
        rightZ, upZ, fwdZ, 0.0f,
        -(rightX*lightEyeX + rightY*lightEyeY + rightZ*lightEyeZ),
        -(upX   *lightEyeX + upY   *lightEyeY + upZ   *lightEyeZ),
        -(fwdX  *lightEyeX + fwdY  *lightEyeY + fwdZ  *lightEyeZ),
        1.0f
    };
    const float near_ = 0.0f;
    // far_ must be at least 2*farRange so the focus point (at depth `farRange`
    // in light space) lands near NDC 0.5, leaving headroom on both sides for
    // tall casters and below-ground receivers. With farRange=2000 (light eye
    // 2000u from focus), far_=4000 puts focus at NDC 0.5 and bias 0.0005 NDC
    // = 2 world units of peter-pan offset.
    const float far_ = farRange * 2.0f;
    float proj[16] = {
        1.0f/halfExt, 0.0f,         0.0f,                0.0f,
        0.0f,         1.0f/halfExt, 0.0f,                0.0f,
        0.0f,         0.0f,         1.0f/(far_-near_),   0.0f,
        0.0f,         0.0f,         -near_/(far_-near_), 1.0f
    };
    // lvp = proj * view
    float lvp[16];
    for (int r = 0; r < 4; ++r)
    for (int c = 0; c < 4; ++c) {
        float s = 0.0f;
        for (int k = 0; k < 4; ++k) s += proj[k*4+r] * view[c*4+k];
        lvp[c*4+r] = s;
    }
    std::memcpy(ctx->lightVP, lvp, sizeof(lvp));
    // NOTE: do NOT force ctx->shadowsEnabled=1 here. That flag is the
    // engine's request ("Metal Optimised" preset selected). If we self-set
    // it on first replay, the user could never turn shadows off again —
    // the engine call MetalShim_SetShadowsEnabled(0) would be silently
    // overwritten on the very next frame. Engine owns the flag; the shim
    // only reads it.

    // DIAG: dump the lvp matrix once at startup + every 600f so we can hand-
    // verify that scene points project to NDC in [-1..1]×[-1..1]×[0..1].
    // Also project the focus point and (focus + scene_height*Z) for sanity.
    if (ctx->frameIndex < 3 || (ctx->frameIndex % 600) == 0) {
        // Project focus point through lvp (focus, 1) by hand. lvp is in
        // column-major math storage: lvp[c*4+r] = M[r][c].
        auto proj_pt = [&](float x, float y, float z, const char* tag) {
            float cx = lvp[0]*x + lvp[4]*y + lvp[8] *z + lvp[12];
            float cy = lvp[1]*x + lvp[5]*y + lvp[9] *z + lvp[13];
            float cz = lvp[2]*x + lvp[6]*y + lvp[10]*z + lvp[14];
            float cw = lvp[3]*x + lvp[7]*y + lvp[11]*z + lvp[15];
            float nx=cw!=0?cx/cw:0, ny=cw!=0?cy/cw:0, nz=cw!=0?cz/cw:0;
            fprintf(stderr, "  [%s] world=(%.0f,%.0f,%.0f) clip=(%.2f,%.2f,%.2f,%.2f) ndc=(%.2f,%.2f,%.2f)\n",
                    tag, x,y,z, cx,cy,cz,cw, nx,ny,nz);
        };
        fprintf(stderr, "[lvp-probe] f%ld lightEye=(%.0f,%.0f,%.0f) focus=(%.0f,%.0f,%.0f) halfExt=%.0f far_=%.0f\n",
                ctx->frameIndex, lightEyeX,lightEyeY,lightEyeZ, focusX,focusY,focusZ, halfExt, far_);
        proj_pt(focusX, focusY, focusZ, "focus     ");
        proj_pt(focusX, focusY, focusZ + 100.0f, "focus+100Z");
        proj_pt(focusX, focusY, 0.0f, "ground@xy ");
        fflush(stderr);
    }

    // -- 4. Spin up a depth-only encoder against the shadow map.
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture     = ctx->shadowMap;
    pass.depthAttachment.loadAction  = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;  // sampled next frame
    pass.depthAttachment.clearDepth  = 1.0;
    id<MTLRenderCommandEncoder> enc = [ctx->cmd renderCommandEncoderWithDescriptor:pass];
    MTLViewport vp = { 0.0, 0.0, (double)METAL_SHADOWMAP_SIZE, (double)METAL_SHADOWMAP_SIZE, 0.0, 1.0 };
    [enc setViewport:vp];

    // -- 4a. Hardware slope-scale depth bias (off by default).
    //
    //        DESIGN NOTE: setDepthBias:slopeScale: on Metal pushes caster
    //        depth AWAY from light by `slope * max(|dz/dx|, |dz/dy|)`. For
    //        Generals' geometry that means BUILDING WALLS and SHIP HULLS get
    //        a HUGE slope-scale bias (steep walls → big derivatives) → caster
    //        depth pushed past 1.0 → fragment fails depth test → wall never
    //        writes to shadow map → wall doesn't cast a shadow → NO SHADOWS
    //        on the ground around the building. Classic gotcha.
    //
    //        So we keep slope=0 by default and let the shader-side NDC bias
    //        (FSParams.shadowBias, set in MetalContext_Draw) do the work.
    //        Env vars MTL_SHADOW_SLOPE_BIAS / MTL_SHADOW_CONST_BIAS exist for
    //        future per-scene tuning if we cap the slope contribution.
    //
    //        Reference: MoltenVK translates Vulkan's vkCmdSetDepthBias to
    //        exactly this API; same trade-off applies there.
    static float s_slope = -1.0f, s_constBias = -2.0f;
    if (s_slope < 0.0f) { const char* e = getenv("MTL_SHADOW_SLOPE_BIAS"); s_slope     = e ? (float)atof(e) : 0.0f; }
    if (s_constBias < -1.0f) { const char* e = getenv("MTL_SHADOW_CONST_BIAS"); s_constBias = e ? (float)atof(e) : 0.0f; }
    if (s_slope != 0.0f || s_constBias != 0.0f) {
        [enc setDepthBias:s_constBias slopeScale:s_slope clamp:0.0f];
    }

    // -- 5. Replay every captured draw, transformed by lightVP*world.
    for (auto& c : ctx->shadowCaptures) {
        // Build a fake MetalDrawCall to feed GetShadowPipeline (it only reads
        // the layout-affecting fields).
        MetalDrawCall fake; std::memset(&fake, 0, sizeof(fake));
        fake.fvf            = c.fvf;
        fake.stride         = c.stride;
        fake.posOffset      = c.posOffset;
        fake.posFloats      = c.posFloats;
        fake.normalOffset   = c.normalOffset;
        fake.diffuseOffset  = c.diffuseOffset;
        fake.tex0Offset     = c.tex0Offset;
        fake.tex1Offset     = c.tex1Offset;
        fake.texCoordIndex  = c.texCoordIndex;
        id<MTLRenderPipelineState> ps = GetShadowPipeline(ctx, &fake);
        if (!ps) continue;

        [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:c.vb offset:0 atIndex:0];

        UniformsCPU u;
        std::memset(&u, 0, sizeof(u));
        std::memcpy(u.world,    c.world, sizeof(float) * 16);
        std::memcpy(u.lightVP,  lvp,     sizeof(float) * 16);
        u.posFloats   = c.posFloats;
        u.shadowPass  = 1;
        u.hasDiffuse  = (c.diffuseOffset >= 0) ? 1 : 0;
        u.hasNormal   = (c.normalOffset  >= 0) ? 1 : 0;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];

        [enc setDepthStencilState:ctx->shadowDS];
        [enc setFrontFacingWinding:MTLWindingClockwise];
        // Default to NO culling in the shadow pass. The textbook "cull front,
        // render back faces" trick is great for fully closed solid meshes
        // (no acne, automatic depth gap) — but Generals models include MANY
        // thin / single-sided parts: flagpoles, fabric flags, antenna masts,
        // bulldozer blades, decals on building walls. Front-face culling
        // erases those entirely → no shadow at all for thin geometry.
        //
        // With MTLCullModeNone every face writes its depth; we rely on the
        // depth bias in the fragment-shader compare to suppress acne. Bumped
        // the default bias accordingly. Set MTL_SHADOW_CULL_MODE=front/back
        // for A/B testing.
        MTLCullMode cull = MTLCullModeNone;
        static int s_cullOverride = -2;
        if (s_cullOverride == -2) {
            const char* e = getenv("MTL_SHADOW_CULL_MODE");
            if      (!e)                     s_cullOverride = -1;        // default
            else if (!strcasecmp(e,"none"))  s_cullOverride = 0;
            else if (!strcasecmp(e,"back"))  s_cullOverride = 1;
            else if (!strcasecmp(e,"front")) s_cullOverride = 2;
            else                              s_cullOverride = -1;
        }
        if      (s_cullOverride == 0) cull = MTLCullModeNone;
        else if (s_cullOverride == 1) cull = MTLCullModeBack;
        else if (s_cullOverride == 2) cull = MTLCullModeFront;
        [enc setCullMode:cull];

        MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
        if      (c.primType == 5 /*TRISTRIP*/) prim = MTLPrimitiveTypeTriangleStrip;
        else if (c.primType == 6 /*TRIFAN*/)   continue;

        if (c.ib) {
            [enc drawIndexedPrimitives:prim
                            indexCount:c.indexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:c.ib
                     indexBufferOffset:c.indexOffsetBytes
                         instanceCount:1
                            baseVertex:c.baseVertex
                          baseInstance:0];
        } else {
            [enc drawPrimitives:prim
                    vertexStart:c.vertexStart
                    vertexCount:c.vertexCount];
        }
    }
    [enc endEncoding];

    // -- 6. Release retained buffers + clear list.
    for (auto& c : ctx->shadowCaptures) {
        if (c.vb) [c.vb release];
        if (c.ib) [c.ib release];
    }
    ctx->shadowCaptures.clear();
    ctx->haveCaptureSnapshot = false;

    // MTL_SHADOW_DBG — dump per-frame filter counts every 30 frames so the
    // user can see in real time how unit selection / state changes affect
    // capture acceptance.
    static int s_dbg = -1;
    if (s_dbg < 0) s_dbg = getenv("MTL_SHADOW_DBG") ? 1 : 0;
    if (s_dbg && (ctx->frameIndex % 30) == 0) {
        // Dump unique FVFs seen this frame (as hex bits) so we can tell which
        // 3D vertex formats appear/disappear with selection.
        fprintf(stderr, "[shadow-dbg] f%ld: total=%d accepted=%d rej(2D)=%d rej(blend)=%d rej(cw0)=%d fvfMask=0x%llx\n",
                ctx->frameIndex,
                ctx->dbgTotalDraws,
                ctx->dbgRejAccepted, ctx->dbgRejPosFloats,
                ctx->dbgRejBlend, ctx->dbgRejColorWrite,
                (unsigned long long)ctx->dbgFvfMask);
        fflush(stderr);
    }
    ctx->dbgRejPosFloats = ctx->dbgRejBlend = ctx->dbgRejColorWrite = ctx->dbgRejAccepted = 0;
    ctx->dbgTotalDraws = 0;
    ctx->dbgFvfMask = 0;
}

static void FlushPendingMips(MetalContext* ctx);   // defined below; batched mip generation
static void SweepRetiredBuffers(MetalContext* ctx); // defined below; dynamic-buffer recycling
static void SweepRetiredTextures(MetalContext* ctx); // defined below; dynamic-texture recycling
static void DecayPools(MetalContext* ctx);           // defined below; periodic pool shrink
static void FlushPendingUploads(MetalContext* ctx);  // defined below; staged private-texture uploads
extern "C" long MetalDiag_LiveVB8(void) __attribute__((weak)); // dx8_device.cpp
extern "C" long MetalDiag_LiveIB8(void) __attribute__((weak)); // dx8_device.cpp

extern "C" void MetalContext_Present(MetalContext* ctx)
{
    if (!ctx) return;
    @autoreleasepool {
        // If nothing was drawn this frame, still clear+present.
        if (!ctx->enc && !ctx->drawable) EnsureEncoder(ctx);
        if (ctx->enc) { [ctx->enc endEncoding]; [ctx->enc release]; ctx->enc = nil; }

        // Regenerate mip chains for textures uploaded this frame, batched into a
        // single command buffer and committed here — before the frame's render
        // buffer (ctx->cmd) is committed below, so the mips are ready when the GPU
        // executes the frame. The encoder is already ended, so ctx->cmd has no
        // open encoder while this separate command buffer is built + committed.
        static int s_da = -1; if (s_da < 0) s_da = getenv("MTL_POOL_LOG") ? 1 : 0;
        const bool daSample = s_da && (ctx->frameIndex % 120) == 0;
        unsigned long da0 = 0, da1 = 0, da2 = 0;
        if (daSample) da0 = (unsigned long)ctx->device.currentAllocatedSize;
        FlushPendingUploads(ctx);
        FlushPendingMips(ctx);
        if (daSample) da1 = (unsigned long)ctx->device.currentAllocatedSize;

        // Stage 6: replay captured draws into the shadow map BEFORE present.
        // The next frame's main fragment shader will sample it. Same command
        // buffer — no extra commit/wait.
        RunShadowReplay(ctx);

        // Debug frame capture: blit the drawable into a shared texture so we can
        // read it back to a PNG. Gated by MTL_DUMP (which also forced
        // framebufferOnly=NO). Captures a few early frames + one per ~120.
        static int s_dumpEnv = -1;
        if (s_dumpEnv < 0) s_dumpEnv = getenv("MTL_DUMP") ? 1 : 0;
        id<MTLTexture> dumpTex = nil;
        bool wantDump = s_dumpEnv && ctx->cmd && ctx->drawable &&
                        (ctx->frameIndex == 5 || ctx->frameIndex == 60 ||
                         ctx->frameIndex == 180 || ctx->frameIndex == 360 ||
                         ctx->frameIndex == 600 || ctx->frameIndex == 900 ||
                         (ctx->frameIndex % 600) == 0);
        if (wantDump) {
            MTLTextureDescriptor* dd =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:ctx->width
                                                                  height:ctx->height
                                                               mipmapped:NO];
            dd.usage = MTLTextureUsageShaderRead;
            dd.storageMode = MTLStorageModeShared;
            dumpTex = [[ctx->device newTextureWithDescriptor:dd] autorelease];
            id<MTLBlitCommandEncoder> blit = [ctx->cmd blitCommandEncoder];
            [blit copyFromTexture:ctx->drawable.texture sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0,0,0)
                       sourceSize:MTLSizeMake(ctx->width, ctx->height, 1)
                        toTexture:dumpTex destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding];
        }
        if (ctx->cmd && ctx->drawable) {
            // Recycle the dynamic buffers this frame's draws referenced once the
            // GPU finishes it (see MetalContext_RetireBuffer / SweepRetiredBuffers).
            const uint64_t fid = ctx->bufFrameId;
            MetalContext* c = ctx;
            [ctx->cmd addCompletedHandler:^(id<MTLCommandBuffer>){
                c->bufCompletedFrame.store(fid, std::memory_order_relaxed);
                c->cbInFlight.fetch_sub(1, std::memory_order_relaxed);
                c->cbCompleted.fetch_add(1, std::memory_order_relaxed);
            }];
            [ctx->drawable addPresentedHandler:^(id<MTLDrawable>){
                c->cbPresented.fetch_add(1, std::memory_order_relaxed);
            }];
            [ctx->cmd presentDrawable:ctx->drawable];
            const int inFlight = ctx->cbInFlight.fetch_add(1, std::memory_order_relaxed) + 1;
            ctx->cbCreated.fetch_add(1, std::memory_order_relaxed);
            [ctx->cmd commit];
            // Backpressure — same cap as FlushPendingMips (see cbInFlight docs).
            // waitUntilCompleted waits for GPU execution only (not presentation),
            // so this cannot deadlock on a stalled CoreAnimation transaction.
            if (inFlight > 8) [ctx->cmd waitUntilCompleted];
        }
        if (daSample) {
            da2 = (unsigned long)ctx->device.currentAllocatedSize;
            fprintf(stderr, "[da] f%ld pre=%luMB mips+%ldKB commit+%ldKB\n", ctx->frameIndex,
                    da0/(1024*1024), (long)(da1-da0)/1024, (long)(da2-da1)/1024);
            fflush(stderr);
        }
        if (wantDump && dumpTex) {
            [ctx->cmd waitUntilCompleted];
            const int W = ctx->width, H = ctx->height;
            std::vector<uint8_t> px((size_t)W * H * 4);
            [dumpTex getBytes:px.data() bytesPerRow:W*4
                   fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
            // Sample a few pixels (BGRA order, before swap) for ground-truth color.
            { int sx[5]={W/4,W/2,3*W/4,W/3,W/2}, sy[5]={H/2,H*2/3,H*3/4,H*4/5,H/3};
              fprintf(stderr,"[px] f%ld:", ctx->frameIndex);
              for(int k=0;k<5;++k){ const uint8_t* p=px.data()+((size_t)sy[k]*W+sx[k])*4;
                fprintf(stderr," (%d,%d)=R%uG%uB%u", sx[k],sy[k],p[2],p[1],p[0]); }
              fprintf(stderr,"\n"); fflush(stderr); }
            // BGRA -> RGBA for NSBitmapImageRep; force opaque alpha (the back
            // buffer is an opaque X8R8G8B8-equivalent — many opaque 3D draws
            // leave dest alpha at 0, which would render the PNG transparent).
            for (size_t i = 0; i + 3 < px.size(); i += 4) { uint8_t b=px[i]; px[i]=px[i+2]; px[i+2]=b; px[i+3]=255; }
            NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H
                            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                          colorSpaceName:NSDeviceRGBColorSpace
                             bytesPerRow:W*4 bitsPerPixel:32] autorelease];
            memcpy([rep bitmapData], px.data(), px.size());
            NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSString* path = [NSString stringWithFormat:@"/tmp/gen_frame_%04ld.png", ctx->frameIndex];
            [png writeToFile:path atomically:YES];
            fprintf(stderr, "[dump] wrote %s\n", path.UTF8String); fflush(stderr);
        }
        if (ctx->cmd)      { [ctx->cmd release];      ctx->cmd = nil; }
        if (ctx->drawable) { [ctx->drawable release]; ctx->drawable = nil; }
        // Recycle GPU-finished dynamic buffers/textures and advance the frame
        // counter used to tag resources retired during the next frame.
        SweepRetiredBuffers(ctx);
        SweepRetiredTextures(ctx);
        DecayPools(ctx);
        ctx->bufFrameId++;
        // MTL_POOL_LOG=1: dump the recycle-pool sizes every 120 frames. Kept as
        // diagnostic infra — this is how the font-texture-churn leak was found
        // (texFree/bufFree stay bounded, no unbounded growth).
        { static int s_poolLog = -1; if (s_poolLog < 0) s_poolLog = getenv("MTL_POOL_LOG") ? 1 : 0;
          if (s_poolLog && (ctx->frameIndex % 120) == 0) {
              std::lock_guard<std::mutex> lk(ctx->poolMutex);
              size_t bfN=0, bfBytes=0; for (auto& kv : ctx->bufFree) { bfN += kv.second.size(); bfBytes += (size_t)kv.first * kv.second.size(); }
              size_t tfN=0, tfBytes=0;
              for (auto& kv : ctx->texFree) {
                  tfN += kv.second.size();
                  for (void* tp : kv.second) {
                      id<MTLTexture> t = (__bridge id<MTLTexture>)tp;
                      size_t px = (size_t)t.width * t.height * 4;      // pool = uncompressed only
                      tfBytes += t.mipmapLevelCount > 1 ? px + px/3 : px;
                  }
              }
              fprintf(stderr, "[pool] f%ld bufFree=%zu(%zuKB) bufRetired=%zu | texFree=%zu(%zuKB keys=%zu) texRetired=%zu | pendingMips=%lu cbInFlight=%d\n",
                      ctx->frameIndex, bfN, bfBytes/1024, ctx->bufRetired.size(),
                      tfN, tfBytes/1024, ctx->texFree.size(), ctx->texRetired.size(),
                      (unsigned long)(ctx->pendingMips ? ctx->pendingMips.count : 0),
                      ctx->cbInFlight.load(std::memory_order_relaxed));
              fprintf(stderr, "[cb] created=%ld completed=%ld presented=%ld liveVB=%ld liveIB=%ld\n",
                      ctx->cbCreated.load(std::memory_order_relaxed),
                      ctx->cbCompleted.load(std::memory_order_relaxed),
                      ctx->cbPresented.load(std::memory_order_relaxed),
                      MetalDiag_LiveVB8 ? MetalDiag_LiveVB8() : -1,
                      MetalDiag_LiveIB8 ? MetalDiag_LiveIB8() : -1);
              fprintf(stderr, "[live] buf=%ld(%ldMB) tex=%ld(%ldMB) deviceAlloc=%luMB\n",
                      ctx->bufLiveN.load(std::memory_order_relaxed),
                      ctx->bufLiveBytes.load(std::memory_order_relaxed) / (1024*1024),
                      ctx->texLiveN.load(std::memory_order_relaxed),
                      ctx->texLiveBytes.load(std::memory_order_relaxed) / (1024*1024),
                      (unsigned long)(ctx->device.currentAllocatedSize / (1024*1024)));
              if ((ctx->frameIndex % 600) == 0) {
                  for (auto& kv : ctx->texFree) {
                      if (kv.second.empty()) continue;
                      id<MTLTexture> s0 = (__bridge id<MTLTexture>)kv.second.front();
                      fprintf(stderr, "[key] %llx: %zu tex of %lux%lu pf=%lu mips=%lu usage=0x%lx\n",
                              (unsigned long long)kv.first, kv.second.size(),
                              (unsigned long)s0.width, (unsigned long)s0.height,
                              (unsigned long)s0.pixelFormat, (unsigned long)s0.mipmapLevelCount,
                              (unsigned long)s0.usage);
                  }
              }
              fprintf(stderr, "[flow] create hit=%ld miss=%ld | rename hit=%ld miss=%ld | push rel=%ld ren=%ld | ovT=%ld ovB=%ld\n",
                      ctx->texPullCreate.load(std::memory_order_relaxed),
                      ctx->texMissCreate.load(std::memory_order_relaxed),
                      ctx->texPullRename.load(std::memory_order_relaxed),
                      ctx->texMissRename.load(std::memory_order_relaxed),
                      ctx->texPushRelease.load(std::memory_order_relaxed),
                      ctx->texPushRename.load(std::memory_order_relaxed),
                      ctx->texOverflow.load(std::memory_order_relaxed),
                      ctx->bufOverflow.load(std::memory_order_relaxed));
              fflush(stderr);
          } }
        if (ctx->dbg < 0) ctx->dbg = getenv("MTL_DEBUG") ? 1 : 0;
        if (ctx->dbg > 0 && (ctx->frameIndex < 8 || (ctx->frameIndex % 120) == 0)) {
            fprintf(stderr, "[metal] frame %ld: %d draws (%d textured)\n",
                    ctx->frameIndex, ctx->drawsThisFrame, ctx->texturedThisFrame);
            fflush(stderr);
        }
        ctx->frameIndex++;
        ctx->drawsThisFrame = 0;
        ctx->texturedThisFrame = 0;
        DrainEvents();
    }
}

// TheSuperHackers @port macOS: full mip-chain support for uncompressed textures.
//
// The DX8 texture path here was single-mip: every texture was created
// mipmapped:NO and only level 0 was ever uploaded. The engine still requests
// trilinear/bilinear-mip sampling — TextureFilterClass::Apply() sets
// D3DTSS_MIPFILTER to LINEAR/POINT for any texture it considers mipmapped
// (texturefilter.cpp), which reaches our GetSampler as MTLSamplerMipFilter*.
// With no mip data to sample, minified terrain (grass/dirt tiles under the
// tilted RTS camera) aliases badly and "crawls"/shimmers as the camera moves —
// the textbook missing-mipmap artifact. We fix it in the backend, transparently
// to the DX8 wrapper: allocate a full mip chain for uncompressed textures and
// GPU-generate levels 1..N from the uploaded level 0 (see GenerateMips, called
// from the upload entrypoints). Sampling stays gated by the engine's
// D3DTSS_MIPFILTER, so textures the engine wants unmipmapped (UI/text, which it
// marks MIP_LEVELS_1 → MIPFILTER=NONE) still sample level 0 only.
//
// Compressed BC textures keep a single level: Metal cannot generate mips for
// compressed formats, and the stub uploads only their level 0. Set
// MTL_NO_MIPMAPS=1 to fully revert to the old single-level behavior (A/B).
static bool MipmapsEnabled()
{
    static int e = -1;
    if (e < 0) e = getenv("MTL_NO_MIPMAPS") ? 0 : 1;
    return e != 0;
}

// Number of mip levels in a full chain down to 1x1 for a width x height texture.
static NSUInteger MipCountFor(int width, int height)
{
    int m = (width > height ? width : height);
    if (m < 1) m = 1;
    NSUInteger levels = 1;
    while (m > 1) { m >>= 1; ++levels; }
    return levels;
}

// Queue a texture (whose level 0 was just uploaded) for mip-chain regeneration.
// No-op for single-level textures (compressed / 1x1 / MTL_NO_MIPMAPS) and when
// no context is available. Self-gates on mip level count. The actual GPU work is
// deferred and batched into ONE command buffer at Present (FlushPendingMips) so
// that dynamic textures re-uploaded every frame (font/UI sentences, render
// targets) cost at most one extra command buffer per frame — not one per upload,
// which saturated the IOGPU submission queue and wedged the main thread.
static void GenerateMips(id<MTLTexture> tex)
{
    if (!tex || tex.mipmapLevelCount <= 1) return;
    MetalContext* ctx = s_uploadCtx;
    if (!ctx) return;
    if (!ctx->pendingMips) ctx->pendingMips = [[NSMutableSet alloc] init];
    [ctx->pendingMips addObject:tex];   // set retains; keeps tex valid until flush
}

// Generate mip chains for every texture uploaded since the last flush, in a
// single blit command buffer. Called at the top of Present, so it is committed
// just before the frame's render command buffer — Metal executes committed
// buffers in commit order on one queue, so the mips are ready before the frame
// samples them. Bounds mip work to one command buffer per frame regardless of
// how many textures were uploaded.
static void FlushPendingMips(MetalContext* ctx)
{
    if (!ctx || !ctx->queue || !ctx->pendingMips || ctx->pendingMips.count == 0) return;
    // Chunked: at most kMipsPerCB textures per command buffer, low in-flight
    // cap. A map-load burst re-uploads HUNDREDS of textures between two
    // Presents; batching them into ONE cb makes the driver keep a pooled
    // resource alive per generateMipmaps command until that cb completes —
    // IOGPU sizes its per-device resource pool at that burst peak (~200 MB,
    // malloc_history-verified: ~6100 live 32 KB blocks under
    // renderMRCDownsample, all load-time) and NEVER shrinks it. Chunking
    // bounds concurrent mip commands, so the pool stays a few MB. Steady-state
    // frames flush 1-2 pending mips and take the single-chunk path unchanged.
    const NSUInteger kMipsPerCB = 32;
    MetalContext* c = ctx;
    id<MTLCommandBuffer> cb = nil;
    id<MTLBlitCommandEncoder> blit = nil;
    NSUInteger inCb = 0;
    for (id<MTLTexture> tex in ctx->pendingMips) {
        if (tex.mipmapLevelCount <= 1) continue;
        if (!cb) {
            cb = [ctx->queue commandBuffer];
            blit = [cb blitCommandEncoder];
            inCb = 0;
        }
        [blit generateMipmapsForTexture:tex];
        if (++inCb < kMipsPerCB) continue;
        [blit endEncoding];
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){
            c->cbInFlight.fetch_sub(1, std::memory_order_relaxed);
            c->cbCompleted.fetch_add(1, std::memory_order_relaxed);
        }];
        const int inFlight = ctx->cbInFlight.fetch_add(1, std::memory_order_relaxed) + 1;
        ctx->cbCreated.fetch_add(1, std::memory_order_relaxed);
        [cb commit];
        if (inFlight > 3) [cb waitUntilCompleted];   // load-burst throttle
        cb = nil; blit = nil;
    }
    if (cb) {
        [blit endEncoding];
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){
            c->cbInFlight.fetch_sub(1, std::memory_order_relaxed);
            c->cbCompleted.fetch_add(1, std::memory_order_relaxed);
        }];
        const int inFlight = ctx->cbInFlight.fetch_add(1, std::memory_order_relaxed) + 1;
        ctx->cbCreated.fetch_add(1, std::memory_order_relaxed);
        [cb commit];
        if (inFlight > 8) [cb waitUntilCompleted];
    }
    [ctx->pendingMips removeAllObjects];
}

extern "C" void* MetalContext_CreateTextureFmt(MetalContext* ctx, int width, int height, int bcKind)
{
    if (!ctx) return nullptr;
    @autoreleasepool {
        MTLPixelFormat pf = MTLPixelFormatBGRA8Unorm;
        bool compressed = false;
        switch (bcKind) {
            case 1: pf = MTLPixelFormatBC1_RGBA; compressed = true; break;  // DXT1
            case 2: pf = MTLPixelFormatBC2_RGBA; compressed = true; break;  // DXT2/3
            case 3: pf = MTLPixelFormatBC3_RGBA; compressed = true; break;  // DXT4/5
            default: pf = MTLPixelFormatBGRA8Unorm; break;
        }
        const int w = (width  > 0 ? width  : 1);
        const int h = (height > 0 ? height : 1);
        MTLTextureDescriptor* desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        // Full mip chain for uncompressed textures so the engine's mip-filter
        // request has real data to sample (see file-scope note above).
        if (!compressed && MipmapsEnabled())
            desc.mipmapLevelCount = MipCountFor(w, h);
        desc.usage = MTLTextureUsageShaderRead;
        if (PrivateTexEnabled()) desc.storageMode = MTLStorageModePrivate;
        // Create/release recycling pool: reuse a same-descriptor texture retired
        // by MetalContext_ReleaseTexture (frame-delayed → GPU-safe) instead of
        // allocating a fresh MTLTexture. Kills the font-glyph churn leak. The
        // caller always fully re-uploads a freshly-created texture before it is
        // sampled (D3D leaves new-texture contents undefined), so stale pooled
        // pixels are safe. Same texFree pool + key as the rename path.
        if (TexPoolable((NSUInteger)w, (NSUInteger)h, pf)) {
            uint64_t key = TexKeyFields((NSUInteger)w, (NSUInteger)h, (unsigned)pf,
                                        desc.mipmapLevelCount, (unsigned)MTLTextureUsageShaderRead);
            std::lock_guard<std::mutex> lk(ctx->poolMutex);
            std::unordered_map<uint64_t, std::vector<void*> >::iterator it = ctx->texFree.find(key);
            if (it != ctx->texFree.end() && !it->second.empty()) {
                void* reuse = it->second.back();
                it->second.pop_back();          // already CF-retained; ownership -> caller
                ctx->texPullCreate.fetch_add(1, std::memory_order_relaxed);
                return reuse;
            }
        }
        id<MTLTexture> tex = [ctx->device newTextureWithDescriptor:desc];
        DiagTexAlloc(ctx, tex);
        // MTL_POOL_LOG=1: poolable-but-pool-missed fresh create — pair with
        // [tex-overflow] lines to spot create/retire key mismatches.
        if (TexPoolable((NSUInteger)w, (NSUInteger)h, pf)) {
            ctx->texMissCreate.fetch_add(1, std::memory_order_relaxed);
            static int s_lg = -1; if (s_lg < 0) s_lg = getenv("MTL_POOL_LOG") ? 1 : 0;
            if (s_lg) { static unsigned long n=0; if ((++n % 64) == 1) {
                fprintf(stderr, "[tex-poolmiss] #%lu %dx%d pf=%lu mips=%lu usage=0x%lx\n",
                        n, w, h, (unsigned long)pf, (unsigned long)desc.mipmapLevelCount,
                        (unsigned long)tex.usage); fflush(stderr); } }
        }
        return (void*)CFBridgingRetain(tex);
    }
}

extern "C" void* MetalContext_CreateTexture(MetalContext* ctx, int width, int height)
{
    return MetalContext_CreateTextureFmt(ctx, width, height, 0);
}

// Flush all staged uploads into ONE blit command buffer (chunked mips-style
// backpressure). Called at Present before the frame cb commits (queue order
// guarantees the GPU sees the new texel data before the frame's draws), and
// inline from StageUpload when a load burst queues 64+.
static void FlushPendingUploads(MetalContext* ctx)
{
    if (!ctx || !ctx->queue) return;
    std::vector<MetalContext::PendingUpload> ups;
    {
        std::lock_guard<std::mutex> lk(ctx->poolMutex);
        if (ctx->pendingUploads.empty()) return;
        ups.swap(ctx->pendingUploads);
    }
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        for (const MetalContext::PendingUpload& u : ups) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)u.tex;
            id<MTLBuffer>  b = (__bridge id<MTLBuffer>)u.buf;
            [blit copyFromBuffer:b
                    sourceOffset:0
               sourceBytesPerRow:(NSUInteger)u.rowBytes
             sourceBytesPerImage:0
                      sourceSize:MTLSizeMake((NSUInteger)u.w, (NSUInteger)u.h, 1)
                       toTexture:t
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
            if (t.mipmapLevelCount > 1) [blit generateMipmapsForTexture:t];
        }
        [blit endEncoding];
        MetalContext* c = ctx;
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){
            c->cbInFlight.fetch_sub(1, std::memory_order_relaxed);
            c->cbCompleted.fetch_add(1, std::memory_order_relaxed);
        }];
        const int inFlight = ctx->cbInFlight.fetch_add(1, std::memory_order_relaxed) + 1;
        ctx->cbCreated.fetch_add(1, std::memory_order_relaxed);
        [cb commit];
        if (inFlight > 8) [cb waitUntilCompleted];
    }
    for (const MetalContext::PendingUpload& u : ups) {
        MetalContext_RetireBuffer(ctx, u.buf);   // recycled once the GPU finishes
        CFRelease(u.tex);
    }
}

// Queue one texture upload through a pooled staging buffer (Private-texture
// path). `h` is in PIXELS; for BC formats the buffer holds (h+3)/4 block rows
// of `rowBytes` each. Takes a CF retain on the texture until the blit commits.
static void StageUpload(void* texture, const void* bytes, int w, int h, int rowBytes)
{
    MetalContext* ctx = s_uploadCtx;
    if (!ctx) return;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    const MTLPixelFormat pf = t.pixelFormat;
    const bool bc = (pf == MTLPixelFormatBC1_RGBA || pf == MTLPixelFormatBC2_RGBA ||
                     pf == MTLPixelFormatBC3_RGBA);
    const size_t rows  = bc ? (size_t)((h + 3) / 4) : (size_t)h;
    const size_t total = (size_t)rowBytes * rows;
    if (!total) return;
    void* sbuf = MetalContext_CreateBuffer(ctx, (unsigned)total);
    if (!sbuf) return;
    std::memcpy(MetalContext_BufferContents(sbuf), bytes, total);
    CFRetain(texture);
    size_t queued;
    {
        std::lock_guard<std::mutex> lk(ctx->poolMutex);
        ctx->pendingUploads.push_back(MetalContext::PendingUpload{ texture, sbuf, w, h, rowBytes });
        queued = ctx->pendingUploads.size();
    }
    // Load bursts upload hundreds of textures between Presents — flush in
    // chunks so staged buffers (and their CF refs) stay bounded.
    if (queued >= 64) FlushPendingUploads(ctx);
}

extern "C" void MetalContext_UploadTextureRaw(void* texture, int width, int height,
                                              const void* bytes, int bytesPerRow)
{
    if (!texture || !bytes || width <= 0 || height <= 0) return;
    // MTL_UPLOAD_SKIP=N (diagnostic): drop N of every N+1 uploads — if the
    // menu deviceAlloc slope scales down proportionally, the driver allocates
    // per-replaceRegion service memory it never returns.
    {
        static int s_skip = -2;
        if (s_skip == -2) { const char* e = getenv("MTL_UPLOAD_SKIP"); s_skip = e ? atoi(e) : 0; }
        if (s_skip > 0) { static unsigned long n = 0; if ((++n % (unsigned)(s_skip + 1)) != 0) return; }
    }
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        if (tex.storageMode == MTLStorageModePrivate) {
            StageUpload(texture, bytes, width, height, bytesPerRow);
            return;   // mips regenerate in the upload blit (FlushPendingUploads)
        }
        [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:bytes
               bytesPerRow:(NSUInteger)bytesPerRow];
        GenerateMips(tex);   // no-op unless tex was allocated with a mip chain
    }
}

extern "C" void MetalContext_ReleaseTexture(void* texture)
{
    if (!texture) return;
    // Route small uncompressed textures (the churny font/text glyph atlases) into
    // the frame-delayed recycle pool instead of freeing immediately: they are
    // re-created every frame, and Metal does not reclaim the freed backing fast
    // enough → a steady IOAccelerator leak. SweepRetiredTextures moves them to
    // texFree once the GPU finishes any frame still referencing them (capped
    // 256/key; excess is freed). CreateTextureFmt reuses them. Everything else
    // (large / BC / render-target textures) frees immediately, as before.
    MetalContext* ctx = s_uploadCtx;
    if (ctx) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
        if (TexPoolable(t.width, t.height, t.pixelFormat)) {
            ctx->texPushRelease.fetch_add(1, std::memory_order_relaxed);
            std::lock_guard<std::mutex> lk(ctx->poolMutex);
            ctx->texRetired.push_back(std::make_pair(texture, ctx->bufFrameId));
            return;   // CF ref transfers to the retire list
        }
    }
    DiagTexFree(texture);
    CFRelease(texture);
}

// Engine-side trapezoid-water tag (set in W3DWater.cpp drawTrapezoidWater
// around the Draw_Triangles call). Weak-linked so the shim still resolves if
// the engine TU is absent (tooling builds). Returns 0 if not present.
extern "C" int MetalDebug_InTrapezoidWater(void) __attribute__((weak));
// Live engine-held D3D buffer-wrapper counts (defined in dx8_device.cpp; weak
// so shim-only tooling builds still link). Printed in the MTL_POOL_LOG line.
extern "C" long MetalDiag_LiveVB8(void) __attribute__((weak));
extern "C" long MetalDiag_LiveIB8(void) __attribute__((weak));
static inline int MetalDebug_InTrapWater_Get(void) {
    return MetalDebug_InTrapezoidWater ? MetalDebug_InTrapezoidWater() : 0;
}


// Map D3D address mode (D3DTADDRESS_*) to Metal sampler address mode. D3D8:
// 1=WRAP, 2=MIRROR, 3=CLAMP, 4=BORDER, 5=MIRRORONCE. 0 (unset) → WRAP (default).
// Note: BORDER returns ClampToBorderColor (real border-color path); callers
// must also set sd.borderColor from D3DTSS_BORDERCOLOR. This matches DXMT's
// d3d11_state_object.cpp (BORDER → ClampToBorderColor, border_color picked
// from preset). Previously we returned ClampToZero which works only when
// the engine wanted transparent black.
static inline MTLSamplerAddressMode MapAddressMode(int d3dAddr)
{
    switch (d3dAddr) {
        case 3 /*CLAMP*/:        return MTLSamplerAddressModeClampToEdge;
        case 2 /*MIRROR*/:       return MTLSamplerAddressModeMirrorRepeat;
        case 4 /*BORDER*/:       return MTLSamplerAddressModeClampToBorderColor;
        case 5 /*MIRRORONCE*/:   return MTLSamplerAddressModeMirrorClampToEdge;
        case 1 /*WRAP*/:
        default:                 return MTLSamplerAddressModeRepeat;
    }
}

// Map D3DTEXTUREFILTERTYPE -> MTLSamplerMinMagFilter. Anisotropic falls back to
// linear; the engine's filter choice is what we care about for "POINT vs LINEAR".
static inline MTLSamplerMinMagFilter MapFilter(int d3dFilter, int legacy)
{
    if (d3dFilter == 1 /*D3DTEXF_POINT*/)  return MTLSamplerMinMagFilterNearest;
    if (d3dFilter == 2 /*D3DTEXF_LINEAR*/) return MTLSamplerMinMagFilterLinear;
    if (d3dFilter == 3 /*D3DTEXF_ANISOTROPIC*/) return MTLSamplerMinMagFilterLinear;
    // 0 / NONE / unset -> use legacy default
    return legacy ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
}

// Pick a Metal sampler border color from a packed D3D ARGB. Metal supports
// only three presets (TransparentBlack / OpaqueBlack / OpaqueWhite). Mirrors
// DXMT's d3d11_state_object.cpp:758-777 snapping logic — anything outside
// those three preset RGBA values falls back to TransparentBlack (the most
// common D3D BORDER intent: "anywhere off-texture, sample transparent").
static inline MTLSamplerBorderColor PickBorderColor(unsigned argb)
{
    uint8_t a = (argb >> 24) & 0xFF;
    uint8_t r = (argb >> 16) & 0xFF;
    uint8_t g = (argb >>  8) & 0xFF;
    uint8_t b = (argb      ) & 0xFF;
    if (r == 0xFF && g == 0xFF && b == 0xFF && a == 0xFF) return MTLSamplerBorderColorOpaqueWhite;
    if (r == 0    && g == 0    && b == 0    && a == 0xFF) return MTLSamplerBorderColorOpaqueBlack;
    return MTLSamplerBorderColorTransparentBlack;  // default for (0,0,0,0) and anything else
}

// Cached per-draw sampler keyed on (addressU/V, magFilter, minFilter, mipFilter,
// aniso-bucket, border-color-bucket). Promoted uint16→uint32 to fit the
// anisotropy + border-color dimensions added per DXMT's d3d11_state_object.cpp
// pattern. The legacy default (bilinear, no-mip, WRAP, no-aniso, transparent
// border) lands on key=0 and a single cached descriptor — no regression for
// engines that never set the new states.
static id<MTLSamplerState> GetSampler(MetalContext* ctx, const MetalDrawCall* dc)
{
    // Anisotropy bucket: log2(1/2/4/8/16) → 3 bits. 0 (engine unset) → bucket 0.
    int aniso = dc->maxAnisotropy;
    int anisoBucket = 0;
    if (aniso >= 16)     anisoBucket = 4;
    else if (aniso >= 8) anisoBucket = 3;
    else if (aniso >= 4) anisoBucket = 2;
    else if (aniso >= 2) anisoBucket = 1;
    // Border-color bucket: only relevant if either address is BORDER.
    int borderBucket = 0;
    if (dc->addressU == 4 /*BORDER*/ || dc->addressV == 4 /*BORDER*/) {
        switch (PickBorderColor(dc->borderColor)) {
            case MTLSamplerBorderColorTransparentBlack: borderBucket = 0; break;
            case MTLSamplerBorderColorOpaqueBlack:      borderBucket = 1; break;
            case MTLSamplerBorderColorOpaqueWhite:      borderBucket = 2; break;
        }
    }
    // 4 bits per address mode, 2 bits per filter, 3 bits for aniso, 2 for border.
    uint32_t key = (uint32_t)((dc->addressU & 0xF)
                            | ((dc->addressV   & 0xF) << 4)
                            | ((dc->magFilter  & 0x3) << 8)
                            | ((dc->minFilter  & 0x3) << 10)
                            | ((dc->mipFilter  & 0x3) << 12)
                            | ((anisoBucket    & 0x7) << 14)
                            | ((borderBucket   & 0x3) << 17));
    auto it = ctx->samplers.find(key);
    if (it != ctx->samplers.end()) return it->second;

    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter    = MapFilter(dc->minFilter, /*legacy*/1);
    sd.magFilter    = MapFilter(dc->magFilter, /*legacy*/1);
    // mipFilter D3DTEXF_NONE(0)/POINT(1)/LINEAR(2). Default no-mip.
    sd.mipFilter    = (dc->mipFilter == 2) ? MTLSamplerMipFilterLinear
                    : (dc->mipFilter == 1) ? MTLSamplerMipFilterNearest
                                           : MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode = MapAddressMode(dc->addressU);
    sd.tAddressMode = MapAddressMode(dc->addressV);
    // Anisotropy. Per DXMT pattern, only enable when the engine asked for
    // ANISOTROPIC explicitly on min OR mag filter — otherwise leave at 1 so
    // POINT/LINEAR draws don't pay the aniso fetch cost.
    bool wantsAniso = (dc->minFilter == 3 /*ANISOTROPIC*/) ||
                      (dc->magFilter == 3 /*ANISOTROPIC*/);
    if (wantsAniso && aniso > 1) {
        int clamped = aniso < 1 ? 1 : (aniso > 16 ? 16 : aniso);
        sd.maxAnisotropy = (NSUInteger)clamped;
    } else {
        sd.maxAnisotropy = 1;
    }
    // Border color only consulted by Metal when an address mode is
    // ClampToBorderColor. Apple Silicon supports this from macOS 12.
    if (dc->addressU == 4 /*BORDER*/ || dc->addressV == 4 /*BORDER*/) {
        sd.borderColor = PickBorderColor(dc->borderColor);
    }
    id<MTLSamplerState> smp = [ctx->device newSamplerStateWithDescriptor:sd];
    ctx->samplers[key] = smp;
    [sd release];
    return smp;
}

extern "C" void MetalDebug_DumpBGRA(const char* name, int width, int height,
                                    const void* bgra8, int bytesPerRow)
{
    if (!getenv("MTL_DUMPTEX") || !bgra8 || width <= 0 || height <= 0) return;
    @autoreleasepool {
        bool vis = getenv("MTL_DUMP_ALPHA") != nullptr;
        std::vector<uint8_t> rgba((size_t)width*height*4);
        const uint8_t* s = (const uint8_t*)bgra8;
        for (int y=0;y<height;++y) for (int x=0;x<width;++x){
            const uint8_t* sp = s + (size_t)y*bytesPerRow + x*4;
            uint8_t* dp = rgba.data() + ((size_t)y*width+x)*4;
            if (vis) { uint8_t a=sp[3]; dp[0]=a; dp[1]=a; dp[2]=a; dp[3]=255; }
            else { dp[0]=sp[2]; dp[1]=sp[1]; dp[2]=sp[0]; dp[3]=sp[3]; }
        }
        NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:width*4 bitsPerPixel:32] autorelease];
        memcpy([rep bitmapData], rgba.data(), rgba.size());
        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString* path = [NSString stringWithFormat:@"/tmp/%s.png", name];
        [png writeToFile:path atomically:YES];
    }
}

extern "C" void MetalContext_UploadTextureBGRA8(void* texture, int width, int height,
                                                const void* bgra8, int bytesPerRow)
{
    if (!texture || !bgra8 || width <= 0 || height <= 0) return;
    // MTL_UPLOAD_SKIP diagnostic — see MetalContext_UploadTextureRaw.
    {
        static int s_skip = -2;
        if (s_skip == -2) { const char* e = getenv("MTL_UPLOAD_SKIP"); s_skip = e ? atoi(e) : 0; }
        if (s_skip > 0) { static unsigned long n = 0; if ((++n % (unsigned)(s_skip + 1)) != 0) return; }
    }
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        if (tex.storageMode == MTLStorageModePrivate) {
            StageUpload(texture, bgra8, width, height, bytesPerRow);
            return;   // mips regenerate in the upload blit (FlushPendingUploads)
        }
        [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:bgra8
               bytesPerRow:(NSUInteger)bytesPerRow];
        GenerateMips(tex);   // build levels 1..N from the just-uploaded level 0

        // Debug: dump uploaded texture content to PNG (MTL_DUMP), capped.
        static int s_te = -1; if (s_te < 0) s_te = getenv("MTL_DUMPTEX") ? 1 : 0;
        if (s_te) {
            static int n = 0;
            if (n < 80) {
                int N = n++;
                std::vector<uint8_t> rgba((size_t)width*height*4);
                const uint8_t* s = (const uint8_t*)bgra8;
                bool vis = getenv("MTL_DUMP_ALPHA") != nullptr;
                for (int y=0;y<height;++y) for (int x=0;x<width;++x){
                    const uint8_t* sp = s + (size_t)y*bytesPerRow + x*4;
                    uint8_t* dp = rgba.data() + ((size_t)y*width+x)*4;
                    if (vis) { uint8_t a=sp[3]; dp[0]=a; dp[1]=a; dp[2]=a; dp[3]=255; } // alpha as luminance, opaque
                    else { dp[0]=sp[2]; dp[1]=sp[1]; dp[2]=sp[0]; dp[3]=sp[3]; }
                }
                NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                              colorSpaceName:NSDeviceRGBColorSpace
                                 bytesPerRow:width*4 bitsPerPixel:32] autorelease];
                memcpy([rep bitmapData], rgba.data(), rgba.size());
                NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString* path = [NSString stringWithFormat:@"/tmp/gen_tex_%02d_%p_%dx%d.png", N, texture, width, height];
                [png writeToFile:path atomically:YES];
            }
        }
    }
}

// Round an allocation up to a reuse bucket (next power of two, min 4 KiB) so that
// varying DrawPrimitiveUP sizes still hit the recycle pool instead of allocating
// a fresh MTLBuffer every draw. The buffer is oversized vs the request; the draw
// only reads stride*count ≤ request ≤ bucket, so the slack is harmless.
static unsigned BufferBucket(unsigned len)
{
    unsigned b = 4096;
    while (b < len) b <<= 1;
    return b;
}

// Move retired dynamic buffers whose frame the GPU has finished into the free
// pool for reuse. Command buffers complete in commit order, so bufCompletedFrame
// is monotonic and "retired frame ≤ completed frame" means the GPU is done with
// the buffer. Cheap; called once per Present. Buffers retired on a frame that was
// never committed (no drawable) self-heal here once any later frame completes.
static void SweepRetiredBuffers(MetalContext* ctx)
{
    if (!ctx) return;
    // Cap per free-bucket (mirrors SweepRetiredTextures): bounds a pathological
    // burst without steady-state frees. Steady state must NOT free at all —
    // every CFRelease of a pooled resource turns into "zombie" memory in the
    // driver's own never-shrinking pool while fresh creates take NEW device
    // memory (A/B-proved: periodic decay ratcheted device.currentAllocatedSize
    // ~13 MB/min in heavy battles; no-decay was FLAT at half the size).
    // Size-scaled (same reasoning as SweepRetiredTextures: a steady-state cap
    // hit = zombie factory; big buckets kept tight so bursts can't pin GBs).
    auto maxFreeForBucket = [](unsigned bytes) -> size_t {
        (void)bytes;
        return 256;
    };
    const uint64_t done = ctx->bufCompletedFrame.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(ctx->poolMutex);
    std::vector<std::pair<void*, uint64_t> >& r = ctx->bufRetired;
    for (size_t i = 0; i < r.size(); ) {
        if (r[i].second <= done) {
            void* b = r[i].first;
            unsigned bucket = (unsigned)[(__bridge id<MTLBuffer>)b length];
            std::vector<void*>& v = ctx->bufFree[bucket];
            if (v.size() < maxFreeForBucket(bucket)) v.push_back(b);
            else { ctx->bufOverflow.fetch_add(1, std::memory_order_relaxed); DiagBufFree(b); CFRelease(b); }
            r[i] = r.back(); r.pop_back();      // swap-remove
        } else {
            ++i;
        }
    }
}

extern "C" void* MetalContext_CreateBuffer(MetalContext* ctx, unsigned length)
{
    if (!ctx) return nullptr;
    if (length == 0) length = 1;
    const unsigned bucket = BufferBucket(length);
    // Reuse a recycled buffer of this bucket if one is free (the common path in
    // steady state — bounds allocations to the working set).
    {
        std::lock_guard<std::mutex> lk(ctx->poolMutex);
        std::unordered_map<unsigned, std::vector<void*> >::iterator it = ctx->bufFree.find(bucket);
        if (it != ctx->bufFree.end() && !it->second.empty()) {
            void* b = it->second.back();
            it->second.pop_back();
            return b;   // already CF-retained; ownership transfers to the caller
        }
    }
    @autoreleasepool {
        id<MTLBuffer> buf = [ctx->device newBufferWithLength:bucket
                                                     options:MTLResourceStorageModeShared];
        DiagBufAlloc(ctx, bucket);
        // MTL_BUF_TRACE=<minKB>: print a backtrace for every FRESH buffer
        // allocation of at least minKB (pool reuse doesn't reach here). This is
        // the same technique that pinned the font-texture churn leak — it names
        // the engine subsystem that keeps creating live buffers.
        {
            static int s_trace = -2;
            if (s_trace == -2) { const char* e = getenv("MTL_BUF_TRACE"); s_trace = e ? atoi(e) : -1; }
            if (s_trace >= 0 && bucket >= (unsigned)s_trace * 1024u) {
                static std::atomic<long> s_n(0);
                long n = s_n.fetch_add(1, std::memory_order_relaxed);
                if ((n % 16) == 0) {
                    fprintf(stderr, "[buftrace] #%ld fresh %u KB\n", n, bucket / 1024);
                    void* frames[24];
                    int cnt = backtrace(frames, 24);
                    backtrace_symbols_fd(frames, cnt, 2);
                    fflush(stderr);
                }
            }
        }
        return (void*)CFBridgingRetain(buf);
    }
}

// Retire a dynamic buffer that was just handed to a draw (a DISCARD orphan or a
// DrawPrimitiveUP temp). The caller's CF ref transfers here; the buffer stays
// alive and is recycled once the GPU finishes the current frame. This replaces an
// immediate MetalContext_ReleaseBuffer at the draw sites.
extern "C" void MetalContext_RetireBuffer(MetalContext* ctx, void* buffer)
{
    if (!buffer) return;
    if (!ctx) { CFRelease(buffer); return; }
    std::lock_guard<std::mutex> lk(ctx->poolMutex);
    ctx->bufRetired.push_back(std::make_pair(buffer, ctx->bufFrameId));
}

// ---------------------------------------------------------------------------
// Dynamic-texture rename pool (see the texFree/texRetired field comment in
// MetalContext for the race this fixes — the menu "black texture flicker").
// ---------------------------------------------------------------------------

// Pool bucket key: textures are interchangeable iff every descriptor field the
// pool copies matches. width/height fit 14 bits (max 16384 — beyond any D3D8
// texture the engine creates), pixelFormat 16 bits, mip count 8, usage 8.
static uint64_t TexPoolKey(id<MTLTexture> t)
{
    return TexKeyFields(t.width, t.height, (unsigned)t.pixelFormat,
                        t.mipmapLevelCount, (unsigned)t.usage);
}

// Move retired textures whose frame the GPU has finished into the free pool.
// Same correctness argument as SweepRetiredBuffers: command buffers complete
// in commit order, so "retired frame <= completed frame" means no in-flight
// command buffer can still be sampling the texture.
static void SweepRetiredTextures(MetalContext* ctx)
{
    if (!ctx) return;
    // Flat cap 256/key — the empirically good configuration (in-game plateau
    // 1.1-1.3 GB). Deeper/uncapped pools and size-scaled variants were tried
    // for the CWC-menu leak and changed nothing (see plan Round 3).
    auto maxFreeForTex = [](id<MTLTexture> t) -> size_t {
        (void)t;
        return 256;
    };
    const uint64_t done = ctx->bufCompletedFrame.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(ctx->poolMutex);
    std::vector<std::pair<void*, uint64_t> >& r = ctx->texRetired;
    for (size_t i = 0; i < r.size(); ) {
        if (r[i].second <= done) {
            void* t = r[i].first;
            std::vector<void*>& bucket = ctx->texFree[TexPoolKey((__bridge id<MTLTexture>)t)];
            if (bucket.size() < maxFreeForTex((__bridge id<MTLTexture>)t)) bucket.push_back(t);
            else {
                // MTL_POOL_LOG=1: an overflow here in STEADY STATE means the
                // create side isn't reusing this key (key mismatch) — each
                // overflow CFRelease becomes driver-zombie memory.
                static int s_lg = -1; if (s_lg < 0) s_lg = getenv("MTL_POOL_LOG") ? 1 : 0;
                if (s_lg) { static unsigned long n=0; if ((++n % 64) == 1) {
                    id<MTLTexture> tt = (__bridge id<MTLTexture>)t;
                    fprintf(stderr, "[tex-overflow] #%lu %lux%lu pf=%lu mips=%lu usage=0x%lx\n",
                            n, (unsigned long)tt.width, (unsigned long)tt.height,
                            (unsigned long)tt.pixelFormat, (unsigned long)tt.mipmapLevelCount,
                            (unsigned long)tt.usage); fflush(stderr); } }
                ctx->texOverflow.fetch_add(1, std::memory_order_relaxed);
                DiagTexFree(t); CFRelease(t);
            }
            r[i] = r.back(); r.pop_back();      // swap-remove
        } else {
            ++i;
        }
    }
}

// Periodic pool decay — DEFAULT OFF, opt-in via MTL_POOL_DECAY=1 (A/B only).
// The first cut of the "+200 MB stays after leaving a match" fix released 1/4
// of each free bucket every 256 frames. A/B against device.currentAllocatedSize
// proved that CURE was the residual leak: every CFRelease of a pooled resource
// becomes a "zombie" backing in the driver's own never-shrinking pool while
// the next create takes NEW device memory — decay ON ratcheted deviceAlloc
// ~13 MB/min in heavy battles, decay OFF was FLAT at roughly HALF the total.
// Correct policy: never free in steady state (pools plateau at the working
// set and get reused — original-game behavior); bound pathological bursts via
// the per-bucket caps in SweepRetiredBuffers/SweepRetiredTextures instead.
static void DecayPools(MetalContext* ctx)
{
    if (!ctx) return;
    static int on = -1;
    if (on < 0) on = getenv("MTL_POOL_DECAY") ? 1 : 0;
    if (!on) return;
    const long kDecayInterval = 256;
    if ((ctx->frameIndex % kDecayInterval) != 0 || ctx->frameIndex == 0) return;
    std::lock_guard<std::mutex> lk(ctx->poolMutex);
    for (auto it = ctx->bufFree.begin(); it != ctx->bufFree.end(); ) {
        std::vector<void*>& v = it->second;
        for (size_t n = (v.size() + 3) / 4; n > 0 && !v.empty(); --n) {
            DiagBufFree(v.back());
            CFRelease(v.back());
            v.pop_back();
        }
        it = v.empty() ? ctx->bufFree.erase(it) : ++it;
    }
    for (auto it = ctx->texFree.begin(); it != ctx->texFree.end(); ) {
        std::vector<void*>& v = it->second;
        for (size_t n = (v.size() + 3) / 4; n > 0 && !v.empty(); --n) {
            DiagTexFree(v.back());
            CFRelease(v.back());
            v.pop_back();
        }
        it = v.empty() ? ctx->texFree.erase(it) : ++it;
    }
}

extern "C" void* MetalContext_RenameTexture(void* oldTexture)
{
    if (!oldTexture) return nullptr;
    static int off = -1;
    if (off < 0) off = getenv("MTL_NO_TEX_RENAME") ? 1 : 0;
    MetalContext* ctx = s_uploadCtx;
    if (off || !ctx) return oldTexture;   // legacy in-place replaceRegion (A/B switch)
    @autoreleasepool {
        id<MTLTexture> old = (__bridge id<MTLTexture>)oldTexture;
        const uint64_t key = TexPoolKey(old);
        void* fresh = nullptr;
        std::unique_lock<std::mutex> poolLk(ctx->poolMutex);
        std::unordered_map<uint64_t, std::vector<void*> >::iterator it = ctx->texFree.find(key);
        if (it != ctx->texFree.end() && !it->second.empty()) {
            fresh = it->second.back();
            it->second.pop_back();          // already CF-retained; ownership -> caller
            ctx->texPullRename.fetch_add(1, std::memory_order_relaxed);
        } else {
            poolLk.unlock();   // texture allocation below is slow; re-lock for the retire push
            MTLTextureDescriptor* desc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:old.pixelFormat
                                                                   width:old.width
                                                                  height:old.height
                                                               mipmapped:NO];
            desc.mipmapLevelCount = old.mipmapLevelCount;
            desc.usage            = old.usage;
            desc.storageMode      = old.storageMode;
            id<MTLTexture> t = [ctx->device newTextureWithDescriptor:desc];
            if (!t) return oldTexture;      // allocation failure: fall back in-place
            DiagTexAlloc(ctx, t);
            ctx->texMissRename.fetch_add(1, std::memory_order_relaxed);
            { static int lg = -1; if (lg < 0) lg = getenv("MTL_POOL_LOG") ? 1 : 0;
              if (lg) { static unsigned long n=0; if ((++n % 64) == 1) {
                fprintf(stderr, "[ren-miss] #%lu %lux%lu pf=%lu mips=%lu usage=0x%lx key=%llx\n",
                        n, (unsigned long)old.width, (unsigned long)old.height,
                        (unsigned long)old.pixelFormat, (unsigned long)old.mipmapLevelCount,
                        (unsigned long)old.usage, (unsigned long long)key); fflush(stderr); } } }
            fresh = (void*)CFBridgingRetain(t);
            [t release];                    // MRC: new(+1) + bridge(+1) -> pool owns exactly one
        }
        // Park the old texture until the GPU finishes every frame that may
        // still reference it (the caller's CF reference transfers here).
        if (!poolLk.owns_lock()) poolLk.lock();
        ctx->texPushRename.fetch_add(1, std::memory_order_relaxed);
        ctx->texRetired.push_back(std::make_pair(oldTexture, ctx->bufFrameId));
        poolLk.unlock();
        static int logOn = -1;
        if (logOn < 0) logOn = getenv("MTL_RENAME_LOG") ? 1 : 0;
        if (logOn) {
            static unsigned long renames = 0;
            if ((++renames % 256) == 1) {
                size_t pooled = 0;
                for (std::unordered_map<uint64_t, std::vector<void*> >::iterator pit = ctx->texFree.begin(); pit != ctx->texFree.end(); ++pit)
                    pooled += pit->second.size();
                fprintf(stderr, "[tex-rename] #%lu %lux%lu fmt=%lu pool: free=%zu retired=%zu\n",
                        renames, (unsigned long)old.width, (unsigned long)old.height,
                        (unsigned long)old.pixelFormat, pooled, ctx->texRetired.size());
                fflush(stderr);
            }
        }
        return fresh;
    }
}

extern "C" void* MetalContext_BufferContents(void* buffer)
{
    if (!buffer) return nullptr;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    return [buf contents];
}

extern "C" void MetalContext_ReleaseBuffer(void* buffer)
{
    if (!buffer) return;
    DiagBufFree(buffer);
    CFRelease(buffer);
}

// --- Input pollers (Stage 3) ---------------------------------------------
extern "C" int MetalInput_PollMouse(int* type, int* x, int* y, int* delta)
{
    if (g_mouseQ.empty()) return 0;
    MouseEv m = g_mouseQ.front(); g_mouseQ.pop_front();
    if (type)  *type  = m.type;
    if (x)     *x     = m.x;
    if (y)     *y     = m.y;
    if (delta) *delta = m.delta;
    return 1;
}

extern "C" int MetalInput_PollKey(int* macKeyCode, int* down)
{
    if (g_keyQ.empty()) return 0;
    KeyEv k = g_keyQ.front(); g_keyQ.pop_front();
    if (macKeyCode) *macKeyCode = k.macKeyCode;
    if (down)       *down       = k.down;
    return 1;
}

extern "C" int MetalInput_CapsOn(void) { return g_capsOn ? 1 : 0; }

extern "C" int MetalInput_PollChar(unsigned int* outChar)
{
    if (g_charQ.empty()) return 0;
    unsigned int c = g_charQ.front(); g_charQ.pop_front();
    if (outChar) *outChar = c;
    return 1;
}

// ---------------------------------------------------------------------------
// Cursor hide/show counter (mirrors Win32 ShowCursor semantics).
// ---------------------------------------------------------------------------
static int g_cursorShowCounter = 0;
static bool g_cursorHidden     = false;

extern "C" int MetalCursor_Show(int show)
{
    int prev = g_cursorShowCounter;
    g_cursorShowCounter = show ? (prev + 1) : (prev - 1);
    bool shouldBeHidden = (g_cursorShowCounter < 0);
    if (shouldBeHidden != g_cursorHidden) {
        @autoreleasepool {
            if (shouldBeHidden) {
                [NSCursor hide];
            } else {
                // Explicitly set the arrow as the active cursor and unhide.
                // [NSCursor unhide] alone is not always enough — the OS may
                // restore the last app-set cursor or leave the cursor in an
                // ambiguous state if no tracking area / cursorUpdate handler
                // ever set one. Setting the arrow explicitly forces a
                // visible system cursor while we wait for proper engine-
                // cursor rendering (RM_POLYGON / RM_W3D need shipped
                // assets that the macOS port does not yet have).
                [[NSCursor arrowCursor] set];
                [NSCursor unhide];
            }
        }
        g_cursorHidden = shouldBeHidden;
    }
    return g_cursorShowCounter;
}

extern "C" int MetalCursor_WarpClient(int clientX, int clientY)
{
    if (!g_inputView || !g_inputView.window) return 0;
    @autoreleasepool {
        // 1) client pixels (top-left origin) -> view-local points (bottom-left origin).
        //    On the active path drawableSize == bounds.size (no Retina up-scale),
        //    so client pixels and view points are 1:1.
        CGFloat h = g_inputView.bounds.size.height;
        NSPoint viewPt = NSMakePoint((CGFloat)clientX, h - (CGFloat)clientY);
        // 2) view-local -> window-base (identity if view is the contentView).
        NSPoint winPt = [g_inputView convertPoint:viewPt toView:nil];
        // 3) window-base -> screen (NSWindow API; macOS 10.7+).
        NSRect winRect  = [g_inputView.window convertRectToScreen:NSMakeRect(winPt.x, winPt.y, 0, 0)];
        NSPoint screen  = winRect.origin;
        // 4) NSScreen origin is bottom-left of main screen; CGWarpMouseCursorPosition
        //    takes top-left-origin screen pixels. Flip Y using the main screen height.
        NSScreen* main  = [[NSScreen screens] firstObject];
        CGFloat   sH    = main ? main.frame.size.height : 0.0;
        CGPoint cgPt    = CGPointMake(screen.x, sH - screen.y);
        CGWarpMouseCursorPosition(cgPt);
        // Re-associate cursor and mouse so the next motion event uses the warped pos.
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    return 1;
}

// Stage 6: minimal draw routine for the shadow pass. Reuses vs_main (with
// shadowPass=1 so it emits lightVP*world*pos), binds shadowDS, draws into
// the shadow map. No fragment uniforms or texture bindings — fragment is
// `shadow_fs` (void) and there's no color attachment.
static void DrawShadowPass(MetalContext* ctx, const MetalDrawCall* dc)
{
    @autoreleasepool {
        if (!ctx->shadowEnc) return;
        id<MTLRenderPipelineState> ps = GetShadowPipeline(ctx, dc);
        if (!ps) return;
        id<MTLBuffer> vb = (__bridge id<MTLBuffer>)dc->vertexBuffer;

        [ctx->shadowEnc setRenderPipelineState:ps];
        [ctx->shadowEnc setVertexBuffer:vb offset:0 atIndex:0];

        UniformsCPU u;
        std::memset(&u, 0, sizeof(u));
        std::memcpy(u.mvp,      dc->mvp,      sizeof(float) * 16);
        std::memcpy(u.world,    dc->world,    sizeof(float) * 16);
        std::memcpy(u.lightVP,  ctx->lightVP, sizeof(float) * 16);
        u.posFloats   = dc->posFloats;
        u.shadowPass  = 1;
        u.hasDiffuse  = (dc->diffuseOffset >= 0) ? 1 : 0;
        u.hasNormal   = (dc->normalOffset  >= 0) ? 1 : 0;
        [ctx->shadowEnc setVertexBytes:&u length:sizeof(u) atIndex:1];

        [ctx->shadowEnc setDepthStencilState:ctx->shadowDS];
        [ctx->shadowEnc setFrontFacingWinding:MTLWindingClockwise];
        // Cull BACK faces (Z-pass-Z-fail with the depth-LESS comparison) so
        // we capture front-facing geometry depth. D3D's terrain/units are
        // typically rendered with CW front, which Metal sees as front-facing
        // under MTLWindingClockwise. Same default as the main pass.
        MTLCullMode cull = MTLCullModeNone;
        if (dc->cullMode == 2 /*D3DCULL_CW*/)        cull = MTLCullModeFront;
        else if (dc->cullMode == 3 /*D3DCULL_CCW*/)  cull = MTLCullModeBack;
        [ctx->shadowEnc setCullMode:cull];

        MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
        if (dc->primType == 5 /*TRISTRIP*/) prim = MTLPrimitiveTypeTriangleStrip;
        else if (dc->primType == 6 /*TRIFAN*/) return;

        if (dc->indexBuffer) {
            id<MTLBuffer> ib = (__bridge id<MTLBuffer>)dc->indexBuffer;
            [ctx->shadowEnc drawIndexedPrimitives:prim
                                        indexCount:dc->indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:ib
                                 indexBufferOffset:dc->indexOffsetBytes
                                     instanceCount:1
                                        baseVertex:dc->baseVertex
                                      baseInstance:0];
        } else {
            [ctx->shadowEnc drawPrimitives:prim
                               vertexStart:dc->vertexStart
                               vertexCount:dc->vertexCount];
        }
    }
}

extern "C" void MetalContext_Draw(MetalContext* ctx, const MetalDrawCall* dc)
{
    if (!ctx || !dc || !dc->vertexBuffer) return;
    if (dc->posOffset < 0) return;          // POSITION is required; others optional
    if (!ctx->vsFn || !ctx->fsFn) return;

    // Stage 6: route to the dedicated depth-only shadow draw when the engine
    // is currently inside a Begin/EndShadowPass bracket. 2D (XYZRHW) draws
    // don't cast shadows — skip them so the HUD/cursor/control-bar doesn't
    // pollute the shadow map.
    if (ctx->shadowPassActive) {
        if (dc->posFloats != 3) return;
        DrawShadowPass(ctx, dc);
        return;
    }

    // Debug: optionally drop the terrain FVF to test what covers the screen.
    { static int s_skip3d = -1; if (s_skip3d < 0) s_skip3d = getenv("MTL_SKIP3D") ? 1 : 0;
      if (s_skip3d && dc->fvf == 0x242) return; }
    // Debug: drop the blend-DISABLED water pass (fvf 0x252) to test if it's the
    // shellmap "black grid" (the depth-writing pass-2 of the FF water).
    { static int s_nwp2 = -1; if (s_nwp2 < 0) s_nwp2 = getenv("MTL_WATER_NOPASS2") ? 1 : 0;
      if (s_nwp2 && dc->fvf == 0x252 && !dc->blendEnable) return; }

    @autoreleasepool {
        if (!EnsureEncoder(ctx)) return;

        // Honour the engine's per-draw D3D viewport (stored by
        // dx8_device.cpp::SetViewport into dc->vp*). Must come AFTER
        // EnsureEncoder so the encoder exists. Without this, every draw uses
        // whatever viewport was last bound (boot default = full ctx), and
        // engine-requested narrower viewports for the tactical scene get
        // silently ignored — which manifests as health bars / HUD overlays
        // floating away from units in pixel-Y proportional to camera tilt.
        ApplyViewportIfChanged(ctx, dc->vpX, dc->vpY, dc->vpW, dc->vpH);

        // Debug: MTL_SHADOW_VOL_VIZ=1 forces colour writes ON for stencil
        // volume INCR/DECR/DECRSAT/INCRSAT draws so the volume mesh itself is
        // visible in the framebuffer. Lets us see WHERE the volume extrudes
        // (and its winding) without relying on the darken pass actually
        // working. Mutates the const dc only for the writes-on bit so the
        // pipeline cache picks the writeOn=1 variant.
        { static int s_volViz = -1;
          if (s_volViz < 0) s_volViz = getenv("MTL_SHADOW_VOL_VIZ") ? 1 : 0;
          if (s_volViz && dc->stencilEnable && dc->colorWriteMask == 0 &&
              (dc->stencilPass == 4 || dc->stencilPass == 5 ||
               dc->stencilPass == 7 || dc->stencilPass == 8)) {
              const_cast<MetalDrawCall*>(dc)->colorWriteMask = 7;
          } }

        id<MTLRenderPipelineState> ps = GetPipeline(ctx, dc);
        if (!ps) return;

        id<MTLBuffer>  vb  = (__bridge id<MTLBuffer>)dc->vertexBuffer;
        id<MTLTexture> tex = dc->texture ? (__bridge id<MTLTexture>)dc->texture : ctx->whiteTex;

        // ---- DECAL DIAGNOSTIC (gated, harmless when off) ------------------
        // MTL_DECAL_LOG=1 : print FVF=0x142 (XYZ|DIFFUSE|TEX1 = W3D shadow
        // decal) draw state for the first few draws of each frame: texture
        // pointer, dimensions, blend, TSS combiner, sample-vertex UVs.
        // MTL_DECAL_WHITETEX=1 : substitute the bound texture with whiteTex
        // for FVF=0x142 draws. If the rendered decal goes GREY instead of
        // black, the texture content is the bug (not blending / not UVs).
        //
        // NB: this catches tree billboards too (same FVF). For
        // shadow-decal-only filtering, restore the engine-side
        // MetalDebug_DecalPass_Begin/End marker (per Debug-first rule).
        { static int s_dlog = -1; if (s_dlog < 0) s_dlog = getenv("MTL_DECAL_LOG") ? 1 : 0;
          static int s_dwt  = -1; if (s_dwt  < 0) s_dwt  = getenv("MTL_DECAL_WHITETEX") ? 1 : 0;
          if (dc->fvf == 0x142) {
              if (s_dwt) tex = ctx->whiteTex;
              if (s_dlog) {
                  static long s_lastF = -1; static int s_perF = 0;
                  if (ctx->frameIndex != s_lastF) { s_lastF = ctx->frameIndex; s_perF = 0; }
                  if (s_perF++ < 6) {
                      id<MTLTexture> realT = dc->texture ? (__bridge id<MTLTexture>)dc->texture : nil;
                      const unsigned char* base = (const unsigned char*)vb.contents;
                      // SHADOW_DECAL_VERTEX layout: x y z (12) | DWORD diffuse (4) | u v (8) = 24
                      const float* v0 = (const float*)(base + (size_t)dc->baseVertex*dc->stride);
                      const uint32_t* d0 = (const uint32_t*)(base + (size_t)dc->baseVertex*dc->stride + dc->diffuseOffset);
                      const float* uv0 = (const float*)(base + (size_t)dc->baseVertex*dc->stride + dc->tex0Offset);
                      fprintf(stderr,
                          "[decal f%ld #%d] tex=%p sz=%lux%lu fmt=%lu blend=%d,%d,%d "
                          "zEn=%d zW=%d alphaT=%d cull=%d colorOp=%d arg1=%d arg2=%d alphaOp=%d "
                          "stride=%u posOff=%d diffOff=%d uvOff=%d nVtx=%u idxCount=%u "
                          "v0=(%.1f,%.1f,%.1f) diff0=0x%08x uv0=(%.3f,%.3f)\n",
                          ctx->frameIndex, s_perF,
                          realT, realT ? (unsigned long)realT.width : 0,
                          realT ? (unsigned long)realT.height : 0,
                          realT ? (unsigned long)realT.pixelFormat : 0,
                          dc->blendEnable, dc->srcBlend, dc->destBlend,
                          dc->zEnable, dc->zWriteEnable, dc->alphaTestEnable, dc->cullMode,
                          dc->colorOp, dc->colorArg1, dc->colorArg2, dc->alphaOp,
                          dc->stride, dc->posOffset, dc->diffuseOffset, dc->tex0Offset,
                          dc->vertexCount, dc->indexCount,
                          v0[0], v0[1], v0[2], *d0, uv0[0], uv0[1]);
                      // Read back texture content — Apple Silicon GPUs are
                      // shared-memory, so a Shared/Managed texture's
                      // getBytes works. For BC-compressed textures, blit
                      // them to a temporary BGRA8 staging texture so we
                      // get fully decoded RGBA we can dump and analyse.
                      if (realT && s_perF <= 2 && realT.storageMode != MTLStorageModePrivate) {
                          NSUInteger w = realT.width, h = realT.height;
                          MTLPixelFormat pf = realT.pixelFormat;
                          @try {
                              if (pf >= 130 && pf <= 135) {
                                  // Read raw compressed bytes
                                  size_t blocksX = (w + 3) / 4;
                                  size_t blocksY = (h + 3) / 4;
                                  size_t blockSize = (pf == 130 || pf == 131) ? 8 : 16;  // BC1=8B, BC2/3=16B
                                  size_t rowB = blocksX * blockSize;
                                  std::vector<uint8_t> raw(blocksX * blocksY * blockSize);
                                  [realT getBytes:raw.data() bytesPerRow:rowB fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
                                  // Decode to BGRA8 — only BC3 (DXT5) here, simplified.
                                  std::vector<uint8_t> rgba8(w * h * 4);
                                  auto u16 = [](const uint8_t* p) -> uint16_t { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); };
                                  auto rgb565to8 = [](uint16_t c, uint8_t* out) {
                                      out[2] = (uint8_t)(((c >> 11) & 31) * 255 / 31);
                                      out[1] = (uint8_t)(((c >> 5)  & 63) * 255 / 63);
                                      out[0] = (uint8_t)((c & 31) * 255 / 31);
                                  };
                                  for (size_t by = 0; by < blocksY; ++by) {
                                      for (size_t bx = 0; bx < blocksX; ++bx) {
                                          const uint8_t* blk = raw.data() + (by * blocksX + bx) * blockSize;
                                          // alpha block first (8 bytes)
                                          uint8_t a[8];
                                          a[0] = blk[0]; a[1] = blk[1];
                                          if (a[0] > a[1]) {
                                              for (int i = 1; i < 7; ++i) a[i+1] = (uint8_t)(((7-i)*a[0] + i*a[1]) / 7);
                                          } else {
                                              for (int i = 1; i < 5; ++i) a[i+1] = (uint8_t)(((5-i)*a[0] + i*a[1]) / 5);
                                              a[6] = 0; a[7] = 255;
                                          }
                                          uint64_t aIdx = 0;
                                          for (int i = 0; i < 6; ++i) aIdx |= ((uint64_t)blk[2+i]) << (i*8);
                                          // color block (8 bytes)
                                          const uint8_t* cb_ = blk + 8;
                                          uint16_t c0 = u16(cb_), c1 = u16(cb_+2);
                                          uint8_t col[4][4];
                                          rgb565to8(c0, col[0]); rgb565to8(c1, col[1]);
                                          for (int ch = 0; ch < 3; ++ch) {
                                              col[2][ch] = (uint8_t)((2*col[0][ch] + col[1][ch]) / 3);
                                              col[3][ch] = (uint8_t)((col[0][ch] + 2*col[1][ch]) / 3);
                                          }
                                          uint32_t cIdx = (uint32_t)cb_[4] | ((uint32_t)cb_[5] << 8) | ((uint32_t)cb_[6] << 16) | ((uint32_t)cb_[7] << 24);
                                          for (int py = 0; py < 4; ++py) for (int px = 0; px < 4; ++px) {
                                              size_t xx = bx*4 + px, yy = by*4 + py;
                                              if (xx >= w || yy >= h) continue;
                                              int aSlot = (int)((aIdx >> (3*(py*4+px))) & 7);
                                              int cSlot = (int)((cIdx >> (2*(py*4+px))) & 3);
                                              uint8_t* dst = rgba8.data() + (yy*w + xx)*4;
                                              dst[0] = col[cSlot][0]; // B
                                              dst[1] = col[cSlot][1]; // G
                                              dst[2] = col[cSlot][2]; // R
                                              dst[3] = a[aSlot];
                                          }
                                      }
                                  }
                                  // Dump as raw RGBA bytes
                                  char fname[256]; snprintf(fname, sizeof(fname), "/tmp/decal_tex_%p_%lux%lu.rgba", realT, (unsigned long)w, (unsigned long)h);
                                  FILE* f = fopen(fname, "wb"); if (f) { fwrite(rgba8.data(), 1, rgba8.size(), f); fclose(f); }
                                  // Stats: min/max alpha + mean RGB
                                  int amin = 255, amax = 0, asum = 0; int rsum=0, gsum=0, bsum=0;
                                  size_t N = w * h;
                                  for (size_t i = 0; i < N; ++i) {
                                      bsum += rgba8[i*4+0]; gsum += rgba8[i*4+1]; rsum += rgba8[i*4+2];
                                      int aa = rgba8[i*4+3];
                                      asum += aa; if (aa<amin) amin=aa; if (aa>amax) amax=aa;
                                  }
                                  fprintf(stderr, "  tex(BC3 %lux%lu) decoded: alpha min=%d max=%d mean=%d  rgb_mean=(%d,%d,%d)  dump=%s\n",
                                          (unsigned long)w, (unsigned long)h, amin, amax, (int)(asum/N),
                                          (int)(rsum/N), (int)(gsum/N), (int)(bsum/N), fname);
                              }
                          } @catch (NSException* e) {
                              fprintf(stderr, "  tex readback failed: %s\n", e.reason.UTF8String);
                          }
                      }
                      fflush(stderr);
                  }
              }
          } }
        // -------------------------------------------------------------------

        if (ps != ctx->boundPS) { [ctx->enc setRenderPipelineState:ps]; ctx->boundPS = ps; }
        if (vb != ctx->boundVB) { [ctx->enc setVertexBuffer:vb offset:0 atIndex:0]; ctx->boundVB = vb; }

        // Build the vertex uniform block (transforms + FF lighting).
        UniformsCPU u;
        std::memcpy(u.mvp,      dc->mvp,      sizeof(float) * 16);
        std::memcpy(u.world,    dc->world,    sizeof(float) * 16);
        std::memcpy(u.view,     dc->view,     sizeof(float) * 16);
        std::memcpy(u.texXform, dc->texXform, sizeof(float) * 16);
        std::memcpy(u.lightVP,  ctx->lightVP, sizeof(float) * 16);
        u.tciMode       = dc->tciMode;
        u.texXformCount = dc->texXformCount;
        u.posFloats     = dc->posFloats;
        u.shadowPass    = 0;
        // Only sample the shadow map on XYZ geometry (3D scene). XYZRHW
        // (HUD/cursor) lives in screen space and has no world position to
        // light-transform — bypass sampling there.
        u.shadowEnable  = (ctx->shadowsEnabled && dc->posFloats == 3) ? 1 : 0;
        u._pad0 = u._pad1 = u._pad2 = u._pad3 = 0;
        // Viewport pixel size for the XYZRHW screen→NDC formula in vs_main.
        // Must be the CURRENT D3D viewport (the engine's per-draw Set_Viewport
        // value), not the full context size — XYZRHW pixel coords are written
        // by the engine assuming whatever viewport is active. Matches DXVK's
        // d3d9_fixed_function.cpp invExtent treatment.
        u.viewportSize[0] = (float)(dc->vpW > 0 ? dc->vpW : ctx->width);
        u.viewportSize[1] = (float)(dc->vpH > 0 ? dc->vpH : ctx->height);
        u._padVP[0] = u._padVP[1] = 0.0f;
        std::memcpy(u.matDiffuse,    dc->matDiffuse,    sizeof(float) * 4);
        std::memcpy(u.matAmbient,    dc->matAmbient,    sizeof(float) * 4);
        std::memcpy(u.matEmissive,   dc->matEmissive,   sizeof(float) * 4);
        std::memcpy(u.globalAmbient, dc->globalAmbient, sizeof(float) * 4);
        u.lightingEnable = dc->lightingEnable;
        u.hasDiffuse     = (dc->diffuseOffset >= 0) ? 1 : 0;
        u.hasNormal      = (dc->normalOffset  >= 0) ? 1 : 0;
        u.numLights      = (dc->numLights > 8) ? 8 : dc->numLights;
        u.diffuseSource  = dc->diffuseSource;
        u.ambientSource  = dc->ambientSource;
        u.emissiveSource = dc->emissiveSource;
        // tciMode/texXformCount/_pad0..2 were already set above (next to the
        // view/texXform memcpys); nothing more to do for the per-stage TCI block.
        for (int i = 0; i < 8; ++i) {
            GpuLightCPU& g = u.lights[i];
            std::memset(&g, 0, sizeof(g));
            if (i < u.numLights) {
                const MetalLight& s = dc->lights[i];
                g.diffuse[0]=s.diffuse[0]; g.diffuse[1]=s.diffuse[1]; g.diffuse[2]=s.diffuse[2]; g.diffuse[3]=s.diffuse[3];
                g.ambient[0]=s.ambient[0]; g.ambient[1]=s.ambient[1]; g.ambient[2]=s.ambient[2]; g.ambient[3]=s.ambient[3];
                g.position[0]=s.position[0]; g.position[1]=s.position[1]; g.position[2]=s.position[2]; g.position[3]=1.0f;
                g.direction[0]=s.direction[0]; g.direction[1]=s.direction[1]; g.direction[2]=s.direction[2]; g.direction[3]=0.0f;
                g.atten[0]=s.atten[0]; g.atten[1]=s.atten[1]; g.atten[2]=s.atten[2]; g.atten[3]=(float)s.type;
            }
        }
        [ctx->enc setVertexBytes:&u length:sizeof(u) atIndex:1];

        if (ctx->dbg < 0) ctx->dbg = getenv("MTL_DEBUG") ? 1 : 0;
        // One-shot per-fvf depth snapshot to bisect "water over everything" issue.
        { static int s_zd = -1; if (s_zd < 0) s_zd = getenv("MTL_ZDUMP") ? 1 : 0;
          if (s_zd && ctx->frameIndex > 500) {
            static unsigned seen[4096] = {0};
            unsigned k = (unsigned)dc->fvf & 0xfff;
            if (!seen[k]) { seen[k] = 1;
              fprintf(stderr, "[zdump] fvf=0x%03x zEn=%d zW=%d zF=%d blend=%d,%d,%d cull=%d\n",
                      dc->fvf, dc->zEnable, dc->zWriteEnable, dc->zFunc,
                      dc->blendEnable, dc->srcBlend, dc->destBlend, dc->cullMode);
              fflush(stderr);
            }
          } }

        // Water-geometry probe: dump the first vertices + indices the shim
        // actually receives for the trapezoid-water path. Gated on the engine-
        // side flag MetalDebug_InTrapezoidWater() (1 only inside the
        // drawTrapezoidWater Draw_Triangles call) so river-water draws (same
        // FVF 0x252) don't win the race. MTL_WATERGEOM=1.
        { static int s_wg = -1; if (s_wg < 0) s_wg = getenv("MTL_WATERGEOM") ? 1 : 0;
          int inTrap = MetalDebug_InTrapWater_Get();
          if (s_wg && dc->fvf == 0x252 && inTrap && ctx->frameIndex > 500) {
            static int s_n = 0; if (s_n < 4) { ++s_n;
            const unsigned char* base = (const unsigned char*)vb.contents;
            // Find diffuse offset for trapezoid water (FVF 0x252 = XYZ|NORMAL|DIFFUSE|TEX2)
            int diffOff = dc->diffuseOffset;
            int uvOff   = dc->tex0Offset;
            fprintf(stderr, "[trapgeom #%d] stride=%u posOff=%d diffOff=%d uvOff=%d nVtx=%u idxCount=%u idxOffB=%u baseV=%d prim=%u blend=%d,%d,%d zEn=%d zW=%d cull=%d\n",
                    s_n, dc->stride, dc->posOffset, diffOff, uvOff,
                    dc->vertexCount, dc->indexCount,
                    dc->indexOffsetBytes, dc->baseVertex, dc->primType,
                    dc->blendEnable, dc->srcBlend, dc->destBlend,
                    dc->zEnable, dc->zWriteEnable, dc->cullMode);
            // Dump the actual trapezoid mesh vertices. Metal's drawIndexed adds
            // baseVertex to each index, so the trapezoid verts live at
            // (baseVertex .. baseVertex+maxIdx) in the dynamic VB. We don't
            // know maxIdx until we scan the indices, so do that first.
            unsigned mn = 0xffff, mx = 0;
            if (dc->indexBuffer && dc->indexCount > 0) {
                id<MTLBuffer> ib = (__bridge id<MTLBuffer>)dc->indexBuffer;
                const uint16_t* idx = (const uint16_t*)((const unsigned char*)ib.contents + dc->indexOffsetBytes);
                for (unsigned k = 0; k < dc->indexCount; ++k) { if (idx[k]<mn) mn=idx[k]; if (idx[k]>mx) mx=idx[k]; }
                int nI = (int)dc->indexCount; if (nI > 48) nI = 48;
                fprintf(stderr, "   idx[0..%d]:", nI); for (int k = 0; k < nI; ++k) fprintf(stderr, " %u", idx[k]);
                fprintf(stderr, "\n   idxRange=[%u..%u] -> verts referenced at buffer slots [%d..%d]\n",
                        mn, mx, dc->baseVertex + (int)mn, dc->baseVertex + (int)mx);
            }
            // Total verts the engine wrote for this draw.
            int nVerts = (int)(mx - mn + 1);
            // Walk the actual vertex range. Dump first 18 (covers first 2 rows
            // of a ~37-wide grid) + last 2.
            int nDump = nVerts; if (nDump > 18) nDump = 18;
            for (int v = 0; v < nDump; ++v) {
                size_t bufIdx = (size_t)dc->baseVertex + (size_t)mn + (size_t)v;
                const float* p = (const float*)(base + bufIdx*dc->stride + dc->posOffset);
                unsigned d = 0; if (diffOff >= 0) d = *(const unsigned*)(base + bufIdx*dc->stride + diffOff);
                float u=0,uv1=0; if (uvOff >= 0) { const float* uv = (const float*)(base + bufIdx*dc->stride + uvOff); u=uv[0]; uv1=uv[1]; }
                fprintf(stderr, "   v%02d pos=(%.2f,%.2f,%.2f) diff=0x%08x uv=(%.3f,%.3f)\n", v, p[0], p[1], p[2], d, u, uv1);
            }
            if (nVerts > 18) {
                for (int off = 2; off >= 1; --off) {
                    size_t bufIdx = (size_t)dc->baseVertex + (size_t)mx - (size_t)(off - 1);
                    const float* p = (const float*)(base + bufIdx*dc->stride + dc->posOffset);
                    fprintf(stderr, "   vLAST-%d pos=(%.2f,%.2f,%.2f)\n", off-1, p[0], p[1], p[2]);
                }
            }
            // Sanity: the WHOLE buffer size in bytes. If baseVertex*stride+nVerts*stride
            // would exceed vb.length, then Metal is reading off the end.
            fprintf(stderr, "   vbLen=%lu needBytes=%zu (=baseV*stride + (maxIdx+1)*stride)\n",
                    (unsigned long)vb.length,
                    (size_t)dc->baseVertex*dc->stride + ((size_t)mx+1)*dc->stride);
            fflush(stderr);
          } } }

        // Depth test/write + backface culling (Stage 4). 2D draws disable depth
        // (zEnable==0) and use cull none. The same descriptor carries stencil
        // state (Stage 5) when dc->stencilEnable; setStencilReferenceValue:
        // applies D3DRS_STENCILREF for the EQUAL/LESS/etc tests this draw uses.
        // The ref MUST be masked to 8 bits — engine writes 0x80808080 (a
        // 32-bit value where only the low byte is meaningful for our 8-bit
        // Depth32Float_Stencil8 attachment); Metal's setStencilReferenceValue:
        // takes the raw uint and would compare the full 32-bit value against
        // the 8-bit stencil sample, producing always-false on shadow-quad
        // passes that set ref=0x80808080. Same goes for read/write masks —
        // already handled by GetDepthState via MTLStencilDescriptor.readMask /
        // writeMask which Metal documents as honouring only the low 8 bits.
        id<MTLDepthStencilState> dss = GetDepthState(ctx, dc);
        if (dss != ctx->boundDSS) { [ctx->enc setDepthStencilState:dss]; ctx->boundDSS = dss; }
        if (dc->stencilEnable) {
            long long sref = (long long)((uint32_t)dc->stencilRef & 0xFFu);
            if (sref != ctx->boundStencilRef) {
                [ctx->enc setStencilReferenceValue:(uint32_t)sref];
                ctx->boundStencilRef = sref;
            }
        }

        // Diagnostic: MTL_STENCIL_LOG=1 prints per-stencil-draw state so we
        // can see what the engine pumps through (especially on shellmap where
        // stencil shadow volumes break visually). Throttled — first 200
        // stencil draws per frame.
        { static int s_slog = -1;
          if (s_slog < 0) s_slog = getenv("MTL_STENCIL_LOG") ? 1 : 0;
          if (s_slog && dc->stencilEnable) {
              static long s_lastFrame = -1;
              static int  s_perFrame = 0;
              if (ctx->frameIndex != s_lastFrame) { s_lastFrame = ctx->frameIndex; s_perFrame = 0; }
              // Cap is high (100k) so the DECR pass + darkening quad aren't
              // hidden behind the INCR fill on busy shellmap frames where
              // the volume INCR pass alone can be tens of thousands of
              // draws. MTL_STENCIL_LOG is opt-in and only used for
              // diagnostics, so file-size cost is acceptable.
              if (s_perFrame++ < 100000) {
                  fprintf(stderr, "[stencil] f%ld d%d sEn=1 sFunc=%d sFail=%d sZFail=%d sPass=%d sRef=0x%x sMask=0x%x sWMask=0x%x cull=%d cw=%d posF=%d blend=%d\n",
                          ctx->frameIndex, s_perFrame,
                          dc->stencilFunc, dc->stencilFail, dc->stencilZFail, dc->stencilPass,
                          (unsigned)dc->stencilRef, (unsigned)dc->stencilMask, (unsigned)dc->stencilWriteMask,
                          dc->cullMode, dc->colorWriteMask, dc->posFloats, dc->blendEnable);
              }
          } }

        // SHADOW-LEAK detector (always on for diagnostic, cheap): a stencil
        // INCR/DECR/DECRSAT/INCRSAT pass with colorWriteMask != 0 is almost
        // certainly a shadow volume that's leaking colour — engine should
        // have set D3DRS_COLORWRITEENABLE=0 around the fill. Counts per
        // frame, log periodically.
        { static long s_lastF = -1;
          static int  s_leakCnt = 0;
          if (ctx->frameIndex != s_lastF) {
              if (s_leakCnt > 0 && s_lastF >= 0) {
                  fprintf(stderr, "[shadow-leak] f%ld: %d stencil-write draws kept colour writes ON (likely shadow volume leak)\n",
                          s_lastF, s_leakCnt);
                  fflush(stderr);
              }
              s_lastF = ctx->frameIndex; s_leakCnt = 0;
          }
          if (dc->stencilEnable && dc->colorWriteMask != 0 &&
              (dc->stencilPass == 4 /*INCRSAT*/ || dc->stencilPass == 5 /*DECRSAT*/ ||
               dc->stencilPass == 7 /*INCR*/   || dc->stencilPass == 8 /*DECR*/)) {
              s_leakCnt++;
          }
        }
        // Front-facing winding (constant CW) is set once per encoder in
        // EnsureEncoder — not here.
        MTLCullMode cull = MTLCullModeNone;
        if (dc->cullMode == 2 /*D3DCULL_CW*/)  cull = MTLCullModeFront;
        else if (dc->cullMode == 3 /*D3DCULL_CCW*/) cull = MTLCullModeBack;
        { static int s_nocull = -1; if (s_nocull < 0) s_nocull = getenv("MTL_NOCULL") ? 1 : 0;
          if (s_nocull) cull = MTLCullModeNone; }
        if ((int)cull != ctx->boundCull) { [ctx->enc setCullMode:cull]; ctx->boundCull = (int)cull; }

        FSParams fp;
        std::memset(&fp, 0, sizeof(fp));
        fp.alphaRef = dc->alphaRef;
        fp.alphaTestEnable = dc->alphaTestEnable;
        { static int s_texonly = -1; if (s_texonly < 0) s_texonly = getenv("MTL_TEXONLY") ? 1 : 0;
          fp.dbgTexOnly = s_texonly; }
        // Stage-0 FF combiner state (see DXVK's d3d9_fixed_function for the
        // reference behaviour). Per-draw — drives the per-stage colour/alpha
        // op + arg1/arg2 selection in MSL. MTL_NO_COMBINER=1 falls back to the
        // legacy `c = t * in.color` MODULATE for A/B testing.
        static int s_noCombiner = -1;
        if (s_noCombiner < 0) s_noCombiner = getenv("MTL_NO_COMBINER") ? 1 : 0;
        if (!s_noCombiner) {
            fp.colorOp   = dc->colorOp;
            fp.colorArg1 = dc->colorArg1;
            fp.colorArg2 = dc->colorArg2;
            fp.alphaOp   = dc->alphaOp;
            fp.alphaArg1 = dc->alphaArg1;
            fp.alphaArg2 = dc->alphaArg2;
        }
        // Stage 6: shadow sampling. Only XYZ (3D) geometry samples shadows;
        // XYZRHW (HUD) skips it because its `lpos` has no meaningful world
        // transform. shadowsEnabled is set by the engine via
        // MetalContext_SetShadowsEnabled and stays sticky across frames.
        fp.shadowEnable = (ctx->shadowsEnabled && dc->posFloats == 3) ? 1 : 0;
        // MTL_SHADOW_VIZ=1 ORs bit 1 into shadowEnable → shader returns the
        // light-space (suv, lp.z) as RGB instead of the regular shaded colour.
        // Lets us see if receivers actually land inside the light frustum.
        static int s_shadowViz = -1;
        if (s_shadowViz < 0) s_shadowViz = getenv("MTL_SHADOW_VIZ") ? 1 : 0;
        if (s_shadowViz && fp.shadowEnable) fp.shadowEnable |= 2;
        // Most of the bias work is now done by hardware slope-scale bias in
        // the shadow pass replay encoder (setDepthBias:slopeScale:clamp:).
        // This shader-side NDC bias is kept as a TINY fixed offset (0.0002 ≈
        // 0.8 world units at far=4000) just to cover sub-texel rounding when
        // the receiver's depth lands almost exactly on a recorded caster
        // depth. Larger values reintroduce peter-panning. Override with
        // MTL_SHADOW_BIAS only for tuning experiments.
        {
            static float s_bias = -1.0f, s_darken = -1.0f, s_pcfMul = -1.0f;
            // 0.0005 NDC at far=4000 → ~2 world-unit peter-pan offset. Most
            // Generals casters are 5-15 units tall → offset is small fraction
            // of caster size → shadow stays attached to base. (Was 0.0015 at
            // far=12000 = 18 unit offset → shadow detached from base.)
            if (s_bias   < 0.0f) { const char* e=getenv("MTL_SHADOW_BIAS");       s_bias   = e?atof(e):0.0005f; }
            // Original Generals' projected blob shadows look like ~40-50%
            // black under units; matching that means darken ≈ 0.4-0.5 (so the
            // shadowed pixel = c.rgb * 0.4 → 60% darker). 0.55 was too pale.
            if (s_darken < 0.0f) { const char* e=getenv("MTL_SHADOW_DARKEN");     s_darken = e?atof(e):0.4f;   }
            if (s_pcfMul < 0.0f) { const char* e=getenv("MTL_SHADOW_PCF_RADIUS"); s_pcfMul = e?atof(e):1.0f;   }
            fp.shadowBias       = s_bias;
            fp.shadowDarken     = s_darken;
            // PCF kernel step = texelSize × radius multiplier. Larger radius =
            // softer/larger penumbra but more blur of shadow features.
            fp.shadowTexelSize  = (1.0f / (float)METAL_SHADOWMAP_SIZE) * s_pcfMul;
        }
        // D3DRS_TEXTUREFACTOR is BGRA in memory; unpack to RGBA float4.
        fp.tfactor[0] = ((dc->tfactor >> 16) & 0xFF) / 255.0f;  // R
        fp.tfactor[1] = ((dc->tfactor >>  8) & 0xFF) / 255.0f;  // G
        fp.tfactor[2] = ((dc->tfactor      ) & 0xFF) / 255.0f;  // B
        fp.tfactor[3] = ((dc->tfactor >> 24) & 0xFF) / 255.0f;  // A
        [ctx->enc setFragmentBytes:&fp length:sizeof(fp) atIndex:0];
        if (tex != ctx->boundTex0) { [ctx->enc setFragmentTexture:tex atIndex:0]; ctx->boundTex0 = tex; }
        // Per-draw sampler based on D3DTSS_ADDRESSU/V (CLAMP for the terrain
        // atlas, WRAP for everything else). Falls back to the legacy global
        // sampler when address modes are unset (key 0 == default WRAP/WRAP).
        id<MTLSamplerState> smp = GetSampler(ctx, dc);
        if (smp != ctx->boundSmp0) { [ctx->enc setFragmentSamplerState:smp atIndex:0]; ctx->boundSmp0 = smp; }

        // Shadow texture/sampler at slot 2 — the fs only samples when
        // fp.shadowEnable != 0, but Metal still requires bindings. Constant for
        // the whole encoder, so bind once (shadowMap only ever appears/changes
        // across a Begin/EndShadowPass, which ends this encoder → re-bound next).
        if (ctx->shadowMap && !ctx->boundShadowSlot) {
            [ctx->enc setFragmentTexture:ctx->shadowMap atIndex:2];
            [ctx->enc setFragmentSamplerState:ctx->shadowSmp atIndex:2];
            ctx->boundShadowSlot = true;
        }

        MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
        if (dc->primType == D3DPT_TRIANGLESTRIP) prim = MTLPrimitiveTypeTriangleStrip;
        // D3DPT_TRIANGLEFAN is unsupported in Metal; fan UI draws are rare — skip.
        else if (dc->primType == D3DPT_TRIANGLEFAN) return;

        if (ctx->dbg < 0) ctx->dbg = getenv("MTL_DEBUG") ? 1 : 0;
        if (ctx->dbg) { ctx->drawsThisFrame++; if (dc->texture) ctx->texturedThisFrame++; }
        if (ctx->dbg && ctx->frameIndex == 180 && dc->diffuseOffset >= 0 && dc->tex0Offset >= 0) {
            const float* m = dc->mvp;
            const unsigned char* base = (const unsigned char*)vb.contents;
            // Determine the set of vertices this draw touches and compute the
            // NDC bounding box, plus read vertex-0 diffuse + uv.
            float minx=1e9f,maxx=-1e9f,miny=1e9f,maxy=-1e9f;
            float minu=1e9f,maxu=-1e9f,minv=1e9f,maxv=-1e9f;
            float vnx[4]={0,0,0,0}, vu[4]={0,0,0,0};  // first 4 verts: ndcX and u
            int vcnt=0;
            auto xf = [&](int vidx, float& nx, float& ny){
                const float* p = (const float*)(base + (size_t)vidx*dc->stride + dc->posOffset);
                float x=p[0],y=p[1],z=(dc->posFloats>=3?p[2]:0.f);
                float cx=m[0]*x+m[4]*y+m[8]*z+m[12];
                float cy=m[1]*x+m[5]*y+m[9]*z+m[13];
                float cw=m[3]*x+m[7]*y+m[11]*z+m[15];
                nx=(cw!=0?cx/cw:0); ny=(cw!=0?cy/cw:0);
                const float* tuv = (const float*)(base + (size_t)vidx*dc->stride + dc->tex0Offset);
                if(tuv[0]<minu)minu=tuv[0]; if(tuv[0]>maxu)maxu=tuv[0];
                if(tuv[1]<minv)minv=tuv[1]; if(tuv[1]>maxv)maxv=tuv[1];
                if(vcnt<4){ vnx[vcnt]=nx; vu[vcnt]=tuv[0]; vcnt++; }
            };
            int nverts = 0; int firstV = 0;
            if (dc->indexBuffer && dc->indexCount > 0) {
                id<MTLBuffer> ib = (__bridge id<MTLBuffer>)dc->indexBuffer;
                const uint16_t* idx = (const uint16_t*)((const unsigned char*)ib.contents + dc->indexOffsetBytes);
                nverts = (int)dc->indexCount;
                for (int i=0;i<nverts && i<64;++i){ float nx,ny; xf(idx[i]+dc->baseVertex,nx,ny);
                    if(nx<minx)minx=nx; if(nx>maxx)maxx=nx; if(ny<miny)miny=ny; if(ny>maxy)maxy=ny; }
                firstV = idx[0]+dc->baseVertex;
            } else {
                nverts = (int)dc->vertexCount; firstV = (int)dc->vertexStart;
                for (int i=0;i<nverts && i<64;++i){ float nx,ny; xf(firstV+i,nx,ny);
                    if(nx<minx)minx=nx; if(nx>maxx)maxx=nx; if(ny<miny)miny=ny; if(ny>maxy)maxy=ny; }
            }
            const unsigned char* d = base + (size_t)firstV*dc->stride + dc->diffuseOffset;
            // also read texcoord set 0 and set 1 of first + last vertex
            int lastV = firstV;
            if (dc->indexBuffer && dc->indexCount>0){ id<MTLBuffer> ib=(__bridge id<MTLBuffer>)dc->indexBuffer;
                const uint16_t* idx=(const uint16_t*)((const unsigned char*)ib.contents+dc->indexOffsetBytes);
                lastV = idx[(dc->indexCount>3?3:dc->indexCount-1)]+dc->baseVertex; }
            const float* t0a=(const float*)(base+(size_t)firstV*dc->stride+dc->tex0Offset);
            const float* t1a=(const float*)(base+(size_t)firstV*dc->stride+dc->tex0Offset+8);
            const float* t0b=(const float*)(base+(size_t)lastV*dc->stride+dc->tex0Offset);
            const float* t1b=(const float*)(base+(size_t)lastV*dc->stride+dc->tex0Offset+8);
            (void)t0a;(void)t0b;(void)t1a;(void)t1b;
            static int gn=0; ++gn;
            fprintf(stderr, "[geom30] #%d ndcX=[%.2f,%.2f] tex=%p diff=%u,%u,%u,%u verts(ndcX,u): (%.2f,%.2f)(%.2f,%.2f)(%.2f,%.2f)(%.2f,%.2f)\n",
                    gn, minx,maxx, dc->texture, d[0],d[1],d[2],d[3],
                    vnx[0],vu[0], vnx[1],vu[1], vnx[2],vu[2], vnx[3],vu[3]);
            fflush(stderr);
        }

        if (dc->indexBuffer && dc->indexCount > 0) {
            id<MTLBuffer> ib = (__bridge id<MTLBuffer>)dc->indexBuffer;
            [ctx->enc drawIndexedPrimitives:prim
                                 indexCount:dc->indexCount
                                  indexType:MTLIndexTypeUInt16
                                indexBuffer:ib
                          indexBufferOffset:dc->indexOffsetBytes
                              instanceCount:1
                                 baseVertex:dc->baseVertex
                               baseInstance:0];
        } else if (dc->vertexCount > 0) {
            [ctx->enc drawPrimitives:prim
                         vertexStart:dc->vertexStart
                         vertexCount:dc->vertexCount];
        }

        // ---- Stage 6 capture for next-frame shadow replay ---------------
        // Filter: only opaque 3D geometry that writes colour goes into the
        // shadow map.
        //   * posFloats != 3        → HUD / 2D, no world-space position
        //   * blendEnable          → translucent (particles, decals, smoke)
        //   * colorWriteMask == 0  → engine's stencil-only passes (shadow
        //                            volume front/back faces, player-colour
        //                            occlusion mask) — their geometry is
        //                            extruded to infinity and would
        //                            otherwise pollute the shadow map.
        // MTL_SHADOW_DBG=1 prints per-frame filter rejection stats so we can
        // diagnose "shadow disappears when X happens" bugs (e.g. unit
        // selection toggling render state in a way that flips a filter).
        // Capture gate must match the replay gate (RunShadowReplay): both
        // are driven by the engine's MetalShim_SetShadowsEnabled flag,
        // overridable by MTL_SHADOW for diagnostics. Reads ctx field directly
        // each frame (no static cache) so a runtime toggle from the Options
        // menu takes effect on the *next* frame, not on process restart.
        int s_shadowEnv = ctx->shadowsEnabled;
        if (const char* e = getenv("MTL_SHADOW")) s_shadowEnv = atoi(e) ? 1 : 0;
        static int s_shadowDbg = -1;
        if (s_shadowDbg < 0) s_shadowDbg = getenv("MTL_SHADOW_DBG") ? 1 : 0;
        static int s_keepBlended = -1;
        if (s_keepBlended < 0) s_keepBlended = getenv("MTL_SHADOW_KEEP_BLENDED") ? 1 : 0;
        if (s_shadowDbg) {
            // Per-frame rejection counters (reset in RunShadowReplay).
            ctx->dbgTotalDraws++;
            if (dc->posFloats != 3)      ctx->dbgRejPosFloats++;
            else if (dc->blendEnable)    ctx->dbgRejBlend++;
            else if (dc->colorWriteMask == 0) ctx->dbgRejColorWrite++;
            else                         ctx->dbgRejAccepted++;
            // Track captured FVFs by tallying unique fvf bits low 12-bit.
            if (dc->posFloats == 3) {
                ctx->dbgFvfMask |= ((uint64_t)1 << (dc->fvf & 0x3F));
            }
        }
        if (s_shadowEnv
            && dc->posFloats == 3
            && (s_keepBlended || !dc->blendEnable)
            && dc->colorWriteMask != 0
            && dc->vertexBuffer
            && (dc->indexCount > 0 || dc->vertexCount > 0))
        {
            MetalContext::CapturedDraw cap;
            cap.vb               = [(__bridge id<MTLBuffer>)dc->vertexBuffer retain];
            cap.ib               = dc->indexBuffer ? [(__bridge id<MTLBuffer>)dc->indexBuffer retain] : nil;
            cap.stride           = dc->stride;
            cap.indexOffsetBytes = dc->indexOffsetBytes;
            cap.indexCount       = dc->indexCount;
            cap.vertexStart      = dc->vertexStart;
            cap.vertexCount      = dc->vertexCount;
            cap.baseVertex       = dc->baseVertex;
            cap.fvf              = dc->fvf;
            cap.primType         = (int)dc->primType;
            cap.cullMode         = dc->cullMode;
            cap.posOffset        = dc->posOffset;
            cap.posFloats        = dc->posFloats;
            cap.normalOffset     = dc->normalOffset;
            cap.diffuseOffset    = dc->diffuseOffset;
            cap.tex0Offset       = dc->tex0Offset;
            cap.tex1Offset       = dc->tex1Offset;
            cap.texCoordIndex    = dc->texCoordIndex;
            std::memcpy(cap.world, dc->world, sizeof(float) * 16);
            ctx->shadowCaptures.push_back(cap);

            // Tally view+lights by majority vote (see ViewBucket comment).
            int found = -1;
            for (size_t i = 0; i < ctx->viewBuckets.size(); ++i) {
                if (std::memcmp(ctx->viewBuckets[i].view, dc->view, sizeof(float) * 16) == 0) {
                    found = (int)i;
                    break;
                }
            }
            if (found >= 0) {
                ctx->viewBuckets[found].count++;
            } else {
                MetalContext::ViewBucket b;
                std::memcpy(b.view,   dc->view,   sizeof(float) * 16);
                std::memcpy(b.lights, dc->lights, sizeof(MetalLight) * 8);
                b.numLights = dc->numLights;
                b.count     = 1;
                ctx->viewBuckets.push_back(b);
            }
            ctx->haveCaptureSnapshot = true;   // signals "have something to replay"
        }
    }
}

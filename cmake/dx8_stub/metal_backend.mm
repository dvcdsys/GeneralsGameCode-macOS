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
#include <unordered_map>
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
bool                g_capsOn = false;
unsigned long       g_prevModFlags = 0;
NSView*             g_inputView = nil;   // active content view, for coord conversion

// Convert an NSEvent window location to content-view pixels, top-left origin.
inline void EventPoint(NSEvent* e, int* outX, int* outY)
{
    *outX = 0; *outY = 0;
    if (!g_inputView) return;
    NSPoint p = [g_inputView convertPoint:e.locationInWindow fromView:nil];
    CGFloat h = g_inputView.bounds.size.height;
    int x = (int)p.x;
    int y = (int)(h - p.y);          // flip: Cocoa is bottom-left, engine top-left
    if (x < 0) x = 0; if (y < 0) y = 0;
    *outX = x; *outY = y;
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
    float3 pos    [[attribute(0)]];
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
    GpuLight lights[8];
};

vertex VSOut vs_main(VSIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    VSOut o;
    // Shadow pass: clip-space position IS the light-space transform, so the
    // depth attachment is filled with light-space z. Color attachment is
    // disabled in that pipeline, so o.color/uv are irrelevant — but we still
    // assign them (Metal vs must populate the [[position]] varying).
    if (u.shadowPass != 0) {
        o.pos   = u.lightVP * u.world * float4(in.pos, 1.0);
        o.color = float4(1.0);
        o.uv    = float2(0.0);
        o.lpos  = float4(0.0);
        return o;
    }
    o.pos = u.mvp * float4(in.pos, 1.0);
    // Main pass: pre-compute light-space position for the fs shadow lookup.
    // Only meaningful when u.shadowEnable!=0 (we still compute to keep the
    // varying interface stable so Metal doesn't optimise it away mid-frame).
    o.lpos = u.lightVP * u.world * float4(in.pos, 1.0);

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
        float4 wpos   = u.world * float4(in.pos, 1.0);
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
        float3 worldPos = (u.world * float4(in.pos, 1.0)).xyz;
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
    // 4 trailing pads round the leading scalar block to 16 ints (=64 bytes)
    // so the float4-aligned `tfactor` lands at offset 64 on both CPU and MSL.
    int   _pad0;
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

    // Stage 6: shadow mapping. Perspective divide light-space pos to NDC, flip
    // Y (Metal tex coords are top-left, light-space NDC is bottom-left), then
    // sample shadowTex and compare. When the fragment's light-space z is
    // farther than the stored depth (+ bias), the fragment is shadowed.
    // 1-tap (no PCF) for Phase 1; PCF later.
    if (p.shadowEnable != 0) {
        float3 lp = in.lpos.xyz / max(in.lpos.w, 1e-6);
        float2 suv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
        // Reject samples outside the shadow map's bounds — those fragments are
        // outside the sun's frustum and shouldn't be darkened (treat as lit).
        if (suv.x >= 0.0 && suv.x <= 1.0 && suv.y >= 0.0 && suv.y <= 1.0 &&
            lp.z >= 0.0 && lp.z <= 1.0)
        {
            float storedZ = shadowTex.sample(shadowSmp, suv);
            if (lp.z > storedZ + p.shadowBias)
                c.rgb *= p.shadowDarken;
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
    GpuLightCPU lights[8];
};
} // namespace

// ---------------------------------------------------------------------------
// Window plumbing
// ---------------------------------------------------------------------------
@interface MetalView : NSView
@end
@implementation MetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer*)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstResponder { return YES; }
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
    int   _pad0;     // round leading block to 16 floats / 64 bytes so the
    int   _pad1;     // 16-aligned MSL `float4 tfactor` lands at the same
    int   _pad2;     // offset on CPU + GPU. Without this, tfactor on CPU
    int   _pad3;     // sat at 52 while MSL aligned it to 64 → bgra leaked.
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
    std::unordered_map<uint16_t, id<MTLSamplerState>> samplers;

    // Depth buffer (Stage 4) + depth-stencil state cache (keyed by z state).
    id<MTLTexture>       depthTex;
    int                  depthW;
    int                  depthH;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>> depthStates;

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
    // Last seen lighting/view state — sampled on every captured draw so
    // RunShadowReplay can derive sun direction + camera focus at Present time.
    float                lastView[16];
    MetalLight           lastLights[8];
    int                  lastNumLights;
    bool                 haveCaptureSnapshot;

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

static void CaptureInputEvent(NSEvent* event)
{
    switch (event.type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: {
            MouseEv m; m.type = METAL_MOUSE_MOVE; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeLeftMouseDown: {
            MouseEv m; m.type = (event.clickCount >= 2) ? METAL_MOUSE_LDBL : METAL_MOUSE_LDOWN;
            m.delta = 0; EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeLeftMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_LUP; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeRightMouseDown: {
            MouseEv m; m.type = METAL_MOUSE_RDOWN; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeRightMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_RUP; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeOtherMouseDown: {
            MouseEv m; m.type = METAL_MOUSE_MDOWN; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeOtherMouseUp: {
            MouseEv m; m.type = METAL_MOUSE_MUP; m.delta = 0;
            EventPoint(event, &m.x, &m.y); g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeScrollWheel: {
            MouseEv m; m.type = METAL_MOUSE_WHEEL;
            EventPoint(event, &m.x, &m.y);
            // One detent ~= 120 (WHEEL_DELTA). scrollingDeltaY is points; sign matters.
            double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY;
            m.delta = (int)(dy * 120.0);
            if (m.delta == 0 && dy != 0.0) m.delta = (dy > 0 ? 120 : -120);
            g_mouseQ.push_back(m);
            break;
        }
        case NSEventTypeKeyDown: {
            if (!event.isARepeat) { KeyEv k; k.macKeyCode = event.keyCode; k.down = 1; g_keyQ.push_back(k); }
            break;
        }
        case NSEventTypeKeyUp: {
            KeyEv k; k.macKeyCode = event.keyCode; k.down = 0; g_keyQ.push_back(k);
            break;
        }
        case NSEventTypeFlagsChanged: {
            unsigned long f = (unsigned long)event.modifierFlags;
            g_capsOn = (f & NSEventModifierFlagCapsLock) != 0;
            // Emit down/up for the modifier whose bit changed (best-effort).
            unsigned long changed = f ^ g_prevModFlags;
            struct { unsigned long mask; } mods[] = {
                { NSEventModifierFlagShift }, { NSEventModifierFlagControl },
                { NSEventModifierFlagOption }, { NSEventModifierFlagCommand },
            };
            for (auto& md : mods) {
                if (changed & md.mask) {
                    KeyEv k; k.macKeyCode = event.keyCode; k.down = (f & md.mask) ? 1 : 0;
                    g_keyQ.push_back(k);
                }
            }
            g_prevModFlags = f;
            break;
        }
        default: break;
    }
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
    // colorWriteMask occupies 1 bit in the key (binary: writes-on / writes-off).
    // The engine only uses 0xF (all) and 0 (none) — no per-channel masking.
    int  writeOn = (dc->colorWriteMask != 0) ? 1 : 0;
    uint64_t key = (uint64_t)dc->fvf
                 | ((uint64_t)(dc->blendEnable ? 1 : 0) << 32)
                 | ((uint64_t)(dc->srcBlend  & 0xFF)    << 33)
                 | ((uint64_t)(dc->destBlend & 0xFF)    << 41)
                 | ((uint64_t)(dc->posFloats & 0x7)     << 49)
                 | ((uint64_t)(uvOff & 0xFF)            << 52)
                 | ((uint64_t)writeOn                   << 60);
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
    // The depth attachment also carries an 8-bit stencil so the FF stencil
    // emulation (occlusion X-ray, shadow volumes) sees a real stencil buffer.
    pd.depthAttachmentPixelFormat   = MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    MTLRenderPipelineColorAttachmentDescriptor* ca = pd.colorAttachments[0];
    ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // D3DRS_COLORWRITEENABLE = 0 (stencil-only passes during volumetric shadow
    // rendering): disable the color attachment entirely so the back/front face
    // passes write only to the stencil buffer, not to the framebuffer.
    ca.writeMask = writeOn ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
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
        k.sZFail    = (uint8_t)(dc->stencilZFail ? dc->stencilZFail : 1);
        k.sPass     = (uint8_t)(dc->stencilPass  ? dc->stencilPass  : 1);
        k.sReadMask  = (uint32_t)dc->stencilMask;
        k.sWriteMask = (uint32_t)dc->stencilWriteMask;
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
// attachment (Apple Silicon supports this natively as a private-storage texture).
static void EnsureDepthTexture(MetalContext* ctx)
{
    if (ctx->depthTex && ctx->depthW == ctx->width && ctx->depthH == ctx->height) return;
    if (ctx->depthTex) { [ctx->depthTex release]; ctx->depthTex = nil; }
    MTLTextureDescriptor* dd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                           width:(ctx->width  > 0 ? ctx->width  : 1)
                                                          height:(ctx->height > 0 ? ctx->height : 1)
                                                       mipmapped:NO];
    dd.usage       = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    ctx->depthTex = [[ctx->device newTextureWithDescriptor:dd] retain];
    ctx->depthW = ctx->width;
    ctx->depthH = ctx->height;
}

// Stage 6: shadow mapping. Lazy-allocate the shadow map texture, depth-stencil
// state (depth write on / depth read LESS / no stencil), and sampler. Called
// from BeginShadowPass; reuses on subsequent frames.
#define METAL_SHADOWMAP_SIZE 2048
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

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture     = ctx->drawable.texture;
    pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
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
    return true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
extern "C" MetalContext* MetalContext_Create(int width, int height, int /*windowed*/)
{
    @autoreleasepool {
        EnsureAppInitialized();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) { NSLog(@"[metal] no system default Metal device"); return nullptr; }

        MetalContext* ctx = new MetalContext();
        ctx->device = device;
        ctx->queue  = [device newCommandQueue];
        ctx->width  = width;
        ctx->height = height;
        ctx->clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        ctx->dbg = -1;
        // Stage 6 shadow defaults: identity lightVP (harmless when shadowsEnabled=0),
        // shadowsEnabled stays 0 until the engine flips it via MetalContext_SetShadowsEnabled.
        std::memset(ctx->lightVP, 0, sizeof(ctx->lightVP));
        ctx->lightVP[0] = 1.0f; ctx->lightVP[5] = 1.0f; ctx->lightVP[10] = 1.0f; ctx->lightVP[15] = 1.0f;
        ctx->shadowsEnabled   = 0;
        ctx->shadowPassActive = false;
        // Single active context for the engine wrappers (the engine never
        // creates more than one MetalContext in practice).
        extern MetalContext* g_activeMetalCtx;
        g_activeMetalCtx = ctx;

        NSRect frame = NSMakeRect(0, 0, width, height);
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

        [window setContentView:view];
        [window makeFirstResponder:view];
        [window setAcceptsMouseMovedEvents:YES];
        [window makeKeyAndOrderFront:nil];

        ctx->window = window;
        ctx->view   = view;
        ctx->layer  = layer;
        g_inputView = view;  // for input coordinate conversion

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
        ctx->sampler  = nil;
        ctx->whiteTex = nil;
        ctx->vsFn = nil; ctx->fsFn = nil;
        if (ctx->enc) { [ctx->enc endEncoding]; [ctx->enc release]; ctx->enc = nil; }
        if (ctx->cmd) { [ctx->cmd release]; ctx->cmd = nil; }
        if (ctx->drawable) { [ctx->drawable release]; ctx->drawable = nil; }
        [ctx->window close];
        ctx->window = nil;
        ctx->view   = nil;
        ctx->layer  = nil;
        ctx->queue  = nil;
        ctx->device = nil;
    }
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
extern "C" void MetalShim_BeginShadowPass(const float lvp[16]) { if (g_activeMetalCtx) MetalContext_BeginShadowPass(g_activeMetalCtx, lvp); }
extern "C" void MetalShim_EndShadowPass(void) { if (g_activeMetalCtx) MetalContext_EndShadowPass(g_activeMetalCtx); }

extern "C" void MetalContext_PumpEvents(MetalContext* /*ctx*/) { DrainEvents(); }

extern "C" void MetalContext_Resize(MetalContext* ctx, int width, int height)
{
    if (!ctx) return;
    @autoreleasepool {
        ctx->width  = width;
        ctx->height = height;
        ctx->layer.drawableSize = CGSizeMake(width, height);
    }
}

extern "C" void MetalContext_Present(MetalContext* ctx)
{
    if (!ctx) return;
    @autoreleasepool {
        // If nothing was drawn this frame, still clear+present.
        if (!ctx->enc && !ctx->drawable) EnsureEncoder(ctx);
        if (ctx->enc) { [ctx->enc endEncoding]; [ctx->enc release]; ctx->enc = nil; }

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
            [ctx->cmd presentDrawable:ctx->drawable];
            [ctx->cmd commit];
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

extern "C" void* MetalContext_CreateTextureFmt(MetalContext* ctx, int width, int height, int bcKind)
{
    if (!ctx) return nullptr;
    @autoreleasepool {
        MTLPixelFormat pf = MTLPixelFormatBGRA8Unorm;
        switch (bcKind) {
            case 1: pf = MTLPixelFormatBC1_RGBA; break;  // DXT1
            case 2: pf = MTLPixelFormatBC2_RGBA; break;  // DXT2/3
            case 3: pf = MTLPixelFormatBC3_RGBA; break;  // DXT4/5
            default: pf = MTLPixelFormatBGRA8Unorm; break;
        }
        MTLTextureDescriptor* desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                               width:(width  > 0 ? width  : 1)
                                                              height:(height > 0 ? height : 1)
                                                           mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [ctx->device newTextureWithDescriptor:desc];
        return (void*)CFBridgingRetain(tex);
    }
}

extern "C" void* MetalContext_CreateTexture(MetalContext* ctx, int width, int height)
{
    return MetalContext_CreateTextureFmt(ctx, width, height, 0);
}

extern "C" void MetalContext_UploadTextureRaw(void* texture, int width, int height,
                                              const void* bytes, int bytesPerRow)
{
    if (!texture || !bytes || width <= 0 || height <= 0) return;
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:bytes
               bytesPerRow:(NSUInteger)bytesPerRow];
    }
}

extern "C" void MetalContext_ReleaseTexture(void* texture)
{
    if (texture) CFRelease(texture);
}

// Engine-side trapezoid-water tag (set in W3DWater.cpp drawTrapezoidWater
// around the Draw_Triangles call). Weak-linked so the shim still resolves if
// the engine TU is absent (tooling builds). Returns 0 if not present.
extern "C" int MetalDebug_InTrapezoidWater(void) __attribute__((weak));
static inline int MetalDebug_InTrapWater_Get(void) {
    return MetalDebug_InTrapezoidWater ? MetalDebug_InTrapezoidWater() : 0;
}

// Map D3D address mode (D3DTADDRESS_*) to Metal sampler address mode. D3D8:
// 1=WRAP, 2=MIRROR, 3=CLAMP, 4=BORDER, 5=MIRRORONCE. 0 (unset) → WRAP (default).
static inline MTLSamplerAddressMode MapAddressMode(int d3dAddr)
{
    switch (d3dAddr) {
        case 3 /*CLAMP*/:        return MTLSamplerAddressModeClampToEdge;
        case 2 /*MIRROR*/:       return MTLSamplerAddressModeMirrorRepeat;
        case 4 /*BORDER*/:       return MTLSamplerAddressModeClampToZero;
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

// Cached per-draw sampler keyed on (addressU, addressV, magFilter, minFilter, mipFilter).
// The legacy default was bilinear, no-mip, WRAP — we keep that for zero-init state.
static id<MTLSamplerState> GetSampler(MetalContext* ctx, const MetalDrawCall* dc)
{
    // 4 bits per address mode, 2 bits per filter (0..3 fits D3D values).
    uint16_t key = (uint16_t)((dc->addressU & 0xF)
                            | ((dc->addressV   & 0xF) << 4)
                            | ((dc->magFilter  & 0x3) << 8)
                            | ((dc->minFilter  & 0x3) << 10)
                            | ((dc->mipFilter  & 0x3) << 12));
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
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:bgra8
               bytesPerRow:(NSUInteger)bytesPerRow];

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

extern "C" void* MetalContext_CreateBuffer(MetalContext* ctx, unsigned length)
{
    if (!ctx) return nullptr;
    @autoreleasepool {
        if (length == 0) length = 1;
        id<MTLBuffer> buf = [ctx->device newBufferWithLength:length
                                                     options:MTLResourceStorageModeShared];
        return (void*)CFBridgingRetain(buf);
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
    if (buffer) CFRelease(buffer);
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
            if (shouldBeHidden) [NSCursor hide];
            else                [NSCursor unhide];
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

        id<MTLRenderPipelineState> ps = GetPipeline(ctx, dc);
        if (!ps) return;

        id<MTLBuffer>  vb  = (__bridge id<MTLBuffer>)dc->vertexBuffer;
        id<MTLTexture> tex = dc->texture ? (__bridge id<MTLTexture>)dc->texture : ctx->whiteTex;

        [ctx->enc setRenderPipelineState:ps];
        [ctx->enc setVertexBuffer:vb offset:0 atIndex:0];

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
        [ctx->enc setDepthStencilState:GetDepthState(ctx, dc)];
        if (dc->stencilEnable)
            [ctx->enc setStencilReferenceValue:(uint32_t)dc->stencilRef];
        [ctx->enc setFrontFacingWinding:MTLWindingClockwise];   // D3D front face = CW
        MTLCullMode cull = MTLCullModeNone;
        if (dc->cullMode == 2 /*D3DCULL_CW*/)  cull = MTLCullModeFront;
        else if (dc->cullMode == 3 /*D3DCULL_CCW*/) cull = MTLCullModeBack;
        { static int s_nocull = -1; if (s_nocull < 0) s_nocull = getenv("MTL_NOCULL") ? 1 : 0;
          if (s_nocull) cull = MTLCullModeNone; }
        [ctx->enc setCullMode:cull];

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
        // Tuned for a single-cascade 2048×2048 ortho covering ~10000 world
        // units (Generals maps). 0.001 in light-NDC depth corresponds to a
        // few centimeters of world depth — enough to prevent self-shadow
        // acne on the receiver, small enough that real shadows stay tight.
        fp.shadowBias   = 0.001f;
        fp.shadowDarken = 0.55f;
        // D3DRS_TEXTUREFACTOR is BGRA in memory; unpack to RGBA float4.
        fp.tfactor[0] = ((dc->tfactor >> 16) & 0xFF) / 255.0f;  // R
        fp.tfactor[1] = ((dc->tfactor >>  8) & 0xFF) / 255.0f;  // G
        fp.tfactor[2] = ((dc->tfactor      ) & 0xFF) / 255.0f;  // B
        fp.tfactor[3] = ((dc->tfactor >> 24) & 0xFF) / 255.0f;  // A
        [ctx->enc setFragmentBytes:&fp length:sizeof(fp) atIndex:0];
        [ctx->enc setFragmentTexture:tex atIndex:0];
        // Per-draw sampler based on D3DTSS_ADDRESSU/V (CLAMP for the terrain
        // atlas, WRAP for everything else). Falls back to the legacy global
        // sampler when address modes are unset (key 0 == default WRAP/WRAP).
        [ctx->enc setFragmentSamplerState:GetSampler(ctx, dc) atIndex:0];

        // Shadow texture/sampler at slot 2 — the fs only samples when
        // fp.shadowEnable != 0, but Metal still requires bindings.
        if (ctx->shadowMap) {
            [ctx->enc setFragmentTexture:ctx->shadowMap atIndex:2];
            [ctx->enc setFragmentSamplerState:ctx->shadowSmp atIndex:2];
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
    }
}

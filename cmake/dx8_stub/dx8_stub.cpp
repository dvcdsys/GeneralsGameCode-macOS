// macOS DirectX8 / DirectInput / DirectDraw / D3DX stubs.
//
// On Windows these symbols come from d3d8.lib / dinput8.lib / dxguid.lib /
// d3dx8.lib import libraries. On macOS no such backend exists yet, so we
// provide stubs:
//   * Device/object creation entrypoints FAIL CLEANLY (null object / failure
//     HRESULT). The engine's device-init paths bail out gracefully.
//   * The D3DX matrix/vector math helpers are implemented FOR REAL (they are
//     pure CPU math, no GPU needed, and the engine may call them off the
//     graphics path).
//   * The D3DX texture/shader helpers return failure / no-op.
//   * DirectInput data-format globals are provided as zeroed constants.
//
// This only needs to LINK so we produce a native arm64 executable; nothing
// here runs a game yet (graphics/input are not wired).
//
// Signatures match the DX8 SDK headers (fetched into _deps/dx8-src) which
// declare the entrypoints inside `extern "C"`, so the compiler emits exactly
// the symbol names the engine references.

#include <windows.h>   // osdep_compat shim: HRESULT, UINT, WINAPI, GUID, etc.
#include <cmath>
#include <cstring>

#include <d3d8.h>
#include <dinput.h>
#include <d3dx8.h>

// ==========================================================================
// Loud stubs (MTL_STUB_LOG=1)
// ==========================================================================
// A "not really implemented" stub that returns E_FAIL / a null object does its
// damage SILENTLY: the caller thinks it failed cleanly and carries on, and we
// (repeatedly) burn debugging time chasing a rendering/logic bug whose real
// cause is "this D3DX helper is a no-op". D3DXLoadSurfaceFromSurface was exactly
// that — it silently broke every surface->texture copy (gray house-color art).
//
// Drop STUB_HIT() at the top of any such stub. With MTL_STUB_LOG=1 in the
// environment each stub announces itself the first time it is hit, then at
// powers of two, so a per-frame stub reveals itself without spamming the log.
static inline bool StubLogOn()
{
    static int e = -1;
    if (e < 0) e = getenv("MTL_STUB_LOG") ? 1 : 0;
    return e != 0;
}
#define STUB_HIT() do {                                                        \
    static unsigned long _sh_n = 0;                                            \
    if (StubLogOn() && ((_sh_n & (_sh_n - 1)) == 0))                           \
        fprintf(stderr, "[STUB] %s  (hit #%lu) -- unimplemented no-op\n",      \
                __func__, _sh_n + 1);                                          \
    ++_sh_n;                                                                    \
} while (0)

// ==========================================================================
// Direct3D 8
// ==========================================================================
// Direct3DCreate8 now lives in dx8_device.cpp (Metal-backed factory). Milestone 1.

// ==========================================================================
// DirectInput 8
// ==========================================================================
extern "C" HRESULT WINAPI DirectInput8Create(HINSTANCE /*hinst*/, DWORD /*dwVersion*/,
                                             REFIID /*riidltf*/, LPVOID* ppvOut,
                                             LPUNKNOWN /*punkOuter*/)
{
    STUB_HIT();
    if (ppvOut)
        *ppvOut = nullptr;
    return E_FAIL;
}

// DirectInput device data-format descriptors. The engine passes the address of
// these to SetDataFormat(); since device creation fails first they are never
// dereferenced. Provide zeroed real constants so references link.
extern "C" {
const DIDATAFORMAT c_dfDIKeyboard  = {0};
const DIDATAFORMAT c_dfDIMouse     = {0};
const DIDATAFORMAT c_dfDIMouse2    = {0};
const DIDATAFORMAT c_dfDIJoystick  = {0};
const DIDATAFORMAT c_dfDIJoystick2 = {0};
}

// ==========================================================================
// D3DX matrix / vector math (implemented for real -- pure CPU math)
// ==========================================================================
extern "C" {

D3DXMATRIX* WINAPI D3DXMatrixTranspose(D3DXMATRIX* pOut, CONST D3DXMATRIX* pM)
{
    D3DXMATRIX t;
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            t.m[i][j] = pM->m[j][i];
    *pOut = t;
    return pOut;
}

// Out = M1 * M2 (row-major, DirectX convention).
D3DXMATRIX* WINAPI D3DXMatrixMultiply(D3DXMATRIX* pOut, CONST D3DXMATRIX* pM1, CONST D3DXMATRIX* pM2)
{
    D3DXMATRIX r;
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
        {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k)
                s += pM1->m[i][k] * pM2->m[k][j];
            r.m[i][j] = s;
        }
    *pOut = r;
    return pOut;
}

D3DXMATRIX* WINAPI D3DXMatrixInverse(D3DXMATRIX* pOut, FLOAT* pDeterminant, CONST D3DXMATRIX* pM)
{
    const float* m = &pM->m[0][0];
    float inv[16], det;

    inv[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
    inv[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
    inv[8]  =  m[4]*m[9]*m[15]  - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
    inv[12] = -m[4]*m[9]*m[14]  + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
    inv[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
    inv[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
    inv[9]  = -m[0]*m[9]*m[15]  + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
    inv[13] =  m[0]*m[9]*m[14]  - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
    inv[2]  =  m[1]*m[6]*m[15]  - m[1]*m[7]*m[14]  - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7]  - m[13]*m[3]*m[6];
    inv[6]  = -m[0]*m[6]*m[15]  + m[0]*m[7]*m[14]  + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7]  + m[12]*m[3]*m[6];
    inv[10] =  m[0]*m[5]*m[15]  - m[0]*m[7]*m[13]  - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7]  - m[12]*m[3]*m[5];
    inv[14] = -m[0]*m[5]*m[14]  + m[0]*m[6]*m[13]  + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6]  + m[12]*m[2]*m[5];
    inv[3]  = -m[1]*m[6]*m[11]  + m[1]*m[7]*m[10]  + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7]   + m[9]*m[3]*m[6];
    inv[7]  =  m[0]*m[6]*m[11]  - m[0]*m[7]*m[10]  - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7]   - m[8]*m[3]*m[6];
    inv[11] = -m[0]*m[5]*m[11]  + m[0]*m[7]*m[9]   + m[4]*m[1]*m[11] - m[4]*m[3]*m[9]  - m[8]*m[1]*m[7]   + m[8]*m[3]*m[5];
    inv[15] =  m[0]*m[5]*m[10]  - m[0]*m[6]*m[9]   - m[4]*m[1]*m[10] + m[4]*m[2]*m[9]  + m[8]*m[1]*m[6]   - m[8]*m[2]*m[5];

    det = m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12];
    if (pDeterminant)
        *pDeterminant = det;
    if (det == 0.0f)
        return nullptr;

    float invDet = 1.0f / det;
    for (int i = 0; i < 16; ++i)
        (&pOut->m[0][0])[i] = inv[i] * invDet;
    return pOut;
}

D3DXMATRIX* WINAPI D3DXMatrixScaling(D3DXMATRIX* pOut, FLOAT sx, FLOAT sy, FLOAT sz)
{
    std::memset(pOut, 0, sizeof(*pOut));
    pOut->m[0][0] = sx; pOut->m[1][1] = sy; pOut->m[2][2] = sz; pOut->m[3][3] = 1.0f;
    return pOut;
}

D3DXMATRIX* WINAPI D3DXMatrixTranslation(D3DXMATRIX* pOut, FLOAT x, FLOAT y, FLOAT z)
{
    std::memset(pOut, 0, sizeof(*pOut));
    pOut->m[0][0] = pOut->m[1][1] = pOut->m[2][2] = pOut->m[3][3] = 1.0f;
    pOut->m[3][0] = x; pOut->m[3][1] = y; pOut->m[3][2] = z;
    return pOut;
}

D3DXMATRIX* WINAPI D3DXMatrixRotationZ(D3DXMATRIX* pOut, FLOAT angle)
{
    std::memset(pOut, 0, sizeof(*pOut));
    float c = std::cos(angle), s = std::sin(angle);
    pOut->m[0][0] =  c; pOut->m[0][1] = s;
    pOut->m[1][0] = -s; pOut->m[1][1] = c;
    pOut->m[2][2] = pOut->m[3][3] = 1.0f;
    return pOut;
}

// Transform (x,y,z,1) by matrix -> 4D result.
D3DXVECTOR4* WINAPI D3DXVec3Transform(D3DXVECTOR4* pOut, CONST D3DXVECTOR3* pV, CONST D3DXMATRIX* pM)
{
    float x = pV->x, y = pV->y, z = pV->z;
    pOut->x = x*pM->m[0][0] + y*pM->m[1][0] + z*pM->m[2][0] + pM->m[3][0];
    pOut->y = x*pM->m[0][1] + y*pM->m[1][1] + z*pM->m[2][1] + pM->m[3][1];
    pOut->z = x*pM->m[0][2] + y*pM->m[1][2] + z*pM->m[2][2] + pM->m[3][2];
    pOut->w = x*pM->m[0][3] + y*pM->m[1][3] + z*pM->m[2][3] + pM->m[3][3];
    return pOut;
}

D3DXVECTOR4* WINAPI D3DXVec4Transform(D3DXVECTOR4* pOut, CONST D3DXVECTOR4* pV, CONST D3DXMATRIX* pM)
{
    float x = pV->x, y = pV->y, z = pV->z, w = pV->w;
    pOut->x = x*pM->m[0][0] + y*pM->m[1][0] + z*pM->m[2][0] + w*pM->m[3][0];
    pOut->y = x*pM->m[0][1] + y*pM->m[1][1] + z*pM->m[2][1] + w*pM->m[3][1];
    pOut->z = x*pM->m[0][2] + y*pM->m[1][2] + z*pM->m[2][2] + w*pM->m[3][2];
    pOut->w = x*pM->m[0][3] + y*pM->m[1][3] + z*pM->m[2][3] + w*pM->m[3][3];
    return pOut;
}

} // extern "C"  (math)

// ==========================================================================
// D3DX texture / surface / shader helpers (fail-cleanly stubs)
// ==========================================================================
extern "C" {

UINT WINAPI D3DXGetFVFVertexSize(DWORD FVF)
{
    // The engine relies on this for vertex stride AND for stepping through its
    // own vertex arrays (render2d etc.), so it must match D3D's layout exactly.
    UINT size = 0;
    switch (FVF & D3DFVF_POSITION_MASK) {
        case D3DFVF_XYZ:    size += 3 * sizeof(float); break;
        case D3DFVF_XYZRHW: size += 4 * sizeof(float); break;
        case D3DFVF_XYZB1:  size += 4 * sizeof(float); break;
        case D3DFVF_XYZB2:  size += 5 * sizeof(float); break;
        case D3DFVF_XYZB3:  size += 6 * sizeof(float); break;
        case D3DFVF_XYZB4:  size += 7 * sizeof(float); break;
        case D3DFVF_XYZB5:  size += 8 * sizeof(float); break;
        default: break;
    }
    // NOTE: FVF colour/point-size components are ALWAYS 32-bit in the vertex
    // layout (D3DCOLOR / FLOAT). Do NOT use sizeof(DWORD) here — on macOS LP64
    // DWORD is `unsigned long` = 8 bytes, which would inflate the stride to 48
    // for XYZ|NORMAL|DIFFUSE|TEX2 (should be 44). That mismatch makes the engine
    // step its 44-byte VertexFormatXYZNDUV2 array at 48 → every vertex past the
    // first is misread → scrambled UVs/positions (the "brown smear" 2D bug).
    if (FVF & D3DFVF_NORMAL)   size += 3 * sizeof(float);
    if (FVF & D3DFVF_PSIZE)    size += 4;
    if (FVF & D3DFVF_DIFFUSE)  size += 4;
    if (FVF & D3DFVF_SPECULAR) size += 4;

    UINT texCount = (FVF & D3DFVF_TEXCOUNT_MASK) >> D3DFVF_TEXCOUNT_SHIFT;
    for (UINT i = 0; i < texCount; ++i) {
        // 2-bit per-coord size selector at bit (16 + i*2): 0=2D,1=3D,2=4D,3=1D.
        unsigned sel = (FVF >> (16 + i * 2)) & 0x3;
        switch (sel) {
            case 0: size += 2 * sizeof(float); break;
            case 1: size += 3 * sizeof(float); break;
            case 2: size += 4 * sizeof(float); break;
            case 3: size += 1 * sizeof(float); break;
        }
    }
    {
        static int dbg = -1; if (dbg < 0) dbg = getenv("MTL_DEBUG") ? 1 : 0;
        if (dbg) { static int n=0; if (n++ < 8) { fprintf(stderr, "[fvfsize] FVF=0x%lx -> %u\n", (unsigned long)FVF, size); fflush(stderr); } }
    }
    return size;
}

HRESULT WINAPI D3DXGetErrorStringA(HRESULT /*hr*/, LPSTR pBuffer, UINT BufferLen)
{
    STUB_HIT();
    if (pBuffer && BufferLen > 0)
        pBuffer[0] = '\0';
    return E_FAIL;
}

HRESULT WINAPI D3DXAssembleShader(LPCVOID, UINT, DWORD,
                                  LPD3DXBUFFER* ppConstants,
                                  LPD3DXBUFFER* ppCompiledShader,
                                  LPD3DXBUFFER* ppCompilationErrors)
{
    STUB_HIT();
    if (ppConstants) *ppConstants = nullptr;
    if (ppCompiledShader) *ppCompiledShader = nullptr;
    if (ppCompilationErrors) *ppCompilationErrors = nullptr;
    return E_FAIL;
}

// D3DXLoadSurfaceFromSurface is implemented for real in dx8_device.cpp (needs
// MetalSurface8 internals). It was a no-op E_FAIL stub here, which silently
// broke every surface->texture copy — see the note on the real implementation.

HRESULT WINAPI D3DXFilterTexture(LPDIRECT3DBASETEXTURE8, CONST PALETTEENTRY*, UINT, DWORD)
{
    // No-op: the Metal backend GPU-generates mip chains itself (GenerateMips),
    // so engine-side mip filtering is not needed. Loud under MTL_STUB_LOG so it
    // is not mistaken for a silent failure if mips ever look wrong.
    STUB_HIT();
    return E_FAIL;
}

HRESULT WINAPI D3DXCreateTexture(LPDIRECT3DDEVICE8 pDevice, UINT Width, UINT Height,
                                 UINT MipLevels, DWORD Usage,
                                 D3DFORMAT Format, D3DPOOL Pool, LPDIRECT3DTEXTURE8* ppTexture)
{
    // TheSuperHackers @port Real implementation: D3DX is just a convenience
    // wrapper over IDirect3DDevice8::CreateTexture. Delegate to the Metal-backed
    // device so the engine actually gets a usable texture (D3DXCreateTexture is
    // how WW3D allocates almost all of its textures, incl. the "missing" tex).
    if (!ppTexture) return E_FAIL;
    *ppTexture = nullptr;
    if (!pDevice) return E_FAIL;
    // D3DX uses 0 to mean "full mip chain"; the Metal backend only exposes a
    // single level today, so 0/D3DX_DEFAULT collapse to 1 level.
    UINT levels = (MipLevels == 0 || MipLevels == 0xFFFFFFFFu) ? 1u : MipLevels;
    return pDevice->CreateTexture(Width, Height, levels, Usage, Format, Pool, ppTexture);
}

HRESULT WINAPI D3DXCreateCubeTexture(LPDIRECT3DDEVICE8, UINT, UINT, DWORD,
                                     D3DFORMAT, D3DPOOL, LPDIRECT3DCUBETEXTURE8* ppCubeTexture)
{
    STUB_HIT();
    if (ppCubeTexture) *ppCubeTexture = nullptr;
    return E_FAIL;
}

HRESULT WINAPI D3DXCreateVolumeTexture(LPDIRECT3DDEVICE8, UINT, UINT, UINT, UINT, DWORD,
                                       D3DFORMAT, D3DPOOL, LPDIRECT3DVOLUMETEXTURE8* ppVolumeTexture)
{
    STUB_HIT();
    if (ppVolumeTexture) *ppVolumeTexture = nullptr;
    return E_FAIL;
}

HRESULT WINAPI D3DXCreateTextureFromFileExA(LPDIRECT3DDEVICE8, LPCSTR, UINT, UINT, UINT, DWORD,
                                            D3DFORMAT, D3DPOOL, DWORD, DWORD, D3DCOLOR,
                                            D3DXIMAGE_INFO*, PALETTEENTRY*,
                                            LPDIRECT3DTEXTURE8* ppTexture)
{
    STUB_HIT();
    if (ppTexture) *ppTexture = nullptr;
    return E_FAIL;
}

} // extern "C"  (texture/shader)

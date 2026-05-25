// Metal-backed implementations of the DirectX8 COM interfaces (Milestone 1).
//
// IDirect3D8 (factory), IDirect3DDevice8, and the resource interfaces
// (texture / surface / vertex buffer / index buffer / swap chain) are all
// declared as pure-virtual COM vtables in <d3d8.h>. The classes below subclass
// them method-for-method, in order, so the vtable layout matches exactly.
//
// For M1 only Clear / Present / device+window creation do real work; resource
// creation returns real-but-minimal Metal-backed objects; all state setters
// store state; draw calls are no-ops (real geometry is M2/M3).
//
// macOS-only. The Cocoa/Metal work lives behind the C boundary in
// metal_backend.{h,mm} so this file stays plain C++.

#include <windows.h>   // osdep_compat shim
#include <d3d8.h>

#include <cstring>
#include <cstdio>
#include <vector>

#include "metal_backend.h"

namespace {

// IID comparison helper (the shim GUIDs are not all defined on macOS, so we
// just succeed for the common "give me myself / IUnknown" queries).
inline HRESULT BasicQueryInterface(void* self, void** ppvObj)
{
    if (!ppvObj) return E_FAIL;
    *ppvObj = self;
    return S_OK;
}

// --- BC / DXT compressed-format helpers ------------------------------------
// Apple Silicon supports BC (S3TC) texture compression natively, so DDS data is
// uploaded as compressed blocks with no CPU decode. DXT1->BC1, DXT2/3->BC2,
// DXT4/5->BC3 (block layout is identical; premultiplied-alpha distinction is a
// sampling interpretation D3D8/Metal don't track here).
inline bool IsCompressedFmt(D3DFORMAT fmt)
{
    switch (fmt) {
        case D3DFMT_DXT1: case D3DFMT_DXT2: case D3DFMT_DXT3:
        case D3DFMT_DXT4: case D3DFMT_DXT5: return true;
        default: return false;
    }
}
// bcKind for MetalContext_CreateTextureFmt: 1=BC1, 2=BC2, 3=BC3 (0 = not BC).
inline int BcKind(D3DFORMAT fmt)
{
    switch (fmt) {
        case D3DFMT_DXT1: return 1;
        case D3DFMT_DXT2: case D3DFMT_DXT3: return 2;
        case D3DFMT_DXT4: case D3DFMT_DXT5: return 3;
        default: return 0;
    }
}
// Tightly-packed BC level layout: 4x4 blocks, 8 bytes/block (BC1) or 16 (BC2/3).
// pitchOut = block-row pitch (bytes), sizeOut = total tightly-packed bytes.
inline void BcLayout(D3DFORMAT fmt, UINT w, UINT h, UINT& pitchOut, size_t& sizeOut)
{
    UINT bw = (w + 3) / 4; if (!bw) bw = 1;
    UINT bh = (h + 3) / 4; if (!bh) bh = 1;
    UINT bb = (BcKind(fmt) == 1) ? 8u : 16u;
    pitchOut = bw * bb;
    sizeOut  = (size_t)pitchOut * bh;
}

// Bytes per pixel for the uncompressed formats that reach CreateTexture.
inline UINT FormatBpp(D3DFORMAT fmt)
{
    switch (fmt) {
        case D3DFMT_A8R8G8B8: case D3DFMT_X8R8G8B8: return 4;
        case D3DFMT_R5G6B5:   case D3DFMT_A1R5G5B5:
        case D3DFMT_A4R4G4B4: return 2;
        case D3DFMT_A8:       case D3DFMT_L8:       return 1;
        case D3DFMT_R8G8B8:                          return 3;
        default:                                     return 4;
    }
}

// Expand one row of the given source format into BGRA8 (Metal BGRA8Unorm).
inline void ConvertRowToBGRA8(D3DFORMAT fmt, const unsigned char* src, unsigned char* dst, UINT width)
{
    switch (fmt) {
        case D3DFMT_A8R8G8B8: // already B,G,R,A in memory
            std::memcpy(dst, src, (size_t)width * 4);
            break;
        case D3DFMT_X8R8G8B8: // B,G,R,X -> force opaque
            for (UINT x = 0; x < width; ++x) {
                dst[x*4+0] = src[x*4+0]; dst[x*4+1] = src[x*4+1];
                dst[x*4+2] = src[x*4+2]; dst[x*4+3] = 255;
            }
            break;
        case D3DFMT_R8G8B8: // B,G,R -> B,G,R,255
            for (UINT x = 0; x < width; ++x) {
                dst[x*4+0] = src[x*3+0]; dst[x*4+1] = src[x*3+1];
                dst[x*4+2] = src[x*3+2]; dst[x*4+3] = 255;
            }
            break;
        case D3DFMT_R5G6B5:
            for (UINT x = 0; x < width; ++x) {
                unsigned short p = ((const unsigned short*)src)[x];
                unsigned r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
                dst[x*4+0] = (unsigned char)((b << 3) | (b >> 2));
                dst[x*4+1] = (unsigned char)((g << 2) | (g >> 4));
                dst[x*4+2] = (unsigned char)((r << 3) | (r >> 2));
                dst[x*4+3] = 255;
            }
            break;
        case D3DFMT_A1R5G5B5:
            for (UINT x = 0; x < width; ++x) {
                unsigned short p = ((const unsigned short*)src)[x];
                unsigned a = (p >> 15) & 0x1, r = (p >> 10) & 0x1F, g = (p >> 5) & 0x1F, b = p & 0x1F;
                dst[x*4+0] = (unsigned char)((b << 3) | (b >> 2));
                dst[x*4+1] = (unsigned char)((g << 3) | (g >> 2));
                dst[x*4+2] = (unsigned char)((r << 3) | (r >> 2));
                dst[x*4+3] = a ? 255 : 0;
            }
            break;
        case D3DFMT_A4R4G4B4:
            for (UINT x = 0; x < width; ++x) {
                unsigned short p = ((const unsigned short*)src)[x];
                unsigned a = (p >> 12) & 0xF, r = (p >> 8) & 0xF, g = (p >> 4) & 0xF, b = p & 0xF;
                dst[x*4+0] = (unsigned char)(b * 17);
                dst[x*4+1] = (unsigned char)(g * 17);
                dst[x*4+2] = (unsigned char)(r * 17);
                dst[x*4+3] = (unsigned char)(a * 17);
            }
            break;
        case D3DFMT_A8: // alpha-only mask: white rgb, src alpha
            for (UINT x = 0; x < width; ++x) {
                dst[x*4+0] = 255; dst[x*4+1] = 255; dst[x*4+2] = 255; dst[x*4+3] = src[x];
            }
            break;
        case D3DFMT_L8: // luminance: grey, opaque
            for (UINT x = 0; x < width; ++x) {
                dst[x*4+0] = src[x]; dst[x*4+1] = src[x]; dst[x*4+2] = src[x]; dst[x*4+3] = 255;
            }
            break;
        default:
            std::memcpy(dst, src, (size_t)width * 4);
            break;
    }
}

// ---------------------------------------------------------------------------
// IDirect3DTexture8  (single-level RGBA texture wrapping an MTLTexture)
// ---------------------------------------------------------------------------
class MetalTexture8 : public IDirect3DTexture8 {
public:
    MetalTexture8(IDirect3DDevice8* dev, MetalContext* ctx, UINT w, UINT h, D3DFORMAT fmt)
        : m_refCount(1), m_device(dev), m_width(w), m_height(h), m_format(fmt)
    {
        m_compressed = IsCompressedFmt(fmt);
        if (m_compressed) {
            // Native BC texture; CPU staging holds tightly-packed compressed
            // blocks (the engine memcpy's the DDS level straight in).
            m_texture = MetalContext_CreateTextureFmt(ctx, (int)w, (int)h, BcKind(fmt));
            size_t sz = 0;
            BcLayout(fmt, w ? w : 1, h ? h : 1, m_pitch, sz);
            m_staging.resize(sz, 0);
        } else {
            m_texture = MetalContext_CreateTexture(ctx, (int)w, (int)h);
            m_bpp     = FormatBpp(fmt);
            m_pitch   = (w ? w : 1) * m_bpp;
            // CPU staging in the source format; converted to BGRA8 on UnlockRect.
            m_staging.resize((size_t)m_pitch * (h ? h : 1), 0);
        }
    }
    ~MetalTexture8() { MetalContext_ReleaseTexture(m_texture); }

    void* dxTexture() const { return m_texture; } // opaque MTLTexture*

    // IUnknown
    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    // IDirect3DResource8
    STDMETHOD(GetDevice)(IDirect3DDevice8** ppDevice) override { if (ppDevice) { *ppDevice = m_device; } return S_OK; }
    STDMETHOD(SetPrivateData)(REFGUID, CONST void*, DWORD, DWORD) override { return S_OK; }
    STDMETHOD(GetPrivateData)(REFGUID, void*, DWORD*) override { return E_FAIL; }
    STDMETHOD(FreePrivateData)(REFGUID) override { return S_OK; }
    STDMETHOD_(DWORD, SetPriority)(DWORD) override { return 0; }
    STDMETHOD_(DWORD, GetPriority)() override { return 0; }
    STDMETHOD_(void, PreLoad)() override {}
    STDMETHOD_(D3DRESOURCETYPE, GetType)() override { return D3DRTYPE_TEXTURE; }

    // IDirect3DBaseTexture8
    STDMETHOD_(DWORD, SetLOD)(DWORD) override { return 0; }
    STDMETHOD_(DWORD, GetLOD)() override { return 0; }
    STDMETHOD_(DWORD, GetLevelCount)() override { return 1; }

    // IDirect3DTexture8
    STDMETHOD(GetLevelDesc)(UINT, D3DSURFACE_DESC* pDesc) override
    {
        if (pDesc) {
            std::memset(pDesc, 0, sizeof(*pDesc));
            pDesc->Format = m_format;
            pDesc->Type   = D3DRTYPE_SURFACE;
            pDesc->Pool   = D3DPOOL_MANAGED;
            pDesc->Width  = m_width;
            pDesc->Height = m_height;
            pDesc->Size   = (UINT)m_staging.size();
        }
        return S_OK;
    }
    // Defined out-of-line below (needs the full MetalSurface8 definition).
    STDMETHOD(GetSurfaceLevel)(UINT Level, IDirect3DSurface8** ppSurfaceLevel) override;
    STDMETHOD(LockRect)(UINT, D3DLOCKED_RECT* pLockedRect, CONST RECT*, DWORD) override
    {
        if (pLockedRect) {
            pLockedRect->Pitch = (INT)m_pitch;
            pLockedRect->pBits = m_staging.data();
        }
        return S_OK;
    }
    STDMETHOD(UnlockRect)(UINT) override
    {
        // Convert the locked source-format bytes to BGRA8 and push to the GPU.
        if (!m_texture || m_staging.empty()) return S_OK;
        if (m_compressed) {
            // Upload the BC blocks verbatim (no conversion).
            MetalContext_UploadTextureRaw(m_texture, (int)(m_width ? m_width : 1),
                                          (int)(m_height ? m_height : 1),
                                          m_staging.data(), (int)m_pitch);
            return S_OK;
        }
        const UINT w = m_width ? m_width : 1;
        const UINT h = m_height ? m_height : 1;
        std::vector<unsigned char> bgra((size_t)w * h * 4);
        for (UINT y = 0; y < h; ++y) {
            ConvertRowToBGRA8(m_format, m_staging.data() + (size_t)y * m_pitch,
                              bgra.data() + (size_t)y * w * 4, w);
        }
        {
            const unsigned char* cc = bgra.data() + ((size_t)(h/2) * w + (w/2)) * 4;
            m_isMissing = (cc[0]==255 && cc[1]==0 && cc[2]==255);
        }
        static int dbg = -1; if (dbg < 0) dbg = getenv("MTL_DEBUG") ? 1 : 0;
        if (dbg) {
            static int n = 0;
            if (n++ < 24) {
                const unsigned char* c = bgra.data() + ((size_t)(h/2) * w + (w/2)) * 4;
                std::fprintf(stderr, "[tex] #%d this=%p fmt=%u %ux%u center BGRA=%u,%u,%u,%u%s\n",
                             n, (void*)this, (unsigned)m_format, w, h, c[0], c[1], c[2], c[3],
                             m_isMissing ? "  <-- MISSING" : "");
            }
        }
        MetalContext_UploadTextureBGRA8(m_texture, (int)w, (int)h, bgra.data(), (int)(w * 4));
        return S_OK;
    }
    bool isMissingTex() const { return m_isMissing; }
    STDMETHOD(AddDirtyRect)(CONST RECT*) override { return S_OK; }

private:
    ULONG             m_refCount;
    IDirect3DDevice8* m_device;
    void*             m_texture;   // MTLTexture (CFRetained)
    UINT              m_width, m_height;
    D3DFORMAT         m_format;
    UINT              m_bpp = 4;
    UINT              m_pitch;
    bool              m_isMissing = false;
    bool              m_compressed = false;
    std::vector<unsigned char> m_staging;
};

// ---------------------------------------------------------------------------
// IDirect3DSurface8  (plain CPU surface; back/depth buffers and image surfaces)
// ---------------------------------------------------------------------------
class MetalSurface8 : public IDirect3DSurface8 {
public:
    MetalSurface8(IDirect3DDevice8* dev, UINT w, UINT h, D3DFORMAT fmt)
        : m_refCount(1), m_device(dev), m_width(w), m_height(h), m_format(fmt)
    {
        m_compressed = IsCompressedFmt(fmt);
        if (m_compressed) {
            // Texture mip level for a BC/DDS texture: staging holds tightly-packed
            // compressed blocks (DDSFileClass::Copy_Level_To_Surface memcpy's them).
            size_t sz = 0;
            BcLayout(fmt, w ? w : 1, h ? h : 1, m_pitch, sz);
            m_staging.resize(sz, 0);
        } else {
            m_bpp   = FormatBpp(fmt);
            m_pitch = (w ? w : 1) * m_bpp;
            m_staging.resize((size_t)m_pitch * (h ? h : 1), 0);
        }
    }

    // When this surface is a texture mip level (returned by
    // MetalTexture8::GetSurfaceLevel), it carries the owning MTLTexture so that
    // a CopyRects/UnlockRect into it pushes the pixels to the GPU.
    void bindUploadTexture(void* mtlTexture) { m_uploadTexture = mtlTexture; }

    // Accessors used by MetalDevice8::CopyRects.
    UINT      surfWidth()  const { return m_width; }
    UINT      surfHeight() const { return m_height; }
    D3DFORMAT surfFormat() const { return m_format; }
    UINT      surfPitch()  const { return m_pitch; }
    unsigned char*       surfBits()       { return m_staging.data(); }
    const unsigned char* surfBits() const { return m_staging.data(); }
    void*     uploadTexture() const { return m_uploadTexture; }

    // Convert this surface's bytes to BGRA8 and push to the bound MTLTexture
    // (no-op if this surface isn't a texture level).
    void flushToTexture()
    {
        if (!m_uploadTexture || m_staging.empty()) return;
        if (m_compressed) {
            // Upload BC blocks verbatim (no conversion).
            MetalContext_UploadTextureRaw(m_uploadTexture, (int)(m_width ? m_width : 1),
                                          (int)(m_height ? m_height : 1),
                                          m_staging.data(), (int)m_pitch);
            return;
        }
        const UINT w = m_width ? m_width : 1;
        const UINT h = m_height ? m_height : 1;
        std::vector<unsigned char> bgra((size_t)w * h * 4);
        for (UINT y = 0; y < h; ++y)
            ConvertRowToBGRA8(m_format, m_staging.data() + (size_t)y * m_pitch,
                              bgra.data() + (size_t)y * w * 4, w);
        static int dbg = -1; if (dbg < 0) dbg = getenv("MTL_DEBUG") ? 1 : 0;
        if (dbg) {
            static int n = 0;
            if (n++ < 40) {
                unsigned long aSum = 0; int aMax = 0;
                unsigned long rgbSum = 0;
                for (size_t i = 0; i + 3 < bgra.size(); i += 4) {
                    aSum += bgra[i+3]; if (bgra[i+3] > aMax) aMax = bgra[i+3];
                    rgbSum += bgra[i] + bgra[i+1] + bgra[i+2];
                }
                const unsigned char* cc = bgra.data() + (((size_t)(h/2) * w) + (w/2)) * 4;
                // raw 16-bit staging value at center (for A1R5G5B5 etc.)
                unsigned rawc = 0;
                if (m_bpp == 2) rawc = ((const unsigned short*)(m_staging.data() + (size_t)(h/2)*m_pitch))[w/2];
                std::fprintf(stderr, "[surf->tex] flush tex=%p %ux%u fmt=%u alphaMax=%d centerBGRA=%u,%u,%u,%u raw16=0x%04x rgbAvg=%lu\n",
                             m_uploadTexture, w, h, (unsigned)m_format, aMax,
                             cc[0],cc[1],cc[2],cc[3], rawc, rgbSum/((unsigned long)w*h*3));
                std::fflush(stderr);
            }
        }
        MetalContext_UploadTextureBGRA8(m_uploadTexture, (int)w, (int)h,
                                        bgra.data(), (int)(w * 4));
    }

    // IUnknown
    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    // IDirect3DSurface8
    STDMETHOD(GetDevice)(IDirect3DDevice8** ppDevice) override { if (ppDevice) *ppDevice = m_device; return S_OK; }
    STDMETHOD(SetPrivateData)(REFGUID, CONST void*, DWORD, DWORD) override { return S_OK; }
    STDMETHOD(GetPrivateData)(REFGUID, void*, DWORD*) override { return E_FAIL; }
    STDMETHOD(FreePrivateData)(REFGUID) override { return S_OK; }
    STDMETHOD(GetContainer)(REFIID, void** ppContainer) override { if (ppContainer) *ppContainer = nullptr; return E_FAIL; }
    STDMETHOD(GetDesc)(D3DSURFACE_DESC* pDesc) override
    {
        if (pDesc) {
            std::memset(pDesc, 0, sizeof(*pDesc));
            pDesc->Format = m_format;
            pDesc->Type   = D3DRTYPE_SURFACE;
            pDesc->Pool   = D3DPOOL_DEFAULT;
            pDesc->Width  = m_width;
            pDesc->Height = m_height;
            pDesc->Size   = (UINT)m_staging.size();
        }
        return S_OK;
    }
    STDMETHOD(LockRect)(D3DLOCKED_RECT* pLockedRect, CONST RECT*, DWORD) override
    {
        if (pLockedRect) {
            pLockedRect->Pitch = (INT)m_pitch;
            pLockedRect->pBits = m_staging.data();
        }
        return S_OK;
    }
    STDMETHOD(UnlockRect)() override { flushToTexture(); return S_OK; }

private:
    ULONG             m_refCount;
    IDirect3DDevice8* m_device;
    UINT              m_width, m_height;
    D3DFORMAT         m_format;
    UINT              m_bpp = 4;
    UINT              m_pitch = 0;
    bool              m_compressed = false;
    void*             m_uploadTexture = nullptr;  // MTLTexture if this is a texture level
    std::vector<unsigned char> m_staging;
};

// MetalTexture8::GetSurfaceLevel — defined here because it constructs a
// MetalSurface8 (full definition only available above this point).
HRESULT STDMETHODCALLTYPE MetalTexture8::GetSurfaceLevel(UINT Level, IDirect3DSurface8** ppSurfaceLevel)
{
    // Hand back a surface describing this mip level. We only expose level 0
    // (GetLevelCount()==1); each level halves the dimensions (min 1).
    if (!ppSurfaceLevel) return E_FAIL;
    UINT w = m_width  >> Level; if (!w) w = 1;
    UINT h = m_height >> Level; if (!h) h = 1;
    // Bind the level surface to this texture's MTLTexture (level 0 only) so that
    // CopyRects / UnlockRect into it pushes the pixels to the GPU. This is the
    // path the font glyph atlas uses (Render2DSentenceClass copies an
    // A4R4G4B4 image surface into the texture's surface level).
    MetalSurface8* surf = new MetalSurface8(m_device, w, h, m_format);
    if (Level == 0) surf->bindUploadTexture(m_texture);
    *ppSurfaceLevel = surf;
    return D3D_OK;
}

// ---------------------------------------------------------------------------
// IDirect3DVertexBuffer8  (wraps an MTLBuffer; Lock/Unlock expose CPU pointer)
// ---------------------------------------------------------------------------
class MetalVertexBuffer8 : public IDirect3DVertexBuffer8 {
public:
    MetalVertexBuffer8(IDirect3DDevice8* dev, MetalContext* ctx, UINT length, DWORD usage, DWORD fvf, D3DPOOL pool)
        : m_refCount(1), m_device(dev), m_length(length), m_usage(usage), m_fvf(fvf), m_pool(pool)
    {
        m_buffer   = MetalContext_CreateBuffer(ctx, length);
        m_contents = MetalContext_BufferContents(m_buffer);
    }
    ~MetalVertexBuffer8() { MetalContext_ReleaseBuffer(m_buffer); }

    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    STDMETHOD(GetDevice)(IDirect3DDevice8** ppDevice) override { if (ppDevice) *ppDevice = m_device; return S_OK; }
    STDMETHOD(SetPrivateData)(REFGUID, CONST void*, DWORD, DWORD) override { return S_OK; }
    STDMETHOD(GetPrivateData)(REFGUID, void*, DWORD*) override { return E_FAIL; }
    STDMETHOD(FreePrivateData)(REFGUID) override { return S_OK; }
    STDMETHOD_(DWORD, SetPriority)(DWORD) override { return 0; }
    STDMETHOD_(DWORD, GetPriority)() override { return 0; }
    STDMETHOD_(void, PreLoad)() override {}
    STDMETHOD_(D3DRESOURCETYPE, GetType)() override { return D3DRTYPE_VERTEXBUFFER; }

    STDMETHOD(Lock)(UINT OffsetToLock, UINT /*SizeToLock*/, BYTE** ppbData, DWORD /*Flags*/) override
    {
        if (ppbData) *ppbData = m_contents ? ((BYTE*)m_contents + OffsetToLock) : nullptr;
        return S_OK; // shared MTLBuffer: writes are visible directly, no upload needed.
    }
    STDMETHOD(Unlock)() override { return S_OK; }
    STDMETHOD(GetDesc)(D3DVERTEXBUFFER_DESC* pDesc) override
    {
        if (pDesc) {
            std::memset(pDesc, 0, sizeof(*pDesc));
            pDesc->Type  = D3DRTYPE_VERTEXBUFFER;
            pDesc->Usage = m_usage;
            pDesc->Pool  = m_pool;
            pDesc->Size  = m_length;
            pDesc->FVF   = m_fvf;
        }
        return S_OK;
    }

    void* contents() const { return m_contents; }
    void* dxBuffer() const { return m_buffer; } // opaque MTLBuffer*

private:
    ULONG             m_refCount;
    IDirect3DDevice8* m_device;
    void*             m_buffer;
    void*             m_contents;
    UINT              m_length;
    DWORD             m_usage;
    DWORD             m_fvf;
    D3DPOOL           m_pool;
};

// ---------------------------------------------------------------------------
// IDirect3DIndexBuffer8
// ---------------------------------------------------------------------------
class MetalIndexBuffer8 : public IDirect3DIndexBuffer8 {
public:
    MetalIndexBuffer8(IDirect3DDevice8* dev, MetalContext* ctx, UINT length, DWORD usage, D3DFORMAT fmt, D3DPOOL pool)
        : m_refCount(1), m_device(dev), m_length(length), m_usage(usage), m_format(fmt), m_pool(pool)
    {
        m_buffer   = MetalContext_CreateBuffer(ctx, length);
        m_contents = MetalContext_BufferContents(m_buffer);
    }
    ~MetalIndexBuffer8() { MetalContext_ReleaseBuffer(m_buffer); }

    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    STDMETHOD(GetDevice)(IDirect3DDevice8** ppDevice) override { if (ppDevice) *ppDevice = m_device; return S_OK; }
    STDMETHOD(SetPrivateData)(REFGUID, CONST void*, DWORD, DWORD) override { return S_OK; }
    STDMETHOD(GetPrivateData)(REFGUID, void*, DWORD*) override { return E_FAIL; }
    STDMETHOD(FreePrivateData)(REFGUID) override { return S_OK; }
    STDMETHOD_(DWORD, SetPriority)(DWORD) override { return 0; }
    STDMETHOD_(DWORD, GetPriority)() override { return 0; }
    STDMETHOD_(void, PreLoad)() override {}
    STDMETHOD_(D3DRESOURCETYPE, GetType)() override { return D3DRTYPE_INDEXBUFFER; }

    STDMETHOD(Lock)(UINT OffsetToLock, UINT /*SizeToLock*/, BYTE** ppbData, DWORD /*Flags*/) override
    {
        if (ppbData) *ppbData = m_contents ? ((BYTE*)m_contents + OffsetToLock) : nullptr;
        return S_OK;
    }
    STDMETHOD(Unlock)() override { return S_OK; }
    STDMETHOD(GetDesc)(D3DINDEXBUFFER_DESC* pDesc) override
    {
        if (pDesc) {
            std::memset(pDesc, 0, sizeof(*pDesc));
            pDesc->Format = m_format;
            pDesc->Type   = D3DRTYPE_INDEXBUFFER;
            pDesc->Usage  = m_usage;
            pDesc->Pool   = m_pool;
            pDesc->Size   = m_length;
        }
        return S_OK;
    }

    void* dxBuffer() const { return m_buffer; } // opaque MTLBuffer*

private:
    ULONG             m_refCount;
    IDirect3DDevice8* m_device;
    void*             m_buffer;
    void*             m_contents;
    UINT              m_length;
    DWORD             m_usage;
    D3DFORMAT         m_format;
    D3DPOOL           m_pool;
};

// ---------------------------------------------------------------------------
// State storage for the device (M1: store only, no GPU effect)
// ---------------------------------------------------------------------------
constexpr int MAX_RENDER_STATES = 256;
constexpr int MAX_TEXTURE_STAGES = 8;
constexpr int MAX_TSS = 32;
constexpr int MAX_LIGHTS = 16;
constexpr int MAX_TRANSFORMS = 512;

// Byte offsets of the vertex components for a given FVF (D3D's fixed order:
// position, normal, [point size], diffuse, specular, texcoords).
struct FvfLayout { int posOffset; int posFloats; int normalOffset; int diffuseOffset; int tex0Offset; int tex1Offset; };
inline FvfLayout ComputeFvfLayout(DWORD fvf)
{
    FvfLayout L;
    L.posOffset  = 0;
    L.posFloats  = (fvf & D3DFVF_XYZRHW) ? 4 : 3;
    int cursor   = L.posFloats * 4;
    L.normalOffset = (fvf & D3DFVF_NORMAL) ? cursor : -1;
    if (fvf & D3DFVF_NORMAL) cursor += 12;
    if (fvf & D3DFVF_PSIZE)  cursor += 4;
    L.diffuseOffset = (fvf & D3DFVF_DIFFUSE) ? cursor : -1;
    if (fvf & D3DFVF_DIFFUSE)  cursor += 4;
    if (fvf & D3DFVF_SPECULAR) cursor += 4;
    int texcount = (fvf & D3DFVF_TEXCOUNT_MASK) >> D3DFVF_TEXCOUNT_SHIFT;
    L.tex0Offset = (texcount >= 1) ? cursor                : -1;
    L.tex1Offset = (texcount >= 2) ? (cursor + 8)          : -1;
    return L;
}

// D3D row-major multiply: C = A * B  (C[i][j] = sum_k A[i][k] * B[k][j]).
inline void MatMul(D3DMATRIX& C, const D3DMATRIX& A, const D3DMATRIX& B)
{
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k) s += A.m[i][k] * B.m[k][j];
            C.m[i][j] = s;
        }
}

inline UINT IndexCountFor(D3DPRIMITIVETYPE p, UINT primCount)
{
    switch (p) {
        case D3DPT_TRIANGLELIST:  return primCount * 3;
        case D3DPT_TRIANGLESTRIP: return primCount + 2;
        case D3DPT_TRIANGLEFAN:   return primCount + 2;
        default:                  return primCount * 3;
    }
}

} // anonymous namespace

// Device-level draw instrumentation (enabled by MTL_DEBUG env var).
static long g_drawCalls = 0, g_drawSkipped = 0, g_beginScene = 0, g_missingBound = 0, g_realBound = 0, g_noTexBound = 0;
static int  g_dbg = -1;
static inline bool DbgOn() { if (g_dbg < 0) g_dbg = getenv("MTL_DEBUG") ? 1 : 0; return g_dbg > 0; }

// ---------------------------------------------------------------------------
// IDirect3DDevice8
// ---------------------------------------------------------------------------
class MetalDevice8 : public IDirect3DDevice8 {
public:
    MetalDevice8(IDirect3D8* parent, MetalContext* ctx, const D3DPRESENT_PARAMETERS& pp)
        : m_refCount(1), m_parent(parent), m_ctx(ctx)
    {
        std::memset(m_renderStates, 0, sizeof(m_renderStates));
        // TheSuperHackers @fix macOS-port: seed D3DRS_ZENABLE=TRUE.
        // WW3D2 has `DX8Wrapper::Apply_Default_State()` that would set this
        // but it is never CALLED in the source tree, and the D3D8 device default
        // is D3DZB_TRUE on hardware with a depth buffer. Without this, the shim's
        // zero-initialized state array leaves D3DRS_ZENABLE = 0 forever, because
        // `ShaderClass::Apply()` (the only place per-shader depth state is set)
        // writes D3DRS_ZFUNC and D3DRS_ZWRITEENABLE but NOT D3DRS_ZENABLE. Result:
        // ALL draws ran with depth-test OFF and 3D only looked vaguely right by
        // submission order — water (drawn last) ended up painted OVER helicopters
        // and ships that should occlude it. Other render states the engine touches
        // per-draw don't need defaults seeded here; only narrow this one to avoid
        // perturbing in-game render flow that depended on the prior (broken) state.
        // Opt-out: MTL_DEPTH_OFF=1 restores zero-init for A/B testing.
        const int s_noDepth = getenv("MTL_DEPTH_OFF") ? 1 : 0;
        m_renderStates[D3DRS_ZENABLE] = s_noDepth ? FALSE : TRUE;  // D3DZB_TRUE
        // Stencil defaults (same as D3D8 spec; otherwise per-draw FillCommon reads
        // zeroes which we map to "no-op" but the FUNC/REF/MASK behaviour would
        // be wrong if a frame enabled stencil without setting every state).
        m_renderStates[D3DRS_STENCILFAIL]      = D3DSTENCILOP_KEEP;
        m_renderStates[D3DRS_STENCILZFAIL]     = D3DSTENCILOP_KEEP;
        m_renderStates[D3DRS_STENCILPASS]      = D3DSTENCILOP_KEEP;
        m_renderStates[D3DRS_STENCILFUNC]      = D3DCMP_ALWAYS;
        m_renderStates[D3DRS_STENCILREF]       = 0;
        m_renderStates[D3DRS_STENCILMASK]      = 0xFFFFFFFF;
        m_renderStates[D3DRS_STENCILWRITEMASK] = 0xFFFFFFFF;
        // Default: all four RGBA channels writable. Volumetric shadow passes
        // disable this (Set_DX8_Render_State(D3DRS_COLORWRITEENABLE, 0)) to do
        // stencil-only writes; the shim must honour that to make the shadow
        // pipeline functional.
        m_renderStates[D3DRS_COLORWRITEENABLE] = 0x0F;
        std::memset(m_tss, 0, sizeof(m_tss));
        std::memset(m_textures, 0, sizeof(m_textures));
        std::memset(&m_material, 0, sizeof(m_material));
        std::memset(m_lights, 0, sizeof(m_lights));
        std::memset(m_lightEnable, 0, sizeof(m_lightEnable));
        std::memset(m_clipPlanes, 0, sizeof(m_clipPlanes));
        m_vertexShader = 0;
        m_pixelShader  = 0;
        m_indices      = nullptr;
        m_baseVertexIndex = 0;
        m_streamSource = nullptr;
        m_streamStride = 0;
        m_clearColor   = 0;

        m_width  = pp.BackBufferWidth  ? pp.BackBufferWidth  : 1024;
        m_height = pp.BackBufferHeight ? pp.BackBufferHeight : 768;

        m_viewport.X = 0; m_viewport.Y = 0;
        m_viewport.Width = m_width; m_viewport.Height = m_height;
        m_viewport.MinZ = 0.0f; m_viewport.MaxZ = 1.0f;

        for (int i = 0; i < MAX_TRANSFORMS; ++i) IdentityMatrix(m_transforms[i]);
    }
    ~MetalDevice8() { if (m_ctx) MetalContext_Destroy(m_ctx); }

    // ---- IUnknown ----
    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    // ---- device info / cooperative level ----
    STDMETHOD(TestCooperativeLevel)() override { return D3D_OK; }
    STDMETHOD_(UINT, GetAvailableTextureMem)() override { return 256u * 1024u * 1024u; }
    STDMETHOD(ResourceManagerDiscardBytes)(DWORD) override { return D3D_OK; }
    STDMETHOD(GetDirect3D)(IDirect3D8** ppD3D8) override { if (ppD3D8) { *ppD3D8 = m_parent; if (m_parent) m_parent->AddRef(); } return D3D_OK; }
    STDMETHOD(GetDeviceCaps)(D3DCAPS8* pCaps) override;
    STDMETHOD(GetDisplayMode)(D3DDISPLAYMODE* pMode) override
    {
        if (pMode) { pMode->Width = m_width; pMode->Height = m_height; pMode->RefreshRate = 60; pMode->Format = D3DFMT_X8R8G8B8; }
        return D3D_OK;
    }
    STDMETHOD(GetCreationParameters)(D3DDEVICE_CREATION_PARAMETERS* p) override
    {
        if (p) { p->AdapterOrdinal = 0; p->DeviceType = D3DDEVTYPE_HAL; p->hFocusWindow = nullptr; p->BehaviorFlags = 0; }
        return D3D_OK;
    }

    // ---- cursor ----
    STDMETHOD(SetCursorProperties)(UINT, UINT, IDirect3DSurface8*) override { return D3D_OK; }
    STDMETHOD_(void, SetCursorPosition)(UINT, UINT, DWORD) override {}
    STDMETHOD_(BOOL, ShowCursor)(BOOL) override { return TRUE; }

    // ---- swap chain / reset / present ----
    STDMETHOD(CreateAdditionalSwapChain)(D3DPRESENT_PARAMETERS*, IDirect3DSwapChain8** pSwapChain) override
    {
        if (pSwapChain) *pSwapChain = nullptr;
        return E_NOTIMPL;
    }
    STDMETHOD(Reset)(D3DPRESENT_PARAMETERS* pp) override
    {
        if (pp && pp->BackBufferWidth && pp->BackBufferHeight) {
            m_width  = pp->BackBufferWidth;
            m_height = pp->BackBufferHeight;
            if (m_ctx) MetalContext_Resize(m_ctx, (int)m_width, (int)m_height);
        }
        return D3D_OK;
    }
    STDMETHOD(Present)(CONST RECT*, CONST RECT*, HWND, CONST RGNDATA*) override
    {
        if (m_ctx) MetalContext_Present(m_ctx);
        if (DbgOn()) {
            static long f = 0;
            if (f < 8 || (f % 120) == 0)
                std::fprintf(stderr, "[dev] present %ld: draws=%ld skipped=%ld | bound real=%ld missing=%ld none=%ld\n",
                             f, g_drawCalls, g_drawSkipped, g_realBound, g_missingBound, g_noTexBound);
            ++f;
        }
        return D3D_OK;
    }

    // ---- back/front buffers ----
    STDMETHOD(GetBackBuffer)(UINT, D3DBACKBUFFER_TYPE, IDirect3DSurface8** ppBackBuffer) override
    {
        if (ppBackBuffer) *ppBackBuffer = new MetalSurface8(this, m_width, m_height, D3DFMT_A8R8G8B8);
        return D3D_OK;
    }
    STDMETHOD(GetRasterStatus)(D3DRASTER_STATUS* p) override { if (p) std::memset(p, 0, sizeof(*p)); return D3D_OK; }
    STDMETHOD_(void, SetGammaRamp)(DWORD, CONST D3DGAMMARAMP* pRamp) override { if (pRamp) m_gammaRamp = *pRamp; }
    STDMETHOD_(void, GetGammaRamp)(D3DGAMMARAMP* pRamp) override { if (pRamp) *pRamp = m_gammaRamp; }

    // ---- resource creation ----
    STDMETHOD(CreateTexture)(UINT Width, UINT Height, UINT, DWORD, D3DFORMAT Format, D3DPOOL, IDirect3DTexture8** ppTexture) override
    {
        if (ppTexture) *ppTexture = new MetalTexture8(this, m_ctx, Width, Height, Format);
        return D3D_OK;
    }
    STDMETHOD(CreateVolumeTexture)(UINT, UINT, UINT, UINT, DWORD, D3DFORMAT, D3DPOOL, IDirect3DVolumeTexture8** pp) override
    {
        if (pp) *pp = nullptr;
        return E_NOTIMPL;
    }
    STDMETHOD(CreateCubeTexture)(UINT, UINT, DWORD, D3DFORMAT, D3DPOOL, IDirect3DCubeTexture8** pp) override
    {
        if (pp) *pp = nullptr;
        return E_NOTIMPL;
    }
    STDMETHOD(CreateVertexBuffer)(UINT Length, DWORD Usage, DWORD FVF, D3DPOOL Pool, IDirect3DVertexBuffer8** ppVB) override
    {
        if (ppVB) *ppVB = new MetalVertexBuffer8(this, m_ctx, Length, Usage, FVF, Pool);
        return D3D_OK;
    }
    STDMETHOD(CreateIndexBuffer)(UINT Length, DWORD Usage, D3DFORMAT Format, D3DPOOL Pool, IDirect3DIndexBuffer8** ppIB) override
    {
        if (ppIB) *ppIB = new MetalIndexBuffer8(this, m_ctx, Length, Usage, Format, Pool);
        return D3D_OK;
    }
    STDMETHOD(CreateRenderTarget)(UINT Width, UINT Height, D3DFORMAT Format, D3DMULTISAMPLE_TYPE, BOOL, IDirect3DSurface8** ppSurface) override
    {
        if (ppSurface) *ppSurface = new MetalSurface8(this, Width, Height, Format);
        return D3D_OK;
    }
    STDMETHOD(CreateDepthStencilSurface)(UINT Width, UINT Height, D3DFORMAT Format, D3DMULTISAMPLE_TYPE, IDirect3DSurface8** ppSurface) override
    {
        if (ppSurface) *ppSurface = new MetalSurface8(this, Width, Height, Format);
        return D3D_OK;
    }
    STDMETHOD(CreateImageSurface)(UINT Width, UINT Height, D3DFORMAT Format, IDirect3DSurface8** ppSurface) override
    {
        if (ppSurface) *ppSurface = new MetalSurface8(this, Width, Height, Format);
        return D3D_OK;
    }
    STDMETHOD(CopyRects)(IDirect3DSurface8* pSourceSurface, CONST RECT* pSourceRectsArray,
                         UINT cRects, IDirect3DSurface8* pDestinationSurface,
                         CONST POINT* pDestPointsArray) override
    {
        // All our surfaces are MetalSurface8. Copy the requested rect(s) from
        // src into dst, converting pixel format via BGRA8 (the lingua franca);
        // then push the destination to its GPU texture if it is a texture level.
        // The main consumer is the font glyph atlas (A4R4G4B4 image surface ->
        // A8R8G8B8 texture level), which copies the whole surface (cRects==0).
        if (!pSourceSurface || !pDestinationSurface) return D3D_OK;
        MetalSurface8* src = static_cast<MetalSurface8*>(pSourceSurface);
        MetalSurface8* dst = static_cast<MetalSurface8*>(pDestinationSurface);

        const UINT srcBpp = FormatBpp(src->surfFormat());
        const UINT dstBpp = FormatBpp(dst->surfFormat());
        unsigned char*       dstBits = dst->surfBits();
        const unsigned char* srcBits = src->surfBits();
        if (!dstBits || !srcBits) return D3D_OK;

        // Debug: dump the source surface (engine-written) to PNG once.
        if (getenv("MTL_DUMPTEX")) {
            static int cn = 0;
            if (cn < 6) {
                UINT sw = src->surfWidth(), sh = src->surfHeight();
                std::vector<unsigned char> bgra((size_t)sw*sh*4);
                for (UINT y=0;y<sh;++y)
                    ConvertRowToBGRA8(src->surfFormat(), srcBits + (size_t)y*src->surfPitch(),
                                      bgra.data() + (size_t)y*sw*4, sw);
                char nm[64]; std::snprintf(nm, sizeof(nm), "copyrect_src_%02d", cn++);
                MetalDebug_DumpBGRA(nm, (int)sw, (int)sh, bgra.data(), (int)(sw*4));
            }
        }

        // Build the rectangle list (NULL/0 means "whole source surface").
        RECT whole = { 0, 0, (LONG)src->surfWidth(), (LONG)src->surfHeight() };
        std::vector<unsigned char> scratch;
        const UINT n = (pSourceRectsArray && cRects) ? cRects : 1;
        for (UINT i = 0; i < n; ++i) {
            RECT r = (pSourceRectsArray && cRects) ? pSourceRectsArray[i] : whole;
            int dx = (pDestPointsArray && cRects) ? pDestPointsArray[i].x : 0;
            int dy = (pDestPointsArray && cRects) ? pDestPointsArray[i].y : 0;

            int rw = (int)r.right - (int)r.left;
            int rh = (int)r.bottom - (int)r.top;
            if (rw <= 0 || rh <= 0) continue;
            scratch.resize((size_t)rw * 4);

            for (int row = 0; row < rh; ++row) {
                int sy = (int)r.top + row;
                int ty = dy + row;
                if (sy < 0 || sy >= (int)src->surfHeight()) continue;
                if (ty < 0 || ty >= (int)dst->surfHeight()) continue;

                const unsigned char* srow = srcBits + (size_t)sy * src->surfPitch()
                                                    + (size_t)r.left * srcBpp;
                // Convert this segment of the source row to BGRA8.
                ConvertRowToBGRA8(src->surfFormat(), srow, scratch.data(), (UINT)rw);

                unsigned char* trow = dstBits + (size_t)ty * dst->surfPitch()
                                              + (size_t)dx * dstBpp;
                if (dstBpp == 4) {
                    // A8R8G8B8/X8R8G8B8 staging is already BGRA8 byte order.
                    int copyW = rw;
                    if (dx + copyW > (int)dst->surfWidth()) copyW = (int)dst->surfWidth() - dx;
                    if (copyW > 0) std::memcpy(trow, scratch.data(), (size_t)copyW * 4);
                } else if (dstBpp == srcBpp) {
                    // Same narrow format: raw byte copy preserves it exactly.
                    int copyW = rw;
                    if (dx + copyW > (int)dst->surfWidth()) copyW = (int)dst->surfWidth() - dx;
                    if (copyW > 0) std::memcpy(trow, srow, (size_t)copyW * srcBpp);
                }
            }
        }
        dst->flushToTexture();
        return D3D_OK;
    }
    STDMETHOD(UpdateTexture)(IDirect3DBaseTexture8*, IDirect3DBaseTexture8*) override { return D3D_OK; }
    STDMETHOD(GetFrontBuffer)(IDirect3DSurface8*) override { return D3D_OK; }

    // ---- render targets ----
    STDMETHOD(SetRenderTarget)(IDirect3DSurface8*, IDirect3DSurface8*) override { return D3D_OK; }
    STDMETHOD(GetRenderTarget)(IDirect3DSurface8** ppRenderTarget) override
    {
        if (ppRenderTarget) *ppRenderTarget = new MetalSurface8(this, m_width, m_height, D3DFMT_A8R8G8B8);
        return D3D_OK;
    }
    STDMETHOD(GetDepthStencilSurface)(IDirect3DSurface8** ppZStencil) override
    {
        if (ppZStencil) *ppZStencil = new MetalSurface8(this, m_width, m_height, D3DFMT_D24S8);
        return D3D_OK;
    }

    // ---- scene / clear ----
    STDMETHOD(BeginScene)() override { if (m_ctx) MetalContext_BeginFrame(m_ctx); m_inScene = true; if (DbgOn()) ++g_beginScene; return D3D_OK; }
    STDMETHOD(EndScene)() override { if (m_ctx) MetalContext_EndFrame(m_ctx); m_inScene = false; return D3D_OK; }
    STDMETHOD(Clear)(DWORD, CONST D3DRECT*, DWORD Flags, D3DCOLOR Color, float, DWORD) override
    {
        if (Flags & D3DCLEAR_TARGET) {
            m_clearColor = Color;
            // D3DCOLOR is ARGB: 0xAARRGGBB.
            double a = ((Color >> 24) & 0xFF) / 255.0;
            double r = ((Color >> 16) & 0xFF) / 255.0;
            double g = ((Color >>  8) & 0xFF) / 255.0;
            double b = ((Color      ) & 0xFF) / 255.0;
            if (m_ctx) MetalContext_SetClearColor(m_ctx, r, g, b, a);
            if (DbgOn()) { static long n=0; if (n<6||(n%600)==0) std::fprintf(stderr, "[clear] #%ld color=0x%08lX\n", n, (unsigned long)Color); ++n; }
        }
        return D3D_OK;
    }

    // ---- transforms ----
    STDMETHOD(SetTransform)(D3DTRANSFORMSTATETYPE State, CONST D3DMATRIX* pMatrix) override
    {
        if (pMatrix && (DWORD)State < MAX_TRANSFORMS) m_transforms[State] = *pMatrix;
        return D3D_OK;
    }
    STDMETHOD(GetTransform)(D3DTRANSFORMSTATETYPE State, D3DMATRIX* pMatrix) override
    {
        if (pMatrix && (DWORD)State < MAX_TRANSFORMS) *pMatrix = m_transforms[State];
        return D3D_OK;
    }
    STDMETHOD(MultiplyTransform)(D3DTRANSFORMSTATETYPE, CONST D3DMATRIX*) override { return D3D_OK; }

    // ---- viewport ----
    STDMETHOD(SetViewport)(CONST D3DVIEWPORT8* pViewport) override { if (pViewport) m_viewport = *pViewport; return D3D_OK; }
    STDMETHOD(GetViewport)(D3DVIEWPORT8* pViewport) override { if (pViewport) *pViewport = m_viewport; return D3D_OK; }

    // ---- material / lights ----
    STDMETHOD(SetMaterial)(CONST D3DMATERIAL8* pMaterial) override { if (pMaterial) m_material = *pMaterial; return D3D_OK; }
    STDMETHOD(GetMaterial)(D3DMATERIAL8* pMaterial) override { if (pMaterial) *pMaterial = m_material; return D3D_OK; }
    STDMETHOD(SetLight)(DWORD Index, CONST D3DLIGHT8* pLight) override { if (pLight && Index < MAX_LIGHTS) m_lights[Index] = *pLight; return D3D_OK; }
    STDMETHOD(GetLight)(DWORD Index, D3DLIGHT8* pLight) override { if (pLight && Index < MAX_LIGHTS) *pLight = m_lights[Index]; return D3D_OK; }
    STDMETHOD(LightEnable)(DWORD Index, BOOL Enable) override { if (Index < MAX_LIGHTS) m_lightEnable[Index] = Enable; return D3D_OK; }
    STDMETHOD(GetLightEnable)(DWORD Index, BOOL* pEnable) override { if (pEnable && Index < MAX_LIGHTS) *pEnable = m_lightEnable[Index]; return D3D_OK; }

    // ---- clip planes ----
    STDMETHOD(SetClipPlane)(DWORD Index, CONST float* pPlane) override
    {
        if (pPlane && Index < 6) for (int i = 0; i < 4; ++i) m_clipPlanes[Index][i] = pPlane[i];
        return D3D_OK;
    }
    STDMETHOD(GetClipPlane)(DWORD Index, float* pPlane) override
    {
        if (pPlane && Index < 6) for (int i = 0; i < 4; ++i) pPlane[i] = m_clipPlanes[Index][i];
        return D3D_OK;
    }

    // ---- render states ----
    STDMETHOD(SetRenderState)(D3DRENDERSTATETYPE State, DWORD Value) override
    {
        if ((DWORD)State < MAX_RENDER_STATES) m_renderStates[State] = Value;
        return D3D_OK;
    }
    STDMETHOD(GetRenderState)(D3DRENDERSTATETYPE State, DWORD* pValue) override
    {
        if (pValue && (DWORD)State < MAX_RENDER_STATES) *pValue = m_renderStates[State];
        return D3D_OK;
    }

    // ---- state blocks ----
    STDMETHOD(BeginStateBlock)() override { return D3D_OK; }
    STDMETHOD(EndStateBlock)(DWORD* pToken) override { if (pToken) *pToken = 0; return D3D_OK; }
    STDMETHOD(ApplyStateBlock)(DWORD) override { return D3D_OK; }
    STDMETHOD(CaptureStateBlock)(DWORD) override { return D3D_OK; }
    STDMETHOD(DeleteStateBlock)(DWORD) override { return D3D_OK; }
    STDMETHOD(CreateStateBlock)(D3DSTATEBLOCKTYPE, DWORD* pToken) override { if (pToken) *pToken = 0; return D3D_OK; }

    // ---- clip status ----
    STDMETHOD(SetClipStatus)(CONST D3DCLIPSTATUS8*) override { return D3D_OK; }
    STDMETHOD(GetClipStatus)(D3DCLIPSTATUS8* p) override { if (p) std::memset(p, 0, sizeof(*p)); return D3D_OK; }

    // ---- textures ----
    STDMETHOD(GetTexture)(DWORD Stage, IDirect3DBaseTexture8** ppTexture) override
    {
        if (ppTexture && Stage < MAX_TEXTURE_STAGES) { *ppTexture = m_textures[Stage]; if (*ppTexture) (*ppTexture)->AddRef(); }
        return D3D_OK;
    }
    STDMETHOD(SetTexture)(DWORD Stage, IDirect3DBaseTexture8* pTexture) override
    {
        if (Stage < MAX_TEXTURE_STAGES) m_textures[Stage] = pTexture;
        return D3D_OK;
    }
    STDMETHOD(GetTextureStageState)(DWORD Stage, D3DTEXTURESTAGESTATETYPE Type, DWORD* pValue) override
    {
        if (pValue && Stage < MAX_TEXTURE_STAGES && (DWORD)Type < MAX_TSS) *pValue = m_tss[Stage][Type];
        return D3D_OK;
    }
    STDMETHOD(SetTextureStageState)(DWORD Stage, D3DTEXTURESTAGESTATETYPE Type, DWORD Value) override
    {
        if (Stage < MAX_TEXTURE_STAGES && (DWORD)Type < MAX_TSS) m_tss[Stage][Type] = Value;
        return D3D_OK;
    }
    STDMETHOD(ValidateDevice)(DWORD* pNumPasses) override { if (pNumPasses) *pNumPasses = 1; return D3D_OK; }
    STDMETHOD(GetInfo)(DWORD, void*, DWORD) override { return E_FAIL; }

    // ---- palettes ----
    STDMETHOD(SetPaletteEntries)(UINT, CONST PALETTEENTRY*) override { return D3D_OK; }
    STDMETHOD(GetPaletteEntries)(UINT, PALETTEENTRY*) override { return D3D_OK; }
    STDMETHOD(SetCurrentTexturePalette)(UINT) override { return D3D_OK; }
    STDMETHOD(GetCurrentTexturePalette)(UINT* p) override { if (p) *p = 0; return D3D_OK; }

    // ---- draw ----
    STDMETHOD(DrawPrimitive)(D3DPRIMITIVETYPE PrimType, UINT StartVertex, UINT PrimCount) override
    {
        if (!m_ctx || !m_streamSource) return D3D_OK;
        MetalDrawCall dc; std::memset(&dc, 0, sizeof(dc));
        if (!FillCommon(dc)) return D3D_OK;
        dc.vertexBuffer = static_cast<MetalVertexBuffer8*>(m_streamSource)->dxBuffer();
        dc.stride       = m_streamStride;
        dc.vertexStart  = StartVertex;
        dc.vertexCount  = IndexCountFor(PrimType, PrimCount);
        dc.primType     = (unsigned)PrimType;
        MetalContext_Draw(m_ctx, &dc);
        return D3D_OK;
    }
    STDMETHOD(DrawIndexedPrimitive)(D3DPRIMITIVETYPE PrimType, UINT /*MinIndex*/, UINT /*NumVertices*/, UINT StartIndex, UINT PrimCount) override
    {
        if (DbgOn()) {
            ++g_drawCalls;
            if (g_drawCalls <= 16 || (g_drawCalls % 600) == 0) {
                FvfLayout L = ComputeFvfLayout(m_vertexShader);
                void* mtl = m_textures[0] ? static_cast<MetalTexture8*>(m_textures[0])->dxTexture() : nullptr;
                std::fprintf(stderr, "[draw] #%ld fvf=0x%lx stride=%u tex(com)=%p mtl=%p\n",
                             g_drawCalls, (unsigned long)m_vertexShader, m_streamStride,
                             (void*)m_textures[0], mtl);
            }
        }
        if (!m_ctx || !m_streamSource || !m_indices) { if (DbgOn()) ++g_drawSkipped; return D3D_OK; }
        MetalDrawCall dc; std::memset(&dc, 0, sizeof(dc));
        if (!FillCommon(dc)) { if (DbgOn()) ++g_drawSkipped; return D3D_OK; }
        if (DbgOn()) {
            if (!m_textures[0]) ++g_noTexBound;
            else if (static_cast<MetalTexture8*>(m_textures[0])->isMissingTex()) ++g_missingBound;
            else ++g_realBound;
        }
        dc.vertexBuffer     = static_cast<MetalVertexBuffer8*>(m_streamSource)->dxBuffer();
        dc.stride           = m_streamStride;
        dc.indexBuffer      = static_cast<MetalIndexBuffer8*>(m_indices)->dxBuffer();
        dc.indexOffsetBytes = StartIndex * sizeof(unsigned short);
        dc.indexCount       = IndexCountFor(PrimType, PrimCount);
        dc.baseVertex       = (int)m_baseVertexIndex;
        dc.primType         = (unsigned)PrimType;
        MetalContext_Draw(m_ctx, &dc);
        return D3D_OK;
    }
    STDMETHOD(DrawPrimitiveUP)(D3DPRIMITIVETYPE PrimType, UINT PrimCount, CONST void* pVtx, UINT Stride) override
    {
        if (!m_ctx || !pVtx || !Stride) return D3D_OK;
        MetalDrawCall dc; std::memset(&dc, 0, sizeof(dc));
        if (!FillCommon(dc)) return D3D_OK;
        UINT vcount = IndexCountFor(PrimType, PrimCount);
        void* vb = MetalContext_CreateBuffer(m_ctx, vcount * Stride);
        if (!vb) return D3D_OK;
        std::memcpy(MetalContext_BufferContents(vb), pVtx, (size_t)vcount * Stride);
        dc.vertexBuffer = vb;
        dc.stride       = Stride;
        dc.vertexStart  = 0;
        dc.vertexCount  = vcount;
        dc.primType     = (unsigned)PrimType;
        MetalContext_Draw(m_ctx, &dc);     // the encoder retains vb until the cmd buffer completes
        MetalContext_ReleaseBuffer(vb);
        return D3D_OK;
    }
    STDMETHOD(DrawIndexedPrimitiveUP)(D3DPRIMITIVETYPE PrimType, UINT MinIndex, UINT NumVertices, UINT PrimCount, CONST void* pIndex, D3DFORMAT IndexFmt, CONST void* pVtx, UINT Stride) override
    {
        if (!m_ctx || !pVtx || !pIndex || !Stride) return D3D_OK;
        MetalDrawCall dc; std::memset(&dc, 0, sizeof(dc));
        if (!FillCommon(dc)) return D3D_OK;
        UINT icount = IndexCountFor(PrimType, PrimCount);
        UINT vbytes = (size_t)(MinIndex + NumVertices) * Stride;
        void* vb = MetalContext_CreateBuffer(m_ctx, vbytes);
        void* ib = MetalContext_CreateBuffer(m_ctx, icount * sizeof(unsigned short));
        if (!vb || !ib) { if (vb) MetalContext_ReleaseBuffer(vb); if (ib) MetalContext_ReleaseBuffer(ib); return D3D_OK; }
        std::memcpy(MetalContext_BufferContents(vb), pVtx, vbytes);
        if (IndexFmt == D3DFMT_INDEX32) {
            const unsigned int* s = (const unsigned int*)pIndex;
            unsigned short* d = (unsigned short*)MetalContext_BufferContents(ib);
            for (UINT i = 0; i < icount; ++i) d[i] = (unsigned short)s[i];
        } else {
            std::memcpy(MetalContext_BufferContents(ib), pIndex, (size_t)icount * sizeof(unsigned short));
        }
        dc.vertexBuffer     = vb;
        dc.stride           = Stride;
        dc.indexBuffer      = ib;
        dc.indexOffsetBytes = 0;
        dc.indexCount       = icount;
        dc.baseVertex       = 0;
        dc.primType         = (unsigned)PrimType;
        MetalContext_Draw(m_ctx, &dc);
        MetalContext_ReleaseBuffer(vb);
        MetalContext_ReleaseBuffer(ib);
        return D3D_OK;
    }
    STDMETHOD(ProcessVertices)(UINT, UINT, UINT, IDirect3DVertexBuffer8*, DWORD) override { return D3D_OK; }

    // ---- vertex shaders ----
    STDMETHOD(CreateVertexShader)(CONST DWORD*, CONST DWORD*, DWORD* pHandle, DWORD) override { if (pHandle) *pHandle = 0; return D3D_OK; }
    STDMETHOD(SetVertexShader)(DWORD Handle) override { m_vertexShader = Handle; return D3D_OK; }
    STDMETHOD(GetVertexShader)(DWORD* pHandle) override { if (pHandle) *pHandle = m_vertexShader; return D3D_OK; }
    STDMETHOD(DeleteVertexShader)(DWORD) override { return D3D_OK; }
    STDMETHOD(SetVertexShaderConstant)(DWORD, CONST void*, DWORD) override { return D3D_OK; }
    STDMETHOD(GetVertexShaderConstant)(DWORD, void*, DWORD) override { return D3D_OK; }
    STDMETHOD(GetVertexShaderDeclaration)(DWORD, void*, DWORD*) override { return E_FAIL; }
    STDMETHOD(GetVertexShaderFunction)(DWORD, void*, DWORD*) override { return E_FAIL; }

    // ---- streams / indices ----
    STDMETHOD(SetStreamSource)(UINT StreamNumber, IDirect3DVertexBuffer8* pStreamData, UINT Stride) override
    {
        // Only stream 0 feeds our 2D pipeline. The engine releases unused streams
        // (1..N) by binding null each frame; ignoring the index would clobber
        // stream 0's binding.
        if (StreamNumber == 0) { m_streamSource = pStreamData; m_streamStride = Stride; }
        if (DbgOn()) { static int n = 0; if (n++ < 30) std::fprintf(stderr, "[sss] #%d stream=%u vb=%p stride=%u\n", n, StreamNumber, (void*)pStreamData, Stride); }
        return D3D_OK;
    }
    STDMETHOD(GetStreamSource)(UINT, IDirect3DVertexBuffer8** ppStreamData, UINT* pStride) override
    {
        if (ppStreamData) { *ppStreamData = m_streamSource; if (m_streamSource) m_streamSource->AddRef(); }
        if (pStride) *pStride = m_streamStride;
        return D3D_OK;
    }
    STDMETHOD(SetIndices)(IDirect3DIndexBuffer8* pIndexData, UINT BaseVertexIndex) override
    {
        m_indices = pIndexData; m_baseVertexIndex = BaseVertexIndex; return D3D_OK;
    }
    STDMETHOD(GetIndices)(IDirect3DIndexBuffer8** ppIndexData, UINT* pBaseVertexIndex) override
    {
        if (ppIndexData) { *ppIndexData = m_indices; if (m_indices) m_indices->AddRef(); }
        if (pBaseVertexIndex) *pBaseVertexIndex = m_baseVertexIndex;
        return D3D_OK;
    }

    // ---- pixel shaders ----
    STDMETHOD(CreatePixelShader)(CONST DWORD*, DWORD* pHandle) override { if (pHandle) *pHandle = 0; return D3D_OK; }
    STDMETHOD(SetPixelShader)(DWORD Handle) override { m_pixelShader = Handle; return D3D_OK; }
    STDMETHOD(GetPixelShader)(DWORD* pHandle) override { if (pHandle) *pHandle = m_pixelShader; return D3D_OK; }
    STDMETHOD(DeletePixelShader)(DWORD) override { return D3D_OK; }
    STDMETHOD(SetPixelShaderConstant)(DWORD, CONST void*, DWORD) override { return D3D_OK; }
    STDMETHOD(GetPixelShaderConstant)(DWORD, void*, DWORD) override { return D3D_OK; }
    STDMETHOD(GetPixelShaderFunction)(DWORD, void*, DWORD*) override { return E_FAIL; }

    // ---- patches ----
    STDMETHOD(DrawRectPatch)(UINT, CONST float*, CONST D3DRECTPATCH_INFO*) override { return D3D_OK; }
    STDMETHOD(DrawTriPatch)(UINT, CONST float*, CONST D3DTRIPATCH_INFO*) override { return D3D_OK; }
    STDMETHOD(DeletePatch)(UINT) override { return D3D_OK; }

private:
    static void IdentityMatrix(D3DMATRIX& m)
    {
        std::memset(&m, 0, sizeof(m));
        m.m[0][0] = m.m[1][1] = m.m[2][2] = m.m[3][3] = 1.0f;
    }

    // Fill the FVF/offsets, bound texture, blend/alpha-test state, MVP and
    // viewport that are common to every draw. Returns false (skip) for vertex
    // layouts the 2D pipeline can't handle (no position/diffuse/tex0 — the 3D
    // mesh path is Stage 4).
    bool FillCommon(MetalDrawCall& dc)
    {
        FvfLayout L = ComputeFvfLayout(m_vertexShader);
        // Only POSITION is required. NORMAL/DIFFUSE/TEX0 are all optional (3D
        // meshes may omit any of them); the backend substitutes defaults.
        if (L.posOffset < 0) return false;
        dc.fvf           = m_vertexShader;
        dc.posOffset     = L.posOffset;
        dc.posFloats     = L.posFloats;
        dc.normalOffset  = L.normalOffset;
        dc.diffuseOffset = L.diffuseOffset;
        dc.tex0Offset    = L.tex0Offset;
        dc.tex1Offset    = L.tex1Offset;
        // D3DTSS_TEXCOORDINDEX:
        //   LOW 16 bits = which vertex UV set sampler stage 0 uses (0=>TEX0,
        //     1=>TEX1). Terrain pass-1 (alpha-edge blend) sets this to 1 so the
        //     edge-tile blend samples with the SECOND UV set — without honoring
        //     it, the shim would sample TEX0 and the blend would paint at the
        //     wrong atlas position (visible dark seams between tile types).
        //   HIGH 16 bits = TCI_* (texcoord-generation mode):
        //     0=PASSTHRU, 1=CAMERASPACENORMAL, 2=CAMERASPACEPOSITION,
        //     3=CAMERASPACEREFLECTIONVECTOR. The shroud overlay sets =2 to
        //     project a shroud texture onto terrain based on camera-space
        //     vertex position (Used to be masked off here — that was the
        //     "black quads on rock peaks" bug. Now plumbed as dc.tciMode.)
        {
            DWORD tciFull   = m_tss[0][D3DTSS_TEXCOORDINDEX];
            dc.texCoordIndex = (int)(tciFull & 0xFFFF);
            dc.tciMode       = (int)((tciFull >> 16) & 0xFFFF);
        }
        // D3DTSS_TEXTURETRANSFORMFLAGS for stage 0. The shroud pass sets COUNT2,
        // everything else leaves this DISABLE (0). The MSL vs uses this to know
        // how many components of (texXform * tciInput) to keep as the final UV.
        dc.texXformCount = (int)m_tss[0][D3DTSS_TEXTURETRANSFORMFLAGS];
        // D3DTS_VIEW + D3DTS_TEXTURE0 (stage-0 texture-transform). Plumbed
        // unconditionally — when tciMode==0 the vs ignores both. D3DTS_TEXTURE0
        // is enum value 16 in d3d8types.h.
        std::memcpy(dc.view,     &m_transforms[D3DTS_VIEW],     sizeof(float) * 16);
        std::memcpy(dc.texXform, &m_transforms[D3DTS_TEXTURE0], sizeof(float) * 16);

        dc.texture = nullptr;
        if (m_textures[0]) dc.texture = static_cast<MetalTexture8*>(m_textures[0])->dxTexture();

        dc.blendEnable     = (int)m_renderStates[D3DRS_ALPHABLENDENABLE];
        dc.srcBlend        = (int)m_renderStates[D3DRS_SRCBLEND];
        dc.destBlend       = (int)m_renderStates[D3DRS_DESTBLEND];
        dc.alphaTestEnable = (int)m_renderStates[D3DRS_ALPHATESTENABLE];
        dc.alphaRef        = (float)(m_renderStates[D3DRS_ALPHAREF] & 0xFF) / 255.0f;
        // Stage 0 texture addressing — terrain explicitly sets CLAMP to keep
        // bilinear sampling from wrapping atlas tile edges to the opposite side
        // (the "scattered black spots on terrain" bug). Honor whatever the engine
        // set; default 0 → fall back to WRAP in the shim (legacy behavior).
        dc.addressU = (int)m_tss[0][D3DTSS_ADDRESSU];
        dc.addressV = (int)m_tss[0][D3DTSS_ADDRESSV];
        // Stage-0 filter state — terrain explicitly switches between POINT and
        // LINEAR depending on TheGlobalData->m_bilinearTerrainTex; water uses
        // LINEAR. Default (0/unset) maps to LINEAR in the backend.
        dc.magFilter = (int)m_tss[0][D3DTSS_MAGFILTER];
        dc.minFilter = (int)m_tss[0][D3DTSS_MINFILTER];
        dc.mipFilter = (int)m_tss[0][D3DTSS_MIPFILTER];
        // Stage-0 anisotropy & border color. The engine's TextureFilterClass
        // applies MAXANISOTROPY per-stage based on the graphics-options slider
        // (texturefilter.cpp:_Set_Max_Anisotropy). BORDERCOLOR is rarely set but
        // is the only way D3DTADDRESS_BORDER produces a meaningful colour.
        // Plumb both through to the Metal sampler (which DXMT also threads through
        // unmodified from D3D11_SAMPLER_DESC).
        dc.maxAnisotropy = (int)m_tss[0][D3DTSS_MAXANISOTROPY];
        dc.borderColor   = (unsigned)m_tss[0][D3DTSS_BORDERCOLOR];
        // Stage-0 FF combiner (D3DTSS_COLOROP / ALPHAOP). The engine sets these
        // per-shader (terrain pass-1 → modulate; water → ADD on alpha). Default
        // when unset: COLOROP=MODULATE, ALPHAOP=MODULATE, ARG1=TEXTURE, ARG2=DIFFUSE.
        // The Metal FS uses these to mirror DXVK's combiner (see dx8_stub note).
        dc.colorOp    = (int)m_tss[0][D3DTSS_COLOROP];
        dc.colorArg1  = (int)m_tss[0][D3DTSS_COLORARG1];
        dc.colorArg2  = (int)m_tss[0][D3DTSS_COLORARG2];
        dc.alphaOp    = (int)m_tss[0][D3DTSS_ALPHAOP];
        dc.alphaArg1  = (int)m_tss[0][D3DTSS_ALPHAARG1];
        dc.alphaArg2  = (int)m_tss[0][D3DTSS_ALPHAARG2];
        dc.tfactor    = m_renderStates[D3DRS_TEXTUREFACTOR];

        // Depth + culling state.
        dc.cullMode     = (int)m_renderStates[D3DRS_CULLMODE];
        dc.zEnable      = (int)m_renderStates[D3DRS_ZENABLE];
        dc.zWriteEnable = (int)m_renderStates[D3DRS_ZWRITEENABLE];
        dc.zFunc        = (int)m_renderStates[D3DRS_ZFUNC];

        // Color write mask (Stage 5). Volumetric shadow stencil-fill passes set
        // this to 0; the rest of the engine leaves it at default 0x0F.
        dc.colorWriteMask = (int)m_renderStates[D3DRS_COLORWRITEENABLE];

        // Stencil state (Stage 5). RTS3DScene::flushOccludedObjectsIntoStencil
        // drives this for the "occluded buildings X-ray" tint; stencil shadow
        // volumes also use it. Without proper stencil emulation the X-ray pass
        // painted a full-screen player-coloured rectangle (see plan, Session
        // 2026-05-24).
        dc.stencilEnable    = (int)m_renderStates[D3DRS_STENCILENABLE];
        dc.stencilFunc      = (int)m_renderStates[D3DRS_STENCILFUNC];
        dc.stencilRef       = (int)m_renderStates[D3DRS_STENCILREF];
        dc.stencilMask      = (int)m_renderStates[D3DRS_STENCILMASK];
        dc.stencilWriteMask = (int)m_renderStates[D3DRS_STENCILWRITEMASK];
        dc.stencilFail      = (int)m_renderStates[D3DRS_STENCILFAIL];
        dc.stencilZFail     = (int)m_renderStates[D3DRS_STENCILZFAIL];
        dc.stencilPass      = (int)m_renderStates[D3DRS_STENCILPASS];

        // Fixed-function lighting state.
        dc.lightingEnable  = (int)m_renderStates[D3DRS_LIGHTING];
        dc.diffuseSource   = (int)m_renderStates[D3DRS_DIFFUSEMATERIALSOURCE];
        dc.ambientSource   = (int)m_renderStates[D3DRS_AMBIENTMATERIALSOURCE];
        dc.emissiveSource  = (int)m_renderStates[D3DRS_EMISSIVEMATERIALSOURCE];
        dc.matDiffuse[0]  = m_material.Diffuse.r;  dc.matDiffuse[1]  = m_material.Diffuse.g;
        dc.matDiffuse[2]  = m_material.Diffuse.b;  dc.matDiffuse[3]  = m_material.Diffuse.a;
        dc.matAmbient[0]  = m_material.Ambient.r;  dc.matAmbient[1]  = m_material.Ambient.g;
        dc.matAmbient[2]  = m_material.Ambient.b;  dc.matAmbient[3]  = m_material.Ambient.a;
        dc.matEmissive[0] = m_material.Emissive.r; dc.matEmissive[1] = m_material.Emissive.g;
        dc.matEmissive[2] = m_material.Emissive.b; dc.matEmissive[3] = m_material.Emissive.a;
        {
            DWORD amb = m_renderStates[D3DRS_AMBIENT];      // 0xAARRGGBB
            dc.globalAmbient[0] = ((amb >> 16) & 0xFF) / 255.0f;
            dc.globalAmbient[1] = ((amb >>  8) & 0xFF) / 255.0f;
            dc.globalAmbient[2] = ((amb      ) & 0xFF) / 255.0f;
            dc.globalAmbient[3] = ((amb >> 24) & 0xFF) / 255.0f;
        }
        std::memcpy(dc.world, &m_transforms[D3DTS_WORLD], sizeof(float) * 16);

        int nl = 0;
        for (int i = 0; i < MAX_LIGHTS && nl < 8; ++i) {
            if (!m_lightEnable[i]) continue;
            const D3DLIGHT8& s = m_lights[i];
            MetalLight& d = dc.lights[nl++];
            d.type = (int)s.Type;
            d.diffuse[0] = s.Diffuse.r; d.diffuse[1] = s.Diffuse.g; d.diffuse[2] = s.Diffuse.b; d.diffuse[3] = s.Diffuse.a;
            d.ambient[0] = s.Ambient.r; d.ambient[1] = s.Ambient.g; d.ambient[2] = s.Ambient.b; d.ambient[3] = s.Ambient.a;
            d.position[0] = s.Position.x; d.position[1] = s.Position.y; d.position[2] = s.Position.z;
            d.direction[0] = s.Direction.x; d.direction[1] = s.Direction.y; d.direction[2] = s.Direction.z;
            d.atten[0] = s.Attenuation0; d.atten[1] = s.Attenuation1; d.atten[2] = s.Attenuation2;
        }
        dc.numLights = nl;

        // MVP = World * View * Proj (D3D row-major; the row-major float layout is
        // exactly the column-major float4x4 the MSL `u.mvp * pos` expects).
        D3DMATRIX wv, wvp;
        MatMul(wv,  m_transforms[D3DTS_WORLD], m_transforms[D3DTS_VIEW]);
        MatMul(wvp, wv,                        m_transforms[D3DTS_PROJECTION]);
        std::memcpy(dc.mvp, &wvp, sizeof(float) * 16);

        dc.vpX = (int)m_viewport.X;     dc.vpY = (int)m_viewport.Y;
        dc.vpW = (int)m_viewport.Width; dc.vpH = (int)m_viewport.Height;
        return true;
    }

    ULONG          m_refCount;
    IDirect3D8*    m_parent;
    MetalContext*  m_ctx;
    UINT           m_width, m_height;
    bool           m_inScene = false;

    D3DCOLOR       m_clearColor;
    D3DVIEWPORT8   m_viewport;
    D3DMATERIAL8   m_material;
    D3DGAMMARAMP   m_gammaRamp{};
    D3DMATRIX      m_transforms[MAX_TRANSFORMS];
    DWORD          m_renderStates[MAX_RENDER_STATES];
    DWORD          m_tss[MAX_TEXTURE_STAGES][MAX_TSS];
    IDirect3DBaseTexture8* m_textures[MAX_TEXTURE_STAGES];
    D3DLIGHT8      m_lights[MAX_LIGHTS];
    BOOL           m_lightEnable[MAX_LIGHTS];
    float          m_clipPlanes[6][4];
    DWORD          m_vertexShader, m_pixelShader;
    IDirect3DIndexBuffer8*  m_indices;
    UINT           m_baseVertexIndex;
    IDirect3DVertexBuffer8* m_streamSource;
    UINT           m_streamStride;
};

// Fill caps with generous fixed-function values (out-of-class: needs MetalDevice8 complete).
HRESULT MetalDevice8::GetDeviceCaps(D3DCAPS8* pCaps)
{
    if (!pCaps) return E_FAIL;
    std::memset(pCaps, 0, sizeof(*pCaps));
    pCaps->DeviceType            = D3DDEVTYPE_HAL;
    pCaps->AdapterOrdinal        = 0;
    pCaps->Caps2                 = 0;
    pCaps->PresentationIntervals = D3DPRESENT_INTERVAL_IMMEDIATE | D3DPRESENT_INTERVAL_ONE;
    pCaps->DevCaps               = D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_HWRASTERIZATION;
    // D3DPMISCCAPS_COLORWRITEENABLE: required by W3DVolumetricShadow's stencil-fill
    // pass (line 3483 — gates the "happy path" that disables colour writes via
    // D3DRS_COLORWRITEENABLE=0, vs an alpha-blend fake that doesn't reliably
    // suppress the volume geometry on every backend). Shim already honours
    // colorWriteMask=0 by mapping to MTLColorWriteMaskNone in GetPipeline.
    pCaps->PrimitiveMiscCaps     = D3DPMISCCAPS_CULLNONE | D3DPMISCCAPS_CULLCW | D3DPMISCCAPS_CULLCCW
                                 | D3DPMISCCAPS_COLORWRITEENABLE;
    pCaps->RasterCaps            = D3DPRASTERCAPS_ZTEST | D3DPRASTERCAPS_FOGVERTEX | D3DPRASTERCAPS_FOGTABLE;
    pCaps->ZCmpCaps              = 0xFF;
    pCaps->SrcBlendCaps          = 0x1FFF;
    pCaps->DestBlendCaps         = 0x1FFF;
    pCaps->AlphaCmpCaps          = 0xFF;
    pCaps->ShadeCaps             = D3DPSHADECAPS_COLORGOURAUDRGB | D3DPSHADECAPS_ALPHAGOURAUDBLEND;
    pCaps->TextureCaps           = D3DPTEXTURECAPS_PERSPECTIVE | D3DPTEXTURECAPS_ALPHA | D3DPTEXTURECAPS_PROJECTED;
    pCaps->TextureFilterCaps     = 0x07000700; // MIN/MAG point+linear+aniso, MIP point+linear
    pCaps->TextureAddressCaps    = D3DPTADDRESSCAPS_WRAP | D3DPTADDRESSCAPS_MIRROR | D3DPTADDRESSCAPS_CLAMP | D3DPTADDRESSCAPS_BORDER;
    pCaps->MaxTextureWidth       = 8192;
    pCaps->MaxTextureHeight      = 8192;
    pCaps->MaxTextureRepeat      = 8192;
    pCaps->MaxTextureAspectRatio = 8192;
    pCaps->MaxAnisotropy         = 16;
    pCaps->MaxVertexW            = 1e10f;
    pCaps->GuardBandLeft         = -1e9f;
    pCaps->GuardBandTop          = -1e9f;
    pCaps->GuardBandRight        =  1e9f;
    pCaps->GuardBandBottom       =  1e9f;
    pCaps->StencilCaps           = 0xFF;
    pCaps->FVFCaps               = 8; // 8 simultaneous texcoords (D3DFVFCAPS_TEXCOORDCOUNTMASK low bits)
    pCaps->TextureOpCaps         = 0xFFFFFF;
    pCaps->MaxTextureBlendStages = 8;
    pCaps->MaxSimultaneousTextures = 8;
    pCaps->VertexProcessingCaps  = D3DVTXPCAPS_TEXGEN | D3DVTXPCAPS_MATERIALSOURCE7 | D3DVTXPCAPS_DIRECTIONALLIGHTS | D3DVTXPCAPS_POSITIONALLIGHTS | D3DVTXPCAPS_LOCALVIEWER;
    pCaps->MaxActiveLights       = 8;
    pCaps->MaxUserClipPlanes     = 6;
    pCaps->MaxVertexBlendMatrices = 4;
    pCaps->MaxPointSize          = 256.0f;
    pCaps->MaxPrimitiveCount     = 0x000FFFFF;
    pCaps->MaxVertexIndex        = 0x00FFFFFF;
    pCaps->MaxStreams            = 16;
    pCaps->MaxStreamStride       = 256;
    pCaps->VertexShaderVersion   = 0xFFFE0101; // vs_1_1 (FVF/T&L path; shim ignores real VS handles)
    pCaps->MaxVertexShaderConst  = 256;
    // TheSuperHackers @fix macOS-port: report NO pixel-shader support. The Metal
    // shim only emulates the D3D8 FIXED-FUNCTION pipeline — SetPixelShader is a
    // no-op. Advertising ps_1_1 made W3DShaderManager::getChipset() classify the
    // device as DC_GENERIC_PIXEL_SHADER_1_1, so the engine built pixel-shader
    // render paths (water surface, terrain cloud/noise, roads, FX) and bound
    // shaders the shim silently dropped → e.g. the shellmap WATER rendered as
    // opaque dark tiles (the "black grid") hiding the terrain + ships. With PS
    // version 0, getChipset() falls back to a non-PS class and the engine uses its
    // fixed-function fallbacks (single/dual-texture + alpha blend), which the shim
    // does emulate. (The game shipped FF paths for GeForce2/TNT-class cards.)
    pCaps->PixelShaderVersion    = 0;
    pCaps->MaxPixelShaderValue   = 0.0f;
    return D3D_OK;
}

// ---------------------------------------------------------------------------
// IDirect3D8 (factory)
// ---------------------------------------------------------------------------
class MetalDirect3D8 : public IDirect3D8 {
public:
    MetalDirect3D8() : m_refCount(1) {}

    STDMETHOD(QueryInterface)(REFIID, void** ppvObj) override { return BasicQueryInterface(this, ppvObj); }
    STDMETHOD_(ULONG, AddRef)() override { return ++m_refCount; }
    STDMETHOD_(ULONG, Release)() override { ULONG c = --m_refCount; if (c == 0) delete this; return c; }

    STDMETHOD(RegisterSoftwareDevice)(void*) override { return D3D_OK; }
    STDMETHOD_(UINT, GetAdapterCount)() override { return 1; }

    STDMETHOD(GetAdapterIdentifier)(UINT, DWORD, D3DADAPTER_IDENTIFIER8* pIdentifier) override
    {
        if (!pIdentifier) return E_FAIL;
        std::memset(pIdentifier, 0, sizeof(*pIdentifier));
        std::snprintf(pIdentifier->Driver, sizeof(pIdentifier->Driver), "Metal");
        std::snprintf(pIdentifier->Description, sizeof(pIdentifier->Description), "Apple Metal (DX8->Metal shim)");
        pIdentifier->DriverVersionLowPart  = 0;
        pIdentifier->DriverVersionHighPart = 8;
        pIdentifier->VendorId  = 0x106B; // Apple
        pIdentifier->DeviceId  = 1;
        pIdentifier->WHQLLevel = 1;
        return D3D_OK;
    }

    STDMETHOD_(UINT, GetAdapterModeCount)(UINT) override { return ModeCount(); }
    STDMETHOD(EnumAdapterModes)(UINT, UINT Mode, D3DDISPLAYMODE* pMode) override
    {
        if (!pMode || Mode >= ModeCount()) return D3DERR_INVALIDCALL;
        *pMode = ModeTable()[Mode];
        return D3D_OK;
    }
    STDMETHOD(GetAdapterDisplayMode)(UINT, D3DDISPLAYMODE* pMode) override
    {
        if (!pMode) return E_FAIL;
        FillMode(pMode);
        return D3D_OK;
    }
    STDMETHOD(CheckDeviceType)(UINT, D3DDEVTYPE, D3DFORMAT, D3DFORMAT, BOOL) override { return D3D_OK; }
    STDMETHOD(CheckDeviceFormat)(UINT, D3DDEVTYPE, D3DFORMAT, DWORD, D3DRESOURCETYPE, D3DFORMAT CheckFormat) override
    {
        // Apple Silicon Metal supports BC/DXT (S3TC) compression natively
        // (device.supportsBCTextureCompression == YES on M1+). Report DXT as
        // available so DX8Caps::Support_DXTC()==true and the engine loads the
        // shipped .dds skins directly (the .tga variants don't exist on disk),
        // handing us compressed blocks we upload to BC textures. Reporting these
        // unsupported made every DDS-only texture (516 of them: unit/building
        // skins, terrain blends) fall back to the missing-texture placeholder.
        (void)CheckFormat;
        return D3D_OK;
    }
    STDMETHOD(CheckDeviceMultiSampleType)(UINT, D3DDEVTYPE, D3DFORMAT, BOOL, D3DMULTISAMPLE_TYPE) override { return D3D_OK; }
    STDMETHOD(CheckDepthStencilMatch)(UINT, D3DDEVTYPE, D3DFORMAT, D3DFORMAT, D3DFORMAT) override { return D3D_OK; }

    STDMETHOD(GetDeviceCaps)(UINT, D3DDEVTYPE, D3DCAPS8* pCaps) override
    {
        // Reuse the device caps via a throwaway helper. Build a temp by hand:
        // simplest is to construct an empty device-less caps. Delegate to a
        // static fill that mirrors MetalDevice8::GetDeviceCaps.
        if (!pCaps) return E_FAIL;
        MetalDevice8 tmp(this, nullptr, D3DPRESENT_PARAMETERS{});
        return tmp.GetDeviceCaps(pCaps);
    }
    STDMETHOD_(HMONITOR, GetAdapterMonitor)(UINT) override { return (HMONITOR)1; }

    STDMETHOD(CreateDevice)(UINT, D3DDEVTYPE, HWND, DWORD,
                            D3DPRESENT_PARAMETERS* pPresentationParameters,
                            IDirect3DDevice8** ppReturnedDeviceInterface) override
    {
        if (!ppReturnedDeviceInterface) return E_FAIL;
        *ppReturnedDeviceInterface = nullptr;

        D3DPRESENT_PARAMETERS pp{};
        if (pPresentationParameters) pp = *pPresentationParameters;
        int w = (int)(pp.BackBufferWidth  ? pp.BackBufferWidth  : 1024);
        int h = (int)(pp.BackBufferHeight ? pp.BackBufferHeight : 768);

        MetalContext* ctx = MetalContext_Create(w, h, pp.Windowed ? 1 : 0);
        if (!ctx) return E_FAIL;

        *ppReturnedDeviceInterface = new MetalDevice8(this, ctx, pp);
        return D3D_OK;
    }

private:
    // Advertised display modes. The engine (DX8Wrapper::Find_Color_Mode) scans
    // these for an exact width/height/format match, so we expose the common
    // resolutions in both a 32-bit (X8R8G8B8) and a 16-bit (R5G6B5) format.
    static const D3DDISPLAYMODE* ModeTable()
    {
        static const struct { UINT w, h; } kRes[] = {
            { 640, 480 }, { 800, 600 }, { 1024, 768 }, { 1152, 864 },
            { 1280, 720 }, { 1280, 960 }, { 1280, 1024 }, { 1366, 768 },
            { 1440, 900 }, { 1600, 900 }, { 1600, 1200 }, { 1680, 1050 },
            { 1920, 1080 }, { 1920, 1200 }, { 2560, 1440 },
        };
        static const D3DFORMAT kFmt[] = { D3DFMT_X8R8G8B8, D3DFMT_R5G6B5 };
        static const UINT kResCount = sizeof(kRes) / sizeof(kRes[0]);
        static const UINT kFmtCount = sizeof(kFmt) / sizeof(kFmt[0]);
        static D3DDISPLAYMODE table[kResCount * kFmtCount];
        static bool built = false;
        if (!built) {
            UINT idx = 0;
            for (UINT f = 0; f < kFmtCount; ++f)
                for (UINT r = 0; r < kResCount; ++r) {
                    table[idx].Width = kRes[r].w;
                    table[idx].Height = kRes[r].h;
                    table[idx].RefreshRate = 60;
                    table[idx].Format = kFmt[f];
                    ++idx;
                }
            built = true;
        }
        return table;
    }
    static UINT ModeCount()
    {
        return 15u /*resolutions*/ * 2u /*formats*/;
    }
    static void FillMode(D3DDISPLAYMODE* pMode)
    {
        pMode->Width = 1024; pMode->Height = 768; pMode->RefreshRate = 60; pMode->Format = D3DFMT_X8R8G8B8;
    }
    ULONG m_refCount;
};

// ---------------------------------------------------------------------------
// Factory entry point (replaces the null stub).
// ---------------------------------------------------------------------------
extern "C" IDirect3D8* WINAPI Direct3DCreate8(UINT /*SDKVersion*/)
{
    return new MetalDirect3D8();
}

/*
**  Apple .ANI cursor loader — implementation.
**
**  Loads Win32 RIFF/ACON animated-cursor files and presents them as
**  Cocoa NSCursors. The engine code path is untouched — only the
**  LoadCursorFromFile / SetCursor shims in <windows.h> call into here.
**
**  File format reference:
**    https://www.daubnet.com/en/file-format-ani
**    https://en.wikipedia.org/wiki/ANI_(file_format)
**    https://learn.microsoft.com/windows/win32/menurc/cursor-resources
**
**  Layout digest:
**    RIFF [size] "ACON"
**      "anih" [size=36] {numFrames, numSteps, w, h, bpp, planes,
**                        defaultJiffies (1/60s), flags}
**      "LIST" [size] "fram"
**        "icon" [size] <full .CUR file payload>     (numFrames times)
**      optional "rate" [size=numSteps*4] {per-step jiffies}
**      optional "seq " [size=numSteps*4] {per-step frame index}
**
**  Each embedded .CUR has an ICONDIR + ICONDIRENTRY + image data.
**  We expect 32-bit BGRA BMP-format from Generals' assets but the
**  decoder also handles 24-bit + 1-bit AND-mask fallbacks.
**
**  Caching strategy: parse on first request, store by path, NEVER
**  re-parse. NSCursor objects are retained for the process lifetime
**  (cursors are small, ~60 total, dominated by Cocoa overhead, well
**  under 2 MB total).
**
**  Animation: a single shared NSTimer ticks at 60 Hz; the active
**  cursor's per-step rate (default 6 jiffies = 100ms) drives frame
**  advance. When no animated cursor is active, the timer remains
**  installed but does no per-tick allocation, so the steady-state cost
**  is one timer callback per frame doing one integer compare.
**
**  HiDPI: we keep cursor frames at their native pixel resolution
**  (typically 32x32) and present them as NSImage with logical size
**  matching pixel size. macOS scales to Retina automatically. For
**  sharpness on Retina we could nearest-neighbour upscale to a 2x
**  representation; today's cost/benefit favours skipping that — the
**  original Win32 game pixel-doubles too.
*/

#include "apple_ani_cursor.h"

#if defined(__APPLE__)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <unordered_map>

// ============================================================
// Parse helpers — endian-safe little-endian reads.
// ============================================================
namespace {

inline uint16_t rd_u16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
inline uint32_t rd_u32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
inline int32_t  rd_s32(const uint8_t* p) { return (int32_t)rd_u32(p); }

// Compare a 4-byte FourCC at p with a literal string. Avoids needing
// memcmp at every chunk while staying readable.
inline bool fourcc(const uint8_t* p, const char* s) {
    return p[0] == (uint8_t)s[0] && p[1] == (uint8_t)s[1]
        && p[2] == (uint8_t)s[2] && p[3] == (uint8_t)s[3];
}

// ============================================================
// Parsed frame: pixels (RGBA8, top-down) + hotspot + size.
// ============================================================
struct AniFrame {
    int width = 0;
    int height = 0;
    int hotspotX = 0;
    int hotspotY = 0;
    std::vector<uint8_t> rgba;   // size = width*height*4
};

// Read entire file at path into a vector. Returns empty on failure.
std::vector<uint8_t> read_file(const std::string& path) {
    std::vector<uint8_t> data;
    FILE* f = ::fopen(path.c_str(), "rb");
    if (!f) return data;
    ::fseek(f, 0, SEEK_END);
    long n = ::ftell(f);
    if (n > 0 && n < (long)(64 * 1024 * 1024)) {   // sanity cap 64 MB
        data.resize((size_t)n);
        ::fseek(f, 0, SEEK_SET);
        size_t got = ::fread(data.data(), 1, (size_t)n, f);
        if (got != (size_t)n) data.clear();
    }
    ::fclose(f);
    return data;
}

// Decode a single embedded .CUR file (one ICONDIR + ICONDIRENTRY + BMP)
// into RGBA pixels. Handles 32-bit BGRA, 24-bit BGR + 1-bit AND mask,
// and 8-bit indexed with palette + 1-bit AND mask. Returns false on
// any parse error.
bool decode_cur_frame(const uint8_t* data, size_t size, AniFrame& out) {
    if (size < 6) return false;

    // ICONDIR
    uint16_t reserved = rd_u16(data + 0);
    uint16_t type     = rd_u16(data + 2);  // 1 = icon, 2 = cursor
    uint16_t count    = rd_u16(data + 4);
    if (reserved != 0 || (type != 1 && type != 2) || count == 0) return false;
    if (size < 6u + 16u * count) return false;

    // First ICONDIRENTRY
    const uint8_t* e = data + 6;
    uint16_t hotspotX = (type == 2) ? rd_u16(e + 4) : 0;
    uint16_t hotspotY = (type == 2) ? rd_u16(e + 6) : 0;
    uint32_t bytesInRes = rd_u32(e + 8);
    uint32_t imageOffset = rd_u32(e + 12);
    if (imageOffset + bytesInRes > size) return false;

    const uint8_t* img = data + imageOffset;

    // Some cursors store frames as inline PNG (rare for .ANI but the
    // ICO spec permits it). Detect by PNG signature and feed straight
    // to NSBitmapImageRep.
    if (bytesInRes >= 8 && img[0] == 0x89 && img[1] == 'P' && img[2] == 'N' && img[3] == 'G') {
        NSData* pngData = [NSData dataWithBytes:img length:bytesInRes];
        NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:pngData];
        if (!rep) return false;
        out.width = (int)rep.pixelsWide;
        out.height = (int)rep.pixelsHigh;
        out.hotspotX = hotspotX;
        out.hotspotY = hotspotY;
        out.rgba.resize((size_t)out.width * out.height * 4);
        // Convert via NSBitmapImageRep -> bitmap copy.
        NSBitmapImageRep* dst = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:nullptr
                          pixelsWide:out.width pixelsHigh:out.height
                       bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:out.width * 4 bitsPerPixel:32];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext* gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
        [NSGraphicsContext setCurrentContext:gc];
        [rep drawInRect:NSMakeRect(0, 0, out.width, out.height)];
        [NSGraphicsContext restoreGraphicsState];
        ::memcpy(out.rgba.data(), dst.bitmapData, out.rgba.size());
        return true;
    }

    // Otherwise it's a BITMAPINFOHEADER + pixels + (1-bit AND mask).
    if (bytesInRes < 40) return false;
    uint32_t hdrSize = rd_u32(img + 0);
    int32_t  bmpW   = rd_s32(img + 4);
    int32_t  bmpH   = rd_s32(img + 8);     // 2x actual height
    uint16_t planes = rd_u16(img + 12);
    uint16_t bpp    = rd_u16(img + 14);
    uint32_t compr  = rd_u32(img + 16);
    if (hdrSize < 40 || planes != 1) return false;
    if (compr != 0 /*BI_RGB*/ && compr != 3 /*BI_BITFIELDS*/) return false;

    int w = bmpW;
    int h = bmpH / 2;
    if (w <= 0 || h <= 0 || w > 256 || h > 256) return false;

    // The XOR image data starts after the header (+ optional palette
    // for low-bpp modes + optional BI_BITFIELDS masks).
    size_t xorOffset = hdrSize;
    if (compr == 3) xorOffset += 12;     // 3x RGB bitfield DWORDs

    // Palette for indexed modes.
    const uint8_t* palette = nullptr;
    if (bpp <= 8) {
        uint32_t paletteEntries = rd_u32(img + 32);  // biClrUsed
        if (paletteEntries == 0) paletteEntries = (1u << bpp);
        palette = img + xorOffset;
        xorOffset += paletteEntries * 4;             // BGRA0
    }

    // XOR scanline stride padded to 4 bytes; AND scanline stride is
    // ceil(w/8) bytes also padded to 4.
    int xorStride = ((w * bpp + 31) / 32) * 4;
    int andStride = ((w + 31) / 32) * 4;
    size_t xorBytes = (size_t)xorStride * h;
    size_t andBytes = (size_t)andStride * h;
    if (xorOffset + xorBytes + andBytes > bytesInRes) {
        // Some files omit AND mask when 32-bit alpha is present.
        if (bpp != 32 || xorOffset + xorBytes > bytesInRes) return false;
    }

    const uint8_t* xorPix = img + xorOffset;
    const uint8_t* andPix = img + xorOffset + xorBytes;
    const bool hasAnd = (xorOffset + xorBytes + andBytes <= bytesInRes);

    out.width = w;
    out.height = h;
    out.hotspotX = hotspotX;
    out.hotspotY = hotspotY;
    out.rgba.assign((size_t)w * h * 4, 0);

    // Decode bottom-up rows into top-down RGBA.
    for (int y = 0; y < h; ++y) {
        const uint8_t* xrow = xorPix + (size_t)(h - 1 - y) * xorStride;
        const uint8_t* arow = hasAnd ? (andPix + (size_t)(h - 1 - y) * andStride) : nullptr;
        uint8_t* dst = out.rgba.data() + (size_t)y * w * 4;

        for (int x = 0; x < w; ++x) {
            uint8_t r = 0, g = 0, b = 0, a = 255;

            switch (bpp) {
                case 32: {
                    b = xrow[x * 4 + 0];
                    g = xrow[x * 4 + 1];
                    r = xrow[x * 4 + 2];
                    a = xrow[x * 4 + 3];
                    // Some encoders leave alpha as 0 for fully-opaque
                    // 32-bit cursors. If the whole frame's alpha is
                    // zero (we'll detect after the loop), the AND mask
                    // is the actual transparency source — handled in a
                    // second pass below.
                } break;

                case 24: {
                    b = xrow[x * 3 + 0];
                    g = xrow[x * 3 + 1];
                    r = xrow[x * 3 + 2];
                    a = 255;
                } break;

                case 8: {
                    uint8_t idx = xrow[x];
                    if (palette) {
                        b = palette[idx * 4 + 0];
                        g = palette[idx * 4 + 1];
                        r = palette[idx * 4 + 2];
                    }
                    a = 255;
                } break;

                case 4: {
                    uint8_t pack = xrow[x / 2];
                    uint8_t idx = (x & 1) ? (pack & 0x0F) : (pack >> 4);
                    if (palette) {
                        b = palette[idx * 4 + 0];
                        g = palette[idx * 4 + 1];
                        r = palette[idx * 4 + 2];
                    }
                    a = 255;
                } break;

                case 1: {
                    uint8_t pack = xrow[x / 8];
                    uint8_t bit = (pack >> (7 - (x & 7))) & 1;
                    if (palette) {
                        b = palette[bit * 4 + 0];
                        g = palette[bit * 4 + 1];
                        r = palette[bit * 4 + 2];
                    } else {
                        b = g = r = bit ? 255 : 0;
                    }
                    a = 255;
                } break;

                default: return false;
            }

            // AND mask: 1 = transparent (cut hole), 0 = opaque.
            // Only applies when XOR data didn't already carry alpha.
            if (arow && bpp != 32) {
                uint8_t pack = arow[x / 8];
                uint8_t bit = (pack >> (7 - (x & 7))) & 1;
                if (bit) a = 0;
            }

            dst[x * 4 + 0] = r;
            dst[x * 4 + 1] = g;
            dst[x * 4 + 2] = b;
            dst[x * 4 + 3] = a;
        }
    }

    // 32-bit-with-zero-alpha rescue: if every alpha is 0, treat AND
    // mask as the authoritative transparency (Win32 cursors authored
    // before the 32-bit-alpha convention took hold often did this).
    if (bpp == 32 && hasAnd) {
        bool allZero = true;
        for (size_t i = 3; i < out.rgba.size(); i += 4) {
            if (out.rgba[i] != 0) { allZero = false; break; }
        }
        if (allZero) {
            for (int y = 0; y < h; ++y) {
                const uint8_t* arow = andPix + (size_t)(h - 1 - y) * andStride;
                uint8_t* dst = out.rgba.data() + (size_t)y * w * 4;
                for (int x = 0; x < w; ++x) {
                    uint8_t pack = arow[x / 8];
                    uint8_t bit = (pack >> (7 - (x & 7))) & 1;
                    dst[x * 4 + 3] = bit ? 0 : 255;
                }
            }
        }
    }

    return true;
}

// ============================================================
// Parsed cursor — array of frames + timing data + NSCursors.
// ============================================================
struct AniCursor {
    int numFrames = 0;            // distinct frames stored
    int numSteps = 0;             // animation steps (may repeat frames)
    uint32_t defaultJiffies = 6;  // 1/60s units; default per step
    std::vector<AniFrame> frames; // size = numFrames
    std::vector<int> seq;         // size = numSteps; index into frames
    std::vector<uint32_t> rates;  // size = numSteps; jiffies per step
    NSMutableArray<NSCursor*>* nsCursors = nil;  // size = numFrames
};

// Path → cached cursor. Pointers are stable; we leak on shutdown
// (cursors live for process lifetime by design).
std::unordered_map<std::string, AniCursor*>& g_cache() {
    static std::unordered_map<std::string, AniCursor*> m;
    return m;
}

// Build NSCursors from decoded frames. Skipped if no frames.
void build_nscursors(AniCursor* c) {
    if (c->frames.empty()) return;
    c->nsCursors = [NSMutableArray arrayWithCapacity:c->frames.size()];
    for (const auto& f : c->frames) {
        // Wrap raw RGBA in a CGImage via CGDataProvider.
        size_t bytes = f.rgba.size();
        CFDataRef cfData = CFDataCreate(nullptr, f.rgba.data(), bytes);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        // RGBA8 with alpha-last and *non*-premultiplied — matches our
        // raw decoder output (we don't premultiply on decode).
        CGBitmapInfo bi = (CGBitmapInfo)(kCGBitmapByteOrderDefault | kCGImageAlphaLast);
        CGImageRef cg = CGImageCreate(
            (size_t)f.width, (size_t)f.height,
            8, 32, (size_t)f.width * 4,
            cs, bi,
            provider, nullptr, false,
            kCGRenderingIntentDefault);
        CGColorSpaceRelease(cs);
        CGDataProviderRelease(provider);
        CFRelease(cfData);

        if (!cg) {
            [c->nsCursors addObject:[NSCursor arrowCursor]];
            continue;
        }

        NSImage* img = [[NSImage alloc]
            initWithCGImage:cg size:NSMakeSize(f.width, f.height)];
        CGImageRelease(cg);

        NSCursor* nsc = [[NSCursor alloc]
            initWithImage:img
                  hotSpot:NSMakePoint(f.hotspotX, f.hotspotY)];
        [c->nsCursors addObject:nsc];
    }
}

// Top-level RIFF walk. Returns nullptr on parse failure.
AniCursor* parse_ani(const std::vector<uint8_t>& buf) {
    if (buf.size() < 12) return nullptr;
    const uint8_t* p = buf.data();
    if (!fourcc(p, "RIFF")) return nullptr;
    uint32_t riffSize = rd_u32(p + 4);
    if ((size_t)riffSize + 8 > buf.size()) riffSize = (uint32_t)(buf.size() - 8);
    if (!fourcc(p + 8, "ACON")) return nullptr;

    AniCursor* c = new AniCursor;
    size_t off = 12;
    size_t end = 8 + riffSize;

    while (off + 8 <= end) {
        const uint8_t* ch = p + off;
        uint32_t chSize = rd_u32(ch + 4);
        size_t dataOff = off + 8;
        if (dataOff + chSize > end) break;
        const uint8_t* data = p + dataOff;

        if (fourcc(ch, "anih") && chSize >= 36) {
            c->numFrames     = (int)rd_u32(data + 4);
            c->numSteps      = (int)rd_u32(data + 8);
            c->defaultJiffies = rd_u32(data + 28);
            if (c->defaultJiffies == 0) c->defaultJiffies = 6;
        } else if (fourcc(ch, "LIST") && chSize >= 4 && fourcc(data, "fram")) {
            // Walk subchunks looking for 'icon'.
            size_t subOff = 4;     // skip 'fram'
            while (subOff + 8 <= chSize) {
                const uint8_t* sub = data + subOff;
                uint32_t subSize = rd_u32(sub + 4);
                if (subOff + 8 + subSize > chSize) break;
                if (fourcc(sub, "icon")) {
                    AniFrame f;
                    if (decode_cur_frame(sub + 8, subSize, f)) {
                        c->frames.push_back(std::move(f));
                    }
                }
                subOff += 8 + subSize;
                if (subSize & 1) ++subOff;  // RIFF pad
            }
        } else if (fourcc(ch, "rate") && chSize >= 4) {
            int n = (int)(chSize / 4);
            c->rates.resize(n);
            for (int i = 0; i < n; ++i) c->rates[i] = rd_u32(data + i * 4);
        } else if (fourcc(ch, "seq ") && chSize >= 4) {
            int n = (int)(chSize / 4);
            c->seq.resize(n);
            for (int i = 0; i < n; ++i) c->seq[i] = (int)rd_u32(data + i * 4);
        }

        off = dataOff + chSize;
        if (chSize & 1) ++off;  // pad to even
    }

    if (c->frames.empty()) { delete c; return nullptr; }

    // Sanity defaults: if seq/rates absent, walk frames 0..n-1 once
    // per cycle, defaultJiffies each.
    if (c->seq.empty()) {
        int n = c->numSteps > 0 ? c->numSteps : (int)c->frames.size();
        c->seq.resize(n);
        for (int i = 0; i < n; ++i) c->seq[i] = i % (int)c->frames.size();
    }
    if (c->rates.empty()) {
        c->rates.assign(c->seq.size(), c->defaultJiffies);
    }

    build_nscursors(c);
    return c;
}

// ============================================================
// Animation timer + active-cursor state.
// ============================================================
AniCursor*  g_active = nullptr;
size_t      g_activeStep = 0;
uint32_t    g_jiffiesIntoStep = 0;
NSTimer*    g_timer = nil;

void apply_active_frame() {
    if (!g_active || !g_active->nsCursors || g_active->nsCursors.count == 0) return;
    int idx = (g_active->seq.empty()) ? 0 : g_active->seq[g_activeStep % g_active->seq.size()];
    if (idx < 0 || idx >= (int)g_active->nsCursors.count) idx = 0;
    [[g_active->nsCursors objectAtIndex:idx] set];
}

void tick_timer() {
    if (!g_active || g_active->seq.size() <= 1) return;
    ++g_jiffiesIntoStep;
    uint32_t needed = g_active->rates[g_activeStep % g_active->rates.size()];
    if (needed == 0) needed = g_active->defaultJiffies;
    if (g_jiffiesIntoStep >= needed) {
        g_jiffiesIntoStep = 0;
        g_activeStep = (g_activeStep + 1) % g_active->seq.size();
        apply_active_frame();
    }
}

void ensure_timer() {
    if (g_timer) return;
    // 60 Hz tick — matches Win32 jiffy resolution.
    g_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                              repeats:YES
                                                block:^(NSTimer*) { tick_timer(); }];
    // Run in common modes so animation continues during modal UI.
    [[NSRunLoop currentRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
}

}  // anonymous namespace

// ============================================================
// Public entry points (C linkage for the win32 shim).
// ============================================================
extern "C" void* MetalCursor_LoadAni(const char* path)
{
    if (!path || !*path) return nullptr;
    std::string key(path);

    auto& cache = g_cache();
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;

    std::vector<uint8_t> buf = read_file(key);
    if (buf.empty()) {
        cache[key] = nullptr;   // negative cache — don't retry
        return nullptr;
    }

    AniCursor* c = parse_ani(buf);
    cache[key] = c;             // may be null on parse fail
    return c;
}

extern "C" void MetalCursor_SetActiveAni(void* handle)
{
    AniCursor* c = (AniCursor*)handle;
    if (c == g_active && c != nullptr) return;   // no-op repeat

    g_active = c;
    g_activeStep = 0;
    g_jiffiesIntoStep = 0;
    if (c) {
        ensure_timer();
        apply_active_frame();
    }
}

#endif  // __APPLE__

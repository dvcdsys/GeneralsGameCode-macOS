/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// FILE: gdi_text.mm //////////////////////////////////////////////////////////
// TheSuperHackers @port macOS GDI text backend.
//
// The engine rasterizes font glyph atlases through a tiny slice of the Win32
// GDI API (CreateFont / CreateDIBSection / ExtTextOutW / GetTextMetrics / ...),
// implemented in WW3D2's FontCharsClass (render2dsentence.cpp). On Windows
// these hit real GDI; on macOS the osdep_compat win32_api.h declares them
// `extern` (no body) and this file backs them with Core Text + Core Graphics.
//
// The engine's glyph build is: create a font, create a 24bpp top-down DIB, draw
// each glyph white-on-black with ExtTextOutW(ETO_OPAQUE), then read the low byte
// of every pixel (stride = ((w*3)+3)&~3, index += 3 per column) as 0..255
// coverage → packed into an ARGB4444 atlas. We reproduce exactly that: a glyph
// is rendered into an RGBA8 CGBitmapContext (white on black, grayscale AA), then
// the R channel is copied into all 3 bytes of the 24bpp DIB.
///////////////////////////////////////////////////////////////////////////////

#if defined(__APPLE__)

// Core Text / Core Graphics pull in libdispatch -> <objc/objc.h>, which does
// `typedef bool BOOL`. osdep_compat's windows.h does `typedef int BOOL`. Two
// conflicting typedefs of the same name is a hard error. Include the frameworks
// FIRST (so objc's BOOL exists), then redirect the `BOOL` *token* to a fresh
// name before windows.h so its `typedef int BOOL;` becomes `typedef int
// WIN_BOOL;` — no clash. The macro stays in force for the rest of this TU, so
// every `BOOL` we (and the win32_api.h declarations) write resolves to int,
// exactly matching the engine's BOOL=int used in render2dsentence.cpp.
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

#define BOOL WIN_BOOL
#include <windows.h>   // osdep_compat: GDI types, HDC/HFONT/HBITMAP, TEXTMETRIC, BITMAPINFO

#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

namespace {

enum {
	GDI_KIND_DC     = 0x47444344,  // 'GDCD'
	GDI_KIND_FONT   = 0x4744464E,  // 'GDFN'
	GDI_KIND_BITMAP = 0x4744424D,  // 'GDBM'
};

struct GdiFont {
	uint32_t kind;
	CTFontRef font;
	int       ascent;
	int       descent;
	int       height;   // ascent + descent
};

struct GdiBitmap {
	uint32_t kind;
	int      width;
	int      height;    // always positive (rows)
	int      bitCount;
	int      stride;     // bytes per row (4-aligned)
	uint8_t* bits;       // owned
};

struct GdiDC {
	uint32_t   kind;
	GdiBitmap* bmp;
	GdiFont*   font;
	uint32_t   bkColor;     // COLORREF 0x00bbggrr
	uint32_t   textColor;
};

inline uint32_t kindOf(void* p)
{
	// All objects we hand out begin with a uint32 kind tag. Pointers we never
	// created won't reach these calls in the macOS build (the only other GDI
	// callers guard their handles), so reading the tag is safe.
	return p ? *reinterpret_cast<uint32_t*>(p) : 0;
}

// Convert a run of engine WCHARs (wchar_t, 4 bytes = Unicode code points) into
// UTF-16 UniChar units for Core Text. Returns the number of UTF-16 units.
int ToUTF16(const WCHAR* s, int n, UniChar* out, int outMax)
{
	int k = 0;
	for (int i = 0; i < n && k < outMax; ++i) {
		uint32_t cp = (uint32_t)s[i];
		if (cp < 0x10000u) {
			out[k++] = (UniChar)cp;
		} else if (k + 1 < outMax) {
			cp -= 0x10000u;
			out[k++] = (UniChar)(0xD800u + (cp >> 10));
			out[k++] = (UniChar)(0xDC00u + (cp & 0x3FFu));
		}
	}
	return k;
}

} // namespace

// ---------------------------------------------------------------------------
// Device contexts
// ---------------------------------------------------------------------------
HDC GetDC(HWND)
{
	GdiDC* dc = (GdiDC*)::calloc(1, sizeof(GdiDC));
	dc->kind = GDI_KIND_DC;
	dc->textColor = 0x00FFFFFF;  // white
	dc->bkColor   = 0x00000000;  // black
	return (HDC)dc;
}

int ReleaseDC(HWND, HDC hdc)
{
	if (hdc && kindOf(hdc) == GDI_KIND_DC) ::free(hdc);
	return 1;
}

HDC CreateCompatibleDC(HDC)
{
	GdiDC* dc = (GdiDC*)::calloc(1, sizeof(GdiDC));
	dc->kind = GDI_KIND_DC;
	dc->textColor = 0x00FFFFFF;
	dc->bkColor   = 0x00000000;
	return (HDC)dc;
}

BOOL DeleteDC(HDC hdc)
{
	if (hdc && kindOf(hdc) == GDI_KIND_DC) ::free(hdc);
	return TRUE;
}

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------
HFONT CreateFont(int height, int /*width*/, int /*esc*/, int /*orient*/,
                 int weight, DWORD italic, DWORD /*underline*/, DWORD /*strikeout*/,
                 DWORD /*charset*/, DWORD /*outprec*/, DWORD /*clipprec*/,
                 DWORD /*quality*/, DWORD /*pitch*/, const char* name)
{
	// Win32: height<0 means "character height = -height pixels" (cell em size).
	CGFloat emSize = (height < 0) ? (CGFloat)(-height) : (CGFloat)height;
	if (emSize <= 0) emSize = 12;

	const char* fontName = (name && name[0]) ? name : "Arial";
	CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, fontName,
	                                               kCFStringEncodingUTF8);
	CTFontRef ctFont = cfName ? CTFontCreateWithName(cfName, emSize, NULL) : NULL;
	if (cfName) CFRelease(cfName);
	if (!ctFont) {
		ctFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, emSize, NULL);
	}

	// Apply bold / italic traits if requested.
	CTFontSymbolicTraits want = 0;
	if (weight >= 600) want |= kCTFontTraitBold;     // FW_SEMIBOLD/FW_BOLD
	if (italic)        want |= kCTFontTraitItalic;
	if (want && ctFont) {
		CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(ctFont, emSize, NULL,
		                                                      want, want);
		if (styled) { CFRelease(ctFont); ctFont = styled; }
	}

	GdiFont* f = (GdiFont*)::calloc(1, sizeof(GdiFont));
	f->kind = GDI_KIND_FONT;
	f->font = ctFont;   // retained
	if (ctFont) {
		f->ascent  = (int)std::ceil(CTFontGetAscent(ctFont));
		f->descent = (int)std::ceil(CTFontGetDescent(ctFont));
	}
	f->height = f->ascent + f->descent;
	return (HFONT)f;
}

HFONT CreateFontIndirect(const LOGFONT*) { return nullptr; }

// ---------------------------------------------------------------------------
// DIB sections (the glyph scratch surface)
// ---------------------------------------------------------------------------
HBITMAP CreateDIBSection(HDC, const BITMAPINFO* bmi, UINT, void** bits, HANDLE, DWORD)
{
	if (bits) *bits = nullptr;
	if (!bmi) return nullptr;

	const BITMAPINFOHEADER& h = bmi->bmiHeader;
	int width  = (int)h.biWidth;
	int height = (int)(h.biHeight < 0 ? -h.biHeight : h.biHeight);
	int bpp    = h.biBitCount ? h.biBitCount : 24;
	if (width <= 0 || height <= 0) return nullptr;

	int stride = (((width * (bpp / 8)) + 3) & ~3);

	GdiBitmap* bm = (GdiBitmap*)::calloc(1, sizeof(GdiBitmap));
	bm->kind     = GDI_KIND_BITMAP;
	bm->width    = width;
	bm->height   = height;
	bm->bitCount = bpp;
	bm->stride   = stride;
	bm->bits     = (uint8_t*)::calloc((size_t)height * stride, 1);

	if (bits) *bits = bm->bits;
	return (HBITMAP)bm;
}

// ---------------------------------------------------------------------------
// Object selection / colors
// ---------------------------------------------------------------------------
HGDIOBJ SelectObject(HDC hdc, HGDIOBJ obj)
{
	if (!hdc || kindOf(hdc) != GDI_KIND_DC) return nullptr;
	GdiDC* dc = (GdiDC*)hdc;
	uint32_t k = kindOf(obj);
	if (k == GDI_KIND_FONT) {
		GdiFont* prev = dc->font;
		dc->font = (GdiFont*)obj;
		return (HGDIOBJ)prev;
	}
	if (k == GDI_KIND_BITMAP) {
		GdiBitmap* prev = dc->bmp;
		dc->bmp = (GdiBitmap*)obj;
		return (HGDIOBJ)prev;
	}
	return nullptr;
}

BOOL DeleteObject(HGDIOBJ obj)
{
	uint32_t k = kindOf(obj);
	if (k == GDI_KIND_FONT) {
		GdiFont* f = (GdiFont*)obj;
		if (f->font) CFRelease(f->font);
		::free(f);
		return TRUE;
	}
	if (k == GDI_KIND_BITMAP) {
		GdiBitmap* bm = (GdiBitmap*)obj;
		::free(bm->bits);
		::free(bm);
		return TRUE;
	}
	return TRUE;  // unknown handle: nothing to do
}

COLORREF SetTextColor(HDC hdc, COLORREF c)
{
	if (!hdc || kindOf(hdc) != GDI_KIND_DC) return 0;
	GdiDC* dc = (GdiDC*)hdc;
	COLORREF prev = dc->textColor;
	dc->textColor = c;
	return prev;
}

COLORREF SetBkColor(HDC hdc, COLORREF c)
{
	if (!hdc || kindOf(hdc) != GDI_KIND_DC) return 0;
	GdiDC* dc = (GdiDC*)hdc;
	COLORREF prev = dc->bkColor;
	dc->bkColor = c;
	return prev;
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------
int GetTextMetrics(HDC hdc, TEXTMETRIC* tm)
{
	if (!tm) return FALSE;
	::memset(tm, 0, sizeof(*tm));
	if (!hdc || kindOf(hdc) != GDI_KIND_DC) return FALSE;
	GdiDC* dc = (GdiDC*)hdc;
	if (dc->font) {
		tm->tmAscent  = dc->font->ascent;
		tm->tmDescent = dc->font->descent;
		tm->tmHeight  = dc->font->height;
	}
	tm->tmOverhang = 0;
	return TRUE;
}

DWORD GetTextExtentPoint32W(HDC hdc, const WCHAR* s, int n, SIZE* sz)
{
	if (sz) { sz->cx = 0; sz->cy = 0; }
	if (!hdc || kindOf(hdc) != GDI_KIND_DC || !s || n <= 0) return FALSE;
	GdiDC* dc = (GdiDC*)hdc;
	if (!dc->font || !dc->font->font) return FALSE;

	UniChar u16[256];
	int u = ToUTF16(s, n, u16, 256);
	if (u <= 0) { if (sz) sz->cy = dc->font->height; return TRUE; }

	std::vector<CGGlyph> glyphs(u);
	CTFontGetGlyphsForCharacters(dc->font->font, u16, glyphs.data(), u);

	std::vector<CGSize> adv(u);
	double total = CTFontGetAdvancesForGlyphs(dc->font->font,
	                                          kCTFontOrientationHorizontal,
	                                          glyphs.data(), adv.data(), u);
	(void)total;
	double cx = 0;
	for (int i = 0; i < u; ++i) cx += adv[i].width;

	if (sz) {
		sz->cx = (int)std::ceil(cx);
		sz->cy = dc->font->height;
	}
	return TRUE;
}

// ---------------------------------------------------------------------------
// Glyph rasterization
// ---------------------------------------------------------------------------
BOOL ExtTextOutW(HDC hdc, int x, int y, UINT /*opts*/, const RECT* /*rc*/,
                 const WCHAR* s, UINT n, const int* /*dx*/)
{
	if (!hdc || kindOf(hdc) != GDI_KIND_DC) return FALSE;
	GdiDC* dc = (GdiDC*)hdc;
	GdiBitmap* bm = dc->bmp;
	if (!bm || !bm->bits) return FALSE;

	const int W = bm->width;
	const int H = bm->height;

	// Background fill (the engine always passes ETO_OPAQUE with bkColor=black).
	uint8_t bkLow = (uint8_t)(dc->bkColor & 0xFF);
	for (int r = 0; r < H; ++r) {
		uint8_t* row = bm->bits + (size_t)r * bm->stride;
		for (int c = 0; c < W; ++c) {
			row[c*3 + 0] = bkLow; row[c*3 + 1] = bkLow; row[c*3 + 2] = bkLow;
		}
	}

	if (!dc->font || !dc->font->font || !s || n == 0) return TRUE;

	// Render the glyph(s) into an RGBA8 context: white text on black, grayscale
	// (no subpixel) AA so the R channel == coverage.
	const size_t bpr = (size_t)W * 4;
	std::vector<uint8_t> tmp((size_t)H * bpr, 0);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(tmp.data(), W, H, 8, bpr, cs,
	                                          kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(cs);
	if (!ctx) return TRUE;

	CGContextSetShouldAntialias(ctx, true);
	CGContextSetShouldSmoothFonts(ctx, false);   // grayscale, not LCD subpixel
	CGContextSetAllowsFontSmoothing(ctx, false);

	// Background (in case glyphs have premultiplied edges over non-black bk).
	uint8_t bkR = (uint8_t)(dc->bkColor & 0xFF);
	uint8_t bkG = (uint8_t)((dc->bkColor >> 8) & 0xFF);
	uint8_t bkB = (uint8_t)((dc->bkColor >> 16) & 0xFF);
	CGContextSetRGBFillColor(ctx, bkR/255.0, bkG/255.0, bkB/255.0, 1.0);
	CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

	uint8_t txR = (uint8_t)(dc->textColor & 0xFF);
	uint8_t txG = (uint8_t)((dc->textColor >> 8) & 0xFF);
	uint8_t txB = (uint8_t)((dc->textColor >> 16) & 0xFF);
	CGContextSetRGBFillColor(ctx, txR/255.0, txG/255.0, txB/255.0, 1.0);

	UniChar u16[256];
	int u = ToUTF16(s, (int)n, u16, 256);
	if (u > 0) {
		std::vector<CGGlyph> glyphs(u);
		CTFontGetGlyphsForCharacters(dc->font->font, u16, glyphs.data(), u);
		std::vector<CGSize> adv(u);
		CTFontGetAdvancesForGlyphs(dc->font->font, kCTFontOrientationHorizontal,
		                           glyphs.data(), adv.data(), u);

		// Win32 ExtTextOut y = top of the cell. Baseline (top-down) row = y +
		// ascent. The CG context is bottom-up, so CG baseline = H - (y + ascent).
		CGFloat baseline = (CGFloat)(H - (y + dc->font->ascent));
		std::vector<CGPoint> pos(u);
		CGFloat pen = (CGFloat)x;
		for (int i = 0; i < u; ++i) {
			pos[i] = CGPointMake(pen, baseline);
			pen += adv[i].width;
		}
		CTFontDrawGlyphs(dc->font->font, glyphs.data(), pos.data(), u, ctx);
	}

	CGContextRelease(ctx);

	// Copy coverage (R channel) into the 24bpp top-down DIB.
	// NOTE: a CGBitmapContext stores row 0 at the TOP of the image in memory,
	// even though its drawing coordinate system is y-up (origin bottom-left).
	// Our baseline math already accounts for the y-up coords (CG baseline =
	// H-(y+ascent)), so the memory rows are ALREADY top-down — copy row r->r
	// directly. (An extra H-1-r flip here vertically mirrored every glyph, which
	// for symmetric letters like 'E' looked fine but turned 'S'->'Ƨ' etc.)
	unsigned long covSum = 0; int covMax = 0;
	for (int r = 0; r < H; ++r) {
		const uint8_t* src = tmp.data() + (size_t)r * bpr;
		uint8_t* dst = bm->bits + (size_t)r * bm->stride;
		for (int c = 0; c < W; ++c) {
			uint8_t cov = src[c*4 + 0];  // R; white text → coverage
			dst[c*3 + 0] = cov; dst[c*3 + 1] = cov; dst[c*3 + 2] = cov;
			covSum += cov; if (cov > covMax) covMax = cov;
		}
	}
	// Debug: dump the rendered DIB (24bpp) to PNG so we can inspect glyph
	// orientation directly. Gated by MTL_DUMP, capped.
	if (::getenv("MTL_DUMPTEX")) {
		static int dn = 0;
		if (covSum > 200 && dn < 8) {
			int N = dn++;
			std::vector<uint8_t> rgba((size_t)W*H*4);
			for (int r=0;r<H;++r) for (int c=0;c<W;++c){
				uint8_t v = bm->bits[(size_t)r*bm->stride + c*3];
				uint8_t* dp = rgba.data() + ((size_t)r*W+c)*4;
				dp[0]=v; dp[1]=v; dp[2]=v; dp[3]=255;
			}
			CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
			CGContextRef bc = CGBitmapContextCreate(rgba.data(), W, H, 8, W*4, cs2, kCGImageAlphaPremultipliedLast);
			CGImageRef img = CGBitmapContextCreateImage(bc);
			char path[128]; snprintf(path, sizeof(path), "/tmp/gdi_dib_%02d_ch%04X.png", N, (s?(unsigned)s[0]:0));
			CFStringRef cfp = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
			CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfp, kCFURLPOSIXPathStyle, false);
			CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);
			if (dest) { CGImageDestinationAddImage(dest, img, NULL); CGImageDestinationFinalize(dest); CFRelease(dest); }
			CFRelease(url); CFRelease(cfp); CGImageRelease(img); CGContextRelease(bc); CGColorSpaceRelease(cs2);
		}
	}
	static int s_dbg = -1;
	if (s_dbg < 0) s_dbg = ::getenv("MTL_DEBUG") ? 1 : 0;
	if (s_dbg) {
		static int s_count = 0;
		if (s_count < 24) {
			::fprintf(stderr, "[gdi] ExtTextOutW ch=U+%04X W=%d H=%d covSum=%lu covMax=%d ascent=%d\n",
			          (s ? (unsigned)s[0] : 0), W, H, covSum, covMax, dc->font->ascent);
			::fflush(stderr);
			++s_count;
		}
	}
	return TRUE;
}

#endif // __APPLE__

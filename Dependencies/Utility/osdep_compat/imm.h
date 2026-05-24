#pragma once
// Minimal <imm.h> (Input Method Manager) shim for non-Windows builds.
//
// The engine's IMEManager drives the Windows IME (for CJK text entry). There is
// no macOS IME wired up yet (real input arrives with the SDL phase), so the IMM
// context is a no-op token and every Imm* call reports "no IME / nothing to
// read". This only has to compile; IME composition is a runtime-input gap.
// TODO(macos): real impl would bridge to NSTextInputClient.
#ifndef _WIN32

#include "windows.h"

// IMM input context handle.
#ifndef _HIMC_DEFINED
#define _HIMC_DEFINED
typedef HANDLE HIMC;
#endif

// CANDIDATELIST: variable-length list of IME candidate strings. Only the header
// fields are referenced; dwOffset[] is the trailing flexible array.
typedef struct tagCANDIDATELIST {
  DWORD dwSize;
  DWORD dwStyle;
  DWORD dwCount;
  DWORD dwSelection;
  DWORD dwPageStart;
  DWORD dwPageSize;
  DWORD dwOffset[1];
} CANDIDATELIST, *LPCANDIDATELIST;

// IMM notification codes (IMN_*). Canonical Win32 values.
#ifndef IMN_OPENSTATUSWINDOW
#define IMN_CLOSESTATUSWINDOW   0x0001
#define IMN_OPENSTATUSWINDOW    0x0002
#define IMN_CHANGECANDIDATE     0x0003
#define IMN_CLOSECANDIDATE      0x0004
#define IMN_OPENCANDIDATE       0x0005
#define IMN_SETCONVERSIONMODE   0x0006
#define IMN_SETSENTENCEMODE     0x0007
#define IMN_SETOPENSTATUS       0x0008
#define IMN_SETCANDIDATEPOS     0x0009
#define IMN_SETCOMPOSITIONFONT  0x000A
#define IMN_SETCOMPOSITIONWINDOW 0x000B
#define IMN_SETSTATUSWINDOWPOS  0x000C
#define IMN_GUIDELINE           0x000D
#define IMN_PRIVATE             0x000E
#endif

// GCS_* (composition-string flags) and CS_* (composition-status flags).
#ifndef GCS_COMPSTR
#define GCS_COMPREADSTR   0x0001
#define GCS_COMPSTR       0x0008
#define GCS_CURSORPOS     0x0080
#define GCS_RESULTSTR     0x0800
#endif
#ifndef CS_INSERTCHAR
#define CS_INSERTCHAR     0x2000
#define CS_NOMOVECARET    0x4000
#endif

// Candidate-list styles (dwStyle).
#ifndef IME_CAND_UNKNOWN
#define IME_CAND_UNKNOWN  0x0000
#define IME_CAND_READ     0x0001
#define IME_CAND_CODE     0x0002
#define IME_CAND_MEANING  0x0003
#define IME_CAND_RADICAL  0x0004
#define IME_CAND_STROKE   0x0005
#endif

// ImmGetProperty index + property bits.
#ifndef IGP_PROPERTY
#define IGP_GETIMEVERSION (-4)
#define IGP_PROPERTY      0x00000004
#define IGP_CONVERSION    0x00000008
#define IGP_SENTENCE      0x0000000C
#endif
#ifndef IME_PROP_UNICODE
#define IME_PROP_AT_CARET            0x00010000
#define IME_PROP_SPECIAL_UI          0x00020000
#define IME_PROP_CANDLIST_START_FROM_1 0x00040000
#define IME_PROP_UNICODE             0x00080000
#endif

// IMM API. All stubbed: no IME context exists on macOS.
inline HIMC ImmCreateContext()                          { return (HIMC)(intptr_t)1; }
inline BOOL ImmDestroyContext(HIMC)                     { return TRUE; }
inline HIMC ImmGetContext(HWND)                         { return (HIMC)(intptr_t)1; }
inline BOOL ImmReleaseContext(HWND, HIMC)               { return TRUE; }
inline HIMC ImmAssociateContext(HWND, HIMC)             { return (HIMC)(intptr_t)1; }
inline HWND ImmGetDefaultIMEWnd(HWND)                   { return nullptr; }
inline BOOL ImmGetConversionStatus(HIMC, DWORD* conv, DWORD* sent)
{ if (conv) *conv = 0; if (sent) *sent = 0; return TRUE; }
inline DWORD ImmGetProperty(HKL, DWORD)                 { return 0; }
inline LONG ImmGetCompositionStringA(HIMC, DWORD, void* buf, DWORD len)
{ if (buf && len) ((char*)buf)[0] = 0; return 0; }
inline LONG ImmGetCompositionStringW(HIMC, DWORD, void* buf, DWORD len)
{ if (buf && len) ((WCHAR*)buf)[0] = 0; return 0; }
inline DWORD ImmGetCandidateListA(HIMC, DWORD, LPCANDIDATELIST, DWORD) { return 0; }
inline DWORD ImmGetCandidateListW(HIMC, DWORD, LPCANDIDATELIST, DWORD) { return 0; }
inline DWORD ImmGetCandidateListCountA(HIMC, DWORD* count) { if (count) *count = 0; return 0; }
inline DWORD ImmGetCandidateListCountW(HIMC, DWORD* count) { if (count) *count = 0; return 0; }
// Non-suffixed spellings (Win32 maps these to A/W via the UNICODE macro).
inline LONG ImmGetCompositionString(HIMC c, DWORD i, void* buf, DWORD len)
{ return ImmGetCompositionStringA(c, i, buf, len); }
inline DWORD ImmGetCandidateList(HIMC c, DWORD i, LPCANDIDATELIST l, DWORD n)
{ return ImmGetCandidateListA(c, i, l, n); }

#endif // !_WIN32

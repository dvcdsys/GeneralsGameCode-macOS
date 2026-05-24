#pragma once
// <dsound.h> shim for non-Windows builds.
//
// DirectSound is Windows-only. The Miles audio backend only touches it to ask
// the (Miles-owned) IDirectSound object for its speaker configuration, so a
// minimal opaque COM-style interface is enough to compile.
//
// TODO(macos): real audio output is a later phase (planned via a portable
// backend); these definitions are inert stubs.
#ifndef _WIN32

#include "windows.h"
#include "objbase.h"

#ifndef DS_OK
#define DS_OK 0
#endif

// Speaker-configuration codes returned by IDirectSound::GetSpeakerConfig.
#ifndef DSSPEAKER_DIRECTOUT
#define DSSPEAKER_DIRECTOUT  0x00000000
#define DSSPEAKER_HEADPHONE  0x00000001
#define DSSPEAKER_MONO       0x00000002
#define DSSPEAKER_QUAD       0x00000003
#define DSSPEAKER_STEREO     0x00000004
#define DSSPEAKER_SURROUND   0x00000005
#define DSSPEAKER_5POINT1    0x00000006
#define DSSPEAKER_7POINT1    0x00000007
#define DSSPEAKER_CONFIG(a)  ((BYTE)(a))
#endif

// Minimal IDirectSound surface used by MilesAudioManager.
struct IDirectSound
{
    virtual HRESULT GetSpeakerConfig(unsigned long * /*config*/) { return DS_OK; }
    virtual ~IDirectSound() {}
};
typedef IDirectSound *LPDIRECTSOUND;

struct IDirectSoundBuffer;
typedef IDirectSoundBuffer *LPDIRECTSOUNDBUFFER;

#endif // !_WIN32

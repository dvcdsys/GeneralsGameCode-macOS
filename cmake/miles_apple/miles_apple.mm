// miles_apple.mm — Real Miles Sound System impl on top of AVAudioEngine.
//
// Drop-in replacement for the upstream miles-sdk-stub on macOS. The MSS
// header (mss/mss.h) is identical, so the engine's MilesAudioManager.cpp
// builds and links unchanged. Only the AIL_* function bodies differ.
//
// Backend choice: AVAudioEngine for mixing / output / 3D positioning,
// AudioToolbox (AudioFileOpenWithCallbacks + ExtAudioFile) for MP3 decode.
// 2D / 3D samples come in as in-memory WAV buffers from the engine's
// AudioFileCache; streams are read from the BIG archives via the engine's
// AIL_set_file_callbacks-registered I/O hooks.
//
// Debug envs:
//   MILES_APPLE_LOG=1      — log every AIL_* call (very chatty)
//   MILES_APPLE_LOG=2      — log only lifecycle (startup/handles/file load)
//   MILES_APPLE_MUTE=1     — short-circuit playback to silent (handles still
//                            cycle so EOS callbacks still fire)

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "mss/mss.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// ----------------------------------------------------------------------------
// Logging
// ----------------------------------------------------------------------------
static int g_logLevel = -1;
static bool g_muted = false;

static int milesLogLevel(void) {
    if (g_logLevel < 0) {
        const char *v = getenv("MILES_APPLE_LOG");
        g_logLevel = v ? atoi(v) : 0;
        const char *m = getenv("MILES_APPLE_MUTE");
        g_muted = m && atoi(m) != 0;
    }
    return g_logLevel;
}

#define MLOG(lvl, fmt, ...) do { \
    if (milesLogLevel() >= (lvl)) { \
        fprintf(stderr, "[miles] " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

// ----------------------------------------------------------------------------
// Internal handle types. The public mss/mss.h declares:
//   HSAMPLE   = struct _SAMPLE *      (incomplete in header — we own the body)
//   HSTREAM   = struct _STREAM *      (incomplete)
//   H3DSAMPLE = h3DPOBJECT *          (header has {unsigned int junk;})
//   HDIGDRIVER= _DIG_DRIVER *         (header has {char pad[168]; int emulated_ds;})
//   HPROVIDER = void *
//
// HDIGDRIVER's layout is observed by the engine (WWAudio reads
// m_Driver2D->emulated_ds), so we keep the public struct as a thin façade and
// stash a back-pointer to our state in its pad[].
// HSAMPLE / HSTREAM are opaque to the engine — pointers only.
// ----------------------------------------------------------------------------

struct ApplePlayerBase;
struct AppleSample;
struct Apple3DSample;
struct AppleStream;
struct AppleProvider;

namespace {

constexpr unsigned int kUserDataSlots = 8;

// Each queued callback is paired with the handle pointer it dereferences
// (AppleSample* / AppleStream* / Apple3DSample*). drainCallbacks() consults
// g_aliveHandles before firing the block — if the owner was released between
// queue and drain, we drop the callback rather than dereferencing freed
// memory (which produces `EXC_BAD_ACCESS in libobjc lookUpImpOrForward` —
// the exact crash observed when ending a mission while a stream's loop-
// continuation callback is still queued, miles_apple.mm:1541 → 650 → 131
// trace). owner==nullptr means "no liveness check, always fire" (rare, for
// device-level callbacks).
struct PendingCallback {
    void *owner;
    dispatch_block_t cb;
};

struct AppleAudioDevice {
    AVAudioEngine *engine = nil;
    AVAudioMixerNode *mixer2D = nil;            // 2D samples + streams
    AVAudioEnvironmentNode *environment = nil;  // 3D samples sink
    double outputSampleRate = 44100.0;
    bool started = false;
    std::mutex pendingCallbacksLock;
    std::deque<PendingCallback> pendingCallbacks;
};

AppleAudioDevice g_device;

// Live-handle registry. Guards against UAF in queued callbacks: every
// AppleSample / AppleStream / Apple3DSample is registered at construction
// (markAlive) and removed before its `delete` (markDead). enqueueCallback
// captures the owning handle pointer; drainCallbacks skips the block if the
// owner is no longer alive. All access on main thread (engine update tick),
// plus the AVAudio internal queue's enqueueCallback (which only writes the
// vector under the device lock — the alive check itself never runs on the
// AVAudio queue).
static std::mutex g_aliveHandlesLock;
static std::unordered_set<void*> g_aliveHandles;
static inline void markAlive(void *p) {
    if (!p) return;
    std::lock_guard<std::mutex> g(g_aliveHandlesLock);
    g_aliveHandles.insert(p);
}
static inline void markDead(void *p) {
    if (!p) return;
    std::lock_guard<std::mutex> g(g_aliveHandlesLock);
    g_aliveHandles.erase(p);
}
static inline bool isAlive(void *p) {
    if (!p) return true;  // null owner == device-level, always live
    std::lock_guard<std::mutex> g(g_aliveHandlesLock);
    return g_aliveHandles.count(p) > 0;
}

// Registry of buffers produced by AIL_decompress_ADPCM. The engine hands the
// raw PCM pointer back to us via AIL_set_(3D_)sample_file, but the data has
// no WAV header for parseWav() to discover format/rate. We remember the
// AILSOUNDINFO that was used to produce each output so we can recreate the
// AVAudioFormat at bind time.
struct ImaDecodedBlob {
    int channels;
    int rate;
    unsigned long size;
};
std::mutex g_imaLock;
std::unordered_map<void*, ImaDecodedBlob> g_imaBlobs;

// Mirror of the active listener's world position. Updated whenever the
// engine calls AIL_set_3D_position on the H3DPOBJECT that was opened with
// AIL_open_3D_listener. We use it (instead of querying the
// AVAudioEnvironmentNode) to do manual pan + distance attenuation for 3D
// voices that route through the flat mixer.
static std::atomic<float> g_listenerX{0.0f};
static std::atomic<float> g_listenerY{0.0f};
static std::atomic<float> g_listenerZ{0.0f};
// Listener orientation: forward = camera look direction, up = camera up
// vector. Default points down the +Y axis with Z-up so a brand-new world
// (before the engine sends the first orientation) still produces sane pan.
static std::atomic<float> g_listenerFwdX{0.0f}, g_listenerFwdY{1.0f}, g_listenerFwdZ{0.0f};
static std::atomic<float> g_listenerUpX{0.0f},  g_listenerUpY{0.0f},  g_listenerUpZ{-1.0f};

// Drain queued EOS callbacks on the caller's thread. The engine pumps via
// every AIL_* call it makes from its update tick (see drainCallbacks() calls
// peppered through the public surface), which keeps the engine's playing-list
// status flips on the main thread, matching Miles's effective model.
static void drainCallbacks() {
    std::deque<PendingCallback> local;
    {
        std::lock_guard<std::mutex> guard(g_device.pendingCallbacksLock);
        local.swap(g_device.pendingCallbacks);
    }
    for (auto &p : local) {
        // Owner was released (delete s in AIL_release_*_handle / close_stream)
        // between this block being queued and this drain. Skip — calling into
        // the captured pointer would touch freed memory (the original symptom:
        // EXC_BAD_ACCESS at libobjc lookUpImpOrForward + 96 inside an objc
        // dispatch from the stale block on miles_apple.mm:1541 → 650 → 131).
        if (!isAlive(p.owner)) continue;
        p.cb();
    }
}

// owner==nullptr → no liveness check (device-level callbacks).
// owner!=nullptr → callback is dropped on drain if owner was released.
static void enqueueCallback(void *owner, dispatch_block_t cb) {
    if (!cb) return;
    std::lock_guard<std::mutex> guard(g_device.pendingCallbacksLock);
    g_device.pendingCallbacks.push_back({owner, cb});
}

} // namespace

struct ApplePlayerBase {
    AVAudioPlayerNode *node = nil;
    AVAudioPCMBuffer *buffer = nil;
    AVAudioFormat *bufferFormat = nil;
    void *userData[kUserDataSlots] = {0};
    float volume = 1.0f;
    float pan = 0.5f;          // 0..1, 0.5=center
    int loopCount = 1;         // 0 = infinite
    int loopsRemaining = 0;
    std::atomic<bool> playing{false};
    std::atomic<int> generation{0}; // bump on stop/reload so stale completion handlers ignore
};

struct AppleSample : ApplePlayerBase {
    AIL_sample_callback eosCallback = nullptr;
    HDIGDRIVER owner = nullptr;
};

// h3DPOBJECT { unsigned int junk; } is the engine-visible header — we tag
// `junk` with a magic value so AIL_set_3D_position/orientation/user_data,
// which accept a bare H3DPOBJECT, can disambiguate listener vs sample without
// a side-channel registry.
constexpr unsigned int k3DTagSample   = 0x53334453;  // 'S3DS'
constexpr unsigned int k3DTagListener = 0x4C334450;  // 'L3DP'

struct Apple3DSample : public h3DPOBJECT {
    ApplePlayerBase player;
    AIL_3dsample_callback eosCallback = nullptr;
    float position[3] = {0,0,0};
    float minDist = 1.0f;
    float maxDist = 1000.0f;
    AppleProvider *provider = nullptr;

    Apple3DSample() { junk = k3DTagSample; }
};

struct Apple3DListener : public h3DPOBJECT {
    AppleProvider *provider = nullptr;
    float position[3] = {0,0,0};
    float forward[3] = {0,0,-1};
    float up[3] = {0,1,0};
    void *userData[kUserDataSlots] = {0};

    Apple3DListener() { junk = k3DTagListener; }
};

static inline bool isListenerObj(H3DPOBJECT obj) {
    return obj && obj->junk == k3DTagListener;
}

// Apply manual pan + distance-volume to a 3D voice based on the source's
// world position vs the listener. For a top-down RTS this matches what a
// player expects: a sound to the listener's left pans left even as the
// camera rotates, far-away sounds attenuate.
// Used in lieu of AVAudioEnvironmentNode, which throws "disconnected state"
// on M-series regardless of rendering algorithm.
static void apply3DPanAndVolumeForSource(Apple3DSample *s) {
    if (!s || !s->player.node) return;
    const float lx = g_listenerX.load();
    const float ly = g_listenerY.load();
    const float lz = g_listenerZ.load();
    const float dx = s->position[0] - lx;
    const float dy = s->position[1] - ly;
    const float dz = s->position[2] - lz;
    const float dist = sqrtf(dx*dx + dy*dy + dz*dz);
    const float minD = s->minDist > 0.0f ? s->minDist : 1.0f;
    const float maxD = s->maxDist > minD ? s->maxDist : (minD + 1.0f);
    float distGain;
    if (dist <= minD)      distGain = 1.0f;
    else if (dist >= maxD) distGain = 0.0f;
    else                   distGain = minD / dist;
    // Project the world-space delta onto the listener-local right axis:
    //   right = forward × up
    // pan = (delta · right) / maxDistance, clamped to ±1. This rotates the
    // panning frame with the camera — turning the view turns the soundscape.
    const float fx = g_listenerFwdX.load(), fy = g_listenerFwdY.load(), fz = g_listenerFwdZ.load();
    const float ux = g_listenerUpX.load(),  uy = g_listenerUpY.load(),  uz = g_listenerUpZ.load();
    const float rx = fy * uz - fz * uy;
    const float ry = fz * ux - fx * uz;
    const float rz = fx * uy - fy * ux;
    // Normalize right (in case forward and up aren't exactly perpendicular).
    const float rlen = sqrtf(rx*rx + ry*ry + rz*rz);
    float pan;
    if (rlen > 1e-6f) {
        const float nrx = rx / rlen, nry = ry / rlen, nrz = rz / rlen;
        pan = (dx * nrx + dy * nry + dz * nrz) / maxD;
    } else {
        // Degenerate basis — fall back to world X so we never go silent.
        pan = dx / maxD;
    }
    if (pan >  1.0f) pan =  1.0f;
    if (pan < -1.0f) pan = -1.0f;
    s->player.node.pan = pan;
    s->player.node.volume = (g_muted ? 0.0f : s->player.volume) * distGain;
}

struct AppleStream : ApplePlayerBase {
    AIL_stream_callback eosCallback = nullptr;
    HDIGDRIVER owner = nullptr;
    int totalMs = 0;
    int positionMs = 0;
};

struct AppleProvider {
    std::string name;
    bool isOpen = false;
    int speakerType = AIL_3D_2_SPEAKER;
};

// ----------------------------------------------------------------------------
// HDIGDRIVER façade — public layout is {char pad[168]; int emulated_ds;}.
// We allocate one real DIG_DRIVER struct and stash a pointer to our state in
// the first 8 bytes of pad[].
// ----------------------------------------------------------------------------

static DIG_DRIVER *g_publicDriver = nullptr; // owns the public-facing struct

struct AppleDriverState {
    DIG_DRIVER *publicDriver = nullptr;
    bool open = false;
};

static AppleDriverState g_driver;

static DIG_DRIVER *makePublicDriver() {
    DIG_DRIVER *d = (DIG_DRIVER *)calloc(1, sizeof(DIG_DRIVER));
    d->emulated_ds = 0;                       // NOT emulated — keeps WWAudio happy
    memcpy(d->pad, &g_driver, sizeof(void*)); // unused; reserved for future use
    return d;
}

// ----------------------------------------------------------------------------
// Providers (3D). The engine probes for "Miles Fast 2D Positional Audio" and
// "Dolby Surround" by name; we expose both, both routed to the same
// AVAudioEnvironmentNode.
// ----------------------------------------------------------------------------

static std::vector<AppleProvider*> g_providers;

static void initProviders() {
    if (!g_providers.empty()) return;
    static const char *names[] = {
        "Miles Fast 2D Positional Audio",
        "Dolby Surround",
    };
    for (const char *n : names) {
        AppleProvider *p = new AppleProvider();
        p->name = n;
        g_providers.push_back(p);
    }
}

// ----------------------------------------------------------------------------
// File-callback bridge for AIL_open_stream — engine registers I/O hooks via
// AIL_set_file_callbacks; streams are filesystem reads inside BIG archives.
// ----------------------------------------------------------------------------

static AIL_file_open_callback  g_openCb  = nullptr;
static AIL_file_close_callback g_closeCb = nullptr;
static AIL_file_seek_callback  g_seekCb  = nullptr;
static AIL_file_read_callback  g_readCb  = nullptr;

// ----------------------------------------------------------------------------
// WAV header parser — minimal RIFF/WAVE walker.
// Reads the in-memory buffer the engine hands us via AIL_set_sample_file /
// AIL_set_3D_sample_file. Supports PCM (16-bit, mono/stereo) and recognises
// IMA ADPCM (which AudioFileCache already decompresses before reaching here
// via AIL_decompress_ADPCM — we'll still parse it through ExtAudioFile if it
// shows up raw).
// ----------------------------------------------------------------------------

struct WavInfo {
    int format = 0;            // WAVE_FORMAT_PCM, WAVE_FORMAT_IMA_ADPCM
    int channels = 0;
    int rate = 0;
    int bits = 0;
    int blockAlign = 0;
    const void *dataPtr = nullptr;
    unsigned int dataLen = 0;
};

static bool parseWav(const void *image, unsigned int hintSize, WavInfo *out) {
    if (!image) return false;
    const unsigned char *p = (const unsigned char *)image;
    if (memcmp(p, "RIFF", 4) != 0) {
        MLOG(1, "parseWav: not a RIFF (%c%c%c%c)", p[0],p[1],p[2],p[3]);
        return false;
    }
    unsigned int riffSize = (unsigned int)(p[4] | (p[5]<<8) | (p[6]<<16) | (p[7]<<24));
    if (memcmp(p+8, "WAVE", 4) != 0) return false;
    // Walk chunks
    const unsigned char *cur = p + 12;
    const unsigned char *end = p + 8 + riffSize;
    if (hintSize && (unsigned int)(end - p) > hintSize) end = p + hintSize;
    while (cur + 8 <= end) {
        char id[5] = {0};
        memcpy(id, cur, 4);
        unsigned int sz = (unsigned int)(cur[4] | (cur[5]<<8) | (cur[6]<<16) | (cur[7]<<24));
        const unsigned char *body = cur + 8;
        if (memcmp(id, "fmt ", 4) == 0 && sz >= 16) {
            out->format     = body[0] | (body[1]<<8);
            out->channels   = body[2] | (body[3]<<8);
            out->rate       = body[4] | (body[5]<<8) | (body[6]<<16) | (body[7]<<24);
            // bytesPerSec at body+8 (skipped — derivable)
            out->blockAlign = body[12] | (body[13]<<8);
            out->bits       = body[14] | (body[15]<<8);
        } else if (memcmp(id, "data", 4) == 0) {
            out->dataPtr = body;
            out->dataLen = sz;
            return out->format != 0 && out->channels > 0 && out->rate > 0;
        }
        // chunks are word-aligned
        cur = body + sz + (sz & 1);
    }
    return false;
}

// Raw 16-bit-signed PCM blob → AVAudioPCMBuffer at the given rate/channel
// count. Used for the engine's IMA-ADPCM round-trip: AudioFileCache decodes
// IMA via AIL_decompress_ADPCM, hands back a bare PCM pointer (no WAV
// header). We look the pointer up in g_imaBlobs to recover the format.
static AVAudioPCMBuffer *makePCMBufferFromIma(const void *data,
                                              const ImaDecodedBlob &info,
                                              size_t byteSize) {
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:(double)info.rate
                                                            channels:(AVAudioChannelCount)info.channels
                                                         interleaved:NO];
    if (!fmt) return nil;
    AVAudioFrameCount frames = (AVAudioFrameCount)(byteSize / (info.channels * 2));
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    if (!buf) return nil;
    buf.frameLength = frames;
    const int16_t *src = (const int16_t *)data;
    float *const *channels = buf.floatChannelData;
    const float kInv = 1.0f / 32768.0f;
    if (info.channels == 1) {
        for (AVAudioFrameCount i = 0; i < frames; ++i) channels[0][i] = src[i] * kInv;
    } else {
        for (AVAudioFrameCount i = 0; i < frames; ++i) {
            channels[0][i] = src[i*2]   * kInv;
            channels[1][i] = src[i*2+1] * kInv;
        }
    }
    return buf;
}

// PCM bytes → AVAudioPCMBuffer (mono or stereo, 16-bit signed).
static AVAudioPCMBuffer *makePCMBuffer16(const WavInfo &wav) {
    if (wav.format != WAVE_FORMAT_PCM || wav.bits != 16 || wav.channels < 1 || wav.channels > 2) {
        MLOG(1, "makePCMBuffer16: unsupported (fmt=%d bits=%d ch=%d)",
             wav.format, wav.bits, wav.channels);
        return nil;
    }
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:(double)wav.rate
                                                            channels:(AVAudioChannelCount)wav.channels
                                                         interleaved:NO];
    if (!fmt) return nil;
    AVAudioFrameCount frames = wav.dataLen / (wav.channels * 2);
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    if (!buf) return nil;
    buf.frameLength = frames;
    const int16_t *src = (const int16_t *)wav.dataPtr;
    float *const *channels = buf.floatChannelData;
    const float kInv = 1.0f / 32768.0f;
    if (wav.channels == 1) {
        for (AVAudioFrameCount i = 0; i < frames; ++i) channels[0][i] = src[i] * kInv;
    } else {
        for (AVAudioFrameCount i = 0; i < frames; ++i) {
            channels[0][i] = src[i*2]   * kInv;
            channels[1][i] = src[i*2+1] * kInv;
        }
    }
    return buf;
}

// ----------------------------------------------------------------------------
// In-memory AudioFile callbacks — for MP3 / non-WAV streams. We feed the
// stream contents to AudioToolbox in a single shot once the engine's file
// callbacks have produced the buffer.
// ----------------------------------------------------------------------------

struct MemFile {
    const uint8_t *data;
    int64_t size;
    int64_t pos;
};

static OSStatus memRead(void *inClientData, SInt64 inPos, UInt32 reqCount,
                        void *buffer, UInt32 *actualCount) {
    MemFile *m = (MemFile *)inClientData;
    if (inPos >= m->size) { *actualCount = 0; return noErr; }
    int64_t avail = m->size - inPos;
    UInt32 n = (UInt32)((int64_t)reqCount < avail ? reqCount : avail);
    memcpy(buffer, m->data + inPos, n);
    *actualCount = n;
    return noErr;
}
static SInt64 memSize(void *inClientData) {
    return ((MemFile *)inClientData)->size;
}

// Try to fully decode an in-memory audio file (MP3/WAV/etc.) into a Float32
// AVAudioPCMBuffer at the engine's output sample rate. Returns nil on failure.
static AVAudioPCMBuffer *decodeFullyToPCM(const void *data, size_t size,
                                          AVAudioFormat **outFormat) {
    MemFile mf{ (const uint8_t *)data, (int64_t)size, 0 };
    AudioFileID afid = nullptr;
    OSStatus err = AudioFileOpenWithCallbacks(&mf, memRead, /*write*/nullptr,
                                              memSize, /*setSize*/nullptr,
                                              /*hint*/0, &afid);
    if (err != noErr || !afid) {
        MLOG(1, "decodeFullyToPCM: AudioFileOpenWithCallbacks err=%d", (int)err);
        return nil;
    }
    ExtAudioFileRef ext = nullptr;
    err = ExtAudioFileWrapAudioFileID(afid, /*forWriting*/false, &ext);
    if (err != noErr) {
        AudioFileClose(afid);
        MLOG(1, "decodeFullyToPCM: ExtAudioFileWrap err=%d", (int)err);
        return nil;
    }
    // Source format
    AudioStreamBasicDescription srcAsbd{};
    UInt32 propSize = sizeof(srcAsbd);
    ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propSize, &srcAsbd);
    SInt64 fileFrames = 0;
    propSize = sizeof(fileFrames);
    ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &propSize, &fileFrames);
    // Destination: Float32 deinterleaved, source channel count, source rate.
    UInt32 channels = srcAsbd.mChannelsPerFrame ? srcAsbd.mChannelsPerFrame : 1;
    double rate = srcAsbd.mSampleRate > 0 ? srcAsbd.mSampleRate : g_device.outputSampleRate;
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:rate
                                                            channels:channels
                                                         interleaved:NO];
    if (!fmt) {
        ExtAudioFileDispose(ext); AudioFileClose(afid);
        return nil;
    }
    AudioStreamBasicDescription dstAsbd = *fmt.streamDescription;
    err = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, sizeof(dstAsbd), &dstAsbd);
    if (err != noErr) {
        ExtAudioFileDispose(ext); AudioFileClose(afid);
        MLOG(1, "decodeFullyToPCM: SetProperty err=%d", (int)err);
        return nil;
    }
    AVAudioFrameCount estimated = (AVAudioFrameCount)(fileFrames * (rate / (srcAsbd.mSampleRate > 0 ? srcAsbd.mSampleRate : rate))) + 1024;
    if (estimated == 0) estimated = 1024;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:estimated];
    if (!buf) {
        ExtAudioFileDispose(ext); AudioFileClose(afid);
        return nil;
    }
    AVAudioFrameCount totalRead = 0;
    while (totalRead < estimated) {
        UInt32 want = estimated - totalRead;
        AudioBufferList abl;
        abl.mNumberBuffers = channels;
        // We need a proper variable-size AudioBufferList. Allocate stack-style.
        UInt32 ablSize = sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer);
        AudioBufferList *ablBig = (AudioBufferList *)alloca(ablSize);
        ablBig->mNumberBuffers = channels;
        for (UInt32 c = 0; c < channels; ++c) {
            ablBig->mBuffers[c].mNumberChannels = 1;
            ablBig->mBuffers[c].mDataByteSize = want * sizeof(float);
            ablBig->mBuffers[c].mData = buf.floatChannelData[c] + totalRead;
        }
        UInt32 numFrames = want;
        err = ExtAudioFileRead(ext, &numFrames, ablBig);
        if (err != noErr) {
            MLOG(1, "decodeFullyToPCM: Read err=%d (read %u/%u)", (int)err, totalRead, estimated);
            break;
        }
        if (numFrames == 0) break;
        totalRead += numFrames;
    }
    buf.frameLength = totalRead;
    ExtAudioFileDispose(ext); AudioFileClose(afid);
    if (outFormat) *outFormat = fmt;
    // Peek a handful of samples so we can tell decoded-silence from a routing issue.
    float peakL = 0, peakR = 0;
    if (totalRead > 0) {
        AVAudioFrameCount peek = totalRead < 8192 ? totalRead : 8192;
        for (AVAudioFrameCount i = 0; i < peek; ++i) {
            float v = fabsf(buf.floatChannelData[0][i]);
            if (v > peakL) peakL = v;
            if (channels > 1) {
                float r = fabsf(buf.floatChannelData[1][i]);
                if (r > peakR) peakR = r;
            }
        }
    }
    MLOG(2, "decodeFullyToPCM: %u frames @ %.0f Hz, %u ch, peakL=%.3f peakR=%.3f",
         totalRead, rate, channels, peakL, peakR);
    return buf;
}

// ----------------------------------------------------------------------------
// Engine bring-up / tear-down. Connections share one format derived from the
// hardware output node so the mixer chain stays sample-rate-consistent.
// ----------------------------------------------------------------------------

static bool ensureEngineRunning() {
    if (getenv("MILES_APPLE_NOENGINE")) return false;
    if (g_device.started) return true;
    if (!g_device.engine) {
        g_device.engine = [[AVAudioEngine alloc] init];

        // Ordering hygiene: touch outputNode (realizes the output AudioUnit +
        // HAL device graph) BEFORE the main mixer attaches. This is the correct
        // attach order, but NOTE it does NOT by itself prevent the
        // EXC_ARM_DA_ALIGN crash seen with CWC active in
        // ListenerMap::forEachBindingForEvent during
        // -[AVAudioMixerNode didAttachToEngine:] — that fault is a misaligned
        // pointer walk inside CoreAudio's AU parameter-listener map, i.e.
        // pre-existing heap corruption surfacing here at the first audio call
        // (AIL_quick_startup), before we decode any sample. Tracked separately;
        // MILES_APPLE_NOENGINE=1 is the current stable-silent workaround.
        AVAudioFormat *outFmt = [g_device.engine.outputNode outputFormatForBus:0];
        g_device.outputSampleRate = outFmt.sampleRate;

        g_device.mixer2D = g_device.engine.mainMixerNode;
        g_device.environment = [[AVAudioEnvironmentNode alloc] init];
        [g_device.engine attachNode:g_device.environment];
        // Force main mixer volume to 1.0 explicitly so we never start muted.
        g_device.mixer2D.outputVolume = 1.0f;
        MLOG(2, "outputNode bus0 format: rate=%.0f ch=%u", outFmt.sampleRate, outFmt.channelCount);

        // Explicitly connect mainMixer → outputNode at the device's native
        // format. Without this, attaching/connecting other nodes before
        // mainMixer's lazy hookup leaves mainMixer at its default 44.1 kHz
        // while outputNode wants 48 kHz — the rate mismatch silently zeroes
        // the output. Disconnect-then-connect forces the desired format.
        [g_device.engine disconnectNodeOutput:g_device.mixer2D];
        [g_device.engine connect:g_device.mixer2D
                              to:g_device.engine.outputNode
                          format:outFmt];

        // Connect 3D environment → main mixer at the same rate.
        AVAudioFormat *envOutFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:g_device.outputSampleRate
                                                                                  channels:2];
        [g_device.engine connect:g_device.environment to:g_device.mixer2D format:envOutFmt];

        AVAudioFormat *mixerIn = [g_device.mixer2D inputFormatForBus:0];
        AVAudioFormat *mixerOut = [g_device.mixer2D outputFormatForBus:0];
        MLOG(2, "mainMixer (post-fix) input: rate=%.0f ch=%u, output: rate=%.0f ch=%u",
             mixerIn.sampleRate, mixerIn.channelCount,
             mixerOut.sampleRate, mixerOut.channelCount);
    }
    NSError *err = nil;
    g_device.started = [g_device.engine startAndReturnError:&err];
    if (!g_device.started) {
        MLOG(0, "AVAudioEngine startAndReturnError failed: %s",
             err.localizedDescription.UTF8String ?: "?");
    } else {
        MLOG(2, "AVAudioEngine started @ %.0f Hz, mainMixer.outputVolume=%.2f",
             g_device.outputSampleRate, g_device.mixer2D.outputVolume);
    }
    return g_device.started;
}

// ----------------------------------------------------------------------------
// Helpers for scheduling and stopping nodes uniformly.
// ----------------------------------------------------------------------------

static void attachAndConnect2D(AVAudioPlayerNode *node) {
    [g_device.engine attachNode:node];
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:g_device.outputSampleRate
                                                                        channels:2];
    [g_device.engine connect:node to:g_device.mixer2D format:fmt];
}

static void attachAndConnect3D(AVAudioPlayerNode *node) {
    [g_device.engine attachNode:node];
    // EnvironmentNode requires mono input for spatialization. Buffer schedule
    // tags the inputs as mono so this format is the right one.
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:g_device.outputSampleRate
                                                                        channels:1];
    [g_device.engine connect:node to:g_device.environment format:fmt];
}

// Mid-play seek helper: copy frames [startFrame .. end) from `src` into a new
// PCM buffer. Returns nil if startFrame is at/past the end or allocation fails.
// Used by AIL_set_sample_ms_position / AIL_set_3D_sample_offset /
// AIL_set_stream_ms_position to reschedule the player from a non-zero offset
// (AVAudioPlayerNode only takes whole-buffer schedules — there is no built-in
// "play from frame N" so we slice).
static AVAudioPCMBuffer *sliceBufferFromFrame(AVAudioPCMBuffer *src,
                                              AVAudioFrameCount startFrame) {
    if (!src) return nil;
    AVAudioFrameCount total = src.frameLength;
    if (startFrame == 0 || startFrame >= total) return nil;
    AVAudioFrameCount remaining = total - startFrame;
    AVAudioPCMBuffer *sub = [[AVAudioPCMBuffer alloc] initWithPCMFormat:src.format
                                                          frameCapacity:remaining];
    if (!sub) return nil;
    sub.frameLength = remaining;
    const float *const *srcCh = src.floatChannelData;
    float *const *dstCh = sub.floatChannelData;
    AVAudioChannelCount nc = src.format.channelCount;
    for (AVAudioChannelCount c = 0; c < nc; ++c) {
        memcpy(dstCh[c], srcCh[c] + startFrame, remaining * sizeof(float));
    }
    return sub;
}

// `owner` is the registered handle pointer (AppleSample* / AppleStream* /
// Apple3DSample*) tagged onto the queued callback for liveness check; pass
// the exact pointer that markAlive/markDead see at alloc/release time.
static void scheduleAndPlay(ApplePlayerBase *p, void *owner, dispatch_block_t onCompleted) {
    if (!p || !p->node || !p->buffer) return;
    p->node.volume = g_muted ? 0.0f : p->volume;
    int gen = p->generation.load();
    @try {
        [p->node scheduleBuffer:p->buffer
                         atTime:nil
                        options:0
              completionHandler:^{
            enqueueCallback(owner, ^{
                if (onCompleted) onCompleted();
            });
            (void)gen;
        }];
        [p->node play];
        p->playing.store(true);
        MLOG(2, "scheduleAndPlay: node=%p vol=%.2f pan=%.2f isPlaying=%d engineRunning=%d",
             (__bridge void*)p->node, p->node.volume, p->node.pan,
             (int)p->node.isPlaying, (int)g_device.engine.isRunning);
    } @catch (NSException *ex) {
        // Diagnose disconnection: dump engine state + node's attached-ness.
        BOOL attached = [g_device.engine.attachedNodes containsObject:p->node];
        NSArray<AVAudioConnectionPoint*> *outs =
            [g_device.engine outputConnectionPointsForNode:p->node outputBus:0];
        MLOG(0, "scheduleAndPlay NSException: %s — %s [attached=%d outputs=%lu]",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?",
             (int)attached, (unsigned long)outs.count);
        p->playing.store(false);
    }
}

static void stopAndDetach(ApplePlayerBase *p) {
    if (!p) return;
    p->generation.fetch_add(1);
    if (p->node) {
        @try {
            [p->node stop];
        } @catch (NSException *ex) {
            MLOG(1, "stopAndDetach stop NSException: %s", ex.reason.UTF8String ?: "?");
        }
        // NOTE: deliberately not calling `-reset`. On macOS Sequoia (and
        // possibly earlier) `-reset` puts the node into an internal
        // "disconnected" state — any subsequent `-play` then throws
        // `com.apple.coreaudio.avfaudio — player started when in a
        // disconnected state`. `-stop` alone is sufficient to halt
        // playback; the next `scheduleBuffer:` clears the pending queue.
    }
    p->playing.store(false);
}

// ============================================================================
// Public AIL_* surface starts here. Order roughly follows mss/mss.h.
// ============================================================================

extern "C" {

// ----- Lifecycle -----------------------------------------------------------

char *AIL_set_redist_directory(const char *) {
    // Windows MSS uses this to locate redist DLLs (mss32.dll friends). N/A on macOS.
    return nullptr;
}

int AIL_startup(void) {
    milesLogLevel();
    MLOG(2, "AIL_startup");
    return 0;  // 0 == success in Miles
}

void AIL_shutdown(void) {
    MLOG(2, "AIL_shutdown");
    if (g_device.engine) {
        [g_device.engine stop];
    }
    g_device.started = false;
}

int AIL_set_preference(unsigned int, int) { return AIL_NO_ERROR; }

int AIL_quick_startup(int /*useDigital*/, int /*useMIDI*/,
                      unsigned int /*rate*/, int /*bits*/, int /*channels*/) {
    MLOG(2, "AIL_quick_startup");
    if (!ensureEngineRunning()) return 0;
    if (!g_publicDriver) {
        g_publicDriver = makePublicDriver();
        g_driver.publicDriver = g_publicDriver;
        g_driver.open = true;
    }
    initProviders();
    return 1;  // non-zero == success
}

void AIL_quick_handles(HDIGDRIVER *pdig, HMDIDRIVER *pmdi, HDLSDEVICE *pdls) {
    if (pdig) *pdig = g_publicDriver;
    if (pmdi) *pmdi = nullptr;
    if (pdls) *pdls = nullptr;
}

void AIL_quick_unload(HAUDIO) {}
HAUDIO AIL_quick_load_and_play(const char *, unsigned int, int) { return nullptr; }
void AIL_quick_set_volume(HAUDIO, float, float) {}

int AIL_waveOutOpen(HDIGDRIVER *driver, LPHWAVEOUT *waveout, int /*id*/, LPWAVEFORMAT /*format*/) {
    MLOG(2, "AIL_waveOutOpen");
    if (!ensureEngineRunning()) return -1;
    if (!g_publicDriver) g_publicDriver = makePublicDriver();
    if (driver)  *driver  = g_publicDriver;
    if (waveout) *waveout = nullptr;
    return AIL_NO_ERROR;
}

void AIL_waveOutClose(HDIGDRIVER) { MLOG(2, "AIL_waveOutClose"); }

void AIL_lock(void)   {}
void AIL_unlock(void) {}

char *AIL_last_error(void) {
    static char emptyError[] = "";
    return emptyError;
}

// ----- File callbacks ------------------------------------------------------

void AIL_set_file_callbacks(AIL_file_open_callback opencb,
                            AIL_file_close_callback closecb,
                            AIL_file_seek_callback seekcb,
                            AIL_file_read_callback readcb) {
    g_openCb = opencb;
    g_closeCb = closecb;
    g_seekCb = seekcb;
    g_readCb = readcb;
    MLOG(2, "AIL_set_file_callbacks installed");
}

// ----- Provider enumeration / 3D listener ---------------------------------

int AIL_enumerate_3D_providers(HPROENUM *next, HPROVIDER *dest, char **name) {
    drainCallbacks();
    initProviders();
    unsigned int idx = next ? *next : 0;
    if (idx >= g_providers.size()) {
        if (dest) *dest = nullptr;
        if (name) *name = nullptr;
        return 0;
    }
    if (dest) *dest = (HPROVIDER)g_providers[idx];
    if (name) *name = const_cast<char*>(g_providers[idx]->name.c_str());
    if (next) *next = idx + 1;
    return 1;
}

int AIL_enumerate_filters(HPROENUM *, HPROVIDER *, char **) {
    return 0;  // No delay filter exposed — engine just skips initDelayFilter.
}

M3DRESULT AIL_open_3D_provider(HPROVIDER lib) {
    if (!lib) return 1;
    AppleProvider *p = (AppleProvider *)lib;
    p->isOpen = true;
    MLOG(2, "AIL_open_3D_provider: %s", p->name.c_str());
    return M3D_NOERR;
}

void AIL_close_3D_provider(HPROVIDER lib) {
    if (!lib) return;
    ((AppleProvider *)lib)->isOpen = false;
}

void AIL_set_3D_speaker_type(HPROVIDER lib, int t) {
    if (lib) ((AppleProvider *)lib)->speakerType = t;
}

H3DPOBJECT AIL_open_3D_listener(HPROVIDER lib) {
    Apple3DListener *l = new Apple3DListener();
    l->provider = (AppleProvider *)lib;
    return l;
}

void AIL_close_3D_listener(H3DPOBJECT listener) {
    if (listener) delete (Apple3DListener *)listener;
}

void AIL_get_DirectSound_info(HSAMPLE, AILLPDIRECTSOUND *lplpDS, AILLPDIRECTSOUNDBUFFER *lplpDSB) {
    // No DirectSound on macOS — engine takes the speaker-type-from-defaults path.
    if (lplpDS)  *lplpDS  = nullptr;
    if (lplpDSB) *lplpDSB = nullptr;
}

// ----- 2D samples ----------------------------------------------------------

HSAMPLE AIL_allocate_sample_handle(HDIGDRIVER dig) {
    drainCallbacks();
    if (getenv("MILES_APPLE_NOPOOL")) return nullptr;
    if (!ensureEngineRunning()) return nullptr;
    // Lazy node allocation — Miles pre-allocates pools of 4×2D + 32×3D voices
    // up front; attaching all 36 AVAudioPlayerNodes to AVAudioEngine at boot
    // trips an internal limit and aborts the process. We create the node when
    // a file is actually bound (AIL_set_sample_file).
    AppleSample *s = new AppleSample();
    s->owner = dig;
    markAlive(s);
    MLOG(2, "AIL_allocate_sample_handle -> %p (lazy node)", s);
    return (HSAMPLE)s;
}

void AIL_release_sample_handle(HSAMPLE sample) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    stopAndDetach(s);
    @try {
        if (s->node) [g_device.engine detachNode:s->node];
    } @catch (NSException *ex) {
        MLOG(1, "release_sample_handle detach NSException: %s", ex.reason.UTF8String ?: "?");
    }
    s->node = nil; s->buffer = nil; s->bufferFormat = nil;
    // Remove from live-handle set BEFORE delete; drainCallbacks consults this
    // to drop blocks queued for `s` (UAF guard — see PendingCallback docs).
    markDead(s);
    delete s;
}

void AIL_init_sample(HSAMPLE sample) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    stopAndDetach(s);
    s->volume = 1.0f; s->pan = 0.5f; s->loopCount = 1;
    s->buffer = nil; s->bufferFormat = nil;
}

int AIL_set_sample_file(HSAMPLE sample, const void *file_image, int /*block*/) {
    drainCallbacks();
    if (!sample || !file_image) return 0;
    MLOG(2, "AIL_set_sample_file(%p)", sample);
    AppleSample *s = (AppleSample *)sample;
    stopAndDetach(s);
    AVAudioPCMBuffer *buf = nil;
    // IMA-ADPCM round-trip: AudioFileCache calls our AIL_decompress_ADPCM,
    // then passes the raw PCM pointer here. No WAV header to parse.
    {
        std::lock_guard<std::mutex> lk(g_imaLock);
        auto it = g_imaBlobs.find((void*)file_image);
        if (it != g_imaBlobs.end()) {
            buf = makePCMBufferFromIma(file_image, it->second, it->second.size);
        }
    }
    if (!buf) {
        WavInfo wav;
        if (parseWav(file_image, 0, &wav) && wav.format == WAVE_FORMAT_PCM) {
            buf = makePCMBuffer16(wav);
        }
        if (!buf) {
            size_t guessed = wav.dataLen ? (wav.dataLen + (size_t)((const unsigned char*)wav.dataPtr - (const unsigned char*)file_image)) : 0;
            if (!guessed) guessed = 1 << 20;
            AVAudioFormat *fmt = nil;
            buf = decodeFullyToPCM(file_image, guessed, &fmt);
            s->bufferFormat = fmt;
        }
    }
    if (!buf) {
        MLOG(1, "AIL_set_sample_file: failed to decode");
        return 0;
    }
    s->buffer = buf;
    // Replace the player node on every file bind. Reusing the same
    // AVAudioPlayerNode across multiple `play → completion → re-schedule`
    // cycles puts it into a permanent "disconnected" internal state on
    // macOS Sequoia — every subsequent `-play` then throws
    // `player started when in a disconnected state` and the sound is
    // silently lost. Detaching the old node and attaching a fresh one is
    // expensive (~µs per voice) but reliable, and Miles only re-binds when
    // an event is starting, never inside the audio thread.
    @try {
        if (s->node) {
            [g_device.engine detachNode:s->node];
            s->node = nil;
        }
        s->node = [[AVAudioPlayerNode alloc] init];
        [g_device.engine attachNode:s->node];
        [g_device.engine connect:s->node to:g_device.mixer2D format:buf.format];
    } @catch (NSException *ex) {
        MLOG(0, "set_sample_file attach NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        s->node = nil;
        s->buffer = nil;
        return 0;
    }
    return 1;
}

int AIL_set_named_sample_file(HSAMPLE sample, const char * /*name*/,
                              const void *file_image, int /*size*/, int block) {
    return AIL_set_sample_file(sample, file_image, block);
}

void AIL_start_sample(HSAMPLE sample) {
    drainCallbacks();
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    if (!s->buffer) return;
    MLOG(2, "AIL_start_sample(%p, %u frames, vol=%.2f)", sample, s->buffer.frameLength, s->volume);
    s->loopsRemaining = s->loopCount;
    AppleSample *captured = s;
    int gen = s->generation.load();
    scheduleAndPlay(s, s, ^{
        if (captured->generation.load() != gen) return; // stale
        if (captured->loopCount == 0 || --captured->loopsRemaining > 0) {
            int gen2 = captured->generation.load();
            AppleSample *self = captured;
            @try {
                [self->node scheduleBuffer:self->buffer atTime:nil options:0
                         completionHandler:^{
                    enqueueCallback(self, ^{
                        if (self->generation.load() == gen2 && self->eosCallback) {
                            self->eosCallback((HSAMPLE)self);
                        }
                    });
                }];
            } @catch (NSException *ex) {
                MLOG(1, "sample loop reschedule NSException: %s", ex.reason.UTF8String ?: "?");
                if (self->eosCallback) self->eosCallback((HSAMPLE)self);
            }
            return;
        }
        captured->playing.store(false);
        if (captured->eosCallback) captured->eosCallback((HSAMPLE)captured);
    });
}

void AIL_stop_sample(HSAMPLE sample) {
    if (!sample) return;
    stopAndDetach((AppleSample *)sample);
}
void AIL_end_sample(HSAMPLE sample) { AIL_stop_sample(sample); }
void AIL_resume_sample(HSAMPLE sample) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    if (s->node) [s->node play];
}

void AIL_set_sample_volume(HSAMPLE sample, int volume) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    s->volume = volume / 127.0f;
    if (s->node) s->node.volume = g_muted ? 0.0f : s->volume;
}
int AIL_sample_volume(HSAMPLE sample) {
    if (!sample) return 0;
    return (int)(((AppleSample *)sample)->volume * 127.0f);
}
void AIL_set_sample_pan(HSAMPLE sample, int pan) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    s->pan = pan / 127.0f;
    if (s->node) s->node.pan = (s->pan - 0.5f) * 2.0f;  // -1..1
}
int AIL_sample_pan(HSAMPLE sample) {
    if (!sample) return 0;
    return (int)(((AppleSample *)sample)->pan * 127.0f);
}
void AIL_set_sample_volume_pan(HSAMPLE sample, float volume, float pan) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    s->volume = volume; s->pan = pan;
    if (s->node) {
        s->node.volume = g_muted ? 0.0f : volume;
        s->node.pan = (pan - 0.5f) * 2.0f;
    }
}
void AIL_sample_volume_pan(HSAMPLE sample, float *volume, float *pan) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    if (volume) *volume = s->volume;
    if (pan)    *pan    = s->pan;
}

void AIL_set_sample_loop_count(HSAMPLE sample, int count) {
    if (sample) ((AppleSample *)sample)->loopCount = count;
}
int  AIL_sample_loop_count(HSAMPLE sample) {
    return sample ? ((AppleSample *)sample)->loopCount : 0;
}
void AIL_set_sample_playback_rate(HSAMPLE, int) {}
int  AIL_sample_playback_rate(HSAMPLE) { return 0; }
void AIL_set_sample_ms_position(HSAMPLE sample, int ms) {
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    if (!s->buffer || !s->node) return;
    double sr = s->buffer.format.sampleRate;
    if (sr <= 0) return;
    if (ms < 0) ms = 0;
    AVAudioFrameCount startFrame = (AVAudioFrameCount)((double)ms * sr / 1000.0);
    if (startFrame >= s->buffer.frameLength) {
        MLOG(2, "AIL_set_sample_ms_position(%p, ms=%d) past end (%u/%u) — ignored",
             sample, ms, (unsigned)startFrame, (unsigned)s->buffer.frameLength);
        return;
    }
    // Seek-before-play: the engine's typical path is bind → start → seek, but
    // AudibleSoundClass::Seek can also fire before start. We only physically
    // seek when currently playing; for the paused case the engine tracks its
    // own playhead via m_Timestamp, so a silent no-op is invisible to typical
    // SFX/voice flows. (Cutscene-level frame-accurate sync would need a
    // queued-seekFrame field; not worth it until something visibly desyncs.)
    if (!s->playing.load()) {
        if (startFrame > 0) {
            MLOG(2, "AIL_set_sample_ms_position(%p, ms=%d) — not playing, deferred no-op",
                 sample, ms);
        }
        return;
    }
    AVAudioPCMBuffer *slice = sliceBufferFromFrame(s->buffer, startFrame);
    if (!slice) return;
    @try { [s->node stop]; } @catch (NSException *ex) {
        MLOG(1, "set_sample_ms_position stop NSException: %s", ex.reason.UTF8String ?: "?");
    }
    s->generation.fetch_add(1);
    s->playing.store(false);
    int gen = s->generation.load();
    AppleSample *captured = s;
    @try {
        // Schedule the slice; on completion, if loops remain, schedule the
        // FULL buffer (subsequent loops always start at frame 0 — only the
        // seeked playback consumes the slice).
        [s->node scheduleBuffer:slice atTime:nil options:0
              completionHandler:^{
            enqueueCallback(captured, ^{
                if (captured->generation.load() != gen) return;
                if (captured->loopCount == 0 || --captured->loopsRemaining > 0) {
                    int gen2 = captured->generation.load();
                    @try {
                        [captured->node scheduleBuffer:captured->buffer atTime:nil options:0
                                     completionHandler:^{
                            enqueueCallback(captured, ^{
                                if (captured->generation.load() == gen2 && captured->eosCallback) {
                                    captured->eosCallback((HSAMPLE)captured);
                                }
                            });
                        }];
                    } @catch (NSException *ex) {
                        MLOG(1, "set_sample_ms_position loop reschedule NSException: %s",
                             ex.reason.UTF8String ?: "?");
                        if (captured->eosCallback) captured->eosCallback((HSAMPLE)captured);
                    }
                    return;
                }
                captured->playing.store(false);
                if (captured->eosCallback) captured->eosCallback((HSAMPLE)captured);
            });
        }];
        [s->node play];
        s->playing.store(true);
        MLOG(2, "AIL_set_sample_ms_position(%p, ms=%d, frame=%u/%u) seeked",
             sample, ms, (unsigned)startFrame, (unsigned)s->buffer.frameLength);
    } @catch (NSException *ex) {
        MLOG(0, "AIL_set_sample_ms_position schedule NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        s->playing.store(false);
    }
}
void AIL_sample_ms_position(HSAMPLE sample, long *total_ms, long *current_ms) {
    if (total_ms)   *total_ms = 0;
    if (current_ms) *current_ms = 0;
    if (!sample) return;
    AppleSample *s = (AppleSample *)sample;
    if (s->buffer && s->buffer.format.sampleRate > 0) {
        if (total_ms) *total_ms = (long)(1000.0 * s->buffer.frameLength / s->buffer.format.sampleRate);
    }
}

void AIL_set_sample_user_data(HSAMPLE sample, unsigned int index, void *value) {
    if (!sample || index >= kUserDataSlots) return;
    ((AppleSample *)sample)->userData[index] = value;
}
void *AIL_sample_user_data(HSAMPLE sample, unsigned int index) {
    if (!sample || index >= kUserDataSlots) return nullptr;
    return ((AppleSample *)sample)->userData[index];
}

AIL_sample_callback AIL_register_EOS_callback(HSAMPLE sample, AIL_sample_callback eos) {
    if (!sample) return nullptr;
    AppleSample *s = (AppleSample *)sample;
    AIL_sample_callback prev = s->eosCallback;
    s->eosCallback = eos;
    return prev;
}

HPROVIDER AIL_set_sample_processor(HSAMPLE, SAMPLESTAGE, HPROVIDER) { return nullptr; }
void AIL_set_filter_sample_preference(HSAMPLE, const char *, const void *) {}

// ----- 3D samples ----------------------------------------------------------

H3DSAMPLE AIL_allocate_3D_sample_handle(HPROVIDER lib) {
    drainCallbacks();
    if (getenv("MILES_APPLE_NOPOOL")) return nullptr;
    if (!ensureEngineRunning()) return nullptr;
    Apple3DSample *s = new Apple3DSample();
    s->provider = (AppleProvider *)lib;
    markAlive(s);
    MLOG(2, "AIL_allocate_3D_sample_handle -> %p (lazy node)", s);
    return (H3DSAMPLE)s;
}

void AIL_release_3D_sample_handle(H3DSAMPLE sample) {
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    stopAndDetach(&s->player);
    @try {
        if (s->player.node) [g_device.engine detachNode:s->player.node];
    } @catch (NSException *ex) {
        MLOG(1, "release_3D_sample_handle detach NSException: %s", ex.reason.UTF8String ?: "?");
    }
    markDead(s);
    delete s;
}

int AIL_set_3D_sample_file(H3DSAMPLE sample, const void *file_image) {
    drainCallbacks();
    if (!sample || !file_image) return 0;
    Apple3DSample *s = (Apple3DSample *)sample;
    stopAndDetach(&s->player);
    AVAudioPCMBuffer *buf = nil;
    {
        std::lock_guard<std::mutex> lk(g_imaLock);
        auto it = g_imaBlobs.find((void*)file_image);
        if (it != g_imaBlobs.end()) {
            buf = makePCMBufferFromIma(file_image, it->second, it->second.size);
        }
    }
    if (!buf) {
        WavInfo wav;
        if (parseWav(file_image, 0, &wav) && wav.format == WAVE_FORMAT_PCM) {
            buf = makePCMBuffer16(wav);
        }
        if (!buf) {
            size_t guessed = wav.dataLen ? (wav.dataLen + 1024) : (1 << 20);
            AVAudioFormat *fmt = nil;
            buf = decodeFullyToPCM(file_image, guessed, &fmt);
            s->player.bufferFormat = fmt;
        }
    }
    if (!buf) {
        MLOG(1, "AIL_set_3D_sample_file: decode failed");
        return 0;
    }
    if (buf.format.channelCount > 1) {
        MLOG(1, "AIL_set_3D_sample_file: stereo 3D source — downmix to mono");
        AVAudioFormat *monoFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:buf.format.sampleRate
                                                                                channels:1];
        AVAudioPCMBuffer *mono = [[AVAudioPCMBuffer alloc] initWithPCMFormat:monoFmt frameCapacity:buf.frameLength];
        mono.frameLength = buf.frameLength;
        const float *L = buf.floatChannelData[0];
        const float *R = buf.floatChannelData[1];
        float *out = mono.floatChannelData[0];
        for (AVAudioFrameCount i = 0; i < buf.frameLength; ++i) out[i] = 0.5f * (L[i] + R[i]);
        buf = mono;
    }
    s->player.buffer = buf;
    @try {
        if (s->player.node) {
            [g_device.engine detachNode:s->player.node];
            s->player.node = nil;
        }
        s->player.node = [[AVAudioPlayerNode alloc] init];
        [g_device.engine attachNode:s->player.node];
        // 3D path: player → mainMixer with manual pan + distance-volume
        // applied at start time based on the listener pose. AVAudioEnvironmentNode
        // would do this internally but empirically throws "player started
        // when in a disconnected state" on M-series even with a fresh node
        // (regardless of rendering algorithm), so we hand-roll the spatial
        // math. For an RTS top-down camera this is plenty: stereo pan from
        // X delta + inverse-distance volume.
        [g_device.engine connect:s->player.node to:g_device.mixer2D format:buf.format];
    } @catch (NSException *ex) {
        MLOG(0, "set_3D_sample_file attach NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        s->player.node = nil;
        s->player.buffer = nil;
        return 0;
    }
    return 1;
}

void AIL_start_3D_sample(H3DSAMPLE sample) {
    drainCallbacks();
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    if (!s->player.buffer) return;
    // Apply pan + distance-volume based on current source/listener positions.
    apply3DPanAndVolumeForSource(s);
    s->player.loopsRemaining = s->player.loopCount;
    Apple3DSample *captured = s;
    int gen = s->player.generation.load();
    scheduleAndPlay(&s->player, s, ^{
        if (captured->player.generation.load() != gen) return;
        captured->player.playing.store(false);
        if (captured->eosCallback) captured->eosCallback((H3DSAMPLE)captured);
    });
}
void AIL_stop_3D_sample(H3DSAMPLE sample) {
    if (sample) stopAndDetach(&((Apple3DSample *)sample)->player);
}
void AIL_end_3D_sample(H3DSAMPLE sample) { AIL_stop_3D_sample(sample); }
void AIL_resume_3D_sample(H3DSAMPLE sample) {
    if (sample) [((Apple3DSample *)sample)->player.node play];
}

#ifdef MILES_NOFLOAT
int AIL_3D_sample_volume(H3DSAMPLE sample) {
    return sample ? (int)(((Apple3DSample *)sample)->player.volume * 127.0f) : 0;
}
void AIL_set_3D_sample_volume(H3DSAMPLE sample, int v) {
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    s->player.volume = v / 127.0f;
    if (s->player.node) s->player.node.volume = g_muted ? 0.0f : s->player.volume;
}
#else
float AIL_3D_sample_volume(H3DSAMPLE sample) {
    return sample ? ((Apple3DSample *)sample)->player.volume : 0.0f;
}
void AIL_set_3D_sample_volume(H3DSAMPLE sample, float v) {
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    s->player.volume = v;
    if (s->player.node) s->player.node.volume = g_muted ? 0.0f : v;
}
#endif

unsigned int AIL_3D_sample_loop_count(H3DSAMPLE sample) {
    return sample ? ((Apple3DSample *)sample)->player.loopCount : 0;
}
void AIL_set_3D_sample_loop_count(H3DSAMPLE sample, unsigned int count) {
    if (sample) ((Apple3DSample *)sample)->player.loopCount = (int)count;
}
void AIL_set_3D_sample_offset(H3DSAMPLE sample, unsigned int bytes) {
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    if (!s->player.buffer || !s->player.node) return;
    // The engine calls this with `bytes = ms * rate * bits / 8 / 1000`
    // (Sound3DHandleClass::Set_Sample_MS_Position). 3D samples are mono
    // 16-bit in practice, so bytes/2 = frame index in the source PCM stream.
    // Our buffer is stored at the original sample rate (makePCMBuffer16 /
    // makePCMBufferFromIma preserve it), so this frame index maps 1:1.
    AVAudioFrameCount startFrame = bytes >> 1;
    if (startFrame >= s->player.buffer.frameLength) {
        MLOG(2, "AIL_set_3D_sample_offset(%p, bytes=%u) past end — ignored",
             sample, bytes);
        return;
    }
    if (!s->player.playing.load()) {
        if (startFrame > 0) {
            MLOG(2, "AIL_set_3D_sample_offset(%p, bytes=%u) — not playing, no-op",
                 sample, bytes);
        }
        return;
    }
    AVAudioPCMBuffer *slice = sliceBufferFromFrame(s->player.buffer, startFrame);
    if (!slice) return;
    @try { [s->player.node stop]; } @catch (NSException *ex) {
        MLOG(1, "set_3D_sample_offset stop NSException: %s", ex.reason.UTF8String ?: "?");
    }
    s->player.generation.fetch_add(1);
    s->player.playing.store(false);
    int gen = s->player.generation.load();
    Apple3DSample *captured = s;
    apply3DPanAndVolumeForSource(s);
    @try {
        // 3D voices are one-shot in practice (engine does its own loop
        // gating); skip the loop-reschedule branch the 2D path has.
        [s->player.node scheduleBuffer:slice atTime:nil options:0
                     completionHandler:^{
            enqueueCallback(captured, ^{
                if (captured->player.generation.load() != gen) return;
                captured->player.playing.store(false);
                if (captured->eosCallback) captured->eosCallback((H3DSAMPLE)captured);
            });
        }];
        [s->player.node play];
        s->player.playing.store(true);
        MLOG(2, "AIL_set_3D_sample_offset(%p, bytes=%u, frame=%u/%u) seeked",
             sample, bytes, (unsigned)startFrame, (unsigned)s->player.buffer.frameLength);
    } @catch (NSException *ex) {
        MLOG(0, "AIL_set_3D_sample_offset schedule NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        s->player.playing.store(false);
    }
}
unsigned int AIL_3D_sample_offset(H3DSAMPLE) { return 0; }
int  AIL_3D_sample_length(H3DSAMPLE) { return 0; }
int  AIL_3D_sample_playback_rate(H3DSAMPLE) { return 0; }
void AIL_set_3D_sample_playback_rate(H3DSAMPLE, int) {}
void AIL_set_3D_sample_effects_level(H3DSAMPLE, float) {}
void AIL_set_3D_sample_occlusion(H3DSAMPLE, float) {}
void AIL_set_3D_sample_distances(H3DSAMPLE sample, float maxD, float minD) {
    if (!sample) return;
    Apple3DSample *s = (Apple3DSample *)sample;
    s->minDist = minD;
    s->maxDist = maxD;
    apply3DPanAndVolumeForSource(s);
}

void AIL_set_3D_velocity_vector(H3DSAMPLE, float, float, float) {}

// Position / orientation — engine calls these for both H3DSAMPLE (source)
// AND the listener (H3DPOBJECT). Branch on type via the provider back-pointer:
// a listener has a non-null provider, a sample has a non-null player.node.
void AIL_set_3D_position(H3DPOBJECT obj, float X, float Y, float Z) {
    if (!obj) return;
    if (isListenerObj(obj)) {
        Apple3DListener *l = (Apple3DListener *)obj;
        l->position[0] = X; l->position[1] = Y; l->position[2] = Z;
        g_listenerX.store(X);
        g_listenerY.store(Y);
        g_listenerZ.store(Z);
    } else {
        Apple3DSample *s = (Apple3DSample *)obj;
        s->position[0] = X; s->position[1] = Y; s->position[2] = Z;
        // Per-frame position updates from processPlayingList — recompute
        // pan/volume each time so a moving source tracks the camera.
        apply3DPanAndVolumeForSource(s);
    }
}

void AIL_set_3D_orientation(H3DPOBJECT obj, float fx, float fy, float fz,
                            float ux, float uy, float uz) {
    if (!obj || !isListenerObj(obj)) return;
    Apple3DListener *l = (Apple3DListener *)obj;
    l->forward[0] = fx; l->forward[1] = fy; l->forward[2] = fz;
    l->up[0] = ux; l->up[1] = uy; l->up[2] = uz;
    g_listenerFwdX.store(fx); g_listenerFwdY.store(fy); g_listenerFwdZ.store(fz);
    g_listenerUpX.store(ux);  g_listenerUpY.store(uy);  g_listenerUpZ.store(uz);
}

void AIL_set_3D_user_data(H3DPOBJECT obj, unsigned int index, void *value) {
    if (!obj || index >= kUserDataSlots) return;
    if (isListenerObj(obj)) {
        ((Apple3DListener *)obj)->userData[index] = value;
    } else {
        ((Apple3DSample *)obj)->player.userData[index] = value;
    }
}
void *AIL_3D_user_data(H3DSAMPLE sample, unsigned int index) {
    if (!sample || index >= kUserDataSlots) return nullptr;
    Apple3DSample *s = (Apple3DSample *)sample;
    return s->player.userData[index];
}

AIL_3dsample_callback AIL_register_3D_EOS_callback(H3DSAMPLE sample, AIL_3dsample_callback eos) {
    if (!sample) return nullptr;
    Apple3DSample *s = (Apple3DSample *)sample;
    AIL_3dsample_callback prev = s->eosCallback;
    s->eosCallback = eos;
    return prev;
}

// ----- Streams (music + speech) -------------------------------------------

static std::vector<uint8_t> slurpStream(const char *filename) {
    if (!g_openCb || !g_readCb || !g_seekCb) {
        MLOG(0, "slurpStream: no file callbacks installed");
        return {};
    }
    void *handle = nullptr;
    if (!g_openCb(filename, &handle) || !handle) return {};
    // size via seek end
    long size = g_seekCb(handle, 0, AIL_FILE_SEEK_END);
    g_seekCb(handle, 0, AIL_FILE_SEEK_BEGIN);
    if (size <= 0) { g_closeCb(handle); return {}; }
    std::vector<uint8_t> buf((size_t)size);
    unsigned long got = g_readCb(handle, buf.data(), (unsigned long)size);
    g_closeCb(handle);
    if ((long)got != size) buf.resize(got);
    return buf;
}

static std::atomic<int> g_streamCount{0};

// Decoded-stream cache. The engine opens each music track at least twice per
// play (once for getFileLengthMS, once for actual playback) — each open
// would otherwise re-decode the full ~3-min MP3 (~67 MB float32 stereo).
// We cache the decoded PCMBuffer by filename and bound the cache to a small
// LRU so memory stays sane.
struct StreamCacheEntry {
    AVAudioPCMBuffer *buf;
    AVAudioFormat *fmt;
    int totalMs;
    uint64_t lru;
};
static std::mutex g_streamCacheLock;
static std::unordered_map<std::string, StreamCacheEntry> g_streamCache;
static std::atomic<uint64_t> g_streamCacheTick{0};
constexpr size_t kStreamCacheCap = 3;
HSTREAM AIL_open_stream(HDIGDRIVER dig, const char *filename, int /*mem*/) {
    drainCallbacks();
    if (!filename) return nullptr;
    if (getenv("MILES_APPLE_NOAUDIO")) return nullptr;
    if (!ensureEngineRunning()) return nullptr;
    MLOG(2, "AIL_open_stream(%s) [active streams=%d]", filename, g_streamCount.load());
    if (getenv("MILES_APPLE_1STREAM") && g_streamCount.load() > 0) {
        MLOG(2, "AIL_open_stream: refused (1-stream cap)");
        return nullptr;
    }

    AVAudioFormat *fmt = nil;
    AVAudioPCMBuffer *buf = nil;
    int cachedTotalMs = 0;
    bool fromCache = false;
    {
        std::lock_guard<std::mutex> lk(g_streamCacheLock);
        auto it = g_streamCache.find(filename);
        if (it != g_streamCache.end()) {
            buf = it->second.buf;
            fmt = it->second.fmt;
            cachedTotalMs = it->second.totalMs;
            it->second.lru = g_streamCacheTick.fetch_add(1);
            fromCache = true;
            MLOG(2, "AIL_open_stream(%s): cache hit", filename);
        }
    }
    if (!buf) {
        std::vector<uint8_t> data = slurpStream(filename);
        if (data.empty()) {
            MLOG(0, "AIL_open_stream(%s): file empty / not found", filename);
            return nullptr;
        }
        WavInfo wav;
        if (parseWav(data.data(), (unsigned int)data.size(), &wav) && wav.format == WAVE_FORMAT_PCM) {
            buf = makePCMBuffer16(wav);
            if (buf) fmt = buf.format;
        }
        if (!buf) {
            buf = decodeFullyToPCM(data.data(), data.size(), &fmt);
        }
        if (!buf) {
            MLOG(0, "AIL_open_stream(%s): decode failed", filename);
            return nullptr;
        }
        // Insert into cache, evict LRU if over cap.
        std::lock_guard<std::mutex> lk(g_streamCacheLock);
        if (g_streamCache.size() >= kStreamCacheCap) {
            auto victim = g_streamCache.begin();
            for (auto it = g_streamCache.begin(); it != g_streamCache.end(); ++it) {
                if (it->second.lru < victim->second.lru) victim = it;
            }
            MLOG(2, "stream cache evict: %s", victim->first.c_str());
            g_streamCache.erase(victim);
        }
        int totalMs = 0;
        if (buf.format.sampleRate > 0) {
            totalMs = (int)(1000.0 * buf.frameLength / buf.format.sampleRate);
        }
        g_streamCache[filename] = StreamCacheEntry{
            buf, fmt, totalMs, g_streamCacheTick.fetch_add(1)
        };
        cachedTotalMs = totalMs;
    }
    AppleStream *st = new AppleStream();
    st->owner = dig;
    st->buffer = buf;
    st->bufferFormat = fmt;
    st->totalMs = cachedTotalMs;
    (void)fromCache;
    @try {
        st->node = [[AVAudioPlayerNode alloc] init];
        [g_device.engine attachNode:st->node];
        [g_device.engine connect:st->node to:g_device.mixer2D format:buf.format];
    } @catch (NSException *ex) {
        MLOG(0, "open_stream attach NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        delete st;
        return nullptr;
    }
    g_streamCount.fetch_add(1);
    markAlive(st);
    return (HSTREAM)st;
}

HSTREAM AIL_open_stream_by_sample(HDIGDRIVER d, HSAMPLE, const char *fn, int m) {
    return AIL_open_stream(d, fn, m);
}

void AIL_close_stream(HSTREAM stream) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    stopAndDetach(s);
    @try {
        if (s->node) [g_device.engine detachNode:s->node];
    } @catch (NSException *ex) {
        MLOG(1, "close_stream detach NSException: %s", ex.reason.UTF8String ?: "?");
    }
    if (g_streamCount.load() > 0) g_streamCount.fetch_sub(1);
    // Drop this stream from the live-handle set BEFORE the actual delete —
    // any pending loop-continuation block enqueued from its AVAudio
    // completionHandler will be skipped on next drain. Without this guard
    // the engine's mission-end teardown (Display::stopMovie → close_stream)
    // races a still-queued block from miles_apple.mm:1541 → UAF in
    // libobjc.A.dylib`lookUpImpOrForward (observed crash on ScoreScreen
    // transition).
    markDead(s);
    delete s;
}

void AIL_start_stream(HSTREAM stream) {
    drainCallbacks();
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    if (!s->buffer) return;
    MLOG(2, "AIL_start_stream(%p, %u frames)", stream, s->buffer.frameLength);
    s->loopsRemaining = s->loopCount;
    AppleStream *captured = s;
    int gen = s->generation.load();
    scheduleAndPlay(s, s, ^{
        if (captured->generation.load() != gen) return;
        if (captured->loopCount == 0 || --captured->loopsRemaining > 0) {
            int gen2 = captured->generation.load();
            AppleStream *self = captured;
            @try {
                [self->node scheduleBuffer:self->buffer atTime:nil options:0
                         completionHandler:^{
                    enqueueCallback(self, ^{
                        if (self->generation.load() == gen2 && self->eosCallback) {
                            self->eosCallback((HSTREAM)self);
                        }
                    });
                }];
            } @catch (NSException *ex) {
                MLOG(1, "stream loop reschedule NSException: %s", ex.reason.UTF8String ?: "?");
                if (self->eosCallback) self->eosCallback((HSTREAM)self);
            }
            return;
        }
        captured->playing.store(false);
        if (captured->eosCallback) captured->eosCallback((HSTREAM)captured);
    });
}

void AIL_pause_stream(HSTREAM stream, int onoff) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    if (!s->node) return;
    if (onoff) [s->node pause]; else [s->node play];
}

void AIL_set_stream_volume(HSTREAM stream, int volume) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    s->volume = volume / 127.0f;
    if (s->node) s->node.volume = g_muted ? 0.0f : s->volume;
}
int AIL_stream_volume(HSTREAM stream) {
    return stream ? (int)(((AppleStream *)stream)->volume * 127.0f) : 0;
}
void AIL_set_stream_pan(HSTREAM stream, int pan) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    s->pan = pan / 127.0f;
    if (s->node) s->node.pan = (s->pan - 0.5f) * 2.0f;
}
int AIL_stream_pan(HSTREAM stream) {
    return stream ? (int)(((AppleStream *)stream)->pan * 127.0f) : 0;
}
void AIL_set_stream_volume_pan(HSTREAM stream, float volume, float pan) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    MLOG(2, "AIL_set_stream_volume_pan(%p, vol=%.3f, pan=%.3f)", stream, volume, pan);
    s->volume = volume; s->pan = pan;
    if (s->node) {
        s->node.volume = g_muted ? 0.0f : volume;
        s->node.pan = (pan - 0.5f) * 2.0f;
    }
}
void AIL_stream_volume_pan(HSTREAM stream, float *volume, float *pan) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    if (volume) *volume = s->volume;
    if (pan)    *pan    = s->pan;
}
void AIL_set_stream_loop_count(HSTREAM stream, int count) {
    if (stream) ((AppleStream *)stream)->loopCount = count;
}
int  AIL_stream_loop_count(HSTREAM stream) {
    return stream ? ((AppleStream *)stream)->loopCount : 0;
}
void AIL_set_stream_loop_block(HSTREAM, int, int) {}
void AIL_set_stream_playback_rate(HSTREAM, int) {}
int  AIL_stream_playback_rate(HSTREAM) { return 0; }
void AIL_stream_ms_position(HSTREAM stream, S32 *total_ms, S32 *current_ms) {
    if (total_ms)   *total_ms   = stream ? ((AppleStream *)stream)->totalMs : 0;
    if (current_ms) *current_ms = stream ? ((AppleStream *)stream)->positionMs : 0;
}
void AIL_set_stream_ms_position(HSTREAM stream, int ms) {
    if (!stream) return;
    AppleStream *s = (AppleStream *)stream;
    if (!s->buffer || !s->node) return;
    double sr = s->buffer.format.sampleRate;
    if (sr <= 0) return;
    if (ms < 0) ms = 0;
    AVAudioFrameCount startFrame = (AVAudioFrameCount)((double)ms * sr / 1000.0);
    if (startFrame >= s->buffer.frameLength) {
        MLOG(2, "AIL_set_stream_ms_position(%p, ms=%d) past end — ignored",
             stream, ms);
        return;
    }
    if (!s->playing.load()) {
        if (startFrame > 0) {
            MLOG(2, "AIL_set_stream_ms_position(%p, ms=%d) — not playing, no-op",
                 stream, ms);
        }
        return;
    }
    AVAudioPCMBuffer *slice = sliceBufferFromFrame(s->buffer, startFrame);
    if (!slice) return;
    @try { [s->node stop]; } @catch (NSException *ex) {
        MLOG(1, "set_stream_ms_position stop NSException: %s", ex.reason.UTF8String ?: "?");
    }
    s->generation.fetch_add(1);
    s->playing.store(false);
    int gen = s->generation.load();
    AppleStream *captured = s;
    @try {
        // After the seeked slice finishes, restart full-buffer looping the
        // same way AIL_start_stream does (music typically loops forever:
        // loopCount == 0).
        [s->node scheduleBuffer:slice atTime:nil options:0
              completionHandler:^{
            enqueueCallback(captured, ^{
                if (captured->generation.load() != gen) return;
                if (captured->loopCount == 0 || --captured->loopsRemaining > 0) {
                    int gen2 = captured->generation.load();
                    @try {
                        [captured->node scheduleBuffer:captured->buffer atTime:nil options:0
                                     completionHandler:^{
                            enqueueCallback(captured, ^{
                                if (captured->generation.load() == gen2 && captured->eosCallback) {
                                    captured->eosCallback((HSTREAM)captured);
                                }
                            });
                        }];
                    } @catch (NSException *ex) {
                        MLOG(1, "set_stream_ms_position loop reschedule NSException: %s",
                             ex.reason.UTF8String ?: "?");
                        if (captured->eosCallback) captured->eosCallback((HSTREAM)captured);
                    }
                    return;
                }
                captured->playing.store(false);
                if (captured->eosCallback) captured->eosCallback((HSTREAM)captured);
            });
        }];
        [s->node play];
        s->playing.store(true);
        s->positionMs = ms;
        MLOG(2, "AIL_set_stream_ms_position(%p, ms=%d, frame=%u/%u) seeked",
             stream, ms, (unsigned)startFrame, (unsigned)s->buffer.frameLength);
    } @catch (NSException *ex) {
        MLOG(0, "AIL_set_stream_ms_position schedule NSException: %s — %s",
             ex.name.UTF8String ?: "?", ex.reason.UTF8String ?: "?");
        s->playing.store(false);
    }
}

AIL_stream_callback AIL_register_stream_callback(HSTREAM stream, AIL_stream_callback cb) {
    if (!stream) return nullptr;
    AppleStream *s = (AppleStream *)stream;
    AIL_stream_callback prev = s->eosCallback;
    s->eosCallback = cb;
    return prev;
}

// ----- WAV info + ADPCM ----------------------------------------------------

int AIL_WAV_info(const void *data, AILSOUNDINFO *info) {
    if (!data || !info) return 0;
    WavInfo w;
    if (!parseWav(data, 0, &w)) {
        memset(info, 0, sizeof(*info));
        return 0;
    }
    memset(info, 0, sizeof(*info));
    info->format     = w.format;
    info->data_ptr   = w.dataPtr;
    info->data_len   = w.dataLen;
    info->rate       = w.rate;
    info->bits       = w.bits;
    info->channels   = w.channels;
    info->block_size = w.blockAlign;
    info->initial_ptr = data;
    if (w.bits > 0 && w.channels > 0) {
        info->samples = w.dataLen / ((w.bits / 8) * w.channels);
    }
    return 1;
}

// IMA ADPCM (WAVE_FORMAT_IMA_ADPCM) → PCM16. Standard Microsoft block layout:
//   [predictor:S16][step_index:U8][reserved:U8] then 4-bit nibbles, LSN first.
//   Block size from blockAlign; samples/block = (blockAlign - 4) * 2 + 1.
// Mono only — Generals sample assets are mono for ADPCM.
static const int kImaIndexAdj[16] = {
    -1,-1,-1,-1, 2, 4, 6, 8, -1,-1,-1,-1, 2, 4, 6, 8
};
static const int kImaStepTable[89] = {
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
    50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
    337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,
    1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,
    6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,
    22385,24623,27086,29794,32767
};

int AIL_decompress_ADPCM(const AILSOUNDINFO *info, void **outdata, unsigned long *outsize) {
    if (!info || !info->data_ptr || !outdata) return 0;
    if (info->format != WAVE_FORMAT_IMA_ADPCM) return 0;
    int channels = info->channels > 0 ? info->channels : 1;
    int blockSize = info->block_size > 0 ? info->block_size : 256;
    const uint8_t *src = (const uint8_t *)info->data_ptr;
    size_t srcLen = info->data_len;
    // Stereo IMA ADPCM is interleaved per-4-bytes; we only need mono for the
    // engine's 3D voice tracks, but handle stereo defensively.
    int samplesPerBlockPerCh = (blockSize / channels - 4) * 2 + 1;
    size_t numBlocks = srcLen / blockSize;
    size_t totalSamples = numBlocks * samplesPerBlockPerCh * channels;
    int16_t *dst = (int16_t *)malloc(totalSamples * sizeof(int16_t));
    if (!dst) return 0;
    size_t outIdx = 0;
    for (size_t b = 0; b < numBlocks; ++b) {
        const uint8_t *blk = src + b * blockSize;
        // Per-channel state
        int predictor[2] = {0,0};
        int stepIndex[2] = {0,0};
        for (int c = 0; c < channels; ++c) {
            predictor[c] = (int16_t)(blk[c*4+0] | (blk[c*4+1] << 8));
            stepIndex[c] = blk[c*4+2];
            if (stepIndex[c] > 88) stepIndex[c] = 88;
            dst[outIdx++] = (int16_t)predictor[c];
        }
        const uint8_t *nibs = blk + 4 * channels;
        int nibLen = blockSize - 4 * channels;
        // Decode 8 samples per 4-byte group per channel (mono path is the
        // hot case; stereo interleaves per-group).
        if (channels == 1) {
            for (int i = 0; i < nibLen; ++i) {
                uint8_t byte = nibs[i];
                for (int n = 0; n < 2; ++n) {
                    int nib = (n == 0) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
                    int step = kImaStepTable[stepIndex[0]];
                    int diff = step >> 3;
                    if (nib & 1) diff += step >> 2;
                    if (nib & 2) diff += step >> 1;
                    if (nib & 4) diff += step;
                    if (nib & 8) diff = -diff;
                    predictor[0] += diff;
                    if (predictor[0] >  32767) predictor[0] =  32767;
                    if (predictor[0] < -32768) predictor[0] = -32768;
                    stepIndex[0] += kImaIndexAdj[nib];
                    if (stepIndex[0] < 0)  stepIndex[0] = 0;
                    if (stepIndex[0] > 88) stepIndex[0] = 88;
                    if (outIdx < totalSamples)               // defensive clamp
                        dst[outIdx++] = (int16_t)predictor[0];
                }
            }
        } else {
            // Stereo: 4-byte groups per channel, then 4-byte groups other ch.
            int groups = nibLen / 8;  // each 8 bytes = 4 left + 4 right
            for (int g = 0; g < groups; ++g) {
                for (int c = 0; c < 2; ++c) {
                    for (int i = 0; i < 4; ++i) {
                        uint8_t byte = nibs[g*8 + c*4 + i];
                        for (int n = 0; n < 2; ++n) {
                            int nib = (n == 0) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
                            int step = kImaStepTable[stepIndex[c]];
                            int diff = step >> 3;
                            if (nib & 1) diff += step >> 2;
                            if (nib & 2) diff += step >> 1;
                            if (nib & 4) diff += step;
                            if (nib & 8) diff = -diff;
                            predictor[c] += diff;
                            if (predictor[c] >  32767) predictor[c] =  32767;
                            if (predictor[c] < -32768) predictor[c] = -32768;
                            stepIndex[c] += kImaIndexAdj[nib];
                            if (stepIndex[c] < 0)  stepIndex[c] = 0;
                            if (stepIndex[c] > 88) stepIndex[c] = 88;
                            // TheSuperHackers @fix Stereo IMA heap overflow.
                            // Each 8-byte group yields 8 frames per channel; the
                            // data-frame index within this block is g*8 + i*2 + n.
                            // The interleaved sample slot is frame*2 + c. The old
                            // code used g*16 (and advanced outIdx by groups*32),
                            // writing ~2x past the `dst` allocation
                            // (totalSamples = numBlocks*samplesPerBlockPerCh*ch),
                            // corrupting the malloc heap. For blockSize=512 that
                            // wrote 2018 int16 into a 1010-int16 region per block.
                            // The corruption surfaced later as an EXC_ARM_DA_ALIGN
                            // bus error in caulk's audio-buffer pool when an
                            // adjacent AVAudioPCMBuffer was deallocated.
                            // Correct stride is g*8; advance is groups*16
                            // (groups*8 frames * 2 channels) — matches the alloc.
                            size_t pos = outIdx + (g * 8 + i*2 + n) * 2 + c;
                            if (pos < totalSamples)              // defensive clamp
                                dst[pos] = (int16_t)predictor[c];
                        }
                    }
                }
            }
            outIdx += groups * 16;
        }
    }
    *outdata = dst;
    if (outsize) *outsize = (unsigned long)(outIdx * sizeof(int16_t));
    {
        std::lock_guard<std::mutex> lk(g_imaLock);
        g_imaBlobs[dst] = ImaDecodedBlob{channels, (int)info->rate,
                                         (unsigned long)(outIdx * sizeof(int16_t))};
    }
    return 1;
}

void AIL_mem_free_lock(void *ptr) {
    if (ptr) {
        std::lock_guard<std::mutex> lk(g_imaLock);
        g_imaBlobs.erase(ptr);
    }
    free(ptr);
}

// ----- Timer / misc stubs -------------------------------------------------

void AIL_stop_timer(HTIMER) {}
void AIL_release_timer_handle(HTIMER) {}
unsigned long AIL_get_timer_highest_delay(void) { return 0; }

} // extern "C"

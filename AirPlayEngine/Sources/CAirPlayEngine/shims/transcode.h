// SPDX-License-Identifier: GPL-2.0-or-later
//
// transcode — SHIM (the ALAC encoder seam). Replaces OwnTone's src/transcode.h.
//
// Implements: docs/seam-map.md §3.8 + §5. RESOLVED DECISIONS Q2: link ffmpeg
// first, evaluate the dependency-free uncompressed-ALAC path later.
//
// The 8 symbols airplay.c actually uses (grep at T-BUILD-1):
//   transcode_frame_new / transcode_frame_free      (airplay.c:504/512)
//   transcode_encode(struct evbuffer *evbuf, ...)   (airplay.c:511)
//   transcode_encode_setup / transcode_encode_cleanup (:1188/:1107)
//   transcode_decode_setup_raw / transcode_decode_cleanup (:1181/:1189)
//   struct transcode_encode_setup_args (fields used: .profile .quality .src_ctx)
//   enums XCODE_PCM16, XCODE_ALAC
//
// SIGNATURES/TYPES ARE COPIED FROM OwnTone src/transcode.h VERBATIM (the used
// subset) — note the differences the T-PKG-1 scaffold got wrong:
//   - transcode_frame is `typedef void` (opaque), NOT a struct.
//   - transcode_encode's first arg is `struct evbuffer *`, its last is `int eof`.
//   - transcode_frame_new takes `void *data` and returns `transcode_frame *`.
//   - transcode_encode_setup_args.quality is `struct media_quality *`.
//   - the enum keeps OwnTone's full ordering so XCODE_PCM16/XCODE_ALAC have the
//     exact integer values airplay.c's designated-initializers expect.
//
// STUB STATUS (T-BUILD-1): transcode.c bodies are MINIMAL stubs that LINK but
// do NOT encode — transcode_encode_setup returns NULL, so master_session_make
// takes airplay.c's own "ffmpeg has no ALAC encoder" error branch (airplay.c:
// 1192) cleanly. This is deliberate: getting the cluster to COMPILE + LINK
// does not require a working encoder. The REAL ffmpeg-backed ALAC encoder
// (Q2a) is T-SHIM-1's job (seam-map §5, risk R-C), at which point the
// avcodec/avutil/swresample link libs get added to Package.swift.
//
// TODO(T-SHIM-1): implement transcode.c for real against libavcodec (ALAC
// encode + PCM16 raw decode-setup), guarding the :1192 failure mode; later
// swap to the uncompressed-ALAC path to shed ffmpeg (seam-map §5.3).

#ifndef CAIRPLAYENGINE_SHIM_TRANSCODE_H
#define CAIRPLAYENGINE_SHIM_TRANSCODE_H

#include <stddef.h>
#include <stdint.h>

#include "misc.h" /* struct media_quality */

#ifdef __cplusplus
extern "C" {
#endif

struct evbuffer; /* from libevent; opaque here */

/* Full ordering copied from OwnTone src/transcode.h so XCODE_PCM16 / XCODE_ALAC
 * carry the exact integer values airplay.c relies on. */
enum transcode_profile
{
  XCODE_UNKNOWN,
  XCODE_NONE,
  XCODE_PCM_NATIVE,
  XCODE_WAV,
  XCODE_PCM16,
  XCODE_PCM24,
  XCODE_PCM32,
  XCODE_MP3,
  XCODE_OPUS,
  XCODE_ALAC,
  XCODE_MP4_ALAC,
  XCODE_MP4_ALAC_HEADER,
  XCODE_OGG,
  XCODE_JPEG,
  XCODE_PNG,
  XCODE_VP8,
};

typedef void transcode_frame;

struct decode_ctx;
struct encode_ctx;

struct transcode_encode_setup_args
{
  enum transcode_profile profile;
  struct media_quality *quality;
  struct decode_ctx *src_ctx;
  struct transcode_evbuf_io *evbuf_io; /* forward-declared; unused by airplay.c */
  struct evbuffer *prepared_header;
  int width;
  int height;
};

/* Setup / cleanup */
struct encode_ctx *
transcode_encode_setup(struct transcode_encode_setup_args args);

void
transcode_encode_cleanup(struct encode_ctx **ctx);

struct decode_ctx *
transcode_decode_setup_raw(enum transcode_profile profile, struct media_quality *quality);

void
transcode_decode_cleanup(struct decode_ctx **ctx);

/* Encode one frame into evbuf. Returns bytes added, or negative on error. */
int
transcode_encode(struct evbuffer *evbuf, struct encode_ctx *ctx, transcode_frame *frame, int eof);

/* Wrap a raw PCM buffer as a frame for transcode_encode. */
transcode_frame *
transcode_frame_new(void *data, size_t size, int nsamples, struct media_quality *quality);

void
transcode_frame_free(transcode_frame *frame);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_TRANSCODE_H */

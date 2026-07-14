// SPDX-License-Identifier: GPL-2.0-or-later
//
// transcode.c — REAL ffmpeg-backed ALAC encoder (T-SHIM-2, Q2a "first light").
//
// This is a PURPOSE-BUILT encoder, NOT a port of OwnTone's src/transcode.c
// (2645 LOC of generic AVFormat/AVFilter muxing machinery). airplay.c only ever
// asks this shim to do ONE thing: turn each 352-sample interleaved-PCM16 frame
// into a raw ALAC packet appended to an evbuffer. So we implement exactly that
// path with libavcodec + libswresample and nothing else. It reproduces the
// codec configuration OwnTone's transcode.c uses for XCODE_ALAC (seam-map §5.1,
// transcode.c:293-300 upstream):
//   AV_CODEC_ID_ALAC, sample_fmt = AV_SAMPLE_FMT_S16P (planar),
//   sample_rate/channels from media_quality, frame_size forced to 352.
// The "frame_size = 352" write after avcodec_open2 is the same documented
// "misuse" hack OwnTone applies (transcode.c:686) so the ALAC encoder accepts
// 352-sample frames instead of its native 4096. The receiver relies on 352 spf.
//
// Input from airplay.c is INTERLEAVED S16 (from XCODE_PCM16 raw). The ALAC
// encoder wants PLANAR S16P, so we resample interleaved->planar with a
// SwrContext (a format-only conversion, same rate/channels).
//
// TODO(seam-map §5.3, R-C): the later swap to the vendored ~50-line
// dependency-free uncompressed-ALAC encoder (lifted from raop.c's
// alac_encode_uncompressed) to shed the ffmpeg dependency entirely. DO NOT do
// that swap here — this task is "link ffmpeg for first light" only, matching
// OwnTone's validated codepath. When that swap lands, remove the
// avcodec/avutil/swresample link libs from Package.swift.

#include "transcode.h"
#include "logger.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <event2/buffer.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/frame.h>
#include <libswresample/swresample.h>

/* airplay.c pushes 352-sample frames even though the ALAC encoder's native
 * frame size is larger — matching OwnTone's behaviour (seam-map §5.1). */
#define ALAC_FRAME_SIZE 352

/* decode_ctx is a thin record: transcode_decode_setup_raw(XCODE_PCM16, quality)
 * doesn't open any real decoder (the input is already raw PCM) — it just
 * captures the source quality so transcode_encode_setup can configure the
 * encoder. Kept as a distinct type to match the airplay.c ownership dance
 * (it allocs the decode ctx, passes it in encode_args.src_ctx, then frees it
 * with transcode_decode_cleanup). */
struct decode_ctx
{
  struct media_quality quality;
};

struct encode_ctx
{
  AVCodecContext *codec;   /* the ALAC encoder */
  SwrContext     *swr;     /* interleaved S16 -> planar S16P */
  AVPacket       *pkt;     /* reused output packet */
  int             channels;
  int             sample_rate;
};

/* A transcode_frame here is just a wrapper carrying one interleaved-PCM16 block
 * (transcode_frame is `typedef void` in the header — opaque to airplay.c). */
struct frame_wrap
{
  const uint8_t *data;   /* borrowed — not owned */
  int            nsamples;
  int            channels;
};

struct decode_ctx *
transcode_decode_setup_raw(enum transcode_profile profile, struct media_quality *quality)
{
  struct decode_ctx *ctx;

  (void)profile; /* always XCODE_PCM16 from airplay.c:1181 */

  if (!quality)
    return NULL;

  ctx = calloc(1, sizeof(*ctx));
  if (!ctx)
    return NULL;

  ctx->quality = *quality;
  return ctx;
}

void
transcode_decode_cleanup(struct decode_ctx **ctx)
{
  if (ctx && *ctx)
    {
      free(*ctx);
      *ctx = NULL;
    }
}

struct encode_ctx *
transcode_encode_setup(struct transcode_encode_setup_args args)
{
  struct encode_ctx *ctx = NULL;
  const AVCodec *codec;
  struct media_quality *q;
  int ret;

  if (args.profile != XCODE_ALAC)
    {
      DPRINTF(E_LOG, L_XCODE, "transcode_encode_setup: only XCODE_ALAC supported (got %d)\n", args.profile);
      return NULL;
    }

  // Quality comes from args.quality (airplay.c sets it), falling back to the
  // source decode ctx if needed.
  q = args.quality;
  if (!q && args.src_ctx)
    q = &args.src_ctx->quality;
  if (!q)
    {
      DPRINTF(E_LOG, L_XCODE, "transcode_encode_setup: no media_quality provided\n");
      return NULL;
    }

  codec = avcodec_find_encoder(AV_CODEC_ID_ALAC);
  if (!codec)
    {
      DPRINTF(E_LOG, L_XCODE, "ffmpeg has no ALAC encoder\n");
      return NULL;
    }

  ctx = calloc(1, sizeof(*ctx));
  if (!ctx)
    return NULL;

  ctx->channels = q->channels;
  ctx->sample_rate = q->sample_rate;

  ctx->codec = avcodec_alloc_context3(codec);
  if (!ctx->codec)
    goto error;

  ctx->codec->sample_rate = q->sample_rate;
  ctx->codec->sample_fmt = AV_SAMPLE_FMT_S16P; // ALAC encoder requires planar
  ctx->codec->time_base = (AVRational){ 1, q->sample_rate };
  av_channel_layout_default(&ctx->codec->ch_layout, q->channels);

  ret = avcodec_open2(ctx->codec, codec, NULL);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_XCODE, "Cannot open ALAC encoder: %d\n", ret);
      goto error;
    }

  // The documented "misuse" hack (OwnTone transcode.c:686): airplay.c feeds
  // 352-sample frames; force the encoder's frame_size so it accepts them.
  ctx->codec->frame_size = ALAC_FRAME_SIZE;

  // Resampler: interleaved S16 (airplay.c's raw PCM16) -> planar S16P, same
  // rate + channel layout (a format-only conversion).
  ret = swr_alloc_set_opts2(&ctx->swr,
                            &ctx->codec->ch_layout, AV_SAMPLE_FMT_S16P, q->sample_rate,
                            &ctx->codec->ch_layout, AV_SAMPLE_FMT_S16, q->sample_rate,
                            0, NULL);
  if (ret < 0 || !ctx->swr)
    {
      DPRINTF(E_LOG, L_XCODE, "Cannot allocate resampler: %d\n", ret);
      goto error;
    }

  ret = swr_init(ctx->swr);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_XCODE, "Cannot init resampler: %d\n", ret);
      goto error;
    }

  ctx->pkt = av_packet_alloc();
  if (!ctx->pkt)
    goto error;

  return ctx;

 error:
  transcode_encode_cleanup(&ctx);
  return NULL;
}

void
transcode_encode_cleanup(struct encode_ctx **ctxp)
{
  struct encode_ctx *ctx;

  if (!ctxp || !*ctxp)
    return;

  ctx = *ctxp;

  if (ctx->pkt)
    av_packet_free(&ctx->pkt);
  if (ctx->swr)
    swr_free(&ctx->swr);
  if (ctx->codec)
    avcodec_free_context(&ctx->codec);

  free(ctx);
  *ctxp = NULL;
}

transcode_frame *
transcode_frame_new(void *data, size_t size, int nsamples, struct media_quality *quality)
{
  struct frame_wrap *fw;

  if (!data || !quality)
    return NULL;

  // Sanity: size must hold nsamples * channels * 2 bytes (S16).
  if (size < (size_t)nsamples * quality->channels * 2)
    {
      DPRINTF(E_LOG, L_XCODE, "transcode_frame_new: buffer too small (%zu < %d samples)\n", size, nsamples);
      return NULL;
    }

  fw = calloc(1, sizeof(*fw));
  if (!fw)
    return NULL;

  fw->data = (const uint8_t *)data; // borrowed; airplay.c owns rawbuf
  fw->nsamples = nsamples;
  fw->channels = quality->channels;

  return fw;
}

void
transcode_frame_free(transcode_frame *frame)
{
  free(frame); // frees the wrapper only, not the borrowed PCM
}

int
transcode_encode(struct evbuffer *evbuf, struct encode_ctx *ctx, transcode_frame *frame, int eof)
{
  struct frame_wrap *fw = frame;
  AVFrame *avframe = NULL;
  const uint8_t *in[1];
  int ret;
  int total = 0;

  (void)eof; // airplay.c always passes 0 (never flushes via this path)

  if (!evbuf || !ctx)
    return -1;

  if (!fw)
    return -1;

  avframe = av_frame_alloc();
  if (!avframe)
    return -1;

  avframe->format = AV_SAMPLE_FMT_S16P;
  avframe->sample_rate = ctx->sample_rate;
  avframe->nb_samples = fw->nsamples;
  ret = av_channel_layout_copy(&avframe->ch_layout, &ctx->codec->ch_layout);
  if (ret < 0)
    goto out;

  ret = av_frame_get_buffer(avframe, 0);
  if (ret < 0)
    goto out;

  ret = av_frame_make_writable(avframe);
  if (ret < 0)
    goto out;

  // Convert the interleaved S16 input into the planar S16P avframe.
  in[0] = fw->data;
  ret = swr_convert(ctx->swr, avframe->data, fw->nsamples, in, fw->nsamples);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_XCODE, "swr_convert failed: %d\n", ret);
      goto out;
    }
  avframe->nb_samples = ret;

  ret = avcodec_send_frame(ctx->codec, avframe);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_XCODE, "avcodec_send_frame failed: %d\n", ret);
      goto out;
    }

  while (1)
    {
      ret = avcodec_receive_packet(ctx->codec, ctx->pkt);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        {
          ret = 0;
          break;
        }
      else if (ret < 0)
        {
          DPRINTF(E_LOG, L_XCODE, "avcodec_receive_packet failed: %d\n", ret);
          goto out;
        }

      // "data" format (no muxing): the raw ALAC packet is exactly what goes on
      // the wire. Append it to the caller's evbuffer.
      if (evbuffer_add(evbuf, ctx->pkt->data, ctx->pkt->size) < 0)
        {
          av_packet_unref(ctx->pkt);
          ret = -1;
          goto out;
        }

      total += ctx->pkt->size;
      av_packet_unref(ctx->pkt);
    }

  ret = total;

 out:
  if (avframe)
    av_frame_free(&avframe);
  return ret;
}

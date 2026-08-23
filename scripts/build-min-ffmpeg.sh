#!/bin/bash
# build-min-ffmpeg.sh — build a MINIMAL, audio-only ffmpeg (ALAC encoder +
# libswresample only) and install it as static libs into
# AirPlayEngine/vendor/ffmpeg-min/, so the shipped app links ONLY the codec it
# actually uses (Apple Lossless) and carries ZERO video-codec code.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS
# ---------------
# AirPlayEngine encodes captured PCM to ALAC via libavcodec's ALAC encoder
# (Sources/CAirPlayEngine/shims/transcode.c — the ONLY ffmpeg symbol it needs is
# avcodec_find_encoder(AV_CODEC_ID_ALAC), plus libswresample for an
# interleaved-S16 -> planar-S16P format conversion). The Homebrew `ffmpeg`
# formula, however, is a FULL build: its libavcodec.dylib hard-links libx264,
# libx265, libvpx, libdav1d, libSvtAv1Enc, libmp3lame and libopus. When
# scripts/bundle-dylibs.sh walks the load-command graph for a self-contained
# release (AUDIOUT_BUNDLE_DYLIBS=1), it drags all of those in — ~24 MB of
# H.264/H.265/AV1/VP9 encoder code an audio-only app never calls (roughly 60% of
# the shipped download). See docs/plans/phase-3-findings/performance.md (M1) and
# AirPlayEngine/docs/ffmpeg-minimal-build.md.
#
# WHAT THIS PRODUCES
# ------------------
# A static (`.a`) minimal ffmpeg under AirPlayEngine/vendor/ffmpeg-min/:
#   include/                 libavcodec / libavutil / libswresample headers
#   lib/libavcodec.a         ALAC encoder + codec core, NO x264/x265/vpx/...
#   lib/libavutil.a
#   lib/libswresample.a
#   lib/pkgconfig/*.pc        (Libs.private lists the system libs to link)
# AirPlayEngine/Package.swift AUTO-DETECTS this prefix (looks for
# lib/libavcodec.a) and links it STATICALLY in preference to Homebrew's fat
# ffmpeg. If this directory is absent, Package.swift falls back to the Homebrew
# dylibs unchanged, so a plain `swift build` still works on any dev machine.
# The vendor/ dir is .gitignored — it is a generated build artifact, arch- and
# version-specific; regenerate it with this script on the build machine.
#
# The ALAC bytes this minimal build emits are BIT-IDENTICAL to the fat build's:
# it is the same libavcodec ALAC encoder (alacenc.c), merely compiled without
# the video codecs. AirPlayEngine's ShimUnitTests.testAlacTranscodeShimProduces-
# ValidFrames exercises it end to end, so `swift test` proves the encoder works
# against whichever ffmpeg is linked.
#
# USAGE
#   scripts/build-min-ffmpeg.sh            # build if missing
#   FFMPEG_MIN_FORCE=1 scripts/build-min-ffmpeg.sh   # rebuild from scratch
#
# No assembler (nasm/yasm) is required: --disable-asm keeps the build portable
# across arm64 and x86_64 without an external assembler. ALAC encode of a
# 352-sample frame is trivially cheap, so the dropped hand-written asm is
# irrelevant to performance.

set -euo pipefail

# --- Pinned source (official ffmpeg.org release) ---------------------------
# Kept deliberately at a version whose libav* API matches what transcode.c
# already compiles against (the new channel-layout API: av_channel_layout_*,
# swr_alloc_set_opts2). Bump both VERSION and SHA256 together when updating.
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
# SHA256 of https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz (official release).
# Bump together with FFMPEG_VERSION. Override with the env var only for testing.
FFMPEG_SHA256="${FFMPEG_SHA256:-733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="$REPO_ROOT/AirPlayEngine/vendor/ffmpeg-min"
WORK_ROOT="${FFMPEG_MIN_WORKDIR:-$REPO_ROOT/AirPlayEngine/vendor/.build-ffmpeg}"
TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
TARBALL="$WORK_ROOT/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="$WORK_ROOT/ffmpeg-${FFMPEG_VERSION}"

# --- Idempotence -----------------------------------------------------------
if [ "${FFMPEG_MIN_FORCE:-0}" != "1" ] && [ -f "$PREFIX/lib/libavcodec.a" ]; then
  echo "==> Minimal ffmpeg already present at $PREFIX (set FFMPEG_MIN_FORCE=1 to rebuild)."
  exit 0
fi

mkdir -p "$WORK_ROOT"

# --- Download --------------------------------------------------------------
if [ ! -f "$TARBALL" ]; then
  echo "==> Downloading $TARBALL_URL"
  curl -fL --retry 3 -o "$TARBALL" "$TARBALL_URL"
fi

# --- Verify checksum (supply-chain integrity) ------------------------------
ACTUAL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ -n "$FFMPEG_SHA256" ]; then
  if [ "$ACTUAL_SHA256" != "$FFMPEG_SHA256" ]; then
    echo "error: SHA256 mismatch for $TARBALL" >&2
    echo "  expected: $FFMPEG_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    exit 1
  fi
  echo "==> Verified SHA256 $ACTUAL_SHA256"
else
  echo "WARNING: no FFMPEG_SHA256 pinned; downloaded tarball sha256 is:" >&2
  echo "  $ACTUAL_SHA256" >&2
  echo "  Bake this into FFMPEG_SHA256 above once confirmed against ffmpeg.org." >&2
fi

# --- Extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> Extracting"
  tar -C "$WORK_ROOT" -xf "$TARBALL"
fi

# --- Configure (audio-only, ALAC encoder + swresample, nothing else) -------
# --disable-everything removes every codec/muxer/parser/protocol/bsf, then we
# re-enable ONLY the ALAC encoder. No decoders, demuxers, parsers or protocols
# are needed: airplay.c/raop.c hand us already-decoded interleaved PCM16 and we
# only ENCODE. libswresample does the interleaved->planar S16 conversion.
echo "==> Configuring minimal ffmpeg $FFMPEG_VERSION -> $PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
(
  cd "$SRC_DIR"
  make distclean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$PREFIX" \
    --disable-everything \
    --enable-encoder=alac \
    --enable-swresample \
    --disable-avformat \
    --disable-avfilter \
    --disable-avdevice \
    --disable-swscale \
    --disable-postproc \
    --disable-programs \
    --disable-doc \
    --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
    --disable-network \
    --disable-protocols \
    --disable-devices \
    --disable-filters \
    --disable-bsfs \
    --disable-parsers \
    --disable-demuxers \
    --disable-muxers \
    --disable-autodetect \
    --disable-debug \
    --disable-asm \
    --enable-static \
    --disable-shared \
    --enable-pic
  echo "==> Building (this takes a few minutes)"
  make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  make install
)

# --- Report ----------------------------------------------------------------
echo ""
echo "==> Minimal ffmpeg installed at $PREFIX"
ls -la "$PREFIX/lib/"*.a
echo ""
echo "==> Static-link system deps (from pkg-config Libs.private):"
for pc in libavcodec libavutil libswresample; do
  if [ -f "$PREFIX/lib/pkgconfig/$pc.pc" ]; then
    priv="$(grep -E '^Libs.private:' "$PREFIX/lib/pkgconfig/$pc.pc" || true)"
    echo "    $pc: ${priv:-<none>}"
  fi
done
echo ""
echo "==> Done. AirPlayEngine/Package.swift will now link this static minimal"
echo "    ffmpeg automatically (delete $PREFIX to fall back to Homebrew ffmpeg)."

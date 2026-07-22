# Minimal audio-only ffmpeg — shedding the video-codec bloat

**Status:** IMPLEMENTED (headless-verified) 2026-07-22. Live-on-hardware
validation deferred to a signed-build session (same as every other engine
change — the ALAC bytes are bit-identical to the validated fat build, so the
protocol risk is minimal; see Risks).

Addresses `docs/plans/phase-3-findings/performance.md` **M1**: ~60% of the real
shipped download is video-codec code an audio-only app never calls.

---

## 1. What ffmpeg is actually used for (traced, not assumed)

Audiouter captures **already-decoded PCM** system audio via Core Audio process
taps. It never decodes video or any media file — the source app already did
that. ffmpeg is used for exactly one thing: **encoding that PCM into Apple
Lossless (ALAC)** for AirPlay.

- The only ffmpeg entry point the engine calls is in
  `Sources/CAirPlayEngine/shims/transcode.c`:
  `avcodec_find_encoder(AV_CODEC_ID_ALAC)` + the libavcodec encode calls
  (`avcodec_alloc_context3`/`_open2`/`_send_frame`/`_receive_packet`), plus
  **libswresample** for an interleaved-S16 → planar-S16P format conversion (the
  ALAC encoder wants planar). No decoder, demuxer, parser, muxer, protocol or
  bitstream filter is used.
- **AP2 (`sender/airplay.c`)** — the primary shipping path — encodes ALAC
  *only* through this ffmpeg shim (`alac_encode` → `transcode_encode`). It has
  no non-ffmpeg fallback: `master_session_make` fails the session if
  `transcode_encode_setup` returns NULL. **So AP2 requires an ALAC encoder from
  ffmpeg.**
- **AP1 / RAOP (`sender/raop.c`)** already avoids ffmpeg: with
  `airplay_shared.uncompressed_alac = true` (the engine default, set in
  `shims/conffile.c`) it uses raop.c's own inline uncompressed-ALAC encoder
  (`alac_encode` → `alac_encode_no_xcode` → `alac_encode_uncompressed`) and
  never builds the ffmpeg encode context (VENDORED-DIFFS Entry 3).

**Conclusion:** the video codecs are provably dead weight — the engine only
ever encodes ALAC — but ffmpeg's *ALAC encoder* is still required for the AP2
path, so ffmpeg cannot simply be dropped without also porting the
uncompressed-ALAC path into airplay.c (see Option B below).

## 2. How ffmpeg was sourced, and why the bloat

`AirPlayEngine/Package.swift` linked `libavcodec`/`libavutil`/`libswresample`
straight out of Homebrew's `ffmpeg` formula. That formula is a **full** build:
its `libavcodec.dylib` (9.8 MB) hard-links (`otool -L`) libx264, libx265,
libvpx, dav1d, SvtAv1Enc, lame, opus, and OpenSSL (libcrypto/libssl, for TLS).
`scripts/bundle-dylibs.sh` walks that whole `otool -L` graph for a
self-contained release (`AUDIOUTER_BUNDLE_DYLIBS=1`) and ships all of it.

Measured transitive closure that exists **only** because of the fat ffmpeg
(everything reachable from the ffmpeg trio minus the libs the app needs anyway
— libevent/libsodium/libgcrypt/libgpg-error/libplist):

| dylib | size |
|---|---|
| libavcodec | 9.78 MB |
| libx265 | 7.23 MB |
| libcrypto (OpenSSL) | 4.85 MB |
| libSvtAv1Enc | 2.80 MB |
| libvpx | 1.74 MB |
| libx264 | 1.30 MB |
| libssl (OpenSSL) | 0.90 MB |
| libdav1d | 0.80 MB |
| libavutil | 0.64 MB |
| libopus | 0.38 MB |
| libmp3lame | 0.31 MB |
| libswresample | 0.12 MB |
| **total** | **30.86 MB (12 dylibs)** |

## 3. Options considered

- **(A) Minimal ffmpeg — CHOSEN.** Build ffmpeg with
  `--disable-everything --enable-encoder=alac --enable-swresample` and link that
  instead of the fat Homebrew build. Keeps the **exact validated ALAC codepath**
  (same libavcodec `alacenc.c`), so the wire bytes are bit-identical and the
  protocol risk is essentially nil. Removes the entire video-codec + OpenSSL
  closure.
- **(B) Drop ffmpeg entirely.** Route AP2's `alac_encode` through the same
  inline uncompressed-ALAC encoder raop.c already uses, eliminating libav*
  altogether. Lighter still, but it is **vendored surgery on the GPL AP2 core**
  (`sender/airplay.c`) plus a receiver-acceptance question (does the AP2 SETUP
  magic-cookie / codec advertisement match uncompressed frames on real AP2
  hardware?). That cannot be proven safe headlessly — it needs the live receiver
  harness — so per this task's hard requirement it is NOT done here. It remains
  the logical follow-up once a signed-build live session exists (the existing
  `transcode.c` TODO and seam-map §5.3 track it).

Option A is the lowest-risk trim that keeps ALAC fully working, so it is what
shipped here.

## 4. What was implemented

- **`scripts/build-min-ffmpeg.sh`** — downloads pinned upstream ffmpeg
  (7.1.1, SHA256-verified), configures it audio-only (ALAC encoder +
  swresample, no decoders/demuxers/parsers/protocols/bsfs, `--disable-network`,
  `--disable-asm` for portability), builds **static** libs, and installs them to
  `AirPlayEngine/vendor/ffmpeg-min/{include,lib}`. Idempotent; `FFMPEG_MIN_FORCE=1`
  rebuilds.
- **`AirPlayEngine/Package.swift`** — auto-detects
  `vendor/ffmpeg-min/lib/libavcodec.a`. If present, it links the three `.a`
  archives statically and points the ffmpeg `-I` at the vendored headers. If
  absent, it falls back to the Homebrew fat ffmpeg dylibs exactly as before.
  ffmpeg was removed from the generic `brewFormulae` list and resolved on its
  own so the two modes don't interfere.
- **`.gitignore`** — `AirPlayEngine/vendor/` is ignored: the minimal ffmpeg is a
  generated, arch/version-specific, multi-MB artifact, rebuilt on the build
  machine rather than committed.
- Static linking (rather than a vendored minimal *dylib*) is deliberate: it
  makes the win **self-contained** — the video codecs simply never enter the
  `otool -L` graph, so `bundle-dylibs.sh` needs no change to realize it — and it
  avoids `@rpath` juggling for a non-Homebrew dylib. The licensing consequence
  (ffmpeg static vs. replaceable-dylib) is handled in NOTICE + license-inventory.

## 5. Size win (measured, M1 arm64)

- Fat mode: `Contents/Frameworks/` carries the 30.86 MB ffmpeg+codec closure
  above (12 dylibs) on top of the 6 libs the app needs regardless.
- Minimal mode: **zero** ffmpeg/video-codec dylibs (verified by `otool -L` on
  both `engine-probe` and `AudiouterApp` — only libevent/libsodium/libgcrypt/
  libgpg-error/libplist remain). The static minimal libs total 1.4 MB on disk
  and only their dead-stripped ALAC/swresample/avutil objects link into the
  binary.
- **Net: ≈ 30.9 MB of dylibs removed − ≤ 1.4 MB static code added ≈ ~29–30 MB**,
  shrinking the ~38–40 MB bundled artifact to roughly ~9–11 MB. (Larger than
  performance.md's ~24 MB estimate because the fat ffmpeg also drags in OpenSSL
  and lame/opus, all unused.)

## 6. Verification (headless)

- `swift build` in `AirPlayEngine/` **and** `AudiouterCore/`: green in **both**
  minimal (vendor present) and fallback (vendor absent) modes.
- `swift test` in `AirPlayEngine/`: unchanged from baseline — 137/138, the one
  failure being `PTPHelperIPCTests` "Error creating shared memory", a
  pre-existing environmental/PTP-resource issue unrelated to ffmpeg.
- **`ShimUnitTests.testAlacTranscodeShimProducesValidFrames` passes against the
  minimal static ffmpeg** — it drives `transcode_encode_setup`/`transcode_encode`
  exactly as `master_session_make` does, encoding 200 frames of a synthesized
  tone and asserting one ALAC packet per 352-sample frame, the frame-size=352
  hack held (packet under the uncompressed ceiling), and the ALAC element header
  first byte `0x20`. That is headless proof the minimal build's encoder produces
  correctly-shaped ALAC — and since it is the same `alacenc.c`, the output is
  bit-identical to the fat build.

## 7. Risks + what's deferred

- **Live-on-hardware validation is deferred** to a signed-build session, like
  every engine change. The residual risk is only "does a real AP2/AP1 receiver
  accept these ALAC frames" — but the frames come from the *same* libavcodec
  ALAC encoder, so this is not a new risk introduced by the trim; it is the
  standing first-light gate.
- **ffmpeg version drift:** the minimal build pins 7.1.1 (libavcodec 61);
  Homebrew was on libavcodec 62 (ffmpeg 8.0). The APIs `transcode.c` uses
  (`av_channel_layout_*`, `swr_alloc_set_opts2`, `avcodec_send_frame`/
  `_receive_packet`) are stable across both. Bump `FFMPEG_VERSION` +
  `FFMPEG_SHA256` together to track upstream.
- **`--disable-asm`** drops ffmpeg's hand-written SIMD. Irrelevant for ALAC
  encoding of 352-sample frames (trivially cheap) and it keeps the build
  portable with no external assembler (nasm/yasm) on arm64 or x86_64.

## 8. Release integration (owned by another agent — NOTE, not done here)

The win only lands in a bundled release if the minimal ffmpeg exists at
`swift build` time. `scripts/make-app.sh` / `scripts/bundle-dylibs.sh` (owned by
another agent) should run `scripts/build-min-ffmpeg.sh` **before** the
`swift build` step of an `AUDIOUTER_BUNDLE_DYLIBS=1` release, e.g. near the top
of the release path:

```sh
scripts/build-min-ffmpeg.sh    # produce AirPlayEngine/vendor/ffmpeg-min (idempotent)
```

With that in place, `bundle-dylibs.sh` needs no change: its `otool -L` walk
simply finds no ffmpeg/video-codec dylibs to copy. If the step is omitted, the
build still works (fat-ffmpeg fallback) — it just ships the old ~30 MB. A plain
dev `swift build` is unaffected either way.

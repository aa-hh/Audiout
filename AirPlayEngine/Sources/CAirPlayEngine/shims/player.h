// SPDX-License-Identifier: GPL-2.0-or-later
//
// player — REPLACE-with-Swift-callback / STUB. Replaces OwnTone's src/player.h.
//
// Implements: docs/seam-map.md §3.6. Two symbol groups actually referenced by
// the vendored cluster (grep at T-BUILD-1):
//   1. Discovery -> registry: player_device_add(void*) (airplay.c:4129),
//      player_device_remove(void*) (airplay.c:4026). NOTE the argument is
//      `void *device` in OwnTone's player.h (NOT struct output_device* — the
//      T-PKG-1 scaffold got this wrong). Per seam-map §2.2 these merge into
//      the shims/outputs.c registry and (later) emit a Swift event.
//   2. airplay_events.c remote-control: player_get_status(&status) reads
//      status.status vs PLAY_PLAYING; then player_playback_pause/start/next/
//      prev. Audio-only sender (SPEC.md §2): these are no-ops.
//
// Only the surface the cluster uses is declared (not OwnTone's full player.h).
// enum play_status keeps OwnTone's integer values (PLAY_PLAYING = 4) so the
// `status.status == PLAY_PLAYING` compare in airplay_events.c behaves the same.
//
// STUB STATUS (T-BUILD-1): player.c bodies are MINIMAL no-ops that LINK —
// player_device_add/remove return 0 (TODO(T-SHIM-1): call into the outputs.c
// registry + emit a Swift deviceAdded/Removed event); player_get_status zeroes
// the struct and returns 0; the four playback controls return 0.
//
// TODO(T-SHIM-1): wire player_device_add/remove into shims/outputs.c's
// registry and surface Swift-visible events; keep the playback controls as
// no-ops (or forward as optional "remote-control received" events).

#ifndef CAIRPLAYENGINE_SHIM_PLAYER_H
#define CAIRPLAYENGINE_SHIM_PLAYER_H

#ifdef __cplusplus
extern "C" {
#endif

enum play_status {
  PLAY_STOPPED = 2,
  PLAY_PAUSED  = 3,
  PLAY_PLAYING = 4,
};

/* Only the one field airplay_events.c reads (seam-map §3.6). */
struct player_status {
  enum play_status status;
};

int
player_get_status(struct player_status *status);

/* Discovery -> registry direction. OwnTone: `int player_device_add(void *)`. */
int
player_device_add(void *device);

int
player_device_remove(void *device);

/* Remote-control -> transport. No-ops for the audio-only sender. */
int
player_playback_start(void);

int
player_playback_pause(void);

int
player_playback_next(void);

int
player_playback_prev(void);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_PLAYER_H */

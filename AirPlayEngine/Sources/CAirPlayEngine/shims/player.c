// SPDX-License-Identifier: GPL-2.0-or-later
//
// player.c — device add/remove shims (T-SHIM-2).
//
// player_device_add / player_device_remove are PORTED from OwnTone's player.c
// (GPL-2.0-or-later): specifically the bodies of device_add() (player.c:1392)
// and device_remove_family() (player.c:1415), which are what OwnTone's
// player_device_add/remove ultimately dispatch to via commands_exec_async.
//
// KEY ADAPTATION: OwnTone bounces these onto the player thread through the
// command queue (commands_exec_async). Our engine has no separate player
// thread + command dispatcher — discovery (Swift addOutput/removeOutput,
// seam-map §4) already runs on, or marshals onto, the single engine thread that
// owns evbase_player (seam-map §8). So we run the registry mutation SYNCHRONOUSLY
// here. The status_update() calls (player listener notifications) are dropped —
// device-list change events are surfaced to Swift by the app layer that drove
// discovery, not from inside the C cluster.
//
// The playback controls + player_get_status remain audio-only-sender no-ops
// (seam-map §3.6): airplay_events.c's receiver->sender remote-control path has
// nothing to drive in a one-way audio sender.

#include "player.h"
#include "outputs.h" /* outputs_device_add/get/remove/free + struct output_device */
#include "logger.h"
#include "engine_bridge.h" /* airplayengine_remote_fire — receiver->sender path */

#include <stdlib.h>
#include <string.h>

int
player_get_status(struct player_status *status)
{
  if (status)
    memset(status, 0, sizeof(*status));
  // Audio-only sender: no transport state to reflect. PLAY_STOPPED (0 here)
  // is a safe answer; airplay_events.c only compares against PLAY_PLAYING.
  return 0;
}

int
player_device_add(void *device)
{
  struct output_device *add = device;
  struct output_device *canonical;

  if (!add)
    return -1;

  // new_deselect (OwnTone: "never turn on new devices during playback") is
  // irrelevant for the engine's single-purpose model — pass false. Ownership of
  // `add` transfers to the registry (or it's merged into the existing entry).
  canonical = outputs_device_add(add, false);
  if (!canonical)
    return -1;

  return 0;
}

int
player_device_remove(void *device)
{
  struct output_device *remove = device;
  struct output_device *dev;

  if (!remove)
    return -1;

  dev = outputs_device_get(remove->id);
  if (!dev)
    {
      DPRINTF(E_WARN, L_PLAYER, "Device '%s' stopped advertising, but not in our list\n",
              remove->name ? remove->name : "(unknown)");
      outputs_device_free(remove);
      return 0;
    }

  // v{4,6}_port non-zero on `remove` indicates that address family stopped
  // advertising (airplay.c sets it before calling us).
  if (remove->v4_port && dev->v4_address)
    {
      free(dev->v4_address);
      dev->v4_address = NULL;
      dev->v4_port = 0;
    }

  if (remove->v6_port && dev->v6_address)
    {
      free(dev->v6_address);
      dev->v6_address = NULL;
      dev->v6_port = 0;
    }

  if (!dev->v4_address && !dev->v6_address)
    {
      dev->advertised = 0;

      // If there's a live session, keep the device until the backend reports a
      // failure (the dispatcher then removes it — see outputs.c drain). With no
      // session, remove now.
      if (!dev->session)
        outputs_device_remove(dev);
    }

  outputs_device_free(remove);

  return 0;
}

// The receiver->sender remote-control path (airplay_events.c handle_event) used
// to dead-end here in no-ops. It now forwards to the app via the engine bridge:
// the user pressed a transport key ON THE SPEAKER, which we turn into a Mac
// media key upstream so the actual media app (Spotify/Music/…) responds.
//
// handle_event() collapses the device's play AND pause into player_playback_start
// (player_get_status is always PLAY_STOPPED for an audio-only sender, so the
// "if PLAYING -> pause else -> start" branch always starts), and macOS exposes a
// single Play/Pause TOGGLE media key anyway — so start and pause both map to
// AIRPLAYENGINE_REMOTE_PLAYPAUSE. device_id is 0 (transport is global: one Mac
// media session) and volume is -1 (unused for transport).
int
player_playback_start(void) { airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PLAYPAUSE, -1.0); return 0; }

int
player_playback_pause(void) { airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PLAYPAUSE, -1.0); return 0; }

int
player_playback_next(void) { airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_NEXT, -1.0); return 0; }

int
player_playback_prev(void) { airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PREVIOUS, -1.0); return 0; }

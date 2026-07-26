// SPDX-License-Identifier: GPL-2.0-or-later
//
// CAirPlayEngine — umbrella header for the vendored+shimmed AirPlay 2 sender
// C target. See AirPlayEngine/README.md and AirPlayEngine/docs/seam-map.md
// for the full extraction blueprint.
//
// T-PKG-1 (scaffold only): this header currently exposes only the shim
// surfaces (which compile as standalone declarations). The vendored sender
// sources (sender/airplay.c etc.) are NOT yet wired to build cleanly against
// these shims — that is T-BUILD-1 (compile) + T-SHIM-1 (implement the .c
// shim bodies). Once those land, this umbrella should also expose the
// engine's public C entry points that T-API-1's Swift wrapper calls
// (session start/stop, addOutput/removeOutput, writePCM, setVolume,
// clockStatus, pairing) — currently airplay.c's own outputs.h-shaped
// surface (shims/outputs.h) stands in for that.
//
// TODO(T-BUILD-1): confirm every header below actually compiles standalone
// against brew include paths (event2/, gcrypt.h, sodium.h, plist/plist.h)
// once Package.swift's unsafeFlags are filled in.
// TODO(T-SHIM-1): once shim .c files exist, this umbrella may need to add
// a narrower "public" vs "internal" split so Swift only sees the intended
// session API, not every OwnTone-shaped internal shim type.

#ifndef CAIRPLAYENGINE_H
#define CAIRPLAYENGINE_H

/* libevent threading support — exposes evthread_use_pthreads() to Swift.
 * EngineThread MUST enable this before creating its event_base so that
 * cross-thread event_base_once() wakes a loop blocked in kevent(). Found the
 * hard way at the gated first-light (2026-07-16): without it, enqueue() from
 * the Swift side is silently deferred until the keep-alive timer fires. */
#include <event2/thread.h>

/* Shim surfaces (T-SHIM-1 implements the .c bodies) */
#include "../shims/logger.h"
#include "../shims/misc.h"
#include "../shims/conffile.h"
#include "../shims/commands.h"
#include "../shims/player.h"
#include "../shims/db.h"
#include "../shims/artwork.h"
#include "../shims/dmap_common.h"
#include "../shims/mdns.h"
#include "../shims/transcode.h"
#include "../shims/ptpd.h"
#include "../shims/outputs.h"
#include "../shims/engine_bridge.h" /* T-API-1: non-static discovery-in bridge */
#include "../shims/engine_workgroup.h" /* T5: os_workgroup_join/leave, unreachable from Swift directly */

/* Vendored, license-labeled clusters (see docs/license-inventory.md):
 * - sender/   GPL-2.0-or-later  (the extracted AirPlay 2 sender)
 * - evrtsp/   BSD-3-Clause      (Provos 2002-2006, Blache 2010)
 * - pair_ap/  MIT               (AirPlay 2 pairing)
 * - libairptp/ MIT              (PTP clock library)
 *
 * TODO(T-BUILD-1): these are NOT included here yet — airplay.c etc. include
 * their OwnTone-relative headers directly (e.g. "evrtsp/evrtsp.h",
 * "pair_ap/pair.h", "rtp_common.h"); T-BUILD-1 resolves those via this
 * target's HeaderSearchPath settings in Package.swift rather than through
 * this umbrella header.
 */

#endif /* CAIRPLAYENGINE_H */

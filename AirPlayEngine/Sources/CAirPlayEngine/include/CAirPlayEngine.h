// SPDX-License-Identifier: GPL-2.0-or-later
//
// CAirPlayEngine — umbrella header for the vendored+shimmed AirPlay 2 sender
// C target. See AirPlayEngine/README.md and AirPlayEngine/docs/seam-map.md
// for the full extraction blueprint.
//
// What Swift sees through this umbrella: the shim headers below, plus
// engine_bridge.h (the non-static bridge the Swift layer calls) and
// engine_workgroup.h. The vendored sender, pairing, RTSP and PTP sources
// include their own headers through the target's header search paths, not
// through this file — so nothing vendored is exposed here.

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
 */

#endif /* CAIRPLAYENGINE_H */

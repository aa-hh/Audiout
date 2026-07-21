// SPDX-License-Identifier: GPL-2.0-or-later
//
// mdns.c — discovery-seam shim (T-BUILD-1 no-op; T-API-1 capture). Discovery is
// app-owned (Q5): the C-side mdns_browse never actually browses. Instead, when
// airplay_init calls mdns_browse("_airplay._tcp", airplay_device_cb, ...)
// (airplay.c:4342), we CAPTURE the (otherwise static, Swift-invisible)
// airplay_device_cb function pointer here. The engine bridge
// (shims/engine_bridge.c) then invokes it for each device the app's NWBrowser
// resolves — driving discovery IN without editing the GPL source (seam-map §4).
//
// [AirPlayEngine vendored change 2026-07-19] raop_init makes the identical call
// with "_raop._tcp"/raop_device_cb (raop-seam-brief §6.6) — a SECOND, distinct
// static callback the engine also cannot name directly. mdns_browse now keys
// the capture on `type` so both callbacks survive side by side regardless of
// init order (previously a single variable meant whichever backend called
// mdns_browse LAST would silently clobber the other's callback).

#include "mdns.h"
#include "engine_bridge.h"

#include <string.h>

/* The captured AP2 discovery callback (== airplay_device_cb, "_airplay._tcp").
 * NULL until airplay_init runs mdns_browse. Read on the engine thread only
 * (seam-map §8). */
mdns_browse_cb airplayengine_device_cb = NULL;

/* The captured AP1/RAOP discovery callback (== raop_device_cb, "_raop._tcp").
 * NULL until raop_init runs mdns_browse. Read on the engine thread only. */
mdns_browse_cb airplayengine_raop_device_cb = NULL;

int
mdns_browse(char *type, mdns_browse_cb cb, enum mdns_options flags)
{
  (void)flags;
  // Capture the sender's device callback so the engine bridge can feed
  // app-resolved descriptors into it. No real mDNS browse is started.
  if (type && strcmp(type, "_raop._tcp") == 0)
    airplayengine_raop_device_cb = cb;
  else
    airplayengine_device_cb = cb;
  return 0;
}

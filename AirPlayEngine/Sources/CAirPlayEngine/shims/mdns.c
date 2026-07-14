// SPDX-License-Identifier: GPL-2.0-or-later
//
// mdns.c — discovery-seam shim (T-BUILD-1 no-op; T-API-1 capture). Discovery is
// app-owned (Q5): the C-side mdns_browse never actually browses. Instead, when
// airplay_init calls mdns_browse("_airplay._tcp", airplay_device_cb, ...)
// (airplay.c:4342), we CAPTURE the (otherwise static, Swift-invisible)
// airplay_device_cb function pointer here. The engine bridge
// (shims/engine_bridge.c) then invokes it for each device the app's NWBrowser
// resolves — driving discovery IN without editing the GPL source (seam-map §4).

#include "mdns.h"
#include "engine_bridge.h"

/* The captured discovery callback (== airplay_device_cb). NULL until airplay_init
 * runs mdns_browse. Read on the engine thread only (seam-map §8). */
mdns_browse_cb airplayengine_device_cb = NULL;

int
mdns_browse(char *type, mdns_browse_cb cb, enum mdns_options flags)
{
  (void)type;
  (void)flags;
  // Capture the sender's device callback so the engine bridge can feed
  // app-resolved descriptors into it. No real mDNS browse is started.
  airplayengine_device_cb = cb;
  return 0;
}

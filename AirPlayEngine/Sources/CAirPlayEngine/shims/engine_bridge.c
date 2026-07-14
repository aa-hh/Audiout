// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_bridge.c — the thin non-static C surface the Swift wrapper drives
// (T-API-1). See engine_bridge.h for the rationale. Runs on the engine thread.

#include "engine_bridge.h"
#include "mdns.h"

/* Defined in shims/mdns.c: the captured airplay_device_cb (set when
 * airplay_init calls mdns_browse). NULL until init has run. */
extern mdns_browse_cb airplayengine_device_cb;

bool
airplayengine_discovery_ready(void)
{
  return airplayengine_device_cb != NULL;
}

int
airplayengine_feed_device(const char *name, const char *hostname, int family,
                          const char *address, int port, struct keyval *txt)
{
  if (!airplayengine_device_cb)
    return -1;

  // Same shape airplay_init registered with mdns_browse. domain "local" and
  // type "_airplay._tcp" match what a real DNS-SD browse would deliver;
  // airplay_device_cb reads name/family/address/port/txt (seam-map §4).
  airplayengine_device_cb(name, "_airplay._tcp", "local", hostname,
                          family, address, port, txt);
  return 0;
}

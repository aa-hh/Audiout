// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_bridge.c — the thin non-static C surface the Swift wrapper drives
// (T-API-1). See engine_bridge.h for the rationale. Runs on the engine thread.

#include "engine_bridge.h"
#include "mdns.h"

#include <gcrypt.h>
#include <sodium.h>

/* Defined in shims/mdns.c: the captured airplay_device_cb (set when
 * airplay_init calls mdns_browse). NULL until init has run. */
extern mdns_browse_cb airplayengine_device_cb;

int
engine_crypto_init(void)
{
  // The app-side libgcrypt init pair_ap's is_initialized() checks for
  // (engine_bridge.h has the full story). Mirrors OwnTone's main():
  // version check (NULL = no minimum), no secure memory (we hold no
  // long-lived secrets), then mark initialization finished.
  if (!gcry_check_version(NULL))
    return -1;
  gcry_control(GCRYCTL_DISABLE_SECMEM, 0);
  gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

  if (sodium_init() == -1)
    return -1;

  return 0;
}

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

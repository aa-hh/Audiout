// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_bridge.c — the thin non-static C surface the Swift wrapper drives
// (T-API-1). See engine_bridge.h for the rationale. Runs on the engine thread.

#include "engine_bridge.h"
#include "mdns.h"

#include <gcrypt.h>
#include <signal.h>
#include <sodium.h>

/* Defined in shims/mdns.c: the captured airplay_device_cb (set when
 * airplay_init calls mdns_browse). NULL until init has run. */
extern mdns_browse_cb airplayengine_device_cb;

/* Defined in shims/mdns.c: the captured raop_device_cb (set when raop_init
 * calls mdns_browse("_raop._tcp", ...)). NULL until raop_init has run. */
extern mdns_browse_cb airplayengine_raop_device_cb;

void
engine_mask_sigpipe(void)
{
  // OwnTone's main() masks SIGPIPE process-wide before spawning any
  // threads (main.c:718-732) so a write() to a peer that has closed its
  // end of an RTSP/data socket returns EPIPE instead of killing the
  // process. Our hosting never ran that step (first-light backlog #2) —
  // do it here, on the engine thread, before airplay_init opens any
  // sockets. SIG_IGN disposition is process-wide (not per-thread), so
  // one call covers every thread/socket the engine creates.
  signal(SIGPIPE, SIG_IGN);
}

/* Minimum libgcrypt version. gcry_check_version(NULL) accepts ANY installed
 * libgcrypt, defeating the whole point of the call (it exists to REFUSE a
 * runtime library too old for the ABI/features the app was built against).
 * pair_ap and the sender cluster use the modern AEAD/ECC surface; 1.8.0
 * (2017) is the conservative floor OwnTone-era builds already assumed and is
 * comfortably below any libgcrypt this decade. Passing a real string also runs
 * libgcrypt's mandatory "must be called before any other function" init side
 * effect, same as NULL did. (first-light hardening #5) */
#define ENGINE_GCRYPT_MIN_VERSION "1.8.0"

int
engine_crypto_init(void)
{
  // The app-side libgcrypt init pair_ap's is_initialized() checks for
  // (engine_bridge.h has the full story). Mirrors OwnTone's main():
  // version floor enforced (returns NULL if the runtime libgcrypt is older
  // than ENGINE_GCRYPT_MIN_VERSION), no secure memory (we hold no long-lived
  // secrets), then mark initialization finished.
  if (!gcry_check_version(ENGINE_GCRYPT_MIN_VERSION))
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

/* [AirPlayEngine vendored change 2026-07-19] RAOP analogue of
 * airplayengine_feed_device above (raop-seam-brief §6.6) — mirrors its shape
 * exactly, targeting the captured raop_device_cb instead. */
bool
airplayengine_raop_discovery_ready(void)
{
  return airplayengine_raop_device_cb != NULL;
}

int
airplayengine_feed_raop_device(const char *name, const char *hostname, int family,
                               const char *address, int port, struct keyval *txt)
{
  if (!airplayengine_raop_device_cb)
    return -1;

  // Same shape raop_init registered with mdns_browse. domain "local" and type
  // "_raop._tcp" match what a real DNS-SD browse would deliver; raop_device_cb
  // reads name/family/address/port/txt the same way airplay_device_cb does.
  airplayengine_raop_device_cb(name, "_raop._tcp", "local", hostname,
                               family, address, port, txt);
  return 0;
}

// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_bridge — SHIM (T-API-1). The thin non-static C surface the Swift
// wrapper (Sources/AirPlayEngine) calls to drive the vendored sender cluster.
//
// WHY THIS EXISTS. The sender's four "verbs" the Swift layer needs to invoke
// are split across two kinds of C symbols:
//
//   1. output_airplay (the struct output_definition, airplay.c:4385) — a
//      NON-static global. Its .init/.deinit/.device_start/.device_stop/
//      .device_volume_set/.device_cb_set/.write function pointers reach the
//      static airplay_* implementations. Swift CAN take output_airplay and call
//      through those pointers, so those verbs need NO bridge.
//
//   2. airplay_device_cb (airplay.c:3927) — the discovery-IN entry point — is
//      STATIC, so Swift cannot name it. BUT airplay_init hands it to
//      mdns_browse("_airplay._tcp", airplay_device_cb, ...) (airplay.c:4342).
//      Our mdns_browse shim (shims/mdns.c) therefore RECEIVES that static
//      function pointer at init time. We capture it there and expose it here as
//      airplayengine_feed_device(). This drives discovery IN (seam-map §4)
//      WITHOUT editing the GPL vendored source at all.
//
// Everything here runs on the engine thread (seam-map §8, risk R-B). The Swift
// wrapper marshals every call onto that thread; this header just declares the
// C surface — it does no threading itself.

#ifndef CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H
#define CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#include "misc.h"    /* struct keyval */
#include "mdns.h"    /* mdns_browse_cb (== airplay_device_cb's signature) */
#include "outputs.h" /* struct output_definition, struct event_base */

#ifdef __cplusplus
extern "C" {
#endif

/* The single backend the engine ships (struct output_definition output_airplay,
 * airplay.c:4385). NON-static, so Swift can take it and call through its
 * .init / .deinit / .device_start / .device_stop / .device_volume_set /
 * .device_cb_set / .write function pointers directly — those are the session
 * verbs (seam-map §2.1). Declared here so the Swift wrapper sees it via the
 * umbrella header (airplay.c has no public header of its own). */
extern struct output_definition output_airplay;

/* The player thread's libevent base (airplay.c:459, defined in shims/outputs.c).
 * The Swift wrapper sets this to the engine thread's event_base BEFORE
 * airplay_init, then calls outputs_dispatcher_init() (seam-map §8, risk R-B). */
extern struct event_base *evbase_player;

/* True once airplay_init has run and mdns_browse captured the device callback.
 * Discovery feeds are dropped (return false) before this. */
bool
airplayengine_discovery_ready(void);

/* Feed a resolved device descriptor into the sender's discovery path — this is
 * the app-owned NWBrowser -> engine seam (seam-map §4). It calls the captured
 * airplay_device_cb(name, "_airplay._tcp", "local", hostname, family, address,
 * port, txt) exactly as OwnTone's mDNS browse would have. `port > 0` = device
 * appeared/updated; `port < 0` = device disappeared (removal, matched by name).
 *
 * `txt` is a keyval built by the caller from the DNS-SD TXT record (deviceid,
 * features, model — seam-map §4). Ownership stays with the caller; the cb reads
 * it synchronously and does not retain it.
 *
 * Returns 0 if delivered, -1 if discovery isn't ready yet (init not run).
 * MUST be called on the engine thread. */
int
airplayengine_feed_device(const char *name, const char *hostname, int family,
                          const char *address, int port, struct keyval *txt);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H */

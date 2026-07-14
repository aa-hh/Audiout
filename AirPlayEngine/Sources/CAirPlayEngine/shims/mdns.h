// SPDX-License-Identifier: GPL-2.0-or-later
//
// mdns — SHIM/CUT (discovery seam). Replaces OwnTone's src/mdns.h.
//
// Implements: docs/seam-map.md §3.5 + §4. RESOLVED DECISIONS Q5: app/NWBrowser
// owns discovery; the engine receives resolved descriptors. In the vendored
// cluster mdns.h is referenced in exactly ONE place: airplay_init calls
//   mdns_browse("_airplay._tcp", airplay_device_cb, MDNS_CONNECTION_TEST)
// (airplay.c:4342). mdns_init/register/cname are never called.
//
// T-BUILD-1 approach: rather than surgically delete the call site (which risks
// altering the GPL source more than needed), we keep the call but shim
// mdns_browse to a NO-OP that returns 0 (success, "no devices from mDNS").
// Discovery instead flows in through the engine's Swift-facing addOutput/
// removeOutput entries (T-API-1), which invoke airplay_device_cb() directly
// with a resolved descriptor — matching mdns_browse_cb's signature. The C-side
// browse simply never fires, which is exactly the intent of cutting mdns.
//
// The mdns_browse_cb typedef and MDNS_CONNECTION_TEST value are copied VERBATIM
// from OwnTone src/mdns.h (note MDNS_CONNECTION_TEST = (1 << 1), which the
// T-PKG-1 scaffold had as (1 << 0)).
//
// STUB STATUS (T-BUILD-1): mdns.c provides mdns_browse as a no-op returning 0.
// TODO(T-API-1): the Swift addOutput/removeOutput path calls airplay_device_cb
// directly; the C-side mdns_browse stub stays a no-op forever.

#ifndef CAIRPLAYENGINE_SHIM_MDNS_H
#define CAIRPLAYENGINE_SHIM_MDNS_H

#include "misc.h" /* struct keyval */

#ifdef __cplusplus
extern "C" {
#endif

enum mdns_options
{
  MDNS_CONNECTION_TEST = (1 << 1),
  MDNS_IPV4ONLY        = (1 << 2),
};

typedef void (* mdns_browse_cb)(const char *name, const char *type, const char *domain, const char *hostname, int family, const char *address, int port, struct keyval *txt);

/* No-op in this shim (discovery is app-owned) — always returns 0. */
int
mdns_browse(char *type, mdns_browse_cb cb, enum mdns_options flags);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_MDNS_H */

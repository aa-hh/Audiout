// SPDX-License-Identifier: GPL-2.0-or-later
//
// ptpd — SHIM (reimplemented on airptp_*). Replaces OwnTone's src/ptpd.h.
//
// Implements: docs/seam-map.md §3.9 + §6. airplay.c never calls airptp_*
// directly; it goes through this thin wrapper. Per seam-map §6, OwnTone's
// ptpd.c (135 LOC) is nearly verbatim reusable — it only calls airptp_*
// (this package's vendored libairptp/), logger, cfg_getstr(general.
// bind_address), and thread_setname. We ADAPT it into shims/ptpd.c (its
// includes point at our shims).
//
// SIGNATURES ARE COPIED FROM OwnTone src/ptpd.h VERBATIM — note:
//   ptpd_clock_id_get() -> uint64_t
//   ptpd_slave_add(uint32_t *slave_id, const char *addr) -> int
//   ptpd_slave_remove(uint32_t slave_id) -> void
//   ptpd_find_or_bind() -> int          (the ONLY privileged step: binds
//                                         UDP 319/320; see T-HELPER-DESIGN-1)
//   ptpd_init(uint64_t clock_id_seed) -> int
//   ptpd_deinit() -> void
// (the T-PKG-1 scaffold had these wrong — int*/int-return; corrected here.)
//
// STUB STATUS (T-BUILD-1): shims/ptpd.c is a REAL adaptation of OwnTone's
// ptpd.c (it links against the vendored libairptp cluster, which compiles).
// This is a full port, not a no-op stub, because ptpd.c has no OwnTone-
// plumbing entanglement beyond logger + cfg + thread_setname (all shimmed).
// It does NOT run anything at build time — T-BUILD-1 is compile+link only.
//
// DEFERRED LOOKUP CONTRACT (T2b, docs/ptp-helper-design.md §1.3/§5.1-5.2):
// the root helper daemon is demand-started (starts on the user's first
// connect, not at engine launch), so "no daemon found" is never permanent.
//   - ptpd_init() ALWAYS returns 0, even with no daemon found yet — it must
//     never latch airplay.c's airplay_ptp_is_disabled, which would
//     permanently disable PTP for every device discovered afterwards.
//   - ptpd_clock_id_get() / ptpd_slave_add() lazily retry
//     airptp_daemon_find() themselves whenever the module-global ptpd_hdl
//     is still NULL (single-assignment: once found, cached until
//     ptpd_deinit()), so a helper that starts after ptpd_init() ran is
//     still picked up at actual connect/session time. On failure they
//     return their pre-existing sentinels ((uint64_t)-1 / non-zero) rather
//     than crash — libairptp's airptp_clock_id_get()/airptp_peer_add()
//     dereference the handle immediately with no NULL check of their own.
//   - ptpd_slave_remove() only NULL-guards (no lazy find — removing a slave
//     that was never added is correctly a no-op).

#ifndef CAIRPLAYENGINE_SHIM_PTPD_H
#define CAIRPLAYENGINE_SHIM_PTPD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t
ptpd_clock_id_get(void);

int
ptpd_slave_add(uint32_t *slave_id, const char *addr);

void
ptpd_slave_remove(uint32_t slave_id);

// Looks for a shared airptpd daemon. If not found, binds privileged ports 319
// and 320, so must be called before the server drops privileges.
int
ptpd_find_or_bind(void);

int
ptpd_init(uint64_t clock_id_seed);

void
ptpd_deinit(void);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_PTPD_H */

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

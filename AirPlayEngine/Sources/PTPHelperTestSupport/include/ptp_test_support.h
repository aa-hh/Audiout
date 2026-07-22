// SPDX-License-Identifier: MIT
//
// ptp_test_support — a thin, TEST-ONLY C shim (T7, ptp-helper-design.md
// §6.2) that re-exposes Clibairptp's airptp_* API as a Swift-visible module.
//
// WHY THIS EXISTS: Clibairptp/module.modulemap deliberately declares
// airptp.h as a `textual header` (see that file's own comment) so the
// vendored, byte-identical airptp.h - which uses `bool` without including
// <stdbool.h> - can pass Clang's modular self-containment check. A textual
// header is never part of a module's Swift-visible interface, so
// `import Clibairptp` alone does not give Swift access to airptp_*. This
// header is a NORMAL modular header (self-contained: only <inttypes.h> +
// <stdbool.h>, mirroring what the vendored airptp.h needs) that forwards
// 1:1 to the real airptp_* calls, purely so a Swift test target can drive
// them. No vendored source is touched.
//
// This is a pass-through only - no logic of its own beyond the forward.
// Every function here has an identical signature to its airptp_* twin in
// libairptp/airptp.h.

#ifndef __PTP_TEST_SUPPORT_H__
#define __PTP_TEST_SUPPORT_H__

#include <inttypes.h>
#include <stdbool.h>

// Opaque, same tag as airptp.h's `struct airptp_handle` - never defined
// here, only forwarded by pointer.
struct airptp_handle;

void
ptp_test_ports_override(unsigned short event_port, unsigned short general_port);

void
ptp_test_shm_name_override(const char *name);

struct airptp_handle *
ptp_test_daemon_bind(const char *node);

int
ptp_test_daemon_start(struct airptp_handle *hdl, uint64_t clock_id_seed, bool is_shared);

struct airptp_handle *
ptp_test_daemon_find(void);

int
ptp_test_peer_add(uint32_t *peer_id, const char *addr, struct airptp_handle *hdl);

void
ptp_test_peer_remove(uint32_t peer_id, struct airptp_handle *hdl);

void
ptp_test_end(struct airptp_handle *hdl);

int
ptp_test_clock_id_get(uint64_t *clock_id, struct airptp_handle *hdl);

const char *
ptp_test_errmsg_get(void);

#endif // __PTP_TEST_SUPPORT_H__

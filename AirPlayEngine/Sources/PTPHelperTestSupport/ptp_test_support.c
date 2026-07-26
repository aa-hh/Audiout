// SPDX-License-Identifier: MIT
//
// See include/ptp_test_support.h for why this shim exists (T7). Pure
// pass-through to the real Clibairptp entry points - "airptp.h" here
// resolves to the vendored, byte-identical header via Clibairptp's own
// publicHeadersPath "." (SwiftPM adds it automatically for a dependent
// target, same as Sources/ptp-helper/main.c's own comment on this).

#include <stdbool.h>
#include "airptp.h"
#include "ptp_test_support.h"

void
ptp_test_ports_override(unsigned short event_port, unsigned short general_port)
{
  airptp_ports_override(event_port, general_port);
}

void
ptp_test_shm_name_override(const char *name)
{
  airptp_shm_name_override(name);
}

struct airptp_handle *
ptp_test_daemon_bind(const char *node)
{
  return airptp_daemon_bind(node);
}

int
ptp_test_daemon_start(struct airptp_handle *hdl, uint64_t clock_id_seed, bool is_shared)
{
  return airptp_daemon_start(hdl, clock_id_seed, is_shared);
}

struct airptp_handle *
ptp_test_daemon_find(void)
{
  return airptp_daemon_find();
}

int
ptp_test_peer_add(uint32_t *peer_id, const char *addr, struct airptp_handle *hdl)
{
  return airptp_peer_add(peer_id, addr, hdl);
}

void
ptp_test_peer_remove(uint32_t peer_id, struct airptp_handle *hdl)
{
  airptp_peer_remove(peer_id, hdl);
}

int
ptp_test_peer_active_count(struct airptp_handle *hdl)
{
  return airptp_peer_active_count(hdl);
}

void
ptp_test_end(struct airptp_handle *hdl)
{
  airptp_end(hdl);
}

int
ptp_test_clock_id_get(uint64_t *clock_id, struct airptp_handle *hdl)
{
  return airptp_clock_id_get(clock_id, hdl);
}

const char *
ptp_test_errmsg_get(void)
{
  return airptp_errmsg_get();
}

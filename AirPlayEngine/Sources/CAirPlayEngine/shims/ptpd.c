/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 * ----
 *
 * ptpd.c — ADAPTED from OwnTone's src/ptpd.c (T-BUILD-1 / seam-map §3.9, §6).
 * This is a near-verbatim port of OwnTone's ptpd wrapper: the ONLY changes are
 * that its includes point at this package's vendored libairptp/airptp.h and our
 * shims (logger.h, misc.h for thread_setname, conffile.h). It has no other
 * OwnTone-plumbing entanglement. It is a REAL implementation (not a stub) — but
 * T-BUILD-1 only compiles+links it; nothing here runs at build time.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdint.h>

#include "libairptp/airptp.h"
#include "misc.h"     /* thread_setname */
#include "logger.h"
#include "conffile.h"
#include "ptpd.h"

static struct airptp_handle *ptpd_hdl;
static bool airptp_create_own_service = false;

static void
logmsg(const char *fmt, ...)
{
  char fmt_newline[1024];
  va_list ap;

  snprintf(fmt_newline, sizeof(fmt_newline), "%s\n", fmt);

  va_start(ap, fmt);
  DVPRINTF(E_DBG, L_AIRPLAY, fmt_newline, ap);
  va_end(ap);
}

static void
hexdump(const char *msg, uint8_t *mem, size_t len)
{
  DHEXDUMP(E_DBG, L_AIRPLAY, mem, (int)len, msg);
}

// T2b (deferred PTP lookup): ptpd_init() no longer latches "unavailable"
// just because the helper daemon hadn't started yet, so ptpd_hdl can still
// be NULL the first time a call reaches here (session/slave setup, not
// engine startup). Retry the find lazily rather than trusting the earlier
// verdict — the helper is demand-started (spins up on the user's first
// connect), so it may well be up by now. Once found, ptpd_hdl is cached for
// the rest of the process (same single-assignment discipline as
// ptpd_init()); only ptpd_deinit() clears it. If still not found, fall back
// to the existing failure sentinel instead of dereferencing a NULL handle —
// airptp_clock_id_get()/airptp_peer_add() read hdl->state immediately with
// no NULL check of their own.
uint64_t
ptpd_clock_id_get(void)
{
  uint64_t clock_id;
  int ret;

  if (!ptpd_hdl)
    ptpd_hdl = airptp_daemon_find();
  if (!ptpd_hdl)
    return (uint64_t)-1;

  ret = airptp_clock_id_get(&clock_id, ptpd_hdl);
  return (ret == 0) ? clock_id : (uint64_t)-1;
}

// T2b: see ptpd_clock_id_get() above — same lazy-find + NULL-guard reasoning.
int
ptpd_slave_add(uint32_t *slave_id, const char *addr)
{
  if (!ptpd_hdl)
    ptpd_hdl = airptp_daemon_find();
  if (!ptpd_hdl)
    return -1;

  return airptp_peer_add(slave_id, addr, ptpd_hdl);
}

// T2b: NULL guard only (no lazy find — removing a slave that was never
// added because no clock was ever found is correctly a no-op, not a reason
// to start probing for a daemon). airptp_peer_remove() also reads
// hdl->state immediately with no NULL check of its own.
void
ptpd_slave_remove(uint32_t slave_id)
{
  if (!ptpd_hdl)
    return;

  airptp_peer_remove(slave_id, ptpd_hdl);
}

// T4 (PLAN-AIRPLAY-COEXISTENCE.md; ptp-helper-design.md §5.1/§5.2): a
// connect-time readiness check for the app side to poll while it waits for
// the on-demand helper it just woke over the Mach service. Deliberately its
// OWN local handle, never the module-global ptpd_hdl: ptpd_find_or_bind()
// would overwrite that global (and log "Using host's ptp daemon" every
// call), which this probe must not do — it only answers "is a shared daemon
// up right now", it does not adopt one. airptp_daemon_find() already
// validates the version and the 15s heartbeat, so a successful find IS the
// readiness signal; airptp_end() on a find()'d (non-daemon) handle just
// frees the local struct, touching no shared state (see airptp_end()).
int
ptpd_daemon_probe(void)
{
  struct airptp_handle *hdl = airptp_daemon_find();

  if (!hdl)
    return -1;

  airptp_end(hdl);
  return 0;
}

// Thread: main (normal privileges in the shipped find-only path; root only
// under the AUDIOUTER_PTP_INPROC_BIND dev fallback below)
//
// FIND-ONLY BY DEFAULT (T3): the shipped path never binds 319/320 itself — a
// separate root launchd helper (T-elsewhere) owns that in is_shared mode, and
// this engine is just its client. Set AUDIOUTER_PTP_INPROC_BIND=1 to restore
// the old in-process root-bind fallback for sudo/dev live-testing when no
// helper is installed yet; leave it unset for the shipped default.
int
ptpd_find_or_bind(void)
{
  struct airptp_callbacks cb = { .logmsg = logmsg, .hexdump = hexdump, .thread_name_set = thread_setname };
  const char *bind_address = cfg_getstr(cfg_getsec(cfg, "general"), "bind_address");

  if (bind_address && strcmp(bind_address, "::") == 0)
    bind_address = NULL;

  airptp_callbacks_register(&cb);

  // Check if the host has an instance of airptp running we can use, otherwise
  // fall back per AUDIOUTER_PTP_INPROC_BIND (see comment above)
  ptpd_hdl = airptp_daemon_find();
  if (ptpd_hdl)
    {
      DPRINTF(E_INFO, L_AIRPLAY, "Using host's ptp daemon\n");
      return 0;
    }

  if (!getenv("AUDIOUTER_PTP_INPROC_BIND"))
    {
      DPRINTF(E_LOG, L_AIRPLAY, "PTP daemon not found; running clock-unavailable (no in-process bind)\n");
      return -1;
    }

  DPRINTF(E_INFO, L_AIRPLAY, "Creating own ptp service\n");
  airptp_create_own_service = true;
  ptpd_hdl = airptp_daemon_bind(bind_address);
  if (!ptpd_hdl)
    {
      DPRINTF(E_LOG, L_AIRPLAY, "%s\n", airptp_errmsg_get());
      return -1;
    }

  return 0;
}

// Thread: main (normal privileges)
//
// T2b (deferred PTP availability, AirPlayEngine/docs/ptp-helper-design.md
// §1.3/§5.1-5.2): the root helper is demand-started — NOT running yet at
// engine start, only spun up on the user's first connect — so "no daemon
// found" here is DEFERRED, not a verdict that PTP is unavailable for the
// life of the process. Returning 0 keeps the vendored airplay.c's
// airplay_ptp_is_disabled latch clear (it is set only when this returns
// < 0), so every PTP-capable device discovered afterwards still gets
// use_ptp=1; the real lookup is retried lazily, once per process until it
// succeeds, by ptpd_clock_id_get()/ptpd_slave_add() at actual
// connect/session time (see those functions below). The find attempt here
// is still made (best-effort — no cost if the daemon happens to already be
// up), it just no longer gates the return value.
int
ptpd_init(uint64_t clock_id_seed)
{
  struct airptp_callbacks cb = { .logmsg = logmsg, .hexdump = hexdump, .thread_name_set = thread_setname };
  int ret;

  airptp_callbacks_register(&cb);

  if (!ptpd_hdl)
    {
      ptpd_hdl = airptp_daemon_find();
      return 0;
    }
  else if (!airptp_create_own_service)
    return 0;

  ret = airptp_daemon_start(ptpd_hdl, clock_id_seed, false);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_AIRPLAY, "%s\n", airptp_errmsg_get());
    }

  return 0;
}

// Thread: main (normal privileges)
//
// IDEMPOTENT (hosting-safety, T-ENG-SIGABRT-1): airptp_end() frees the handle
// but does NOT null the caller's pointer. In our hosting the vendored
// airplay_deinit() already calls ptpd_deinit() (airplay.c, "After freeing
// sessions, since that's where the active ptp peers get removed"), and the
// engine's stop() then calls ptpd_deinit() a second time for symmetry with the
// hosting-added ptpd_find_or_bind() in start(). Without this guard the second
// call re-entered daemon_stop() on an already-joined pthread (is_running never
// clears) and pthread_join() on a stale tid → SIGABRT (exit 134) at "Stopping
// airptp event loop". Nulling ptpd_hdl after airptp_end() makes every call
// after the first a clean no-op (airptp_end(NULL) returns immediately), and
// resets the bind-mode flag so a later start()/stop() cycle is well-defined.
void
ptpd_deinit(void)
{
  airptp_end(ptpd_hdl);
  ptpd_hdl = NULL;
  airptp_create_own_service = false;
}

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

uint64_t
ptpd_clock_id_get(void)
{
  uint64_t clock_id;
  int ret;

  ret = airptp_clock_id_get(&clock_id, ptpd_hdl);
  return (ret == 0) ? clock_id : (uint64_t)-1;
}

int
ptpd_slave_add(uint32_t *slave_id, const char *addr)
{
  return airptp_peer_add(slave_id, addr, ptpd_hdl);
}

void
ptpd_slave_remove(uint32_t slave_id)
{
  airptp_peer_remove(slave_id, ptpd_hdl);
}

// Thread: main (root privileges may be required for binding)
int
ptpd_find_or_bind(void)
{
  struct airptp_callbacks cb = { .logmsg = logmsg, .hexdump = hexdump, .thread_name_set = thread_setname };
  const char *bind_address = cfg_getstr(cfg_getsec(cfg, "general"), "bind_address");

  if (bind_address && strcmp(bind_address, "::") == 0)
    bind_address = NULL;

  airptp_callbacks_register(&cb);

  // Check if the host has an instance of airptp running we can use, otherwise
  // try to bind ourselves
  ptpd_hdl = airptp_daemon_find();
  if (ptpd_hdl)
    {
      DPRINTF(E_INFO, L_AIRPLAY, "Using host's ptp daemon\n");
      return 0;
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
int
ptpd_init(uint64_t clock_id_seed)
{
  struct airptp_callbacks cb = { .logmsg = logmsg, .hexdump = hexdump, .thread_name_set = thread_setname };
  int ret;

  airptp_callbacks_register(&cb);

  if (!ptpd_hdl)
    {
      ptpd_hdl = airptp_daemon_find();
      return ptpd_hdl ? 0 : -1;
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

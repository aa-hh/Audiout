// SPDX-License-Identifier: GPL-2.0-or-later
//
// logger — SHIM (1 of 10). Replaces OwnTone's src/logger.h.
//
// Implements: docs/seam-map.md §3.2 "logger — logger.h (SHIM, ~40 LOC)".
// DPRINTF is called ~137x across the vendored cluster (per seam-map §1);
// DVPRINTF is used by the ptpd shim's logmsg adapter; DHEXDUMP is used by
// rtp_common.c, airplay_events.c, and the ptpd shim. thread_setname is used
// by ptpd.c and airplay_events.c (declared in misc.h shim, not here).
//
// T-BUILD-1 grounding: the log-domain and severity constants below are copied
// VERBATIM from OwnTone's src/logger.h so that every DPRINTF(...,L_XXX,...)
// call site in the vendored cluster resolves. rtp_common.c uses L_PLAYER
// (the README "Known build gaps" item 4) in addition to L_AIRPLAY; keeping
// the full domain table is cheap and future-proofs any other domain a call
// site references. Signatures match OwnTone's exactly (note DHEXDUMP takes
// `int data_len`, not size_t).
//
// STUB STATUS (T-BUILD-1): the .c bodies (logger.c) are MINIMAL stubs so the
// link succeeds — DPRINTF/DVPRINTF/DHEXDUMP currently no-op (or write to
// stderr). T-SHIM-1 replaces them with the real os_log/stderr routing gated
// by an env log level, per seam-map §3.2.
//
// TODO(T-SHIM-1): implement real logging in logger.c (os_log / stderr,
// env-gated severity). Bodies are stubbed for T-BUILD-1's link only.

#ifndef CAIRPLAYENGINE_SHIM_LOGGER_H
#define CAIRPLAYENGINE_SHIM_LOGGER_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Log domains — verbatim from OwnTone src/logger.h so all L_* call sites in
 * the vendored cluster resolve (the cluster uses L_AIRPLAY and L_PLAYER). */
#define L_CONF        0
#define L_DAAP        1
#define L_DB          2
#define L_HTTPD       3
#define L_HTTP        4
#define L_MAIN        5
#define L_MDNS        6
#define L_MISC        7
#define L_RSP         8
#define L_SCAN        9
#define L_XCODE       10
#define L_EVENT       11
#define L_REMOTE      12
#define L_DACP        13
#define L_FFMPEG      14
#define L_ART         15
#define L_PLAYER      16
#define L_RAOP        17
#define L_LAUDIO      18
#define L_DMAP        19
#define L_DBPERF      20
#define L_SPOTIFY     21
#define L_SCROBBLE    22
#define L_CACHE       23
#define L_MPD         24
#define L_STREAMING   25
#define L_CAST        26
#define L_FIFO        27
#define L_LIB         28
#define L_WEB         29
#define L_AIRPLAY     30
#define L_RCP         31

#define N_LOGDOMAINS  32

/* Severities — verbatim from OwnTone src/logger.h. */
#define E_FATAL   0
#define E_LOG     1
#define E_WARN    2
#define E_INFO    3
#define E_DBG     4
#define E_SPAM    5

/* Signatures match OwnTone src/logger.h exactly. */
void
DPRINTF(int severity, int domain, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

void
DVPRINTF(int severity, int domain, const char *fmt, va_list ap);

void
DHEXDUMP(int severity, int domain, const unsigned char *data, int data_len, const char *heading);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_LOGGER_H */

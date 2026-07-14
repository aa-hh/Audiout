// SPDX-License-Identifier: GPL-2.0-or-later
//
// conffile — SHIM (3 of 10). Replaces OwnTone's src/conffile.h + the
// libconfuse (<confuse.h>) surface the vendored cluster reads through it.
//
// Implements: docs/seam-map.md §3.1 "conffile / cfg_* — every key airplay.c
// (+ptpd.c) reads, with default". OwnTone reads config via libconfuse: a
// global `cfg_t *cfg`, `cfg_getsec(cfg, "general")`, `cfg_getstr/getint/
// getbool`, `cfg_gettsec(cfg, "airplay", name)` for per-device overrides,
// `cfg_getopt(devcfg, "reconnect")` + `cfg_opt_getnbool(opt, 0)`. We do NOT
// vendor libconfuse — instead we provide our own trivial cfg_t/cfg_opt_t
// opaque types + accessors backed by a STATIC CONFIG STRUCT (T-SHIM-1), so
// no config file is read.
//
// EXACT call sites (grep at T-BUILD-1):
//   cfg_getstr(cfg_getsec(cfg,"general"),"user_agent")     airplay.c:4308
//   cfg_getstr(cfg_getsec(cfg,"library"),"name")           airplay.c:4309
//   cfg_getint(cfg_getsec(cfg,"airplay_shared"),"timing_port")  :4311
//   cfg_getint(cfg_getsec(cfg,"airplay_shared"),"control_port") :4319
//   cfg_getstr(cfg_getsec(cfg,"general"),"bind_address")   ptpd.c (find_or_bind)
//   cfg_gettsec(cfg,"airplay",name) + per-device cfg_getbool/getstr/getint
//   cfg_getopt(devcfg,"reconnect") + cfg_opt_getnbool(opt,0) :4102-4104
//
// STUB STATUS (T-BUILD-1): conffile.c bodies are MINIMAL — cfg_getsec/getstr/
// getint/getbool return safe defaults (the conffile.c defaults from seam-map
// §3.1), cfg_gettsec returns NULL (so all `if (devcfg && ...)` per-device
// override branches in airplay.c short-circuit), cfg_getopt returns NULL,
// cfg_opt_getnbool returns false. This is enough to LINK and run with pure
// defaults. T-SHIM-1 wires these to the real config struct populated from the
// Swift API.
//
// TODO(T-SHIM-1): back cfg_* with the static config struct, populated from
// the Swift AirPlayEngine session config (user_agent, client name, ports,
// bind address, per-device nickname/password/max_volume/ptp_disable).

#ifndef CAIRPLAYENGINE_SHIM_CONFFILE_H
#define CAIRPLAYENGINE_SHIM_CONFFILE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Stand-ins for libconfuse's cfg_t (a config section) and cfg_opt_t (a single
 * option). airplay.c mostly passes these as pointers, but it DOES read one
 * field: cfgopt->nvalues (airplay.c:4103, the "reconnect" tri-state check), so
 * cfg_opt_s must be a complete type exposing nvalues. cfg_t stays opaque. */
typedef struct cfg_s cfg_t;

typedef struct cfg_opt_s {
  unsigned int nvalues; /* libconfuse: number of set values for this option */
} cfg_opt_t;

/* Global root config handle — OwnTone declares `extern cfg_t *cfg;` here and
 * defines it in conffile.c. Same shape. */
extern cfg_t *cfg;

/* OwnTone's conffile.h also declares `extern uint64_t libhash;` (a hash of the
 * library name, defined in conffile.c). airplay.c uses it as the AirPlay device
 * id and the PTP clock-id seed (airplay.c:918/4291/4335). Provide it here. */
extern uint64_t libhash;

/* Section lookup. */
cfg_t *cfg_getsec(cfg_t *cfg, const char *name);
cfg_t *cfg_gettsec(cfg_t *cfg, const char *name, const char *title);

/* Value accessors (return the configured value or the built-in default).
 * cfg_getbool returns int (libconfuse's cfg_bool_t is an int-backed enum;
 * airplay.c only uses the result in a boolean context). */
char *cfg_getstr(cfg_t *sec, const char *name);
long int cfg_getint(cfg_t *sec, const char *name);
int cfg_getbool(cfg_t *sec, const char *name);

/* Option-level access for the "reconnect" tri-state (unset / true / false). */
cfg_opt_t *cfg_getopt(cfg_t *sec, const char *name);
int cfg_opt_getnbool(cfg_opt_t *opt, unsigned int index);

/* --- T-API-1 config setters (T-SHIM-2) ---
 * The in-memory config is populated from the Swift session config BEFORE
 * airplay_init runs. Strings passed here are NOT copied — the caller (the
 * Swift wrapper) must keep them alive for the engine's lifetime. */
void conffile_set_user_agent(const char *user_agent);
void conffile_set_library_name(const char *name);
void conffile_set_bind_address(const char *addr);   /* NULL = bind to any */
void conffile_set_ipv6(bool enabled);
void conffile_set_ports(long int timing_port, long int control_port);
void conffile_set_libhash(uint64_t h);              /* device id / PTP clock seed */

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_CONFFILE_H */

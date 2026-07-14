// SPDX-License-Identifier: GPL-2.0-or-later
//
// conffile.c — REAL in-memory config shim (T-SHIM-2).
//
// This is FRESH code (not ported from OwnTone — OwnTone's conffile.c wraps
// libconfuse + file parsing, which we deliberately do NOT vendor). It backs the
// cfg_* accessor surface with a single static config struct holding the global
// keys the vendored cluster reads at init, populated with the seam-map §3.1
// defaults. There is NO file parsing: T-API-1 mutates the struct (via
// conffile_set_*) from the Swift session config before airplay_init.
//
// Keys served (seam-map §3.1, "global / shared" scope — the ~16 keys airplay.c
// + ptpd.c + the net helpers read):
//   general.user_agent            str   "AirPlayEngine/0.1.0"
//   general.bind_address          str   NULL   (PTP bind addr; "::"->any)
//   general.ipv6                  bool  true    (attempt v6; needed for PTP v6 peers)
//   library.name                  str   "My Music on %h"
//   airplay_shared.timing_port    int   0       (ephemeral bind)
//   airplay_shared.control_port   int   0       (ephemeral bind)
//   (start_buffer_ms is served via outputs_buffer_duration_ms_get, not here.)
//
// Per-device (airplay.<name>) overrides: cfg_gettsec returns NULL, so every
// `if (devcfg && ...)` branch in airplay.c short-circuits to the built-in
// per-device defaults (max_volume=11, all bools off, nickname/password NULL).
// The engine surfaces per-device overrides through the Swift addOutput
// descriptor (seam-map §3.1 "Shim decision"), not through this config.
//
// TODO(seam-map §3.1 / T-API-1): derive `libhash` from the Swift-provided
// client/library name (OwnTone murmur-hashes the expanded library name — see
// conffile.c:475 upstream) so the AirPlay device id + PTP clock-id seed is
// stable and unique per install. conffile_set_libhash() is provided for that.

#include "conffile.h"

#include <stddef.h>
#include <string.h>

/* The one real backing struct. Global keys only (per-device is app-owned). */
struct conffile_config
{
  const char *user_agent;
  const char *library_name;
  const char *bind_address;
  int         ipv6;
  long int    timing_port;
  long int    control_port;
  long int    max_volume; /* per-device default, served when no override */
};

static struct conffile_config config = {
  .user_agent   = "AirPlayEngine/0.1.0", /* neutralized product name (SPEC §4) */
  .library_name = "My Music on %h",
  .bind_address = NULL,                  /* NULL => bind to any; ptpd maps "::"->NULL */
  .ipv6         = 1,                     /* attempt IPv6 (PTP peers may be link-local v6) */
  .timing_port  = 0,                     /* 0 => ephemeral bind */
  .control_port = 0,                     /* 0 => ephemeral bind */
  .max_volume   = 11,
};

/* cfg_s stays opaque in the header; a trivial complete type here. The two
 * sentinels below just need to be non-NULL so cfg_getsec(cfg, ...) chains are
 * safe (the section identity is irrelevant — the value accessors key on the
 * option name, and all our option names are globally unique). */
struct cfg_s { int _unused; };

static cfg_t cfg_root = { 0 };
cfg_t *cfg = &cfg_root;

static cfg_t cfg_section_sentinel = { 0 };

/* OwnTone derives libhash from the (expanded) library name via murmur_hash64
 * and uses it as the AirPlay device id + PTP clock-id seed (airplay.c:918/4291/
 * 4335). A fixed non-zero seed suffices until T-API-1 wires the real name. */
uint64_t libhash = 0x0123456789ABCDEFULL;

/* --- T-API-1 setters: populate the struct from the Swift session config. --- */

void
conffile_set_user_agent(const char *user_agent)
{
  if (user_agent)
    config.user_agent = user_agent;
}

void
conffile_set_library_name(const char *name)
{
  if (name)
    config.library_name = name;
}

void
conffile_set_bind_address(const char *addr)
{
  config.bind_address = addr; /* NULL is a valid value (bind to any) */
}

void
conffile_set_ipv6(bool enabled)
{
  config.ipv6 = enabled ? 1 : 0;
}

void
conffile_set_ports(long int timing_port, long int control_port)
{
  config.timing_port = timing_port;
  config.control_port = control_port;
}

void
conffile_set_libhash(uint64_t h)
{
  libhash = h;
}

/* -------------------------------- accessors ------------------------------- */

cfg_t *
cfg_getsec(cfg_t *sec, const char *name)
{
  (void)sec;
  (void)name;
  return &cfg_section_sentinel;
}

cfg_t *
cfg_gettsec(cfg_t *sec, const char *name, const char *title)
{
  (void)sec;
  (void)name;
  (void)title;
  // No per-device overrides in the in-memory config — short-circuits airplay.c's
  // `if (devcfg && ...)` branches to the per-device defaults.
  return NULL;
}

char *
cfg_getstr(cfg_t *sec, const char *name)
{
  (void)sec;
  if (!name)
    return NULL;

  if (strcmp(name, "user_agent") == 0)
    return (char *)config.user_agent;
  if (strcmp(name, "name") == 0)          // library.name
    return (char *)config.library_name;
  if (strcmp(name, "bind_address") == 0)  // general.bind_address (PTP + net_bind)
    return (char *)config.bind_address;

  return NULL;
}

long int
cfg_getint(cfg_t *sec, const char *name)
{
  (void)sec;
  if (!name)
    return 0;

  if (strcmp(name, "timing_port") == 0)
    return config.timing_port;
  if (strcmp(name, "control_port") == 0)
    return config.control_port;
  if (strcmp(name, "max_volume") == 0)    // per-device; default 11
    return config.max_volume;

  return 0;
}

int
cfg_getbool(cfg_t *sec, const char *name)
{
  (void)sec;
  if (!name)
    return 0;

  if (strcmp(name, "ipv6") == 0)
    return config.ipv6;

  // All per-device bool keys default to false/off (seam-map §3.1).
  return 0;
}

cfg_opt_t *
cfg_getopt(cfg_t *sec, const char *name)
{
  (void)sec;
  (void)name;
  // No option overrides — airplay.c's reconnect tri-state stays "unset".
  return NULL;
}

int
cfg_opt_getnbool(cfg_opt_t *opt, unsigned int index)
{
  (void)opt;
  (void)index;
  return 0;
}

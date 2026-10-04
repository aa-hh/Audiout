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
//   general.ipv6                  bool  false   (OwnTone's default; the Swift
//                                                EngineConfig re-enables it via
//                                                conffile_set_ipv6 before init)
//   library.name                  str   "My Music on %h"
//   airplay_shared.timing_port    int   0       (ephemeral bind)
//   airplay_shared.control_port   int   0       (ephemeral bind)
//   (start_buffer_ms is served via outputs_buffer_duration_ms_get, not here.)
//
// Per-device (airplay.<name>) overrides: a small table keyed by the name the
// vendored device callbacks pass to cfg_gettsec, filled by
// conffile_set_device_password from the Swift feedDescriptor. cfg_gettsec
// returns an entry's section only while it holds a password, so every other
// device still gets NULL and airplay.c/raop.c take their built-in per-device
// defaults. A returned section serves only the password; every other
// per-device key reads as its default (max_volume=11, bools off, nickname NULL).
// Reads and writes both run on the engine thread, so the table has no lock.
//
// `libhash` (the AirPlay device id + PTP clock-id seed) is derived in Swift
// from the client name and the install seed and pushed in through
// conffile_set_libhash() — AirPlayEngine.start does this before airplay_init.
// OwnTone instead murmur-hashes the expanded library name (conffile.c:475
// upstream); seam-map §3.1.

#include "conffile.h"
#include "logger.h"

#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* Unknown-key policy (first-light hardening #5). Historically every cfg_get*
 * accessor fell through to a silent `return 0/NULL` for a key it doesn't serve,
 * so a typo in a vendored call site (or a new upstream key the shim forgot to
 * add) would masquerade as "value is 0/empty" — a silent wrong default that is
 * exactly the class of bug the first-light audit flagged. Make the miss LOUD:
 * log at E_WARN so it shows up in Console/stderr, and assert() in debug builds
 * so a test/dev run trips immediately at the offending lookup. Release builds
 * (NDEBUG) still return the safe default after logging, so a stray lookup can
 * never crash a shipped session. */

/* Test/diagnostic counters (definitions for the extern decls in conffile.h). A
 * hermetic test flips conffile_unknown_key_assert to false so it can exercise
 * the log+default path deterministically WITHOUT the assert aborting the test
 * process, and reads conffile_unknown_key_count to confirm the miss fired. In
 * normal (non-test) operation the flag stays true and the assert bites in debug
 * builds. */
bool conffile_unknown_key_assert = true;
unsigned long conffile_unknown_key_count = 0;

static void
conffile_unknown_key(const char *accessor, const char *name)
{
  conffile_unknown_key_count++;
  DPRINTF(E_WARN, L_CONF,
          "conffile shim: %s asked for unknown key \"%s\" — returning default "
          "(add it to the shim if the vendored cluster needs it)\n",
          accessor, name ? name : "(null)");
  if (conffile_unknown_key_assert)
    assert(0 && "conffile shim: unknown config key requested (see log)");
}

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
  int         uncompressed_alac; /* airplay_shared.uncompressed_alac (RAOP) */
};

static struct conffile_config config = {
  .user_agent   = "AirPlayEngine/0.1.0", /* neutralized product name (SPEC §4) */
  .library_name = "My Music on %h",
  .bind_address = NULL,                  /* NULL => bind to any; ptpd maps "::"->NULL */
  .ipv6         = 0,                     /* OFF by default, matching OwnTone's own
                                          * general.ipv6=false (first-light hardening
                                          * #5). The Swift EngineConfig re-enables it
                                          * (default enableIPv6=true) via
                                          * conffile_set_ipv6() before airplay_init. */
  .timing_port  = 0,                     /* 0 => ephemeral bind */
  .control_port = 0,                     /* 0 => ephemeral bind */
  .max_volume   = 11,
  .uncompressed_alac = 1,                /* [AirPlayEngine vendored change
                                          * 2026-07-19] RAOP (sender/raop.c)
                                          * reads airplay_shared.uncompressed_alac
                                          * in raop_init. Default TRUE so the
                                          * AirPlay-1 send path uses raop.c's own
                                          * inline uncompressed-ALAC encoder and
                                          * never touches the ffmpeg encoder. */
};

/* cfg_s stays opaque in the header. The root and the sentinel just need to be
 * non-NULL so cfg_getsec(cfg, ...) chains are safe, and both keep a NULL
 * password; only a per-device section from the table below carries one. The
 * global value accessors key on the option name, which is globally unique. */
struct cfg_s { const char *password; };

static cfg_t cfg_root = { 0 };
cfg_t *cfg = &cfg_root;

static cfg_t cfg_section_sentinel = { 0 };

/* Per-device sections, keyed by the cfg_gettsec title. Entries are never
 * removed; a cleared entry keeps its name with a NULL password. */
struct conffile_device
{
  char *name;
  struct cfg_s section;
  struct conffile_device *next;
};

static struct conffile_device *conffile_devices = NULL;

static struct conffile_device *
conffile_device_find(const char *name)
{
  struct conffile_device *d;

  for (d = conffile_devices; d; d = d->next)
    if (strcmp(d->name, name) == 0)
      return d;
  return NULL;
}

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

void
conffile_set_device_password(const char *name, const char *password)
{
  struct conffile_device *d;

  if (!name)
    return;

  d = conffile_device_find(name);
  if (!d)
    {
      if (!password)
        return;
      d = calloc(1, sizeof(*d));
      if (!d)
        return;
      d->name = strdup(name);
      if (!d->name)
        {
          free(d);
          return;
        }
      d->next = conffile_devices;
      conffile_devices = d;
    }

  // razor: the previous copy is never freed, because device->password and
  // session->password alias it (airplay.c:4129, :1706, raop.c:4472,
  // shims/outputs.c:143). Each replacement leaks one short string; refcount it
  // if that ever matters.
  d->section.password = password ? strdup(password) : NULL;
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
  struct conffile_device *d;

  (void)sec;
  (void)name;
  if (!title)
    return NULL;

  // Only a device with a password gets a section; every other device keeps
  // airplay.c's `if (devcfg && ...)` branches on their per-device defaults.
  d = conffile_device_find(title);
  if (d && d->section.password)
    return &d->section;
  return NULL;
}

char *
cfg_getstr(cfg_t *sec, const char *name)
{
  if (!name)
    return NULL;

  // Per-device str keys, read only through a section cfg_gettsec returned.
  if (sec && strcmp(name, "password") == 0)
    return (char *)sec->password;
  if (sec && strcmp(name, "nickname") == 0)
    return NULL;

  if (strcmp(name, "user_agent") == 0)
    return (char *)config.user_agent;
  if (strcmp(name, "name") == 0)          // library.name
    return (char *)config.library_name;
  if (strcmp(name, "bind_address") == 0)  // general.bind_address (PTP + net_bind)
    return (char *)config.bind_address;

  // Anything else is an unserved key. Make the miss loud instead of silently
  // returning NULL.
  conffile_unknown_key("cfg_getstr", name);
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

  conffile_unknown_key("cfg_getint", name);
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

  // [AirPlayEngine vendored change 2026-07-19] airplay_shared.uncompressed_alac,
  // read once by raop_init (sender/raop.c). Unlike the per-device bool keys this
  // is a genuine global, so it is served here (default true) rather than tripping
  // the unknown-key path.
  if (strcmp(name, "uncompressed_alac") == 0)
    return config.uncompressed_alac;

  // Per-device bool keys (exclude/permanent/exclusive/airplay2_disable/
  // raop_disable/ptp_disable) are read behind a `devcfg && ...` guard, so they
  // arrive only for a device with a password section. None is configurable:
  // each is off.
  if (strcmp(name, "exclude") == 0 || strcmp(name, "permanent") == 0
      || strcmp(name, "exclusive") == 0 || strcmp(name, "airplay2_disable") == 0
      || strcmp(name, "raop_disable") == 0 || strcmp(name, "ptp_disable") == 0)
    return 0;

  // The only global bool the vendored cluster reads is "ipv6" (misc.c net
  // helpers). Anything else is a genuine unserved key: make it loud rather than
  // masquerading as a false/off default.
  conffile_unknown_key("cfg_getbool", name);
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

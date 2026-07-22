// SPDX-License-Identifier: GPL-2.0-or-later
//
// logger.c — REAL logger shim (T-SHIM-2). FRESH code (not ported from OwnTone;
// OwnTone's logger.c is a file/syslog logger with its own threading — we route
// to Apple's os_log instead so session progress is visible in Console.app /
// `log stream` during bring-up).
//
// Routing: every DPRINTF/DVPRINTF is formatted once and emitted to os_log under
// a per-process subsystem, plus (for E_FATAL/E_LOG/E_WARN, or when
// AIRPLAYENGINE_LOG_STDERR is set) mirrored to stderr so it's visible when
// running the unit binary / a CLI probe outside Console. The severity is gated
// by the env var AIRPLAYENGINE_LOG_LEVEL (0=fatal .. 5=spam; default E_LOG=1),
// so verbose SPAM/DBG output is off unless explicitly requested.
//
// DHEXDUMP prints a classic offset | hex | ascii dump (capped) to the log.

#include "logger.h"

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <os/log.h>
#include <event2/event.h>

/* seam-map §3.2: default to E_LOG. Overridable via env for bring-up. */
static int
log_threshold(void)
{
  static int cached = -1;
  const char *env;

  if (cached >= 0)
    return cached;

  env = getenv("AIRPLAYENGINE_LOG_LEVEL");
  if (env && env[0])
    {
      int v = atoi(env);
      if (v < E_FATAL) v = E_FATAL;
      if (v > E_SPAM)  v = E_SPAM;
      cached = v;
    }
  else
    cached = E_LOG;

  return cached;
}

static bool
mirror_to_stderr(int severity)
{
  static int forced = -1;
  if (forced < 0)
    forced = (getenv("AIRPLAYENGINE_LOG_STDERR") != NULL) ? 1 : 0;
  // Errors/warnings always mirror; everything else only when forced.
  return forced || severity <= E_WARN;
}

/* Optional append-to-file sink, opened once from AIRPLAYENGINE_LOG_FILE. Unlike
 * stderr (swallowed when the app is launched via `open`/LaunchServices) and
 * os_log (a custom subsystem from an ad-hoc-signed bundle isn't reliably
 * persisted), a plain file is readable from a bundled, TCC-correct live session —
 * the only way to observe a real receiver session's logs. NULL when unset. */
static FILE *
log_file(void)
{
  static FILE *f = NULL;
  static int tried = 0;
  if (!tried)
    {
      const char *path = getenv("AIRPLAYENGINE_LOG_FILE");
      tried = 1;
      if (path && path[0])
        f = fopen(path, "a");
    }
  return f;
}

static const char *
domain_label(int domain)
{
  switch (domain)
    {
      case L_AIRPLAY:   return "airplay";
      case L_PLAYER:    return "player";
      case L_MISC:      return "misc";
      case L_XCODE:     return "xcode";
      case L_MDNS:      return "mdns";
      case L_MAIN:      return "main";
      case L_EVENT:     return "event";
      case L_RAOP:      return "raop";
      case L_RCP:       return "rcp";
      default:          return "engine";
    }
}

static os_log_type_t
os_type_for(int severity)
{
  switch (severity)
    {
      case E_FATAL: return OS_LOG_TYPE_FAULT;
      case E_LOG:   return OS_LOG_TYPE_DEFAULT;
      case E_WARN:  return OS_LOG_TYPE_ERROR;
      case E_INFO:  return OS_LOG_TYPE_INFO;
      case E_DBG:
      case E_SPAM:  return OS_LOG_TYPE_DEBUG;
      default:      return OS_LOG_TYPE_DEFAULT;
    }
}

static os_log_t
engine_log(void)
{
  static os_log_t log = NULL;
  if (!log)
    log = os_log_create("com.airplayengine", "engine");
  return log;
}

static void
emit(int severity, int domain, const char *msg)
{
  os_log_with_type(engine_log(), os_type_for(severity), "[%{public}s] %{public}s",
                   domain_label(domain), msg);

  if (mirror_to_stderr(severity))
    {
      fprintf(stderr, "[%s] %s", domain_label(domain), msg);
      // Ensure a trailing newline for readability even if fmt lacked one.
      size_t n = strlen(msg);
      if (n == 0 || msg[n - 1] != '\n')
        fputc('\n', stderr);
    }

  FILE *lf = log_file();
  if (lf)
    {
      size_t n = strlen(msg);
      fprintf(lf, "[%s] %s", domain_label(domain), msg);
      if (n == 0 || msg[n - 1] != '\n')
        fputc('\n', lf);
      fflush(lf); // flush every line: a live capture must not lose the tail
    }
}

void
DPRINTF(int severity, int domain, const char *fmt, ...)
{
  char buf[1024];
  va_list ap;

  if (severity > log_threshold())
    return;

  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);

  emit(severity, domain, buf);
}

void
DVPRINTF(int severity, int domain, const char *fmt, va_list ap)
{
  char buf[1024];

  if (severity > log_threshold())
    return;

  vsnprintf(buf, sizeof(buf), fmt, ap);
  emit(severity, domain, buf);
}

void
DHEXDUMP(int severity, int domain, const unsigned char *data, int data_len, const char *heading)
{
#define HEXDUMP_MAX_BYTES 512
#define HEXDUMP_COLS      16
  char line[128];
  int cap;
  int i, j;

  if (severity > log_threshold())
    return;

  if (heading)
    emit(severity, domain, heading);

  if (!data || data_len <= 0)
    return;

  cap = (data_len > HEXDUMP_MAX_BYTES) ? HEXDUMP_MAX_BYTES : data_len;

  for (i = 0; i < cap; i += HEXDUMP_COLS)
    {
      int pos = 0;
      pos += snprintf(line + pos, sizeof(line) - pos, "%04x  ", i);

      for (j = 0; j < HEXDUMP_COLS; j++)
        {
          if (i + j < cap)
            pos += snprintf(line + pos, sizeof(line) - pos, "%02x ", data[i + j]);
          else
            pos += snprintf(line + pos, sizeof(line) - pos, "   ");
        }

      pos += snprintf(line + pos, sizeof(line) - pos, " ");
      for (j = 0; j < HEXDUMP_COLS && i + j < cap; j++)
        {
          unsigned char c = data[i + j];
          pos += snprintf(line + pos, sizeof(line) - pos, "%c", isprint(c) ? c : '.');
        }

      emit(severity, domain, line);
    }

  if (data_len > cap)
    {
      snprintf(line, sizeof(line), "... (%d of %d bytes shown)", cap, data_len);
      emit(severity, domain, line);
    }
#undef HEXDUMP_MAX_BYTES
#undef HEXDUMP_COLS
}

/* --- libevent log bridge (first-light hardening #5) ------------------------
 *
 * libevent emits its own diagnostics (event base warnings, evrtsp transport
 * errors, kqueue failures) through an internal default callback that writes to
 * stderr with no severity control and no route into Console.app — invisible
 * once the engine runs as an installed helper. OwnTone wires libevent's log
 * output into its own logger; our hosting never did, so a libevent-level
 * failure during a session was silently lost. Route it through the same
 * os_log/stderr path (under the L_EVENT domain, env-gated by
 * AIRPLAYENGINE_LOG_LEVEL) as everything else. */

static int
severity_for_event_log(int event_severity)
{
  switch (event_severity)
    {
      case EVENT_LOG_DEBUG: return E_DBG;
      case EVENT_LOG_MSG:   return E_INFO;
      case EVENT_LOG_WARN:  return E_WARN;
      case EVENT_LOG_ERR:   return E_LOG; /* libevent's hard errors -> visible */
      default:              return E_LOG;
    }
}

static void
libevent_log_adapter(int severity, const char *msg)
{
  int mapped = severity_for_event_log(severity);
  if (mapped > log_threshold())
    return;
  emit(mapped, L_EVENT, msg ? msg : "(libevent: null message)");
}

void
engine_logger_wire_libevent(void)
{
  // Idempotent: event_set_log_callback just stores the pointer, so re-calling
  // with the same adapter is a no-op. Passing NULL would restore libevent's
  // default stderr writer — we always install ours.
  event_set_log_callback(libevent_log_adapter);
}

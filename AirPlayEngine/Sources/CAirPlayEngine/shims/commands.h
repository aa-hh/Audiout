// SPDX-License-Identifier: GPL-2.0-or-later
//
// commands — STUB (airplay_events.c only). Replaces OwnTone's src/commands.h.
//
// Implements: docs/seam-map.md §3.7. Only two calls exist in the cluster:
//   commands_base_new(evbase, NULL)   (airplay_events.c:507)
//   commands_base_destroy(cmdbase)    (airplay_events.c:530)
// The cmdbase is created and destroyed but NEVER used to dispatch a command
// (seam-map confirms via trace), so a trivial alloc/free suffices — we do NOT
// vendor OwnTone's commands.c/evthr machinery.
//
// Signature note: OwnTone's commands_base_new takes (struct event_base *,
// command_exit_cb) — airplay_events.c passes NULL for the exit cb. We mirror
// that so the call compiles; the exit cb is ignored.
//
// STUB STATUS (T-BUILD-1): commands.c is a REAL trivial impl (alloc a tiny
// struct stashing evbase; free it). It links and is behaviorally complete for
// this cluster's use (no dispatch needed) — not a placeholder.

#ifndef CAIRPLAYENGINE_SHIM_COMMANDS_H
#define CAIRPLAYENGINE_SHIM_COMMANDS_H

#include <event2/event.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*command_exit_cb)(void);

struct commands_base;

struct commands_base *
commands_base_new(struct event_base *evbase, command_exit_cb exit_cb);

void
commands_base_destroy(struct commands_base *cmdbase);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_COMMANDS_H */

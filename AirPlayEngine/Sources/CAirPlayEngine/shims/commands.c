// SPDX-License-Identifier: GPL-2.0-or-later
//
// commands.c — trivial shim (T-BUILD-1). Behaviorally complete for the
// cluster's use: airplay_events.c creates a commands_base and destroys it but
// never dispatches through it (seam-map §3.7), so a bare alloc/free suffices.
// This is NOT a placeholder to be replaced — the full commands.c/evthr
// machinery is intentionally not vendored.

#include "commands.h"

#include <stdlib.h>

struct commands_base {
  struct event_base *evbase;
  command_exit_cb exit_cb;
};

struct commands_base *
commands_base_new(struct event_base *evbase, command_exit_cb exit_cb)
{
  struct commands_base *cmdbase = calloc(1, sizeof(struct commands_base));
  if (!cmdbase)
    return NULL;

  cmdbase->evbase = evbase;
  cmdbase->exit_cb = exit_cb;
  return cmdbase;
}

void
commands_base_destroy(struct commands_base *cmdbase)
{
  free(cmdbase);
}

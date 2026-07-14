// SPDX-License-Identifier: GPL-2.0-or-later
//
// db.c — no-op shim (T-BUILD-1). Metadata/persist path is cut (Q6), so these
// are permanent no-ops, not placeholders. db_queue_fetch_byitemid returns NULL
// (so airplay_metadata_prepare early-returns NULL), db_speaker_save returns 0
// (fire-and-forget; does not block the volume-set callback), free_queue_item
// does nothing.
//
// TODO(T-SHIM-1): keep as no-ops. Volume persistence, if wanted, lives in Swift.

#include "db.h"

#include <stddef.h>

struct db_queue_item *
db_queue_fetch_byitemid(uint32_t item_id)
{
  (void)item_id;
  return NULL;
}

int
db_speaker_save(struct output_device *device)
{
  (void)device;
  return 0;
}

void
free_queue_item(struct db_queue_item *queue_item, int content_only)
{
  (void)queue_item;
  (void)content_only;
}

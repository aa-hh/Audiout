// SPDX-License-Identifier: GPL-2.0-or-later
//
// dmap_common.c — no-op shim (T-BUILD-1). Metadata path is cut (Q6). Returns
// -1. Dead at runtime (reached only via the stubbed metadata_prepare) but must
// compile+link.
//
// TODO(T-SHIM-1): keep as a no-op.

#include "dmap_common.h"

int
dmap_encode_queue_metadata(struct evbuffer *songlist, struct evbuffer *song, struct db_queue_item *queue_item)
{
  (void)songlist;
  (void)song;
  (void)queue_item;
  return -1;
}

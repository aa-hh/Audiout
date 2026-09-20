// SPDX-License-Identifier: GPL-2.0-or-later
//
// dmap_common.c — a no-op by design. The metadata path is cut (Q6), so this
// returns -1. Dead at runtime (reached only via the no-op metadata_prepare)
// but must compile+link.

#include "dmap_common.h"

int
dmap_encode_queue_metadata(struct evbuffer *songlist, struct evbuffer *song, struct db_queue_item *queue_item)
{
  (void)songlist;
  (void)song;
  (void)queue_item;
  return -1;
}

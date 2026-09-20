// SPDX-License-Identifier: GPL-2.0-or-later
//
// artwork.c — a no-op by design. The metadata path is cut (Q6), so this
// returns -1 (no artwork). The call site is dead at runtime (reached only via
// the no-op metadata_prepare) but must compile+link.

#include "artwork.h"

int
artwork_get_by_queue_item_id(struct evbuffer *evbuf, int item_id, int max_w, int max_h, int format)
{
  (void)evbuf;
  (void)item_id;
  (void)max_w;
  (void)max_h;
  (void)format;
  return -1;
}

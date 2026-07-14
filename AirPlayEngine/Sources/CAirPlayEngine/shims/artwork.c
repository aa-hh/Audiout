// SPDX-License-Identifier: GPL-2.0-or-later
//
// artwork.c — no-op shim (T-BUILD-1). Metadata path is cut (Q6). Returns -1
// (no artwork). This call site is dead at runtime (reached only via the stubbed
// metadata_prepare) but must compile+link.
//
// TODO(T-SHIM-1): keep as a no-op (audio-only, no artwork).

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

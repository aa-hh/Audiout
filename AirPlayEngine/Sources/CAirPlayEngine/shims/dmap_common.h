// SPDX-License-Identifier: GPL-2.0-or-later
//
// dmap_common — STUB-noop (metadata cluster). Replaces OwnTone's
// src/dmap_common.h.
//
// Implements: docs/seam-map.md §3.4. RESOLVED DECISIONS Q6: metadata cut.
// Only reference (grep at T-BUILD-1):
//   dmap_encode_queue_metadata(songlist, song, queue_item)  airplay.c:1708
// (inside airplay_metadata_prepare, dead once metadata is stubbed).
//
// Signature copied VERBATIM from OwnTone src/dmap_common.h (three args:
// songlist, song, queue_item — the T-PKG-1 scaffold had only two).
//
// STUB STATUS (T-BUILD-1): dmap_common.c returns -1. Dead at runtime.
//
// TODO(T-SHIM-1): keep as a no-op.

#ifndef CAIRPLAYENGINE_SHIM_DMAP_COMMON_H
#define CAIRPLAYENGINE_SHIM_DMAP_COMMON_H

#include <event2/buffer.h>

#include "db.h" /* struct db_queue_item */

#ifdef __cplusplus
extern "C" {
#endif

/* No-op: returns -1. */
int
dmap_encode_queue_metadata(struct evbuffer *songlist, struct evbuffer *song, struct db_queue_item *queue_item);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_DMAP_COMMON_H */

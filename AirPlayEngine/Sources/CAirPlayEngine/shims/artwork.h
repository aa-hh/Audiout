// SPDX-License-Identifier: GPL-2.0-or-later
//
// artwork — STUB-noop (metadata cluster). Replaces OwnTone's src/artwork.h.
//
// Implements: docs/seam-map.md §3.4. RESOLVED DECISIONS Q6: metadata cut.
// Cluster references (grep at T-BUILD-1):
//   artwork_get_by_queue_item_id(evbuf, item_id, w, h, fmt)  airplay.c:1698
//   ART_DEFAULT_WIDTH / ART_DEFAULT_HEIGHT (airplay.c:1698)
//   ART_FMT_PNG / ART_FMT_JPEG (airplay.c:2515-2521, switch on rmd->artwork_fmt)
//
// The ART_* macros and the function signature (note: `int item_id`, not
// uint32_t — the T-PKG-1 scaffold got this wrong) are copied VERBATIM from
// OwnTone src/artwork.h.
//
// STUB STATUS (T-BUILD-1): artwork.c returns -1 (no artwork). Since the caller
// (airplay_metadata_prepare) is only reached via the metadata path — which is
// cut — this is dead at runtime but must compile.
//
// TODO(T-SHIM-1): keep as a no-op (audio-only, no artwork).

#ifndef CAIRPLAYENGINE_SHIM_ARTWORK_H
#define CAIRPLAYENGINE_SHIM_ARTWORK_H

#include <event2/buffer.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ART_FMT_PNG        1
#define ART_FMT_JPEG       2
#define ART_FMT_VP8        3

#define ART_DEFAULT_HEIGHT 600
#define ART_DEFAULT_WIDTH  600

/* No-op: returns -1 (no artwork). */
int
artwork_get_by_queue_item_id(struct evbuffer *evbuf, int item_id, int max_w, int max_h, int format);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_ARTWORK_H */

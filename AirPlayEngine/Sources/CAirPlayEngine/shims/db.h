// SPDX-License-Identifier: GPL-2.0-or-later
//
// db — STUB-noop (metadata cluster). Replaces OwnTone's src/db.h.
//
// Implements: docs/seam-map.md §3.4. RESOLVED DECISIONS Q6: metadata/db/
// artwork is cut (audio-only, SPEC.md §2). Cluster references (grep at
// T-BUILD-1):
//   db_queue_fetch_byitemid(uint32_t item_id)  airplay.c:1686 (metadata_prepare)
//   db_speaker_save(struct output_device*)      airplay.c:3512 (volume persist)
//   free_queue_item(struct db_queue_item*, int) airplay.c:1710 (metadata_prepare)
// plus field access queue_item->id / queue_item->path (airplay.c:1698/1701).
//
// struct db_queue_item is trimmed to just the two fields airplay.c touches
// (id, path). Since db_queue_fetch_byitemid returns NULL (metadata stubbed),
// the field-access code at 1698-1710 is dead at runtime but must still compile.
//
// STUB STATUS (T-BUILD-1): db.c bodies are no-ops — db_queue_fetch_byitemid
// returns NULL, db_speaker_save returns 0 (fire-and-forget; does not block the
// volume-set callback per seam-map §3.4), free_queue_item does nothing.
//
// TODO(T-SHIM-1): keep these no-ops. Volume persistence, if wanted, lives in
// the Swift/app layer, not here.

#ifndef CAIRPLAYENGINE_SHIM_DB_H
#define CAIRPLAYENGINE_SHIM_DB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct output_device; /* real def in shims/outputs.h */

/* Only the fields airplay.c's (dead) metadata path reads. */
struct db_queue_item {
  uint32_t id;
  char *path;
};

/* No-op: returns NULL (metadata path is cut). */
struct db_queue_item *
db_queue_fetch_byitemid(uint32_t item_id);

/* No-op: returns 0. */
int
db_speaker_save(struct output_device *device);

/* No-op free (matches OwnTone signature free_queue_item(qi, content_only)). */
void
free_queue_item(struct db_queue_item *queue_item, int content_only);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_DB_H */

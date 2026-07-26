// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_workgroup.c — SHIM bodies (T5). See engine_workgroup.h for the full
// ownership contract; this file is the one place that contract must hold.
//
// This translation unit compiles as plain C (not Objective-C), so the
// os_workgroup_t reference handed back by kAudioDevicePropertyIOThreadOSWorkgroup
// is NOT ARC-managed here — os_retain()/os_release() resolve to their plain
// C-function form (see <os/object.h>: the `[obj retain]`/`[obj release]`
// macro substitution is gated on OS_OBJECT_USE_OBJC, which requires
// Objective-C). Every retain this file is responsible for is tracked by hand
// below.

#include "engine_workgroup.h"

#include <errno.h>
#include <stdlib.h>

#include <CoreAudio/CoreAudio.h>
#include <os/workgroup.h>
#include <os/workgroup_object.h>

/* Opaque to Swift and to every other shim — only this file knows the shape.
 * One token == one join == one required matching leave, on the same thread,
 * which trivially satisfies os_workgroup_leave's reverse-order requirement
 * (there is nothing to reorder with exactly one join per token). */
struct engine_workgroup_token
{
  os_workgroup_t wg;                 /* the +1 reference this token owns   */
  os_workgroup_join_token_s join_tok; /* populated by os_workgroup_join()   */
};

int
engine_workgroup_join(engine_workgroup_audio_object_id device_id,
                      engine_workgroup_token **out_token)
{
  /* Hard NULL-safety requirement: never crash, always EINVAL. */
  if (out_token == NULL)
    return EINVAL;

  *out_token = NULL;

  AudioObjectPropertyAddress addr = {
    .mSelector = kAudioDevicePropertyIOThreadOSWorkgroup,
    .mScope    = kAudioObjectPropertyScopeGlobal,
    .mElement  = kAudioObjectPropertyElementMain,
  };

  if (!AudioObjectHasProperty((AudioObjectID)device_id, &addr))
    return EINVAL;

  /* kAudioDevicePropertyIOThreadOSWorkgroup hands back the os_workgroup_t
   * ALREADY +1 RETAINED (AudioHardware.h: "The caller is responsible for
   * releasing the returned object."). From this line on, `wg` is a
   * reference THIS FUNCTION owns until it either transfers it into a
   * token (success) or releases it itself (every failure path below). */
  os_workgroup_t wg = NULL;
  UInt32 dataSize = sizeof(wg);
  OSStatus status = AudioObjectGetPropertyData((AudioObjectID)device_id,
                                               &addr,
                                               0, NULL,
                                               &dataSize, &wg);
  if (status != noErr || wg == NULL)
    return EINVAL;

  struct engine_workgroup_token *token = calloc(1, sizeof(*token));
  if (token == NULL)
    {
      os_release(wg); /* release the +1 before returning on this failure path */
      return ENOMEM;
    }

  /* os_workgroup_join() is real-time safe and joins the CALLING (current)
   * thread — callers of engine_workgroup_join() must already be on the
   * thread meant to join. */
  int rc = os_workgroup_join(wg, &token->join_tok);
  if (rc != 0)
    {
      /* Join failed after we already retained the workgroup above (per
       * F-plan requirement: no leak on the failure path). EALREADY / EINVAL
       * are passed through verbatim so the caller can distinguish them. */
      os_release(wg);
      free(token);
      return rc;
    }

  token->wg = wg; /* token now owns the +1 reference; released in leave() */
  *out_token = token;
  return 0;
}

void
engine_workgroup_leave(engine_workgroup_token *token)
{
  /* NULL is a documented no-op (mirrors free()'s NULL-safety) — there is
   * nothing to leave. This is deliberately NOT an error: callers that never
   * successfully joined (engine_workgroup_join returned non-zero, or was
   * never called) can unconditionally call this in a cleanup/defer path. */
  if (token == NULL)
    return;

  /* Reverse-order requirement: os_workgroup_leave() must be called in the
   * reverse order of joins made by this thread, or behavior is UNDEFINED
   * (Apple's documentation is explicit that this is not a checked error).
   * This shim's token shape enforces the only case it can enforce
   * structurally — one token, one join, one leave — so a caller that joins
   * at most once per thread via this API cannot violate the ordering rule.
   * A caller joining multiple workgroups on one thread via multiple tokens
   * MUST leave them in the reverse order it joined them; that discipline is
   * the caller's responsibility and cannot be checked here. */
  os_workgroup_leave(token->wg, &token->join_tok);

  /* Release the +1 reference retained by the 'oswg' property getter back in
   * engine_workgroup_join() — exactly once, matching exactly one retain. */
  os_release(token->wg);

  free(token);
}

// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_workgroup — SHIM (T5, PLAN-AUDIO-THREAD-SCHEDULING.md).
//
// WHY THIS EXISTS. Real-time parity with Apple's own audio threads requires
// joining a Core Audio device's os_workgroup_t (AudioWorkInterval.h, case 1),
// but os_workgroup_join()/os_workgroup_leave() are declared
// OS_REFINED_FOR_SWIFT in <os/workgroup_object.h> — Swift's importer refines
// them into an unusable (and here, unwanted) shape, so they are not directly
// callable from Swift. This shim is plain C, so it sees the real, refined-
// for-Swift-but-ordinary-C symbols, and re-exposes them behind an opaque
// token Swift CAN call.
//
// OWNERSHIP CONTRACT (read before touching engine_workgroup.c):
//   * kAudioDevicePropertyIOThreadOSWorkgroup ('oswg') hands back the
//     os_workgroup_t ALREADY +1 RETAINED (AudioHardware.h: "The caller is
//     responsible for releasing the returned object."). The join function
//     below takes ownership of that +1 and releases it exactly once, no
//     matter which path it returns through (success or failure).
//   * This target compiles as plain C, not Objective-C/ARC, so os_retain/
//     os_release resolve to the plain function form (not [obj retain]/
//     [obj release]) — the retain count here is managed BY HAND, not by ARC.
//   * os_workgroup_leave() MUST be called in the reverse order of
//     os_workgroup_join() calls on a given thread; the Apple documentation
//     states that leaving out of order is UNDEFINED BEHAVIOR, not a checked
//     error. This shim only supports the single-join-per-token shape (one
//     token = one join = one matching leave); it does not attempt to make
//     nested/reordered joins safe. Callers must not misuse it.
//
// NULL-SAFETY: engine_workgroup_join returns EINVAL (never crashes) if
// either the output token pointer or the resulting workgroup reference would
// be unusable. This is exercised directly by a hermetic test — see
// AirPlayEngineTests/EngineWorkgroupShimTests.swift.

#ifndef CAIRPLAYENGINE_SHIM_ENGINE_WORKGROUP_H
#define CAIRPLAYENGINE_SHIM_ENGINE_WORKGROUP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Core Audio's AudioObjectID (a UInt32) — declared here rather than pulling in
 * <CoreAudio/CoreAudio.h> for every consumer of this header. The .c file
 * includes the real framework header and confirms the types agree. */
typedef uint32_t engine_workgroup_audio_object_id;

/* Opaque token returned by engine_workgroup_join(), consumed exactly once by
 * engine_workgroup_leave(). Callers must treat this as opaque — do not read
 * or copy its fields, and do not call leave() more than once per successful
 * join(). Heap-allocated by the shim; leave() frees it. */
typedef struct engine_workgroup_token engine_workgroup_token;

/* Join the CURRENT thread to the os_workgroup_t published by the given Core
 * Audio device/aggregate object's kAudioDevicePropertyIOThreadOSWorkgroup
 * ('oswg') property, and hand back an opaque token in *out_token that
 * engine_workgroup_leave() later consumes.
 *
 * Returns 0 on success. On failure returns a positive errno-style code and
 * leaves *out_token untouched (when out_token is non-NULL):
 *   EINVAL   - out_token is NULL, or the device has no workgroup property
 *              (property unsupported / not a tap-bearing aggregate), or
 *              os_workgroup_join() itself reported EINVAL (workgroup
 *              cancelled).
 *   EALREADY - the current thread is already part of a workgroup that this
 *              one does not nest with (os_workgroup_join()'s own EALREADY,
 *              passed through verbatim).
 *   (other)  - the underlying AudioObjectGetPropertyData or
 *              os_workgroup_join OSStatus/errno, coerced to a positive code.
 *
 * On any failure path, if the 'oswg' property getter had already handed back
 * a retained os_workgroup_t before the failure, this function releases that
 * reference before returning — no leak on the failure path.
 *
 * Must be called ON the thread that is meant to join (os_workgroup_join()
 * joins "the current thread"). */
int
engine_workgroup_join(engine_workgroup_audio_object_id device_id,
                      engine_workgroup_token **out_token);

/* Leave the workgroup previously joined via engine_workgroup_join(), release
 * the +1 retained os_workgroup_t reference taken at join time, and free the
 * token. token may be NULL, in which case this is a no-op (mirrors free()'s
 * NULL-safety; there is nothing to leave).
 *
 * MUST be called ON the same thread that performed the matching join, and —
 * if the calling thread ever joins more than one workgroup — MUST be called
 * in the reverse order of the corresponding joins. Apple's os_workgroup_leave
 * documentation is explicit that violating join/leave ordering is UNDEFINED
 * BEHAVIOR (and a malformed/already-consumed token aborts the process), not
 * something this shim can turn into a safe error return. Callers that join
 * only one workgroup per thread (the only shape this shim's token supports)
 * automatically satisfy the ordering requirement. */
void
engine_workgroup_leave(engine_workgroup_token *token);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_ENGINE_WORKGROUP_H */

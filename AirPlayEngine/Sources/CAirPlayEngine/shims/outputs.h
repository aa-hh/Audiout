// SPDX-License-Identifier: GPL-2.0-or-later
//
// outputs — SHIM (the big one). Replaces OwnTone's src/outputs.h + the
// registry/runner half of src/outputs.c.
//
// Implements: docs/seam-map.md §2 + §2.2 + §9 row 10 (~350-450 LOC, HIGH risk
// R-A). This is the load-bearing shim.
//
// T-BUILD-1 GROUNDING: airplay.c fills `struct output_definition
// output_airplay` and reads MANY output_device / output_buffer / output_data
// fields directly (device->type, ->type_name, ->v6_disabled bitfield, ->quality,
// obuf->data[i].{buffer,bufsize,samples,quality}, obuf->pts, etc.). The
// T-PKG-1 scaffold's hand-shrunk structs were missing several of these and got
// output_status_cb / outputs_cb / the state enum values WRONG. So this header
// now mirrors OwnTone src/outputs.h's type definitions VERBATIM (the full
// structs), and declares only the outputs_* functions the cluster actually
// references (grep at T-BUILD-1: outputs_device_get/free/session_add/
// session_remove, outputs_cb, outputs_name, outputs_quality_subscribe/
// unsubscribe, outputs_buffer_duration_ms_get, outputs_exclusive_mode_get,
// outputs_list) plus outputs_device_add/remove (the discovery->registry path
// merged from player_device_add/remove).
//
// KEY SIGNATURE FACTS (from OwnTone outputs.h — the scaffold had these wrong):
//   output_status_cb = void (*)(struct output_device*, enum output_device_state)
//   outputs_cb(int callback_id, uint64_t device_id, enum output_device_state)
//   OUTPUT_STATE_FAILED = -1, OUTPUT_STATE_PASSWORD = -2  (negative!)
//   outputs_buffer_duration_ms_get() returns uint64_t
//   struct output_buffer.data[] is [MAX + 2]
//
// The async callback contract (seam-map §2.1, CRITICAL, risk R-A): every
// device_* entry point returning positive N promises to call
// outputs_cb(callback_id, device_id, state) exactly N times, or the engine
// hangs. That dispatcher is T-SHIM-1's real work.
//
// STUB STATUS (T-BUILD-1): shims/outputs.c provides MINIMAL bodies so the
// cluster LINKS: a trivial singly-linked device registry (add/remove/get/list),
// session attach/detach as no-ops, outputs_cb as a no-op (DOES NOT yet dispatch
// to Swift — R-A dispatcher is UNIMPLEMENTED), outputs_name returns "AirPlay 2",
// quality subscribe/unsubscribe return 0, buffer_duration returns the default
// 2250 ms, exclusive_mode returns false. This links but does NOT drive a real
// session — see build-notes.md for the exact T-SHIM-1 starting state.
//
// TODO(T-SHIM-1): implement the REAL device registry + the outputs_cb
// async-callback dispatcher that turns C completions into Swift-visible events
// (risk R-A — needs a dynamic trace of the N-callbacks accounting), plus the
// quality-subscription + buffer-duration trackers wired to config.

#ifndef CAIRPLAYENGINE_SHIM_OUTPUTS_H
#define CAIRPLAYENGINE_SHIM_OUTPUTS_H

#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <event2/event.h>
#include <event2/buffer.h>

#include "misc.h" /* struct media_quality, enum media_format */

#ifdef __cplusplus
extern "C" {
#endif

#define OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS 5

/* Forward declarations (as in OwnTone outputs.h). */
struct output_device;
struct output_metadata;
enum output_device_state;

typedef void (*output_status_cb)(struct output_device *device, enum output_device_state status);
typedef int (*output_metadata_finalize_cb)(struct output_metadata *metadata);

/* Only AIRPLAY is used by the extracted cluster, but the enum keeps OwnTone's
 * ordering — airplay.c only ever references OUTPUT_TYPE_AIRPLAY (value 1). */
enum output_types
{
  OUTPUT_TYPE_RAOP,
  OUTPUT_TYPE_AIRPLAY,
  OUTPUT_TYPE_STREAMING,
  OUTPUT_TYPE_DUMMY,
  OUTPUT_TYPE_FIFO,
  OUTPUT_TYPE_RCP,
};

/* Values copied VERBATIM from OwnTone — FAILED/PASSWORD are NEGATIVE. */
enum output_device_state
{
  OUTPUT_STATE_STOPPED   = 0,
  OUTPUT_STATE_STARTUP   = 1,
  OUTPUT_STATE_CONNECTED = 2,
  OUTPUT_STATE_STREAMING = 3,
  OUTPUT_STATE_FAILED    = -1,
  OUTPUT_STATE_PASSWORD  = -2,
};

/* Full struct copied from OwnTone outputs.h — airplay.c reads many of these
 * fields (including the bitflags). Kept identical so field offsets/semantics
 * match the vendored code exactly. */
struct output_device
{
  uint64_t id;
  char *name;
  enum output_types type;
  const char *type_name;
  enum output_device_state state;

  unsigned selected:1;
  unsigned advertised:1;
  unsigned has_password:1;
  unsigned has_video:1;
  unsigned requires_auth:1;
  unsigned v6_disabled:1;
  unsigned prevent_playback:1;
  unsigned busy:1;
  unsigned resurrect:1;

  const char *password;
  char *auth_key;

  int volume;
  int relvol;
  int max_volume;

  struct media_quality quality;

  enum media_format selected_format;
  enum media_format default_format;
  uint32_t supported_formats;

  int offset_ms;

  char *v4_address;
  char *v6_address;
  short v4_port;
  short v6_port;

  int audio_fd;
  int metadata_fd;

  struct event *stop_timer;

  void *extra_device_info;
  void *session;

  struct output_device *next;
};

struct output_metadata
{
  enum output_types type;
  uint32_t item_id;

  uint32_t pos_ms;
  uint32_t len_ms;
  struct timespec pts;
  bool startup;

  void *priv;

  struct event *ev;

  output_metadata_finalize_cb finalize_cb;
};

struct output_data
{
  struct media_quality quality;
  struct evbuffer *evbuf;
  uint8_t *buffer;
  size_t bufsize;
  int samples;
};

struct output_buffer
{
  struct timespec pts;
  // Two larger than max subscriptions: element 0 holds the original untranscoded
  // data, last element is a zero terminator.
  struct output_data data[OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS + 2];
};

/* The interface airplay.c IMPLEMENTS (struct output_definition output_airplay,
 * airplay.c:4385). Copied VERBATIM from OwnTone so all the .field = fn
 * designated initializers in airplay.c type-check against the exact prototypes. */
struct output_definition
{
  const char *name;
  const char *cfg_name;
  enum output_types type;
  int priority;
  int disabled;

  int (*init)(void);
  void (*deinit)(void);

  int (*device_start)(struct output_device *device, int callback_id);
  int (*device_stop)(struct output_device *device, int callback_id);
  int (*device_flush)(struct output_device *device, int callback_id);
  int (*device_probe)(struct output_device *device, int callback_id);
  int (*device_volume_set)(struct output_device *device, int callback_id);
  int (*device_volume_to_pct)(struct output_device *device, const char *volume);
  int (*device_quality_set)(struct output_device *device, struct media_quality *quality, int callback_id);
  int (*device_authorize)(struct output_device *device, const char *pin, int callback_id);
  void (*device_cb_set)(struct output_device *device, int callback_id);
  void (*device_free_extra)(struct output_device *device);

  void (*write)(struct output_buffer *buffer);

  void *(*metadata_prepare)(struct output_metadata *metadata);
  void (*metadata_send)(struct output_metadata *metadata);
  void (*metadata_purge)(void);
};

/* --- §2.2 registry seam: the outputs_* symbols airplay.c calls back into.
 * Signatures copied VERBATIM from OwnTone outputs.h. --- */

struct output_device *
outputs_device_get(uint64_t device_id);

uint64_t
outputs_buffer_duration_ms_get(void);

bool
outputs_exclusive_mode_get(void);

int
outputs_device_session_add(uint64_t device_id, void *session);

void
outputs_device_session_remove(uint64_t device_id);

int
outputs_quality_subscribe(struct media_quality *quality);

void
outputs_quality_unsubscribe(struct media_quality *quality);

/* THE load-bearing async completion — R-A. (int callback_id, uint64_t, state) */
void
outputs_cb(int callback_id, uint64_t device_id, enum output_device_state state);

/* --- R-A dispatcher: callback-id registry + engine completion hook (T-SHIM-1).
 *
 * The callback-id registry reproduces OwnTone outputs.c's replace-on-add,
 * one-pending-callback-per-device semantics. The layer that issues a device_*
 * op (OwnTone's player; here the engine / Swift layer, T-API-1) calls
 * outputs_callback_add(device, cb) to get the callback_id it passes to the
 * backend, and reads the device_* return value N to decide whether to wait:
 *   N > 0  -> exactly one deferred outputs_cb completion will arrive for the id
 *   N <= 0 -> no callback promised; complete immediately, register no waiter.
 * (In this cluster N is always 0 or 1 — see docs/outputs-dispatcher-contract.md.)
 *
 * outputs_cb() defers delivery onto evbase_player (never runs the cb inline, to
 * avoid re-entrancy from deep inside airplay.c's RTSP state machine). The
 * deferred delivery resolves the device by device_id (the device may have been
 * freed since the report), updates device->state, invokes the registered
 * output_status_cb, and finally fires the engine completion hook so an async
 * waiter (T-API-1) unblocks.
 */

/* Returns the callback_id to hand to a device_* op, or -1 if cb is NULL or the
 * registry is full. Replaces any existing registration for `device`. */
int
outputs_callback_add(struct output_device *device, output_status_cb cb);

/* Remove any pending registration for `device` (used by the issuer if it aborts
 * an op before calling the backend). NOTE: session teardown must NOT call this —
 * see contract §4c (start_retry hands the same callback_id to a new session). */
void
outputs_callback_remove(struct output_device *device);

/* The registered cb for `device`, or NULL. */
output_status_cb
outputs_callback_get(struct output_device *device);

/* Engine completion hook: fired (deferred, on evbase_player) once per delivered
 * outputs_cb, AFTER the output_status_cb, so the Swift/T-API-1 async waiter that
 * armed `callback_id` unblocks. `state` is terminal for the op that armed the id
 * (STREAMING/CONNECTED/STOPPED/FAILED/PASSWORD) except STARTUP (intermediate
 * progress). `context` is the pointer passed to outputs_engine_completion_set. */
typedef void (*outputs_engine_completion_cb)(int callback_id, uint64_t device_id,
                                             enum output_device_state state,
                                             void *context);

void
outputs_engine_completion_set(outputs_engine_completion_cb cb, void *context);

/* Engine device-state hook (T-ENG-STATESTREAM-1): fired (deferred, on
 * evbase_player) for EVERY outputs_cb report, keyed by device_id only — INCLUDING
 * the out-of-band reports that spend no callback_id.
 *
 * The completion hook above is keyed by callback_id and fires exactly once per
 * armed op, so it can only observe a device's state up to the moment its op
 * resolves (e.g. device_start's CONNECTED). But the RTSP state machine keeps
 * reporting AFTER that: session_status() is called again on a later transition
 * (e.g. rtsp_close_cb -> session_failure -> FAILED) with session->callback_id
 * already spent (== -1). Those reports flow through outputs_cb(-1, device_id,
 * state) and were previously DROPPED by the callback_id guard, so a
 * `.connected -> .failed` transition after addOutput resolved was invisible.
 *
 * This hook surfaces those out-of-band transitions: it is called for every
 * report (armed OR spent id) so the engine can drive an async device-state
 * stream with no polling. Delivered on the engine thread, in the same deferred
 * drain, AFTER the output_status_cb and the completion hook. `context` is the
 * pointer passed to outputs_engine_state_set. */
typedef void (*outputs_engine_state_cb)(uint64_t device_id,
                                        enum output_device_state state,
                                        void *context);

void
outputs_engine_state_set(outputs_engine_state_cb cb, void *context);

/* Run the deferred-delivery pass synchronously. In production this is what the
 * libevent deferred event invokes; exposed so a unit test (no event loop) can
 * drive the exact same accounting after feeding synthetic outputs_cb calls. */
void
outputs_cb_deferred_run(void);

/* Test-only: reset the whole dispatcher state (registry + completion hook).
 * Not used in production; lets the unit test start each case from a clean slate. */
void
outputs_dispatcher_reset(void);

/* Wire the deferred-delivery event to evbase_player. T-API-1 calls this after
 * setting evbase_player and before airplay_init. Returns 0 on success, -1 if
 * evbase_player is NULL or the event can't be created. Idempotent. */
int
outputs_dispatcher_init(void);

void
outputs_dispatcher_deinit(void);

const char *
outputs_name(enum output_types type);

struct output_device *
outputs_list(void);

/* Discovery -> registry (merged from player_device_add/remove per seam-map
 * §2.2). Ownership of *add transfers; returns the canonical device (may differ
 * if it was already in the list). */
struct output_device *
outputs_device_add(struct output_device *add, bool new_deselect);

void
outputs_device_remove(struct output_device *remove);

void
outputs_device_free(struct output_device *device);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_OUTPUTS_H */

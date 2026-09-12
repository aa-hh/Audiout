// SPDX-License-Identifier: GPL-2.0-or-later
//
// outputs.c — the registry/runner shim (T-BUILD-1 MINIMAL scaffolding).
//
// This is the load-bearing shim (seam-map §2, risk R-A). For T-BUILD-1
// (compile+link only) it provides:
//   - A trivial singly-linked device registry (add/remove/get/list/free) — a
//     REAL minimal registry so airplay.c's outputs_list()/outputs_device_get()
//     resolve to actual lookups. Not thread-safe, not the final shape.
//   - outputs_device_session_add/remove: attach/detach the opaque session
//     pointer on the matching device (minimal but real).
//   - outputs_cb + the callback-id registry: **REAL** as of T-SHIM-1 — the R-A
//     async-callback dispatcher. It reproduces OwnTone outputs.c's callback
//     machinery (OUTPUTS_MAX_CALLBACKS slots, replace-on-add-per-device,
//     deferred delivery on evbase_player, device re-resolved by device_id) and
//     adds the engine completion hook that unblocks T-API-1's async waiter.
//     Implemented against docs/outputs-dispatcher-contract.md (N ∈ {0,1},
//     exactly once, keyed by callback_id). See that doc + §4 of build-notes.md.
//   - outputs_name / quality_subscribe/unsubscribe / buffer_duration_ms_get /
//     exclusive_mode_get: trivial correct values (name string, 0, default
//     2250 ms, false).
//
// TODO(T-SHIM-1): the REAL registry ownership/merge semantics + string-freeing
// outputs_device_free remain (see build-notes §4); those are independent of the
// R-A dispatcher, which is now complete.

#include "outputs.h"
#include "engine_bridge.h" /* prototypes for the idle-fill test seam defined here */
#include "logger.h" /* DPRINTF / L_AIRPLAY / E_* — real logging on the R-A path */
#include "misc.h"   /* ARRAY_SIZE */

#include <stdlib.h>
#include <stddef.h>
#include <string.h> /* memset */
#include <inttypes.h> /* PRIu64 (start-buffer clamp log) */

/* The player thread's libevent base. airplay.c declares `extern struct
 * event_base *evbase_player;` (airplay.c:459) and uses it to own the timing/
 * control UDP services, every RTSP connection, and its timers (seam-map §8).
 * The engine owns one event_base on one dedicated thread and sets this at
 * airplay_init. For T-BUILD-1 (compile+link only, nothing runs) it is NULL.
 * TODO(T-API-1): set this to the engine thread's event_base before
 * airplay_init runs, per seam-map §8's threading model. */
struct event_base *evbase_player = NULL;

/* Minimal global device registry (single linked list). Not thread-safe by
 * design — all access is on the single engine thread that owns evbase_player
 * (seam-map §8). */
static struct output_device *device_list = NULL;

/* The two backends the engine ships. airplay.c defines output_airplay
 * (airplay.c:4385, AP2); raop.c defines output_raop (AirPlay 1). Both are
 * non-static globals — every helper inside each file is file-static, so the
 * identically-named statics never clash (raop-seam-brief §1.12). Declared
 * extern because the shim can't include a per-sender header (there isn't one).
 * The engine registry is shared across both; per-device operations dispatch to
 * the matching definition by device->type via backend_for() (raop-seam-brief
 * §6.1). */
extern struct output_definition output_airplay;
extern struct output_definition output_raop;

/* Pick the backend that owns `device`, keyed by the type stamped at discovery
 * (airplay_device_cb -> OUTPUT_TYPE_AIRPLAY, raop_device_cb -> OUTPUT_TYPE_RAOP).
 * The opaque device->session is a struct airplay_session* OR struct
 * raop_session*; dispatch-by-type guarantees only the owning backend ever casts
 * it (raop-seam-brief §6.1). Returns NULL for an unhandled type — callers treat
 * that as a no-op and log the bug. */
static struct output_definition *
backend_for(struct output_device *device)
{
  switch (device->type)
    {
      case OUTPUT_TYPE_AIRPLAY: return &output_airplay;
      case OUTPUT_TYPE_RAOP:    return &output_raop;
      default:
        DPRINTF(E_LOG, L_AIRPLAY, "BUG! No output backend for device type %d\n", device->type);
        return NULL;
    }
}

struct output_device *
outputs_list(void)
{
  return device_list;
}

struct output_device *
outputs_device_get(uint64_t device_id)
{
  struct output_device *d;
  for (d = device_list; d; d = d->next)
    if (d->id == device_id)
      return d;
  return NULL;
}

struct output_device *
outputs_device_add(struct output_device *add, bool new_deselect)
{
  struct output_device *device;

  if (!add)
    return NULL;

  // Ported from OwnTone outputs.c:outputs_device_add (the AP1/AP2 dual-type
  // priority merge is dropped — this engine has a single backend, so a device
  // with the same id is always the same type). Two cases: brand-new device
  // (take ownership, prepend), or re-appearing device (merge addresses/name/
  // password into the existing entry, then free `add`).
  device = outputs_device_get(add->id);

  if (!device)
    {
      // New device — ownership of `add` transfers to the registry.
      device = add;

      if (new_deselect)
        device->selected = 0;

      device->next = device_list;
      device_list = device;
    }
  else
    {
      // Update an existing entry. Move the freshly-resolved addresses over
      // (freeing the old ones), and hand ownership of those strings to `device`
      // by NULLing them on `add` so outputs_device_free(add) doesn't free them.
      if (add->v4_address)
        {
          free(device->v4_address);
          device->v4_address = add->v4_address;
          device->v4_port = add->v4_port;
          add->v4_address = NULL;
        }

      if (add->v6_address)
        {
          free(device->v6_address);
          device->v6_address = add->v6_address;
          device->v6_port = add->v6_port;
          add->v6_address = NULL;
        }

      free(device->name);
      device->name = add->name;
      add->name = NULL;

      device->has_password = add->has_password;
      device->password = add->password;

      outputs_device_free(add);
    }

  device->advertised = 1;

  return device;
}

void
outputs_device_remove(struct output_device *remove)
{
  struct output_device **pp;
  if (!remove)
    return;

  for (pp = &device_list; *pp; pp = &(*pp)->next)
    {
      if (*pp == remove)
        {
          *pp = remove->next;
          break;
        }
    }
  outputs_device_free(remove);
}

void
outputs_device_free(struct output_device *device)
{
  if (!device)
    return;

  // Ported from OwnTone outputs.c:outputs_device_free. Free the backend's
  // per-device extra (airplay_extra: mdns_name + struct) via device_free_extra,
  // then the stop_timer event, then the owned strings, then the struct.
  if (device->session)
    DPRINTF(E_LOG, L_PLAYER, "BUG! Freeing device with active session?\n");

  // device_free_extra frees the backend's per-device extra (airplay_extra:
  // mdns_name + struct; raop_extra: the struct) via the owning backend. Guard on
  // extra_device_info: a real device always has it, but a device created without
  // it (e.g. a bare registry entry in a unit test, or a partially-built device
  // on an early error path) would otherwise NULL-deref inside
  // airplay_device_free_extra (which does `free(extra->mdns_name)`
  // unconditionally). This guard is the registry's responsibility.
  if (device->extra_device_info)
    {
      struct output_definition *backend = backend_for(device);
      if (backend && backend->device_free_extra)
        backend->device_free_extra(device);
    }

  if (device->stop_timer)
    event_free(device->stop_timer);

  free(device->name);
  free(device->auth_key);
  free(device->v4_address);
  free(device->v6_address);

  free(device);
}

int
outputs_device_session_add(uint64_t device_id, void *session)
{
  struct output_device *d = outputs_device_get(device_id);
  if (!d)
    return -1;
  d->session = session;
  /* A fresh session means the device is (re)starting, so let the idle fill
   * serve it again after any earlier stop suppressed it. */
  d->idle_fill_suppressed = 0;
  return 0;
}

void
outputs_device_session_remove(uint64_t device_id)
{
  struct output_device *d = outputs_device_get(device_id);
  if (d)
    d->session = NULL;
}

/* ============================ TWO-BACKEND DISPATCH =========================
 *
 * The shared registry hosts AP1 (output_raop) and AP2 (output_airplay) devices
 * side by side; each per-device operation forwards to the definition that owns
 * the device (backend_for, above), preserving the backend's return value N — the
 * count the async waiter keys on (raop-seam-brief §5/§6.2). The callback
 * accounting below is BACKEND-AGNOSTIC: both raop_status and airplay's
 * session_status feed the identical outputs_cb(callback_id, device_id, state),
 * so a wrapper adds nothing to the N contract beyond passing the value through.
 *
 * A NULL backend (unhandled type — already logged by backend_for) is treated as
 * "no callback promised": the int ops return -1 (register no waiter), the void
 * ops no-op. The engine/Swift layer calls these in place of the previously
 * hardcoded output_airplay.<op> calls. `write` is the exception — it is a
 * broadcast, not a per-device op (§6.3). */

int
outputs_device_start(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  return backend ? backend->device_start(device, callback_id) : -1;
}

int
outputs_device_stop(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);

  /* Teardown starts here (this is the deselect path). Suppress the idle fill for
   * the whole teardown window right away: the sender frees the session only at
   * the end (session_cleanup) and reports the stopped state through a deferred
   * callback, so `device->session` and `device->state` both stay "live" for the
   * ~1 s the RTSP TEARDOWN takes. The fill must yield when the stop is
   * requested, not when the teardown finishes. */
  device->idle_fill_suppressed = 1;

  return backend ? backend->device_stop(device, callback_id) : -1;
}

int
outputs_device_flush(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  return backend ? backend->device_flush(device, callback_id) : -1;
}

int
outputs_device_probe(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  return backend ? backend->device_probe(device, callback_id) : -1;
}

int
outputs_device_volume_set(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  return backend ? backend->device_volume_set(device, callback_id) : -1;
}

int
outputs_device_authorize(struct output_device *device, const char *pin, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  return backend ? backend->device_authorize(device, pin, callback_id) : -1;
}

void
outputs_device_cb_set(struct output_device *device, int callback_id)
{
  struct output_definition *backend = backend_for(device);
  if (backend && backend->device_cb_set)
    backend->device_cb_set(device, callback_id);
}

void
outputs_device_free_extra(struct output_device *device)
{
  struct output_definition *backend;

  /* Same extra_device_info guard as outputs_device_free: airplay_device_free_extra
   * NULL-derefs (free(extra->mdns_name)) if extra is unset. */
  if (!device->extra_device_info)
    return;

  backend = backend_for(device);
  if (backend && backend->device_free_extra)
    backend->device_free_extra(device);
}

/* ========================== IDLE SESSION SILENCE FILL ======================
 *
 * A receiver closes its RTSP session when a bound session carries no audio (a
 * Sonos Move was seen dropping after about 30 s). The system tap idles until an
 * app plays, so a freshly selected speaker would be dropped before the user ever
 * pressed play. Once the host has been quiet for IDLE_FILL_QUIET_NS, this writes
 * zeroed PCM at exactly real-time rate for every stream that still has a device
 * with a live session, and stops the moment the host writes again.
 *
 * It calls the two backends' write functions directly instead of going through
 * outputs_write, so the Swift layer's write guards and telemetry keep counting
 * host writes only. Engine thread only, like everything else in this file. */

#define IDLE_FILL_RATE            44100
#define IDLE_FILL_BITS            16
#define IDLE_FILL_CHANNELS        2
#define IDLE_FILL_PACKET_SAMPLES  352        /* AIRPLAY_SAMPLES_PER_PACKET */
#define IDLE_FILL_QUIET_NS        100000000LL
#define IDLE_FILL_MAX_PACKETS     32         /* ceiling on one cycle's ALAC encode work */
#define IDLE_FILL_MAX_STREAMS     16
#define IDLE_FILL_TICK_MS         8

struct idle_fill_entry
{
  bool in_use;
  uint32_t stream_id;
  struct timespec last_host_write_mono;
  struct timespec end_pts;      /* end of the last audio delivered for this stream */
};

/* One slot per stream that has a live device, never one per host stream: a Mac
 * running many per-app streams into one speaker must not spend every slot on
 * streams no receiver is listening to. Only the device scan in idle_fill_tick
 * allocates.
 *
 * razor: a fixed table, sized well above the speakers one Mac drives. A 17th
 * stream with a live device simply gets no fill; grow the constant if that ever
 * happens. */
static struct idle_fill_entry idle_fill_table[IDLE_FILL_MAX_STREAMS];
static struct event *idle_fill_timer = NULL;
static uint8_t idle_fill_silence[IDLE_FILL_PACKET_SAMPLES * IDLE_FILL_CHANNELS * (IDLE_FILL_BITS / 8)];

static int64_t
idle_fill_ns(struct timespec t)
{
  return (int64_t)t.tv_sec * 1000000000LL + (int64_t)t.tv_nsec;
}

static struct timespec
idle_fill_ts(int64_t ns)
{
  struct timespec t;

  t.tv_sec = (time_t)(ns / 1000000000LL);
  t.tv_nsec = (long)(ns % 1000000000LL);
  if (t.tv_nsec < 0)
    {
      t.tv_nsec += 1000000000L;
      t.tv_sec -= 1;
    }
  return t;
}

static int64_t
idle_fill_samples_to_ns(int64_t samples)
{
  return samples * 1000000000LL / IDLE_FILL_RATE;
}

/* The silence buffer is one packet of interleaved S16LE 44100/2 and nothing
 * else. A device advertising another format (raop.c reads the format off the
 * TXT record) would have the sender read 352 frames of ITS quality out of this
 * fixed 1408-byte buffer, past the end of it. Such a stream gets no fill. */
static bool
idle_fill_quality_is_default(const struct media_quality *quality)
{
  return quality->sample_rate == IDLE_FILL_RATE &&
         quality->bits_per_sample == IDLE_FILL_BITS &&
         quality->channels == IDLE_FILL_CHANNELS;
}

/* True when the stream still has at least one device the fill may serve right
 * now: a live session, a connected/streaming state, the default quality, and no
 * teardown in progress. Called both to enumerate streams and again immediately
 * before each write, so a device whose stop began after the enumeration — or in
 * any future path that yields mid-tick — is never written to. Reads only device
 * fields (the session pointer is tested, never dereferenced), so it is safe to
 * call on a session that is being torn down. */
static bool
idle_fill_stream_servable(uint32_t stream_id)
{
  struct output_device *device;
  bool servable = false;

  for (device = device_list; device; device = device->next)
    {
      if (device->stream_id != stream_id)
        continue;
      if (!device->session || device->idle_fill_suppressed)
        continue;
      if (device->state != OUTPUT_STATE_CONNECTED && device->state != OUTPUT_STATE_STREAMING)
        continue;

      /* One device on another format disqualifies the whole stream: every live
       * device on it is fed from the one default-quality silence buffer. */
      if (!idle_fill_quality_is_default(&device->quality))
        return false;

      servable = true;
    }

  return servable;
}

static struct idle_fill_entry *
idle_fill_entry_find(uint32_t stream_id)
{
  int i;

  for (i = 0; i < IDLE_FILL_MAX_STREAMS; i++)
    if (idle_fill_table[i].in_use && idle_fill_table[i].stream_id == stream_id)
      return &idle_fill_table[i];

  return NULL;
}

static struct idle_fill_entry *
idle_fill_entry_claim(uint32_t stream_id)
{
  struct idle_fill_entry *entry = idle_fill_entry_find(stream_id);
  int i;

  if (entry)
    return entry;

  for (i = 0; i < IDLE_FILL_MAX_STREAMS; i++)
    {
      if (idle_fill_table[i].in_use)
        continue;

      memset(&idle_fill_table[i], 0, sizeof(idle_fill_table[i]));
      idle_fill_table[i].in_use = true;
      idle_fill_table[i].stream_id = stream_id;
      return &idle_fill_table[i];
    }

  return NULL;
}

/* Wipe the per-stream bookkeeping. An engine stop leaves stale end times behind
 * while CLOCK_MONOTONIC keeps running; on the next start every stream would look
 * owed the whole downtime and flood packets until it caught up. */
static void
idle_fill_forget_all(void)
{
  memset(idle_fill_table, 0, sizeof(idle_fill_table));
}

/* Stamped by the host's broadcast write and never by the fill, so the fill can
 * tell the two apart and always yields to real audio. Updates only: a stream
 * earns its slot by having a device, not by being written to. */
static void
idle_fill_note_host_write(struct output_buffer *buffer)
{
  struct timespec now;
  int i;

  clock_gettime(CLOCK_MONOTONIC, &now);

  for (i = 0; buffer->data[i].buffer; i++)
    {
      struct idle_fill_entry *entry = idle_fill_entry_find(buffer->data[i].stream_id);

      if (!entry)
        continue;

      entry->last_host_write_mono = now;
      entry->end_pts = idle_fill_ts(idle_fill_ns(buffer->pts) +
                                    idle_fill_samples_to_ns(buffer->data[i].samples));
    }
}

static int
idle_fill_tick(struct timespec now)
{
  uint32_t live[IDLE_FILL_MAX_STREAMS];
  int live_count = 0;
  struct output_device *device;
  int64_t now_ns = idle_fill_ns(now);
  int64_t one_packet_ns = idle_fill_samples_to_ns(IDLE_FILL_PACKET_SAMPLES);
  int total = 0;
  int i;
  int j;

  /* Enumerate the distinct streams that have a device the fill may serve. Stream
   * discovery comes from this registry rather than the senders' session lists,
   * which are file-static inside the vendored code and unreachable here. Whether
   * a stream is actually served is decided again at write time below. */
  for (device = device_list; device; device = device->next)
    {
      if (!device->session || device->idle_fill_suppressed)
        continue;
      if (device->state != OUTPUT_STATE_CONNECTED && device->state != OUTPUT_STATE_STREAMING)
        continue;

      for (j = 0; j < live_count; j++)
        if (live[j] == device->stream_id)
          break;

      if (j == live_count && live_count < IDLE_FILL_MAX_STREAMS)
        live[live_count++] = device->stream_id;
    }

  /* Release before claiming, so a stream whose devices have gone frees its slot
   * for a stream that just gained one. Forgetting also means a later session on
   * the same stream is seeded fresh rather than from a stale end time. */
  for (i = 0; i < IDLE_FILL_MAX_STREAMS; i++)
    {
      if (!idle_fill_table[i].in_use)
        continue;

      for (j = 0; j < live_count; j++)
        if (live[j] == idle_fill_table[i].stream_id)
          break;

      if (j == live_count)
        idle_fill_table[i].in_use = false;
    }

  for (j = 0; j < live_count; j++)
    {
      struct idle_fill_entry *entry = idle_fill_entry_claim(live[j]);
      struct output_buffer obuf;
      int64_t end_ns;
      int64_t owed_ns;
      int packets;
      int p;

      if (!entry)
        continue;

      /* A stream the host has never written starts one packet behind now, so
       * this cycle owes nothing and later cycles owe only what has elapsed. */
      if (entry->end_pts.tv_sec == 0 && entry->end_pts.tv_nsec == 0)
        entry->end_pts = idle_fill_ts(now_ns - one_packet_ns);

      /* Re-validate against the registry right before writing, never from the
       * enumeration above: a device whose teardown started in between must not
       * be fed. This also applies the wrong-format disqualification. */
      if (!idle_fill_stream_servable(live[j]))
        continue;
      if (now_ns - idle_fill_ns(entry->last_host_write_mono) < IDLE_FILL_QUIET_NS)
        continue;

      /* Stay one packet behind the present, so the fill never claims time that
       * has not passed and the host can take over without overlapping it. */
      end_ns = idle_fill_ns(entry->end_pts);
      owed_ns = (now_ns - one_packet_ns) - end_ns;
      if (owed_ns < one_packet_ns)
        continue;

      packets = (int)(owed_ns / one_packet_ns);
      if (packets > IDLE_FILL_MAX_PACKETS)
        packets = IDLE_FILL_MAX_PACKETS;

      memset(&obuf, 0, sizeof(obuf));
      obuf.data[0].quality.sample_rate = IDLE_FILL_RATE;
      obuf.data[0].quality.bits_per_sample = IDLE_FILL_BITS;
      obuf.data[0].quality.channels = IDLE_FILL_CHANNELS;
      obuf.data[0].stream_id = entry->stream_id;
      obuf.data[0].buffer = idle_fill_silence;
      obuf.data[0].bufsize = sizeof(idle_fill_silence);
      obuf.data[0].samples = IDLE_FILL_PACKET_SAMPLES;

      for (p = 0; p < packets; p++)
        {
          obuf.pts = idle_fill_ts(end_ns + (int64_t)p * one_packet_ns);
          if (output_raop.write)
            output_raop.write(&obuf);
          if (output_airplay.write)
            output_airplay.write(&obuf);
        }

      entry->end_pts = idle_fill_ts(end_ns +
                                    idle_fill_samples_to_ns((int64_t)packets * IDLE_FILL_PACKET_SAMPLES));
      total += packets * IDLE_FILL_PACKET_SAMPLES;
    }

  return total;
}

static void
idle_fill_timer_cb(int fd, short what, void *arg)
{
  struct timespec now;

  (void)fd;
  (void)what;
  (void)arg;

  clock_gettime(CLOCK_MONOTONIC, &now);
  idle_fill_tick(now);
}

/* Test seam (NOT a shipping API): headless mode has no event base, so the timer
 * above cannot fire; a test runs one cycle at a time of its own choosing. */
int
outputs_idle_fill_tick_for_test(struct timespec now)
{
  return idle_fill_tick(now);
}

struct timespec
outputs_idle_fill_end_pts_for_test(uint32_t stream_id)
{
  struct idle_fill_entry *entry = idle_fill_entry_find(stream_id);
  struct timespec none = { 0, 0 };

  return entry ? entry->end_pts : none;
}

/* Broadcast the buffer to BOTH backends (raop-seam-brief §6.3, contract-critical
 * R1). Each backend's write iterates its OWN static master-session list and
 * self-filters by quality/stream_id, so the same obuf fed to both is correct —
 * RAOP sessions get RAOP packets, AP2 sessions get AP2 packets, no cross-talk,
 * and a backend with no matching session no-ops. Order is irrelevant (the
 * session sets are disjoint). Engine thread only (hot path). */
void
outputs_write(struct output_buffer *buffer)
{
  idle_fill_note_host_write(buffer);

  if (output_raop.write)
    output_raop.write(buffer);
  if (output_airplay.write)
    output_airplay.write(buffer);
}

/* Test/diagnostic seam (NOT a shipping API): expose the routing decision so a
 * headless test can prove a device dispatches to output_raop vs output_airplay
 * by type WITHOUT opening a socket or running a session. The per-op wrappers
 * above all route through backend_for(); this returns the same pointer. */
const struct output_definition *
outputs_backend_definition_for(struct output_device *device)
{
  return backend_for(device);
}

/* ============================ R-A CALLBACK DISPATCHER ======================
 *
 * Port of OwnTone src/outputs.c's callback-accounting machinery, narrowed to the
 * single-backend AirPlay engine and extended with an engine completion hook.
 *
 * Contract (docs/outputs-dispatcher-contract.md): every device_* op that returns
 * a positive N promises exactly N outputs_cb() calls for the callback_id it was
 * handed, and in this cluster N is always 0 or 1. The registry keys on a stable
 * callback_id (int slot index) and re-resolves the device by device_id at
 * delivery time — so the start_retry id-hand-off (§4c) still delivers exactly
 * one completion even though the original session was torn down.
 *
 * CRITICAL (§4c): a waiter is released ONLY through outputs_cb -> deferred
 * delivery. Session teardown must never clear a pending slot. We therefore do
 * NOT call outputs_callback_remove() on session_cleanup; the slot is cleared
 * only when its deferred completion is delivered (or explicitly by the issuer
 * before it hands the id to the backend).
 */

#define OUTPUTS_MAX_CALLBACKS 64

struct outputs_callback_register
{
  output_status_cb cb;          /* who to notify (the player/engine status cb) */
  struct output_device *device; /* which device armed it (pointer used only for
                                 * add/remove matching — never dereferenced at
                                 * delivery time; it may have been freed) */
  bool ready;                   /* backend has reported via outputs_cb */
  uint64_t device_id;           /* captured at report time (stable across free) */
  enum output_device_state state;
};

static struct outputs_callback_register outputs_cb_register[OUTPUTS_MAX_CALLBACKS];

/* The engine-thread deferred-delivery event on evbase_player. outputs_cb marks a
 * slot ready and event_active()s this; the loop then runs deferred_cb -> the
 * shared drain. NULL until outputs_dispatcher_init runs (T-API-1). When NULL
 * (unit test, or pre-init) callers drive delivery via outputs_cb_deferred_run(). */
static struct event *outputs_deferredev = NULL;

/* Engine completion hook (T-API-1 registers a C shim that resumes the async
 * Swift continuation waiting on callback_id). */
static outputs_engine_completion_cb outputs_engine_completion = NULL;
static void *outputs_engine_completion_ctx = NULL;

/* Engine device-state hook (T-ENG-STATESTREAM-1). Fired for EVERY delivered
 * report — armed slots AND the out-of-band, spent-id reports below — so the
 * engine can drive an async device-state stream with no polling. */
static outputs_engine_state_cb outputs_engine_state = NULL;
static void *outputs_engine_state_ctx = NULL;

/* Out-of-band state-notification ring (T-ENG-STATESTREAM-1).
 *
 * A report whose callback_id is spent (< 0, the sentinel airplay.c sets after a
 * terminal completion) or otherwise not tied to a live registry slot has no slot
 * to ride in the callback register. To make those transitions observable to the
 * state hook WITHOUT resurrecting a completion (the async waiter must stay a
 * once-only, callback_id-keyed contract — contract §1), we record them in a
 * small deferred ring keyed by device_id only, drained in the same pass and
 * routed ONLY to the state hook (never the completion hook).
 *
 * A ring (not a growable queue) keeps the shim allocation-free and bounded; the
 * volume of out-of-band transitions between two drains is tiny (one device
 * emits at most a couple of post-terminal transitions per drain interval). If it
 * ever overflows we drop the oldest and log — a dropped state note only costs a
 * momentarily stale stream value, never a hang. */
#define OUTPUTS_MAX_STATE_NOTES 64

struct outputs_state_note
{
  uint64_t device_id;
  enum output_device_state state;
};

static struct outputs_state_note outputs_state_ring[OUTPUTS_MAX_STATE_NOTES];
static unsigned int outputs_state_ring_head; /* next slot to write */
static unsigned int outputs_state_ring_count;

/* Enqueue an out-of-band state note for deferred delivery to the state hook. */
static void
outputs_state_note_enqueue(uint64_t device_id, enum output_device_state state)
{
  unsigned int slot;

  if (outputs_state_ring_count == OUTPUTS_MAX_STATE_NOTES)
    {
      /* Full: drop the oldest to make room (state notes are advisory). */
      DPRINTF(E_LOG, L_AIRPLAY, "Output state-note ring full (size %d); dropping oldest\n", OUTPUTS_MAX_STATE_NOTES);
      outputs_state_ring_head = (outputs_state_ring_head + 1) % OUTPUTS_MAX_STATE_NOTES;
      outputs_state_ring_count--;
    }

  slot = (outputs_state_ring_head + outputs_state_ring_count) % OUTPUTS_MAX_STATE_NOTES;
  outputs_state_ring[slot].device_id = device_id;
  outputs_state_ring[slot].state = state;
  outputs_state_ring_count++;
}

output_status_cb
outputs_callback_get(struct output_device *device)
{
  unsigned int callback_id;

  for (callback_id = 0; callback_id < ARRAY_SIZE(outputs_cb_register); callback_id++)
    if (outputs_cb_register[callback_id].device == device)
      return outputs_cb_register[callback_id].cb;

  return NULL;
}

void
outputs_callback_remove(struct output_device *device)
{
  unsigned int callback_id;

  if (!device)
    return;

  /* Match OwnTone: clear EVERY slot for this device. Note: this must NOT be
   * called from session teardown (§4c) — only by the issuer aborting an op
   * before the backend was invoked. */
  for (callback_id = 0; callback_id < ARRAY_SIZE(outputs_cb_register); callback_id++)
    if (outputs_cb_register[callback_id].device == device)
      memset(&outputs_cb_register[callback_id], 0, sizeof(outputs_cb_register[callback_id]));
}

void
outputs_callback_clear(int callback_id)
{
  /* Clear exactly one slot by id (B5). A timed-out op leaves its slot armed
   * (cb != NULL) forever; without this, OUTPUTS_MAX_CALLBACKS such leaks
   * exhaust the register and outputs_callback_add returns -1 for every op. */
  if (callback_id < 0 || (unsigned int)callback_id >= ARRAY_SIZE(outputs_cb_register))
    return;
  memset(&outputs_cb_register[callback_id], 0, sizeof(outputs_cb_register[callback_id]));
}

void
outputs_registry_clear(void)
{
  /* C2: empty the registry on stop() so a fresh start() begins clean.
   * airplay_deinit frees the sessions but leaves device->session dangling and
   * never empties device_list — so a stop→start cycle would otherwise inherit
   * freed session pointers and stale devices. NULL each session (already freed
   * by airplay_deinit — do NOT double-free) so outputs_device_free's
   * active-session BUG log doesn't fire, then free every device. */
  while (device_list)
    {
      struct output_device *d = device_list;
      device_list = d->next;
      d->session = NULL;
      outputs_device_free(d);
    }

  /* Drop any leaked callback slots + out-of-band state notes from the old run. */
  memset(outputs_cb_register, 0, sizeof(outputs_cb_register));
  memset(outputs_state_ring, 0, sizeof(outputs_state_ring));
  outputs_state_ring_head = 0;
  outputs_state_ring_count = 0;
}

int
outputs_callback_add(struct output_device *device, output_status_cb cb)
{
  unsigned int callback_id;

  if (!cb)
    return -1;

  /* Replace any previously registered callback for this device — one pending
   * callback per device, "since that's what the player expects". */
  outputs_callback_remove(device);

  for (callback_id = 0; callback_id < ARRAY_SIZE(outputs_cb_register); callback_id++)
    if (outputs_cb_register[callback_id].cb == NULL)
      break;

  if (callback_id == ARRAY_SIZE(outputs_cb_register))
    {
      DPRINTF(E_LOG, L_AIRPLAY, "Output callback queue is full! (size is %d)\n", OUTPUTS_MAX_CALLBACKS);
      return -1;
    }

  outputs_cb_register[callback_id].cb = cb;
  outputs_cb_register[callback_id].device = device; /* don't dereference later! */

  return (int)callback_id;
}

/* The shared deferred-delivery pass. Runs on the engine thread (either from the
 * libevent deferred event, or synchronously from outputs_cb_deferred_run in the
 * unit test). Copies each ready slot, clears it, re-resolves the device by id,
 * updates device->state, invokes the status cb, then fires the engine hook. */
static void
outputs_cb_deferred_drain(void)
{
  struct output_device *device;
  output_status_cb cb;
  enum output_device_state state;
  uint64_t device_id;
  unsigned int callback_id;

  for (callback_id = 0; callback_id < ARRAY_SIZE(outputs_cb_register); callback_id++)
    {
      if (!outputs_cb_register[callback_id].ready)
        continue;

      /* Copy out BEFORE the callback runs — the cb may re-enter (issue a new op
       * that reallocates this very slot). */
      cb = outputs_cb_register[callback_id].cb;
      state = outputs_cb_register[callback_id].state;
      device_id = outputs_cb_register[callback_id].device_id;

      /* NULL if the device disappeared between report and delivery. */
      device = outputs_device_get(device_id);

      memset(&outputs_cb_register[callback_id], 0, sizeof(outputs_cb_register[callback_id]));

      /* Device has left the building (stopped/failed) and the backend no longer
       * holds it — drop it from the registry, deliver a NULL device. */
      if (device && !device->advertised && !device->session)
        {
          outputs_device_remove(device);
          device = NULL;
        }
      else if (device)
        device->state = state;

      if (cb)
        cb(device, state);

      /* Engine completion hook: unblock the async waiter on this id. */
      if (outputs_engine_completion)
        outputs_engine_completion((int)callback_id, device_id, state, outputs_engine_completion_ctx);

      /* Engine state hook LAST: an armed report is also a state transition, so
       * feed it to the device-state stream (T-ENG-STATESTREAM-1). The
       * out-of-band ring below carries the transitions that spend no slot. */
      if (outputs_engine_state)
        outputs_engine_state(device_id, state, outputs_engine_state_ctx);
    }

  /* Drain the out-of-band state notes (spent-id / not-a-slot reports). These go
   * ONLY to the state hook — never the completion hook — so the once-only,
   * callback_id-keyed async waiter contract (§1) is preserved. Snapshot the
   * count first: the state hook must not be able to grow the ring mid-drain
   * (it runs on this same thread; a re-entrant enqueue is deferred to the next
   * pass, exactly like the callback register above). */
  {
    unsigned int n = outputs_state_ring_count;
    unsigned int i;
    for (i = 0; i < n; i++)
      {
        uint64_t device_id = outputs_state_ring[outputs_state_ring_head].device_id;
        enum output_device_state state = outputs_state_ring[outputs_state_ring_head].state;
        struct output_device *device;

        outputs_state_ring_head = (outputs_state_ring_head + 1) % OUTPUTS_MAX_STATE_NOTES;
        outputs_state_ring_count--;

        /* Update device->state for the out-of-band report too, mirroring the
         * armed-slot path above (device->state = state). airplay.c only ever
         * writes session->state, never device->state, so this drain is the SOLE
         * writer of device->state — and without this the field stays pinned at
         * the value the last armed completion left (e.g. CONNECTED) even after a
         * receiver drops RTSP and reports FAILED via outputs_cb(-1,…). The
         * engine's idempotency guards read device->state (AirPlayEngine
         * liveDeviceState); a stale CONNECTED there would defeat the recovery
         * re-issue of device_start. Re-resolve by id — the device may have been
         * freed between report and delivery. */
        device = outputs_device_get(device_id);
        if (device)
          device->state = state;

        if (outputs_engine_state)
          outputs_engine_state(device_id, state, outputs_engine_state_ctx);
      }
  }
}

/* libevent entry point (production). */
static void
deferred_cb(int fd, short what, void *arg)
{
  (void)fd;
  (void)what;
  (void)arg;
  outputs_cb_deferred_drain();
}

void
outputs_cb(int callback_id, uint64_t device_id, enum output_device_state state)
{
  /* A negative id is the legitimate "no callback promised / already spent"
   * sentinel that airplay.c clears to -1 after firing a terminal completion
   * (contract §1). It resolves NO async waiter — but it IS still a real device
   * state transition (e.g. rtsp_close_cb -> session_failure -> FAILED reported
   * after device_start's CONNECTED already spent the id). Route it out-of-band
   * to the device-state stream (T-ENG-STATESTREAM-1) instead of dropping it. */
  if (callback_id < 0)
    {
      outputs_state_note_enqueue(device_id, state);
      if (outputs_deferredev)
        event_active(outputs_deferredev, 0, 0);
      return;
    }

  if (!((unsigned int)callback_id < ARRAY_SIZE(outputs_cb_register)) ||
      !outputs_cb_register[callback_id].cb)
    {
      DPRINTF(E_LOG, L_AIRPLAY, "Bug! Output backend called us with an illegal callback id (%d)\n", callback_id);
      return;
    }

  outputs_cb_register[callback_id].ready = true;
  outputs_cb_register[callback_id].device_id = device_id;
  outputs_cb_register[callback_id].state = state;

  /* Hop onto the engine loop (never deliver inline — re-entrancy safety). If the
   * loop event isn't wired yet (pre-init / unit test), the caller drives the
   * drain explicitly via outputs_cb_deferred_run(). */
  if (outputs_deferredev)
    event_active(outputs_deferredev, 0, 0);
}

void
outputs_engine_completion_set(outputs_engine_completion_cb cb, void *context)
{
  outputs_engine_completion = cb;
  outputs_engine_completion_ctx = context;
}

void
outputs_engine_state_set(outputs_engine_state_cb cb, void *context)
{
  outputs_engine_state = cb;
  outputs_engine_state_ctx = context;
}

void
outputs_cb_deferred_run(void)
{
  outputs_cb_deferred_drain();
}

void
outputs_dispatcher_reset(void)
{
  memset(outputs_cb_register, 0, sizeof(outputs_cb_register));
  outputs_engine_completion = NULL;
  outputs_engine_completion_ctx = NULL;
  outputs_engine_state = NULL;
  outputs_engine_state_ctx = NULL;
  memset(outputs_state_ring, 0, sizeof(outputs_state_ring));
  outputs_state_ring_head = 0;
  outputs_state_ring_count = 0;
  idle_fill_forget_all();
}

/* Wire the deferred event to evbase_player. T-API-1 calls this after setting
 * evbase_player and before airplay_init. Kept separate from outputs_cb so the
 * dispatcher is testable without a libevent base. */
int
outputs_dispatcher_init(void)
{
  if (!evbase_player)
    {
      DPRINTF(E_LOG, L_AIRPLAY, "outputs_dispatcher_init: evbase_player not set\n");
      return -1;
    }
  if (outputs_deferredev)
    return 0; /* already initialised */

  outputs_deferredev = evtimer_new(evbase_player, deferred_cb, NULL);
  if (!outputs_deferredev)
    return -1;

  /* The idle silence fill runs off this same base, so it lives exactly as long
   * as the engine does. Headless tests never reach here (no base), and drive
   * the fill through its test seam instead. */
  if (!idle_fill_timer)
    {
      struct timeval tick = { 0, IDLE_FILL_TICK_MS * 1000 };

      idle_fill_timer = event_new(evbase_player, -1, EV_PERSIST, idle_fill_timer_cb, NULL);
      if (!idle_fill_timer)
        return -1;
      event_add(idle_fill_timer, &tick);
    }

  return 0;
}

void
outputs_dispatcher_deinit(void)
{
  if (outputs_deferredev)
    {
      event_free(outputs_deferredev);
      outputs_deferredev = NULL;
    }
  if (idle_fill_timer)
    {
      event_free(idle_fill_timer);
      idle_fill_timer = NULL;
    }
  idle_fill_forget_all();
}

const char *
outputs_name(enum output_types type)
{
  (void)type;
  return "AirPlay 2"; // neutral rename happens at the Swift/product layer
}

int
outputs_quality_subscribe(struct media_quality *quality)
{
  (void)quality;
  // TODO(T-SHIM-1): track the single 44100/16/2 quality. Stub: success.
  return 0;
}

void
outputs_quality_unsubscribe(struct media_quality *quality)
{
  (void)quality;
}

/* The served start-buffer duration. Default = OwnTone's general.start_buffer_ms
 * default (seam-map §3.1). airplay.c turns this into the sender-side scheduling
 * lead (output_buffer_samples = (ms - 250) worth of samples), which is the
 * dominant deterministic term of capture->speaker latency — see
 * docs/latency-analysis.md. Mutated only by outputs_set_buffer_duration_ms()
 * (engine config, before airplay_init). */
static uint64_t outputs_start_buffer_ms = OUTPUTS_START_BUFFER_MS_DEFAULT;

uint64_t
outputs_buffer_duration_ms_get(void)
{
  return outputs_start_buffer_ms;
}

void
outputs_set_buffer_duration_ms(uint64_t ms)
{
  uint64_t clamped = ms;

  if (clamped < OUTPUTS_START_BUFFER_MS_MIN)
    clamped = OUTPUTS_START_BUFFER_MS_MIN;
  else if (clamped > OUTPUTS_START_BUFFER_MS_MAX)
    clamped = OUTPUTS_START_BUFFER_MS_MAX;

  if (clamped != ms)
    DPRINTF(E_WARN, L_PLAYER,
            "start_buffer_ms %" PRIu64 " out of range [%d, %d] — clamped to %" PRIu64 "\n",
            ms, OUTPUTS_START_BUFFER_MS_MIN, OUTPUTS_START_BUFFER_MS_MAX, clamped);

  outputs_start_buffer_ms = clamped;
}

bool
outputs_exclusive_mode_get(void)
{
  return false; // single-purpose engine
}

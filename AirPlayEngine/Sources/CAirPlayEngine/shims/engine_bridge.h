// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_bridge — SHIM (T-API-1). The thin non-static C surface the Swift
// wrapper (Sources/AirPlayEngine) calls to drive the vendored sender cluster.
//
// WHY THIS EXISTS. The sender's four "verbs" the Swift layer needs to invoke
// are split across two kinds of C symbols:
//
//   1. output_airplay (the struct output_definition, airplay.c:4385) — a
//      NON-static global. Its .init/.deinit/.device_start/.device_stop/
//      .device_volume_set/.device_cb_set/.write function pointers reach the
//      static airplay_* implementations. Swift CAN take output_airplay and call
//      through those pointers, so those verbs need NO bridge.
//
//   2. airplay_device_cb (airplay.c:3927) — the discovery-IN entry point — is
//      STATIC, so Swift cannot name it. BUT airplay_init hands it to
//      mdns_browse("_airplay._tcp", airplay_device_cb, ...) (airplay.c:4342).
//      Our mdns_browse shim (shims/mdns.c) therefore RECEIVES that static
//      function pointer at init time. We capture it there and expose it here as
//      airplayengine_feed_device(). This drives discovery IN (seam-map §4)
//      WITHOUT editing the GPL vendored source at all.
//
// Everything here runs on the engine thread (seam-map §8, risk R-B). The Swift
// wrapper marshals every call onto that thread; this header just declares the
// C surface — it does no threading itself.

#ifndef CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H
#define CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#include "misc.h"    /* struct keyval */
#include "mdns.h"    /* mdns_browse_cb (== airplay_device_cb's signature) */
#include "outputs.h" /* struct output_definition, struct event_base */

#ifdef __cplusplus
extern "C" {
#endif

/* The single backend the engine ships (struct output_definition output_airplay,
 * airplay.c:4385). NON-static, so Swift can take it and call through its
 * .init / .deinit / .device_start / .device_stop / .device_volume_set /
 * .device_cb_set / .write function pointers directly — those are the session
 * verbs (seam-map §2.1). Declared here so the Swift wrapper sees it via the
 * umbrella header (airplay.c has no public header of its own). */
extern struct output_definition output_airplay;

/* [AirPlayEngine vendored change 2026-07-19] The RAOP (AirPlay 1) backend
 * (struct output_definition output_raop, sender/raop.c). NON-static, the file's
 * only external symbol — every raop_* helper is file-static, so it never clashes
 * with airplay.c's identically-named statics. Declared here so the Swift wrapper
 * (and the headless test) can reach it through the umbrella header the same way
 * they reach output_airplay: read its fields and call through its
 * .device_volume_to_pct / .device_probe / .write function pointers. The
 * two-backend dispatch that fans engine ops to output_airplay OR output_raop by
 * device->type is a later integration step (see docs/raop-seam-brief.md §6);
 * this task only ports and links the backend. */
extern struct output_definition output_raop;

/* The player thread's libevent base (airplay.c:459, defined in shims/outputs.c).
 * The Swift wrapper sets this to the engine thread's event_base BEFORE
 * airplay_init, then calls outputs_dispatcher_init() (seam-map §8, risk R-B). */
extern struct event_base *evbase_player;

/* One-time process-wide crypto initialization, called by the Swift wrapper
 * BEFORE airplay_init. libgcrypt's documentation requires the APPLICATION
 * (not a library) to run gcry_check_version() + GCRYCTL_INITIALIZATION_FINISHED;
 * pair_ap only CHECKS this via is_initialized() (pair.c) and, when the app
 * never did it, pair_setup_new() fails with the misleading "Out of memory for
 * verification setup context" log. OwnTone's main() did this init; the engine
 * must do its own. Found at the gated first-light (2026-07-16). Also runs
 * sodium_init(). Idempotent. Returns 0 on success, -1 on failure. */
int
engine_crypto_init(void);

/* Set SIGPIPE's process-wide disposition to SIG_IGN. OwnTone's main() does
 * this before spawning any threads (main.c:718-732) so a write() to a
 * socket whose peer has closed its end returns EPIPE instead of killing
 * the process with an unhandled signal; our hosting never did (first-light
 * backlog #2). The Swift wrapper calls this once on the engine thread,
 * before airplay_init opens any sockets. Idempotent — safe to call more
 * than once. */
void
engine_mask_sigpipe(void);

/* True once airplay_init has run and mdns_browse captured the device callback.
 * Discovery feeds are dropped (return false) before this. */
bool
airplayengine_discovery_ready(void);

/* Feed a resolved device descriptor into the sender's discovery path — this is
 * the app-owned NWBrowser -> engine seam (seam-map §4). It calls the captured
 * airplay_device_cb(name, "_airplay._tcp", "local", hostname, family, address,
 * port, txt) exactly as OwnTone's mDNS browse would have. `port > 0` = device
 * appeared/updated; `port < 0` = device disappeared (removal, matched by name).
 *
 * `txt` is a keyval built by the caller from the DNS-SD TXT record (deviceid,
 * features, model — seam-map §4). Ownership stays with the caller; the cb reads
 * it synchronously and does not retain it.
 *
 * Returns 0 if delivered, -1 if discovery isn't ready yet (init not run).
 * MUST be called on the engine thread. */
int
airplayengine_feed_device(const char *name, const char *hostname, int family,
                          const char *address, int port, struct keyval *txt);

/* [AirPlayEngine vendored change 2026-07-19] RAOP (AirPlay 1) analogue of the
 * two entries above (raop-seam-brief §6.6). True once raop_init has run and
 * mdns_browse captured raop_device_cb ("_raop._tcp"). */
bool
airplayengine_raop_discovery_ready(void);

/* Feed a resolved device descriptor into the RAOP backend's discovery path —
 * same seam and shape as airplayengine_feed_device, but calls the captured
 * raop_device_cb(name, "_raop._tcp", "local", hostname, family, address, port,
 * txt) instead. A device that advertises both _airplay._tcp and _raop._tcp is
 * fed to whichever backend(s) the app chooses by calling the matching feed
 * entry (or both).
 *
 * Returns 0 if delivered, -1 if RAOP discovery isn't ready yet (raop_init not
 * run). MUST be called on the engine thread. */
int
airplayengine_feed_raop_device(const char *name, const char *hostname, int family,
                               const char *address, int port, struct keyval *txt);

/* [AirPlayEngine vendored change 2026-07-17] P2b TEST/DIAGNOSTIC SEAM. These
 * accessors (defined in sender/airplay.c) expose the otherwise-static
 * master-session cache so the headless multi-stream test can prove that distinct
 * stream_ids bind to distinct master sessions. NOT part of the shipping session
 * API — do not call these from production code.
 *
 *   _make  : build (or reuse) a master session for (stream_id, quality, use_ptp),
 *            returning an opaque pointer to it (the real master_session_make).
 *   _stream_id : read a master session's stream_id back off that opaque pointer.
 *   _count : number of live master sessions.
 *   _reset : tear every master session down (between test cases).
 *
 * MUST be called on the engine thread (or, in a headless test, with no engine
 * thread running and no sessions attached). */
void *
airplay_test_master_session_make(uint32_t stream_id, struct media_quality *quality, bool use_ptp);
uint32_t
airplay_test_master_session_stream_id(const void *ams);
/* [AirPlayEngine vendored change 2026-07-17] P2b/T2: sample count accumulated
 * in this master session's input_buffer by airplay_write's fan-out — lets a
 * headless test prove distinct stream_ids never cross-pollute each other's
 * buffer when driven through the real AirPlayEngine.write(pcm:streamId:pts:)
 * API. See airplay.c for the full rationale. */
uint32_t
airplay_test_master_session_input_buffer_samples(const void *ams);
int
airplay_test_master_session_count(void);
void
airplay_test_master_sessions_reset(void);

/* [AirPlayEngine vendored change 2026-07-19] P2b TEST/DIAGNOSTIC SEAM for the
 * RAOP/AirPlay-1 sender — mirror of the airplay_test_master_session_* accessors
 * above (defined in sender/raop.c). Expose the otherwise-static RAOP
 * master-session cache so the headless multi-stream test can prove distinct
 * stream_ids bind to distinct master sessions, and that raop_write's fan-out
 * routes a PCM blob only into the master session whose stream_id matches. NOT
 * part of the shipping session API — do not call from production code.
 *
 *   _make  : build (or reuse) a master session for (stream_id, quality, encrypt),
 *            returning an opaque pointer to it (the real master_session_make).
 *   _stream_id : read a master session's stream_id back off that opaque pointer.
 *   _input_buffer_samples : samples raop_write has accumulated into it.
 *   _count : number of live master sessions.
 *   _reset : tear every master session down (between test cases).
 *   _write_one : drive the real raop_write with a one-entry output_buffer tagged
 *                with the given stream_id/quality (proves the cross-talk gate). */
void *
raop_test_master_session_make(uint32_t stream_id, struct media_quality *quality, bool encrypt);
uint32_t
raop_test_master_session_stream_id(const void *rms);
uint32_t
raop_test_master_session_input_buffer_samples(const void *rms);
int
raop_test_master_session_count(void);
void
raop_test_master_sessions_reset(void);
void
raop_test_write_one(uint32_t stream_id, struct media_quality *quality, const void *pcm, size_t bufsize, uint32_t samples, uint32_t pts_sec);

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_ENGINE_BRIDGE_H */

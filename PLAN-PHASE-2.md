# PLAN — Phase 2: Native, Swift-wrapped AirPlay 2 sender engine

Extract OwnTone's AirPlay 2 sender (`airplay.c` + `airplay_events.c` +
`rtp_common.c` + `libairptp` + `pair_ap` + `evrtsp`) into an engine **we own and
name neutrally**, wrap it in a Swift API, verify it against a receiver harness,
and land it behind the existing `OutputBackend` seam as `NativeBackend`
(`AIRPLAY_BACKEND=native`). The shipped product carries **zero OwnTone
references** (SPEC.md §4). Only a tiny PTP clock helper ever runs privileged.

Status: PLANNING. Phase 1 is being planned/executed in parallel — this plan does
**not** edit `PLAN-PHASE-1.md` or claim its files.

---

## A. End state (one paragraph)

A new, self-contained C/Swift package (recommended: `Sources/AirPlayEngine` +
a vendored C target `Sources/CAirPlayEngine`) builds the extracted AirPlay 2
sender as a static library against brew libs (libevent, libsodium, libgcrypt,
libplist, ffmpeg-for-ALAC), with all OwnTone plumbing (`conffile`, `logger`,
`mdns`, `player`, `db`, `artwork`, `transcode`, `outputs.c`) replaced by thin
shims we own. A Swift wrapper exposes a neutral session API (start/stop session,
add/remove output by address+params, per-output volume, write PCM frames, clock
status, pairing). A receiver-side PCM-capture harness (Phase-0 verify-script
idiom, PASS/FAIL verdicts) proves the sender works without real speakers. The
engine is exposed to the app as `NativeBackend : OutputBackend`, selected by
`AIRPLAY_BACKEND=native`. The privileged PTP boundary is delivered as a
**design document** this phase (the MIT-licensed `libairptp` shared-daemon mode →
an `SMAppService` launchd daemon), with an `osascript`-admin dev launch as the
interim for live tests. Real-Sonos/HomePod behavior remains a deferred
real-hardware checkpoint.

---

## B. OPEN QUESTIONS — needs confirmation

> Resolve these before/at the start of execution. Recommended answer marked.

- **Q1 — Verification receiver on macOS (BIGGEST unknown).** The suggested harness
  is "shairport-sync as an AP2 receiver + nqptp." Research (mikebrady docs) says
  shairport-sync **cannot run in AirPlay-2 mode on macOS** — nqptp needs UDP
  319/320 which macOS reserves, and there is "no feasible workaround." Also nqptp
  contends with our engine's own PTP on the same Mac (can't run both live at
  once). How do we verify PTP-timed AP2 send without real speakers?
  - (a, **recommended**) **Two-host harness:** run shairport-sync AP2 + nqptp on a
    cheap Linux box / Raspberry Pi / spare Mac on the LAN as the receiver; the
    engine (with its PTP) runs on the dev Mac. Sidesteps the single-host 319/320
    war entirely and is the only setup that exercises *real* PTP timing. Needs one
    extra device (confirm Alec has/will get a Pi or second machine).
  - (b) **Linux VM / Docker receiver** on the same Mac with a bridged/macvlan NIC
    so nqptp binds 319/320 *inside the guest* (host still reserves them, but the
    guest has its own stack). Verify multicast/PTP crosses the bridge — often
    flaky; medium confidence.
  - (c) **Cut PTP out of the verification loop:** verify RTSP handshake + pairing +
    ALAC RTP framing + volume against an **AirPlay-1 / NTP** shairport receiver
    (the existing `dev/fake-speakers.sh`), and treat PTP-timed multi-room as a
    pure deferred real-hardware checkpoint (matches how Phase 0 closed 0d/0f).
    Cheapest, no new hardware, but leaves the single riskiest bit (PTP) unproven
    until speakers return.
  - (d) Buy back access to the Sonos/AirPort Express sooner and make real hardware
    the harness.
  - Recommendation: **(a) if a second host is available, else (c) as the interim**
    with PTP explicitly deferred. Do NOT sink time into (b) unless (a) is
    impossible. This choice reshapes Wave 3's harness task — flagged in each.

- **Q2 — ALAC encoder dependency.** `airplay.c` requires an ALAC encoder — it calls
  `transcode_encode(..., XCODE_ALAC, ...)`, and OwnTone's `transcode.c` wraps
  **ffmpeg/libavcodec** (airplay.c:1152, and it even logs "ffmpeg has no ALAC
  encoder" at :1192). We must supply ALAC. Which route?
  - (a, **recommended**) **Link ffmpeg/libavcodec** (already brew-installed) and
    port a *minimal* `transcode_encode`-shaped shim that drives only ALAC encode +
    PCM16 raw decode-setup — the two profiles airplay.c actually uses (XCODE_ALAC,
    XCODE_PCM16). Reuses the exact codepath OwnTone validated; heaviest dep but
    lowest protocol risk.
  - (b) Vendor **Apple's open-source ALAC encoder** (Apple ALAC, Apache-2.0,
    ~small) and write a tiny encoder shim, dropping the ffmpeg dependency
    entirely. Much lighter runtime, cleaner licensing story, but new integration
    risk (frame sizing / bitstream must match what receivers expect).
  - (c) Use macOS **AudioToolbox** `kAudioFormatAppleLossless`
    `AudioConverter` — zero third-party dep, but ALAC magic-cookie/packetization
    for the AirPlay RTP payload must be reverse-matched; highest unknown.
  - Recommendation: **(a) to get first light**, then evaluate **(b)** as a
    dependency-shedding follow-up before ship (ffmpeg is a large dep for a
    "read-it-line-by-line" ideal). Note: check whether target receivers accept
    the raw/PCM AirPlay-2 path so ALAC can be skipped — see Q6.

- **Q3 — Engine package placement & build model.** Where does the C+Swift engine
  live and how is it built?
  - (a, **recommended**) A **new top-level SwiftPM package** `AirPlayEngine/`
    (its own `Package.swift`, `.macOS(.v14)`) with a C target
    (`CAirPlayEngine`, the vendored sources + a module map) and a Swift target
    wrapping it; `AirPlayControllerCore` depends on it only via the
    `NativeBackend`. Keeps the extracted GPL C isolated in one package, keeps the
    v13 core lib clean, and lets the engine build/test independently.
  - (b) Add a `CAirPlayEngine` target *inside* `AirPlayControllerCore/Package.swift`.
    Simpler wiring, but drags brew/C build flags + GPL sources into the core lib
    and forces its platform up to v14.
  - (c) Build the C cluster as a **standalone static lib via Makefile/CMake**
    (mirrors OwnTone's autotools) and link the `.a` into a thin SwiftPM C target.
    Closest to how the sources build today (evrtsp/libairptp have autotools), but
    two build systems to maintain.
  - Recommendation: **(a)**, with the C sources compiled by SwiftPM's clang via a
    module map + `unsafeFlags` for brew include/lib paths. `libairptp` may still
    build via its own autotools `Makefile` into `libairptp.a` and be linked
    (it's self-contained by design) — decide per T-BUILD-1's findings.

- **Q4 — GPL licensing posture (personal, non-distributed).** airplay.c /
  airplay_events.c / rtp_common.c are **GPL-2.0+**; pair_ap + libairptp are
  **MIT**; evrtsp is **BSD (Provos/Blaché)**. For Alec's personal, non-distributed
  tool, GPL imposes no obligation (no distribution = no trigger). But it caps
  future options. Confirm intent:
  - (a, **recommended**) **Personal use only, never distribute** — GPL is a
    non-issue; proceed. Add a NOTICE recording the licenses per component.
  - (b) If distribution is ever wanted, the GPL sender forces GPL on the whole
    linked app (incl. the AppKit UI) — a deliberate choice, not an accident.
  - Recommendation: (a); record the split so a future distribute decision is
    informed, not surprised.

- **Q5 — Discovery ownership.** airplay.c includes `mdns.h` and calls
  `mdns_browse()` to discover `_airplay._tcp` and populate device params (address,
  port, txt keys like PTP support, required auth). Phase 1 already does discovery
  via `NWBrowser`. Who owns discovery in the native engine?
  - (a, **recommended**) **App/Phase-1 owns discovery** (NWBrowser); the engine
    takes a fully-resolved output descriptor (host, port, txt-record fields) via
    the Swift API `addOutput(...)`. Cuts the entire `mdns.h` dependency out of the
    C core — one of the larger seam wins — and keeps one discovery implementation.
  - (b) Keep OwnTone's mdns inside the engine (Bonjour via Apple `dns_sd`).
    Duplicates discovery, re-drags the dependency; only worth it if airplay.c's
    session setup is deeply entangled with live mdns callbacks (verify in T-SEAM-1).
  - Recommendation: **(a)** — verify in T-SEAM-1 how much of airplay.c's device
    lifecycle assumes mdns-driven add/remove vs. can be fed a static descriptor.

- **Q6 — Metadata/artwork path: cut it.** airplay.c's only `db`/`artwork` calls are
  in the metadata-send path (airplay.c:1686 `db_queue_fetch_byitemid`, :1698
  `artwork_get_by_queue_item_id`) plus `db_speaker_save` (:3514). Audio-only scope
  (SPEC.md §2) has no now-playing metadata. Confirm we **stub metadata_send /
  metadata_prepare / metadata_purge to no-ops** and drop db/artwork entirely.
  - (a, **recommended**) Stub metadata to no-ops; drop `db.h`/`artwork.h`; replace
    `db_speaker_save` with a no-op (volume persistence, if wanted, lives in the
    Swift/app layer). Big seam win, matches audio-only scope.
  - (b) Keep a minimal metadata channel for future "now playing on speaker"
    nicety. Not in scope now; defer.
  - Recommendation: (a).

- **Q7 — Pairing scope for the test fleet.** `pair_ap` has `pair_fruit.c`
  (AirPlay-2 "fruit"/MFi pairing, used by Apple TV/HomePod) and `pair_homekit.c`
  (HomeKit transient pairing). Phase-0 targets (Sonos, AirPort Express gen2) use
  the non-authenticated / transient path. Do we need full HomeKit PIN pairing now?
  - (a, **recommended**) Port **both** pair_ap modules as-is (they're MIT and
    self-contained) but only *exercise/verify* the transient path the test fleet
    uses; PIN-pairing (Apple TV/HomePod) becomes a deferred checkpoint (no such
    hardware — SPEC.md §6). Zero extra porting cost since we vendor the whole dir.
  - (b) Port only the transient path. Saves nothing (it's one directory) and risks
    needing homekit later.
  - Recommendation: (a).

---

## C. Task list

Legend: `kind` = research | new-code | backend | build | test | docs | design.
`model` = haiku 4.5 | sonnet 5 | opus 4.8. `effort` = low/med/high/xhigh.
Anchors reference the OwnTone source (fresh clone lands at `dev/owntone-src/`;
Phase-0 build tree at the ephemeral scratchpad was used to ground this plan).

### Wave 1 — Acquire + analyze (all parallel; no shared files)

**T-SRC-1 — Fresh shallow clone of OwnTone source**
- files: `dev/owntone-src/` (new, git-ignored — extend `.gitignore`).
- what: `git clone --depth 1 https://github.com/owntone/owntone-server dev/owntone-src`
  (pin the tag matching the Phase-0 build — **29.2**, per SPEC.md §8 0b). Record
  the commit SHA. The Phase-0 scratchpad tree is ephemeral; this is the durable
  source of truth all extraction tasks read from.
- kind: research · depends_on: none
- model: haiku 4.5 — mechanical clone + tag pin + gitignore line.
- effort: low — one clone, verify the six cluster paths exist, note SHA.
- verify: `dev/owntone-src/src/outputs/airplay.c` present; `wc -l` ≈ 4413;
  `.gitignore` contains `dev/owntone-src/`; SHA written to the notes file.

**T-SEAM-1 — Seam-cut analysis of the extraction cluster** ⭐ critical-path seed
- files: `dev/notes/p2-seam-map.md` (new).
- what: Enumerate exactly what `airplay.c` + `airplay_events.c` + `rtp_common.c`
  pull from OwnTone plumbing and design the severing. GROUNDED FINDINGS to build
  on (already verified from source): includes = `conffile.h logger.h mdns.h
  misc.h player.h db.h artwork.h dmap_common.h transcode.h ptpd.h outputs.h`
  + `evrtsp/evrtsp.h` + `pair_ap/pair.h`. Symbol weights: `DPRINTF`×137 (logging
  shim), `cfg_get*` (config shim, ~6 keys), `event_*`/`evbase_player` (libevent —
  KEEP, real dep), `outputs_device_*` (the backend seam we reimplement),
  `mdns_browse`×1 (→ Q5), `player_device_add/remove` (2 callbacks → Swift events),
  `db_queue_fetch_byitemid`/`artwork_*`/`db_speaker_save` (metadata+persist → Q6),
  `transcode_*` (ALAC → Q2). Produce: per-symbol disposition (KEEP-real-dep /
  SHIM / STUB-noop / REPLACE-with-Swift-callback), the shim header list, and the
  reimplemented-`outputs.h` surface (`output_device`, `output_buffer`,
  `media_quality`, `output_status_cb`, `output_device_state`). Also map
  `airplay_events.c` deps and `ptpd.h`→`libairptp` glue (airplay.c uses the
  `ptpd_*` wrapper, not libairptp directly — the shim reimplements `ptpd_*` on
  `airptp_*`).
- kind: research · depends_on: T-SRC-1
- model: opus 4.8 — this analysis is the linchpin; a missed dependency or a wrong
  seam boundary derails every downstream build task. High blast radius.
- effort: high — 4400-line file, careful per-symbol tracing across the cluster.
- verify: every non-libc `#include` in the three GPL files has a disposition;
  the shim `outputs.h` surface compiles against airplay.c's call sites (checked in
  T-SHIM-1); doc reviewed against the grounded symbol list above.

**T-PTP-1 — libairptp interface study + nqptp/shairport clock-sharing comparison**
- files: `dev/notes/p2-ptp-brief.md` (new).
- what: Document `libairptp` public API (grounded: `airptp_daemon_bind(node)` →
  binds 319/320 [root]; `airptp_daemon_start(hdl, clock_id_seed, is_shared)` [no
  priv]; `airptp_daemon_find()`; `airptp_peer_add/remove`; `airptp_clock_id_get`;
  `airptp_ports_override` for tests). Explain the **three modes** (shared daemon /
  private daemon / client). Compare to nqptp's shared-memory interface and how
  shairport-sync consumes it, and how airplay.c consumes `ptpd_*`→libairptp. Nail
  the privilege boundary: **only bind() needs root; start/peer ops don't** — this
  is the crux of the SMAppService split (helper = bind + run master clock;
  unprivileged engine = `airptp_daemon_find()` + peer add/remove). Note
  libairptp is **MIT** (separable from the GPL sender — helper can be its own
  clean binary). Note the `airptp_ports_override` hook enables non-privileged
  local testing on high ports.
- kind: research · depends_on: T-SRC-1 (reads the same clone)
- model: opus 4.8 — the privilege boundary + clock-sharing model is the security
  spine (SPEC.md §4.1); getting it wrong misdesigns the shipped helper.
- effort: med — self-contained lib, interface is small and already read.
- verify: brief states which calls need root, the shared-daemon handshake, and a
  concrete helper↔engine split that T-HELPER-DESIGN-1 can consume.

**T-HARNESS-RESEARCH-1 — Verification receiver feasibility (drives Q1)**
- files: `dev/notes/p2-harness-feasibility.md` (new).
- what: Settle how AP2 send gets verified with no real speakers. GROUNDED: brew
  has `shairport-sync` + `ffmpeg`; `nqptp` is NOT in brew (source build /
  mikebrady tap). Research says shairport AP2 mode is **infeasible on macOS**
  (nqptp vs macOS 319/320). Evaluate Q1 options (a) two-host Pi/second-Mac
  receiver, (b) Linux VM/Docker bridged NIC, (c) AirPlay-1/NTP-only local verify
  via existing `dev/fake-speakers.sh` (PTP deferred). Recommend a concrete harness
  + the exact PASS/FAIL PCM-capture verdict method (Phase-0 idiom:
  receiver-side PCM non-silent + rate-exact + tone/Goertzel check). Restate the
  PTP contention rule: engine-PTP and any nqptp can't hold 319/320 on one host
  simultaneously; live sessions take turns.
- kind: research · depends_on: none
- model: sonnet 5 — mostly empirical/environmental research + a recommendation;
  bounded, not correctness-critical code.
- effort: med — includes trying a shairport source-build feasibility check.
- verify: doc picks a harness aligned with Q1's resolution and names the
  verdict script contract T-HARNESS-2 will implement.

**T-LICENSE-1 — Licensing sanity check + NOTICE (drives Q4)**
- files: `dev/notes/p2-licensing.md` (new); later a `NOTICE`/`THIRD-PARTY` file.
- what: Record the per-component license split (GROUNDED from headers):
  airplay.c / airplay_events.c / rtp_common.c = **GPL-2.0+**; `pair_ap/*` =
  **MIT**; `libairptp` = **MIT** (LICENSE ©2026 OwnTone); `evrtsp/rtsp.c` = **BSD**
  (Provos 2002-2006 + Blaché 2010). State implications: personal/non-distributed =
  no GPL trigger; distribution would GPL the whole linked app. Flag that the
  MIT PTP helper can ship as a separate clean binary. Note the SPEC "no OwnTone
  naming" rule is a *product* requirement, independent of license attribution
  (GPL still requires retaining copyright/license notices in the source we keep).
- kind: docs · depends_on: T-SRC-1
- model: haiku 4.5 — read headers, tabulate; low judgment beyond the grounded facts.
- effort: low.
- verify: table matches the header scan; NOTICE lists every vendored component.

### Wave 2 — Scaffold + build the C cluster standalone

**T-PKG-1 — Scaffold the AirPlayEngine package (drives Q3)**
- files: `AirPlayEngine/Package.swift`, `AirPlayEngine/Sources/CAirPlayEngine/`
  (vendored C + `include/module.modulemap`), `AirPlayEngine/Sources/AirPlayEngine/`
  (Swift), `AirPlayEngine/Tests/`, extend root `.gitignore`. (All NEW dirs — no
  overlap with Phase-1 or core.)
- what: Create a new SwiftPM package per Q3(a): a C target with a module map and
  brew include/lib `unsafeFlags`, a Swift target depending on it, `.macOS(.v14)`.
  No sources copied yet — just the buildable skeleton (a trivial C symbol the
  Swift side calls) proving the toolchain/module-map/brew-linkage works.
- kind: build · depends_on: T-SEAM-1 (package shape follows the seam decisions),
  Q3 resolved.
- model: sonnet 5 — SwiftPM C-interop + module maps + brew flags are fiddly but
  well-trodden; not opus-deep.
- effort: med.
- verify: `swift build` in `AirPlayEngine/` succeeds; Swift calls the stub C fn.

**T-BUILD-1 — Compile the extracted C cluster into the package** ⭐ critical path
- files: copy into `AirPlayEngine/Sources/CAirPlayEngine/`: `outputs/airplay.c`,
  `outputs/airplay_events.c`(+`.h`), `outputs/rtp_common.c`(+`.h`),
  `evrtsp/rtsp.c`(+headers), `pair_ap/*` (all), and `libairptp` (as vendored
  sources or its prebuilt/rebuilt `libairptp.a`). HOT: this is the package's
  primary source dir — serialize with T-SHIM-1.
- what: Get the cluster to **compile and link** against brew libevent/libsodium/
  libgcrypt/libplist (+ ffmpeg if Q2(a)) with the T-SHIM-1 shims satisfying the
  cut OwnTone symbols. Resolve platform/autotools quirks: `evrtsp` and `libairptp`
  carry autotools; per T-PTP-1 decide whether libairptp builds via its own
  `Makefile`→`.a` (self-contained) or is folded into the SwiftPM C target.
  Strip AirPlay-1 (`raop.c`) and all other outputs. Keep GPL copyright headers.
- kind: build · depends_on: T-PKG-1, T-SHIM-1 (co-developed — the shims exist to
  make this link). depends_on T-SRC-1.
- model: opus 4.8 — cross-language build bring-up of a 4400-line reverse-eng C
  file with autotools deps and brew linkage; high blast radius, many subtle link
  errors.
- effort: xhigh — the single biggest engineering node in the phase.
- verify: `swift build` links a static lib exporting the engine entry points; no
  unresolved symbols; ALAC encoder present at link (guards the :1192 failure mode).

**T-SHIM-1 — Write the OwnTone-plumbing shims** ⭐ critical path (co-dev with T-BUILD-1)
- files: `AirPlayEngine/Sources/CAirPlayEngine/shims/` — new headers/impls:
  `outputs.h` (reimplemented seam: `output_device`, `output_buffer`,
  `media_quality`, `output_status_cb`, states), `logger.h`(DPRINTF→os_log/stderr),
  `conffile.h`(cfg_* → static config struct, ~6 keys from T-SEAM-1),
  `misc.h`/`dmap_common.h` (only the helpers airplay.c actually calls),
  `ptpd.h` (reimplemented on `airptp_*` per T-PTP-1), and no-op
  `db.h`/`artwork.h`/`transcode.h`-metadata (Q6). `transcode.h` ALAC path per Q2.
  Same dir as T-BUILD-1 sources → HOT FILE, one owner.
- what: Provide compile-satisfying, behavior-correct replacements for every
  symbol T-SEAM-1 marked SHIM/STUB/REPLACE, so the GPL sender runs with **no
  OwnTone runtime**. The `outputs.h` reimpl is the load-bearing piece: it feeds
  `airplay_write(output_buffer*)` the PCM the Swift layer hands in, and turns
  airplay's `output_status_cb` / `player_device_add/remove` into Swift-visible
  events. Config becomes a small struct populated from the Swift API, not a file.
- kind: new-code · depends_on: T-SEAM-1, T-PTP-1 (for the ptpd shim), Q2/Q6.
  Co-developed with T-BUILD-1 (same package, same source dir — SERIALIZE / single
  owner; treat T-BUILD-1 + T-SHIM-1 as one workstream by one agent).
- model: opus 4.8 — correctness-critical C: the write/quality/status contract must
  exactly match what airplay.c expects or audio is silent/garbled. Highest-risk
  logic after T-BUILD-1.
- effort: xhigh.
- verify: cluster compiles (with T-BUILD-1); a unit smoke test drives a fake
  session through the shim'd `outputs.h` and observes status callbacks.

**T-HELPER-DESIGN-1 — PTP privileged-helper design doc (design-only)**
- files: `dev/notes/p2-ptp-helper-design.md` (new).
- what: DESIGN, not code. Specify the SMAppService launchd **daemon** boundary
  from T-PTP-1: helper = MIT `libairptp` in shared-daemon mode (`airptp_daemon_bind`
  [root] + `airptp_daemon_start(is_shared=true)` running master clock);
  unprivileged engine = `airptp_daemon_find()` + `airptp_peer_add/remove` +
  `airptp_clock_id_get`. Define the discovery/handshake between the two (how
  libairptp's shared mode locates the daemon — grounded in T-PTP-1), what the
  helper does NOT do (no audio, no RTSP, clock-only — like nqptp), install/signing/
  firewall-allowlist story (Phase-0 lessons: sign + firewall-register at install;
  restart after allowlist), and the interim **dev launch via osascript admin
  dialog** (Alec present) used until the helper exists. Keep it small enough to
  audit line-by-line (SPEC.md §4.1).
- kind: design · depends_on: T-PTP-1
- model: opus 4.8 — the one privileged surface in the whole product; the design
  is a security contract.
- effort: med — design doc, no implementation.
- verify: doc answers exactly-what-runs-as-root, the shared-clock consumption
  path, and the install/interim story; reviewed against SPEC §4.1.

### Wave 3 — Swift API + harness (after the C lib links)

**T-API-1 — Swift wrapper API over the C engine**
- files: `AirPlayEngine/Sources/AirPlayEngine/*.swift` (new).
- what: A neutral, Swift-idiomatic API over the linked C engine: session
  lifecycle (start/stop), `addOutput(descriptor)` / `removeOutput(id)` taking a
  resolved descriptor (host/port/txt per Q5(a)), `setVolume(_:for:)`, `writePCM`
  (feeds airplay_write via the shim, from the Phase-0 tap format 44.1/48k
  float32→whatever the ALAC path wants), `clockStatus`, pairing entry points
  (Q7). Bridges the libevent thread + status callbacks into an async event
  stream. NO OwnTone naming in any public symbol.
- kind: new-code · depends_on: T-BUILD-1, T-SHIM-1
- model: opus 4.8 — the C/Swift threading + memory-ownership bridge over a
  libevent loop is correctness-sensitive (lifetimes, callbacks across the FFI).
- effort: high.
- verify: unit test constructs a session, adds a descriptor, and drives the API
  without crashing (against a stub/loopback before the live harness).

**T-HARNESS-2 — Receiver harness + PASS/FAIL verify scripts (shape follows Q1)**
- files: `dev/verify-p2-*.sh` (new), `dev/notes/p2-harness-runbook.md`.
- what: Implement the harness chosen in T-HARNESS-RESEARCH-1/Q1: stand up the
  receiver (two-host shairport-AP2 OR AirPlay-1 local fallback), drive the engine
  via T-API-1 (or a small CLI on it), capture receiver-side PCM, emit Phase-0-style
  PASS/FAIL verdicts (non-silent + rate-exact + Goertzel tone). Bake in the PTP
  contention rule (engine-PTP vs any nqptp take turns on 319/320) and the macOS
  AirPlay-Receiver-off precondition. USER-GATED where root/PTP or listening is
  needed — batch into few sessions.
- kind: test · depends_on: T-API-1, T-HARNESS-RESEARCH-1
- model: sonnet 5 — scripting + verdict logic in the established Phase-0 idiom;
  the hard unknowns were settled in research.
- effort: med (high if two-host bring-up per Q1(a)).
- verify: script prints VERDICT: PASS against the chosen receiver for a known tone.

**T-CLI-1 — Thin engine test CLI (optional harness driver)**
- files: `AirPlayEngine/Sources/airplay-engine-probe/main.swift` (new executable
  target).
- what: A headless CLI over T-API-1 (add output by host/port, feed a tone or a
  `.pcm`/FIFO from the Phase-0 `dev/audiocap` tool, set volume) so T-HARNESS-2 has
  something to drive without the full app. Mirrors `mock-speakers-demo`.
- kind: new-code · depends_on: T-API-1
- model: sonnet 5 — glue over an existing API.
- effort: low.
- verify: `swift run airplay-engine-probe --host … --tone 440` runs; feeds bytes.

### Wave 4 — Land behind the OutputBackend seam

**T-BACKEND-1 — `NativeBackend : OutputBackend` + `AIRPLAY_BACKEND=native`**
- files: `AirPlayControllerCore/Sources/AirPlayControllerCore/NativeBackend.swift`
  (new); `AirPlayControllerCore/Sources/AirPlayControllerCore/OwnToneBackend.swift`
  (edit `BackendKind` + `makeBackend`); `AirPlayControllerCore/Package.swift` (add
  dependency on the `AirPlayEngine` package); `dev/README.md` (document `native`).
- what: Implement `OutputBackend` (devices/start/stop/makeEventStream/setVolume/
  setMuted/setSoloed/setOutputSet — OutputBackend.swift:31-59) on top of
  `AirPlayEngine`: map discovered `Device`s → engine descriptors, `setOutputSet`
  → add/remove outputs, `setVolume` → engine volume, engine status/level →
  `BackendEvent` (deviceAdded/Updated/Removed/level). Add `BackendKind.native`
  and `AIRPLAY_BACKEND=native` in `resolved()` (OwnToneBackend.swift:36-67) and a
  `makeBackend` case (:76-81). NOTE: neutral naming — do NOT reuse `OwnToneBackend`;
  per SPEC §4.3 the interim `OwnToneBackend` + `owntone` env value are ultimately
  deleted (that deletion may be its own follow-up once `native` is proven).
- kind: backend · depends_on: T-API-1 (and T-BUILD-1/T-SHIM-1 transitively).
  HOT FILE: `OwnToneBackend.swift` (shared with the resolver) — but no other
  Phase-2 task edits it, so no intra-plan contention. Coordinate with Phase 1 if
  Phase 1 also touches the resolver (cross-plan flag).
- model: opus 4.8 — the mapping from engine semantics to the event-sourced
  `OutputBackend` contract is correctness-sensitive and is the app-visible seam.
- effort: high.
- verify: `AIRPLAY_BACKEND=native swift run mock-speakers-demo` drives the engine;
  existing `MockBackendTests` + `BackendKindResolutionTests` stay green
  (add a `native`-resolution case to the latter).
- SUBTASK T-BACKEND-1b (test): extend `BackendKindResolutionTests.swift` for the
  `native` value (haiku, low) — same file, serialize after T-BACKEND-1's enum edit.

**T-CLEANUP-1 — Retire the interim OwnTone scaffolding (GATED on `native` proven)**
- files: delete `AirPlayControllerCore/Sources/AirPlayControllerCore/OwnToneBackend.swift`'s
  `OwnToneBackend` type + the `.ownTone` `BackendKind` case + `owntone` env value +
  its `makeBackend` case; delete `dev/owntone/` (git-ignored spike server) and its
  `AIRPLAY_BACKEND=owntone` docs in `dev/README.md`. HOT FILE: `OwnToneBackend.swift`
  (rename the file too, e.g. `Backends.swift`) — same file T-BACKEND-1 edits, so this
  runs strictly AFTER it.
- what: Execute SPEC §4.3's "delete when the native sender lands" — the shipped
  product carries zero OwnTone references (naming included). Fix `BackendKindResolutionTests`
  for the removed `.ownTone` case; keep `.mock` + `.native`.
- kind: pure-delete (with small import/enum fallout) · depends_on: T-BACKEND-1
  (native must be proven first), T-HARNESS-2 (don't delete the spike server until
  the native path passes). GATED — Alec confirms native is trusted before deleting.
- model: sonnet 5 — a cross-cutting deletion with enum/test/doc fallout across the
  resolver seam; small but not haiku-blind (must keep resolution + tests green).
- effort: med.
- verify: `swift build` + `swift test` green with no `OwnTone`/`owntone` symbols
  remaining (`grep -ri owntone AirPlayControllerCore/Sources` empty); app still
  resolves `mock`/`native`.

**T-DOC-P2 — Phase-2 close-out: SPEC + NOTICE + engine README**
- files: `SPEC.md` (§4/§8 — record the extraction landed, neutral naming, the PTP
  helper design pointer, deferred real-hardware checkpoints); `NOTICE`/`THIRD-PARTY`
  (from T-LICENSE-1); `AirPlayEngine/README.md`.
- what: Consolidate results, mark Phase-2 status, list the deferred real-hardware
  checkpoints (real Sonos/HomePod PTP multi-room; ALAC-on-real-receiver; latency/
  stability), and record the ffmpeg-vs-Apple-ALAC follow-up (Q2). Sole editor of
  `SPEC.md` in this plan.
- kind: docs · depends_on: T-BACKEND-1, T-LICENSE-1, T-HELPER-DESIGN-1
- model: sonnet 5 — prose consolidation.
- effort: low.
- verify: SPEC reflects the landed engine + zero-OwnTone-naming invariant; NOTICE
  complete.

---

## D. Parallelization — waves, concurrency, critical path

**Hot files / shared resources (name them):**
- `AirPlayEngine/Sources/CAirPlayEngine/` (sources + shims) — **T-BUILD-1 and
  T-SHIM-1 edit the same dir; treat as ONE workstream / one agent. Do not run
  concurrently.**
- `AirPlayControllerCore/.../OwnToneBackend.swift` — T-BACKEND-1 AND T-CLEANUP-1
  (this plan) edit it; **serialize (T-BACKEND-1 first, then T-CLEANUP-1)**.
  Cross-plan contention risk with Phase 1's resolver work → coordinate.
- `AirPlayControllerCore/.../BackendKindResolutionTests.swift` — T-BACKEND-1b after
  T-BACKEND-1.
- `SPEC.md` — T-DOC-P2 only.
- `.gitignore` (root) — appended by T-SRC-1 and T-PKG-1; tiny, serialize or
  one-time.
- PTP UDP 319/320 — engine-PTP vs nqptp can't both hold live on one host;
  **live PTP sessions take turns** (T-HARNESS-2, any live T-BUILD-1 smoke).

**Wave 1 (fully parallel, no shared files):**
T-SRC-1 → then concurrently T-SEAM-1 ∥ T-PTP-1 ∥ T-HARNESS-RESEARCH-1 ∥
T-LICENSE-1. (T-SEAM-1/T-PTP-1/T-LICENSE-1 each read the clone read-only, write
distinct notes files. T-HARNESS-RESEARCH-1 is independent.) **Critical-path seed:
T-SEAM-1.**

**Wave 2:** T-PKG-1 (after T-SEAM-1) → then the **T-BUILD-1 + T-SHIM-1 combined
workstream** (serialized, one owner, the xhigh core). **In parallel, off the
critical path:** T-HELPER-DESIGN-1 (after T-PTP-1, design-only, edits its own
note).

**Wave 3 (after the C lib links):** T-API-1 → then T-CLI-1 ∥ T-HARNESS-2 (distinct
files; T-HARNESS-2 also needs T-HARNESS-RESEARCH-1 from Wave 1). Live runs of
T-HARNESS-2 respect the 319/320 turn-taking rule.

**Wave 4:** T-BACKEND-1 → T-BACKEND-1b (same test file) → **T-CLEANUP-1**
(GATED: only after `native` is proven by T-HARNESS-2; edits the same
`OwnToneBackend.swift` → strictly serial after T-BACKEND-1) → T-DOC-P2 (sole SPEC
editor, last).

**Critical path:**
T-SRC-1 → T-SEAM-1 → T-PKG-1 → **[T-BUILD-1 + T-SHIM-1]** → T-API-1 →
T-BACKEND-1 → T-DOC-P2.
The two xhigh nodes (T-BUILD-1, T-SHIM-1) are the dominant cost and the project's
core risk; everything else (PTP research, helper design, licensing, harness
research, CLI) is slack that can proceed alongside.

---

## E. Test + docs / registry impact

- **New tests:** engine session smoke (T-SHIM-1/T-API-1), harness verdict scripts
  (T-HARNESS-2), `BackendKindResolutionTests` extended for `native` (T-BACKEND-1b).
- **Existing tests must stay green:** `MockBackendTests` (5),
  `BackendKindResolutionTests` — adding `.native` must not break `.mock`/`.owntone`
  resolution.
- **Registry/config:** `AIRPLAY_BACKEND` gains value `native` (docs in
  `dev/README.md`, SPEC §4). `makeBackend`/`BackendKind` gain a `.native` case.
- **Docs:** `SPEC.md` §4/§8, new `NOTICE`/`THIRD-PARTY`, `AirPlayEngine/README.md`,
  four `dev/notes/p2-*.md` research/design briefs.
- **.gitignore:** add `dev/owntone-src/`; ignore engine `.build/`.
- **Deferred (SPEC checkpoints):** real-Sonos/HomePod PTP multi-room + audible
  volume + latency/stability + ALAC-on-real-receiver — carried forward from
  Phase-0's deferred list; PTP send is only fully proven when Q1 gives a real PTP
  receiver or speakers return.

## F. Open risks / confirm during execution

- **R1 (highest) — PTP verification without speakers** (Q1). If no second host,
  PTP-timed send stays unproven until hardware returns; the harness then only
  covers RTSP/pairing/ALAC/volume over AirPlay-1/NTP. Do not let a green AP1
  harness masquerade as "AP2 works."
- **R2 — ALAC encoder** (Q2). airplay.c hard-requires an ALAC encoder; the ffmpeg
  path is proven but a heavy dep. Link-time absence reproduces OwnTone's
  "ffmpeg has no ALAC encoder" silent-fail (airplay.c:1192) — guard in T-BUILD-1.
- **R3 — Seam creep.** If airplay.c's device lifecycle is more entangled with live
  `mdns`/`player`/`db` than the symbol scan suggests, the shim grows. T-SEAM-1
  must trace call *contexts*, not just counts, before T-BUILD-1 commits.
- **R4 — libevent threading across FFI** (T-API-1). The engine runs its own
  libevent loop; bridging to Swift async without data races/lifetime bugs is
  subtle. Budget accordingly.
- **R5 — Cross-plan file contention** on `OwnToneBackend.swift` /
  `BackendKindResolutionTests.swift` if Phase 1 edits the resolver concurrently.
  Coordinate the merge; do not both rewrite `makeBackend`.
- **R6 — GPL scope** (Q4). Fine for personal use; a future distribute decision
  GPLs the whole linked app — record now (T-LICENSE-1), decide later.
- **R7 — OwnTone version drift.** Pin the clone to the Phase-0-validated tag
  (29.2); a newer airplay.c may have shifted the seam or protocol details.


---

## RESOLVED DECISIONS (Alec, 2026-07-13) — authoritative, supersedes the open questions above

- **Q1 PTP verification: TWO-HOST receiver harness.** Alec HAS a second machine —
  it runs shairport-sync in AirPlay-2 mode (+ nqptp) as the test receiver. Full
  PTP send verification without speakers. Harness tasks should target this;
  identify the machine's OS at harness-setup time.
- **Q2 ALAC:** link ffmpeg first; evaluate vendoring Apple's ALAC encoder later.
- **Q3 Engine placement:** new SwiftPM package `AirPlayEngine/` at repo root.
- **Q4 License posture: OPEN SOURCE, GPL-2.0-or-later for the project** (changed
  from "personal use only" — Alec may redistribute). Vendored GPL sender cluster
  is therefore fine; keep MIT (libairptp, pair_ap) and BSD (evrtsp) files
  separately marked with their original headers; add a LICENSE file task-level
  note. The tiny SMAppService PTP helper ships MIT.
- **Q5 Discovery:** app/NWBrowser owns discovery; engine receives resolved descriptors.
- **Q6 Metadata/db/artwork:** cut — no-op stubs.
- **Q7 Pairing:** vendor both pair_ap modules; verify transient path now.

## NEW REQUIREMENT (Alec, 2026-07-13) — synced local Core Audio endpoint

The engine's Swift API (T-API-1) and NativeBackend (T-BACKEND-1) must support a
**local Mac speaker as a first-class, PTP-SYNCED output** alongside the AirPlay
outputs — for the "play everywhere" mode. Requirements:
- Mute the live OS output (tap muteBehavior .mutedWhenTapped) and render a DELAYED
  local Core Audio copy scheduled on the SAME PTP presentation clock as the remote
  receivers, so Mac + speakers are sample-aligned (raw local currently runs ~2s
  ahead — the AirPlay 2 buffer).
- "Mute the Mac" mode = just the tap mute, no local sink.
- This is a genuine reason the native engine beats OwnTone (OwnTone has no synced
  local output on macOS). Add to T-API-1 scope: a `localOutput` sink type on the
  shared clock. Verify by ear (Mac + a real AirPlay device in step) once the
  engine can run a session.

## T-SHIM-1 ✅ (2026-07-13) — incl. the R-A dispatcher
Vendored C cluster compiles+links; shims implemented. **R-A outputs_cb dispatcher
DONE** (the highest-risk node): 64-slot callback-id registry, deferred delivery on
evbase_player, exactly-once completion incl. §4c auth-retry id-hand-off and N=0
no-waiter cases; 9 dispatcher tests, 11/11 green, verified vs pinned OwnTone source.
Engine integration points exported: outputs_dispatcher_init/reset,
outputs_engine_completion_set.

**Remaining before a REAL session (feeds T-SHIM-2 → T-API-1):** real-session stubs
still needed — misc.c net/keyval/hex/uuid, transcode.c ffmpeg ALAC, conffile real
config + libhash, player.c device add/remove, logger os_log, outputs registry
ownership/free. Then T-API-1 wires evbase_player + dispatcher_init + completion
hook + drives the issuing side. Then T-HARNESS-2 (real receiver — Cinema/Pool now
available!) + T-BACKEND-1 (NativeBackend).

## T-SHIM-2 ✅ (2026-07-13) — all real-session shims REAL
misc net/keyval/hex/uuid, conffile (in-mem, ~16 keys), logger (os_log), player
device add/remove, outputs registry merge/free, transcode ALAC (ffmpeg linked +
verified). 17 tests green, 0 warnings. Fixed a NULL-deref in vendored
airplay_device_free_extra. NO shim code blocks T-API-1. Full T-API-1 checklist in
build-notes §6.

## T-API-1 (NEXT, build-only) — Swift wrapper
Wire evbase_player + dispatcher_init + completion hook→async Swift, config via
conffile_set_*, output_airplay.init, discovery feed, session lifecycle (add
output / volume / write PCM). BUILD + headless tests only. A LIVE session is a
SEPARATE gated step: needs a real receiver (Cinema/Pool) AND OwnTone stopped
(PTP port 319/320 contention) AND Alec present. Runtime unknowns to validate
then: R-A count under real retry, R-B write cadence, R-C ALAC acceptance, PTP
if-scope.

## T-API-1 ✅ (2026-07-13) — Swift wrapper complete
`actor AirPlayEngine` with async start/addOutput/setVolume/write(pcm:)/stop +
discovery-in (no GPL edits — mdns_browse shim captures airplay_device_cb). C
completion→async continuation bridge verified vs the real dispatcher (synthetic
callbacks). One engine thread + libevent base (R-B). 29 tests green. Gated probe
CLI `engine-probe` ready (needs --i-have-a-receiver-and-owntone-is-stopped).
localOutput sink = API placeholder + TODO.

**NEXT = GATED LIVE TEST (user-present):** stop OwnTone (frees PTP 319/320), run
engine-probe against a real receiver (Cinema/Pool), validate R-A/R-B/R-C + PTP.
THE moment of truth for the extracted engine. Then T-BACKEND-1 (NativeBackend on
OutputBackend) + the synced localOutput Core Audio sink.

## Gated live engine test — RE-DEFERRED (2026-07-14)
The transient network with Cinema/Pool is gone (only the excluded LG TV remains
visible). The engine-probe first-light test needs a real AirPlay 2 receiver;
options, in preference order: (1) an opportunistic window with real AP2 hardware
(probe CLI is ready to run in minutes), (2) Alec's second machine as a
shairport-sync AP2 receiver (docs/receiver-harness-guide.md is ready — machine
identity/OS still unconfirmed; must be Linux/Pi, a second Mac cannot do it),
(3) speakers returning. NOTE: the fake AP1 shairport receiver is NOT valid for
the engine (we vendored only the AP2 sender path).

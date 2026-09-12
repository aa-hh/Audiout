# Spec: keep an idle AirPlay session alive by feeding silence from the sender shim

Status: ready-for-agent

Source: conversation 2026-09-11/12 and the research note `dev/notes/idle-session-fill-c-shim-2026-09-12.md` (primary-source citations live there; this spec carries the decisions).

## Problem Statement

When I turn on an AirPlay speaker in Audiout while nothing on my Mac is playing, the speaker drops the connection about 30 seconds later. The app shows "Connection dropped" and the speaker row goes red. If I press Try again, it connects and drops again 30 seconds later, as long as nothing is playing. It looks like the app is flapping. It has behaved this way on every build since at least 2026-09-04, including the released 1.1.1.

The cause is that the receiver expects a live session to carry audio packets, and Audiout only sends packets once some app on the Mac starts playing. The whole-system capture is designed to sleep until then, which is the right thing for CPU, so the sender has nothing to send. The receiver hangs up. A first fix that made the capture run all the time cured the drop but cost 7 to 8 percent of a CPU core in coreaudiod for as long as a speaker was on, which was rejected.

## Solution

A speaker that is on stays connected whether or not anything is playing, with no CPU cost from macOS while idle. From the moment a speaker's session is up, the AirPlay sender keeps it fed: if the app has had nothing to send for a tenth of a second, the sender fills the gap with silence at exactly real-time rate until the app has audio again, then stops the instant real audio resumes. The user never hears the handover. The system audio capture keeps sleeping while nothing plays, exactly as before.

## User Stories

1. As a listener, I want to turn on a speaker before I start music, so that it is ready when I press play.
2. As a listener, I want a speaker I turned on to stay connected while I pick what to play, so that I do not have to reconnect it.
3. As a listener, I want a speaker to stay connected through a long pause, so that resuming plays instantly.
4. As a listener, I want to stay connected while my Mac is silent for minutes, so that "on" means on.
5. As a listener, I want the first note after silence to play cleanly, so that the fill is invisible to me.
6. As a listener, I want the pause between silence and sound to add no audible gap or click, so that music feels continuous.
7. As a listener with several speakers on, I want all of them to stay connected while idle, so that the group is intact when I play.
8. As a listener who adds a speaker to an already-idle group, I want the new speaker to join and stay, so that idle groups can be assembled.
9. As a listener who routes one app to one speaker, I want that speaker to stay connected before the app has played, so that per-app routing behaves like whole-system routing.
10. As a listener whose routed app pauses, I want its speaker to stay connected, so that per-app routing survives pauses.
11. As a listener on an AirPlay 1 speaker, I want the same idle behaviour as on AirPlay 2, so that older speakers are not second class.
12. As a listener on an AirPlay 2 speaker, I want the session's heartbeat to run while idle, so that the receiver treats the session as live.
13. As a laptop user, I want an idle speaker to cost nothing in coreaudiod, so that my fan stays quiet and my battery lasts.
14. As a laptop user, I accept the sender's own cost for encoding and sending silence, so that the trade-off is clear and bounded.
15. As a user, I want the mixer's meters to keep idling when apps are silent, so that leaving the mixer open costs nothing.
16. As a user, I want the app's health log to keep reporting what the app itself wrote, so that "writes" and "silent seconds" stay honest for diagnosis.
17. As a user, I want a session drop caused by a genuinely dead speaker to still be reported, so that real failures are not masked.
18. As a user, I want the "Connection dropped" card to appear only for real drops, so that I trust it when I see it.
19. As a user, I want the Wi-Fi blip recovery and removal grace behaviours unchanged, so that this fix does not regress reconnects.
20. As a user, I want the clock alignment (PTP) start-up unchanged, so that multi-room sync starts the same way.
21. As a user, I want a speaker that briefly goes to "connected" during an audio re-anchor to be fed again straight away, so that re-anchors do not create a 30 s vulnerability.
22. As a user, I want the fix to hold on the Sonos Move, so that the speaker I tested with stops flapping.
23. As a user with other AirPlay brands, I want the same guarantee, so that the fix is not brand-specific.
24. As a developer, I want the fill to live beside the sender, so that every session the sender holds is covered, whatever fed it.
25. As a developer, I want the fill to run on the engine's own thread, so that no locks or cross-thread marshalling are added.
26. As a developer, I want the fill to bypass the Swift-side write guards, so that backlog, cadence and level telemetry keep their meaning.
27. As a developer, I want the vendored C untouched, so that the licence ledger needs no new entry.
28. As a developer, I want a headless test seam that runs one fill cycle at a chosen time, so that timing is tested without a clock or hardware.
29. As a developer, I want the fill to write exactly the samples owed by elapsed time, so that timer jitter never drifts the stream.
30. As a developer, I want the fill capped per cycle, so that a long stall cannot burst-encode unbounded work on the engine thread.
31. As a developer, I want the fill to seed its clock from the last delivered end time, so that the join anchor is continuous.
32. As a developer, I want a documented rule in the folder's agent notes, so that nobody reintroduces the auto-start change.
33. As a developer, I want the capture tap's auto-start behaviour restored to what main had, so that the earlier partial fix is fully reverted.
34. As a developer, I want a live-proof checklist, so that the owner can verify the change on real speakers.

## Implementation Decisions

- **Placement.** The fill lives in the project-owned C shim layer beside the AirPlay senders, not in Swift and not in the vendored sender files. The vendored sender stays byte-identical.
- **Trigger.** A persistent 8 ms libevent timer on the engine's event base, created and destroyed alongside the shim's existing deferred-dispatch event, so its lifetime matches the engine's start and stop.
- **Which streams.** On each tick the shim scans its own device registry for devices that have a live session and whose state is connected or streaming. It feeds one entry per distinct stream id among those devices. It does not read the vendored senders' session lists, which are file-static.
- **Idle rule.** A stream is idle when the host has not written to it for 100 ms. While idle, each tick writes the number of whole packets owed by elapsed time, computed as (now minus one packet) minus the stream's last delivered end time, converted to samples and floored to packets, capped at 32 packets per tick.
- **Presentation time.** The fill stamps each write with a presentation time continuing from the stream's last delivered end time. A stream first seen idle is seeded at now minus one packet. This affects only the anchor a joining device receives; an already-streaming session's packet clock comes from the sample counter, and periodic sync packets are compiled off, so no receiver-visible discontinuity exists.
- **Handover.** The moment a host write arrives, the stream's last-write timestamp updates and the next tick writes nothing. The host's first buffer may carry a presentation time 2 to 22 ms earlier than the fill's last; that is absorbed by the receiver's start buffer.
- **Bookkeeping.** The shim's broadcast write function stamps, per stream, the last host write time and the last delivered end time. The fill calls the two senders' write functions directly and never goes through the broadcast function, so nothing counted as a host write is a fill.
- **Swift side.** No behavioural change. The write backlog guard, cadence, latency and level trackers, and the stream-health telemetry keep reporting host writes only. One stale comment about cumulative deficit is corrected. The heartbeat on AirPlay 2 arms itself as a side effect of the first fill packet, as it does for the first real packet.
- **Capture side.** The whole-system tap's auto-start key returns to what main has, reverting the capture half of the earlier fix. Per-app taps were never changed.
- **Clock gate.** Unchanged. The PTP activation wait completes before a session is bound, and the fill only acts on bound, connected sessions, so silence cannot begin before the clock decision.
- **Documentation.** One rule line in the shim folder's agent notes and one in the core library's agent notes, replacing the earlier "tap never idles" rule.

## Testing Decisions

- A good test drives the public seam and asserts on observable output: how many samples reached the sender for a given clock time and host activity, and where the stream's end time landed. It never inspects the timer, the registry layout, or the packet encoder.
- **Seam.** One new test-only entry in the shim bridge: run one fill cycle at a given time and return the samples written; plus a reader for a stream's last delivered end time. Tests run under the engine's headless test mode with real master sessions, and seed the registry device's session and state directly, as those fields are written only by the shim.
- **Modules tested.** The shim's fill (new suite, four cases: no fill within 100 ms of a host write; samples owed by elapsed time, including a second consecutive tick; no fill for a stream without a connected device; host write stops the fill on the next tick). The existing multi-stream routing and write-backlog suites are rerun unchanged to prove the Swift path is untouched.
- **Prior art.** The multi-stream write routing suite (real master sessions through the bridge's test entries, serialized under the shared engine-state parent) and the shim unit suite, which already runs the ALAC encoder headless on full packets, so full fill packets are safe in tests.
- **Live proof.** Dev bundle id, live-test slot held. Select the Sonos Move with nothing playing, wait 120 s, expect no drop and the heartbeat armed in the engine log; start music and listen at the handover; repeat with 5 s and 60 s pauses; confirm coreaudiod sits at its idle level while the speaker is on. The shairport-sync fake speaker proves only that fill packets are accepted on AirPlay 1; it never drops on silence.

## Out of Scope

- A protocol-level heartbeat with the stream stopped (AirPlay 2 feedback only, AirPlay 1 has none). Not pursued: silence is the reference sender's own idle behaviour and covers both protocols.
- Reducing the sender's own cost of encoding and sending silence.
- Bluetooth and Cast outputs. They have no session that idles out this way and zero-fill on their own.
- The AirPlay receiver password prompt seen on the Mac's own receiver (roadmap 027).
- Which sender leg (AirPlay 1 or 2) a speaker lands on after power-up; noted as a separate observation.
- The stale dev PTP helper respawn loop on the owner's machine.

## Further Notes

- The earlier diagnosis cleared the diagnostics work (PR #166) as a cause; the drop predates it by a week.
- Branch: `claude/audio-sync-airplay-flapping-344115`. Commits 7093048c and 1f978918 hold the interim capture-side fix; this spec supersedes the capture half of it.
- Unverified until live: Sonos's exact idle rule, handover audibility, the interplay with the app's re-anchor flush (which sets a session back to connected), and the encode cost of a capped burst tick.
- Timestamps in the app's own logs are UTC; the unified log is local time.

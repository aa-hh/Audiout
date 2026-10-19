# 04: Live proof on the Sonos Move

**What to build:** The owner can verify on real hardware that a speaker selected with nothing playing stays connected, the handover to real audio is inaudible, and coreaudiod stays at its idle level. Deliver a dev-bundle-id build and the checklist.

**Blocked by:** 01, 03.

**Status:** ready-for-agent

- [ ] Dev-id build made while holding the live-test slot; the slot is released on the owner's verdict.
- [ ] Checklist: 120 s idle with no drop and heartbeat armed in the engine log; start music and listen at the handover; 5 s and 60 s pauses; coreaudiod at idle level while the speaker is on.
- [ ] Verdict recorded in the memory note.

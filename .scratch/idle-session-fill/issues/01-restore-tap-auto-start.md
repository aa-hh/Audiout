# 01: Restore the whole-system tap's auto-start behaviour

**What to build:** With a speaker on and nothing playing, macOS's whole-system capture sleeps again as it did on main, so coreaudiod sits at its idle level. This reverts the capture half of the interim fix (commits 7093048c and 1f978918) and replaces the "tap never idles" rule in the core library's agent notes with the new rule: an idle session is fed by the sender shim, never by keeping the tap awake.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The whole-system tap's aggregate description matches main (auto-start key present, comment explaining why it must stay).
- [ ] The tap protocol doc no longer promises continuous delivery.
- [ ] The core library agent notes carry the new rule and no longer the "never idles" one; the taps brief note is consistent.
- [ ] Both capture-coordinator suites pass, with a "Test run with N tests" line.

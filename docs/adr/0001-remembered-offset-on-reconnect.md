# A reconnected Bluetooth speaker gets its last offset back, labelled

Until now a Bluetooth speaker that reconnected kept its stored offset but was flagged "Reconnected, timing not set", on the basis that a Bluetooth link re-rolls its delay per connection and the old number no longer fits. Decided 2026-09-05, on the research in `dev/notes/bt-latency-stability-research-2026-09-05.md`: apply the stored offset immediately on reconnect, show the row as "Timing from last time", and once the Mac's clock verdict says the link has settled, offer a re-check on the phone through the same invite card that offers a first measurement, which opens the sync sheet. The sheet is the offer because a run needs the phone held still where the user listens, so no card starts one directly. The re-roll is typically 25 to 45 ms within one device and codec, so the remembered number is usually far closer to right than zero, and a wrong 30 ms is audible but not an echo. A re-measurement that differs by 10 ms or more replaces the stored value; under 10 ms the old value stays to avoid churn; over 40 ms the user is told.

## Considered options

- Keep the stale flag and apply nothing. Honest about variability, but throws away a mostly-correct number on every reconnect and leaves the speaker untuned until someone measures.
- Fire the re-check automatically when the phone is in the room. Rejected: the sweeps need a person in the room and the discovery note's rule that no measurement is app-initiated stands. The banner requires a tap.

## Consequences

- Every connection logs speaker, codec, jump count, time to settle, and settled offset. Debug builds log locally; release builds send the same anonymised fields through PostHog. Twenty reconnects on the owner's own speakers replace the literature's "20 to 70 ms" with a measured spread, and the 10 ms threshold is revisited against it.
- A per-model crowd median on the licence server is deferred until that log says it would help.

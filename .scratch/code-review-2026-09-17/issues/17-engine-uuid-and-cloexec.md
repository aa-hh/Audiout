# 17 — Shims: real per-call UUIDs and real close-on-exec

Status: ready-for-agent
Wave: 4
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings engine #1, engine #7

`uuid_make` re-seeds `srand(time())` per call, so `session_uuid` and `group_uuid` are identical; `O_CLOEXEC` is passed to `fcntl(F_SETFL)`, which ignores it.

## Done when

`uuid_make` draws from `arc4random_buf` (no seeding); `fcntl(fd, F_SETFD, FD_CLOEXEC)` sets close-on-exec. Guard 6 green; an engine test proves two consecutive `uuid_make` calls differ.

## Test seam

AirPlayEngine tests

## Verification

```bash
bash scripts/run-tests.sh --package AirPlayEngine 2>/dev/null || echo 'use the AirPlayEngine runner named in AirPlayEngine/AGENTS.md'
```

## Findings (verbatim from the area reports)

### 1. [BUG] `uuid_make` re-seeds `srand()` on every call, so a session's `session_uuid` and `group_uuid` are always identical
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/misc.c:778-807`; call site `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:1624-1625`
- Evidence:
  ```c
  uuid_make(char *str)
  {
    ...
    now = time(NULL);
    srand((unsigned int)now);
    for (i = 0; i < ARRAY_SIZE(uuid); i++)
      uuid[i] = (uint16_t)rand();
  ```
  and in the sender:
  ```c
  uuid_make(session->session_uuid);
  uuid_make(session->group_uuid);
  ```
- Why it matters: the second call re-seeds the global PRNG with the same `time(NULL)` second and replays the
  identical sequence, so `sessionUUID` and `groupUUID` — both sent to the receiver in SETUP
  (`airplay.c:2874`, `airplay.c:2878`) — are the same string, and any two sessions created in the same second
  on this Mac advertise the same pair. It also clobbers the process-wide `rand()` stream for every other
  caller.
- Fix: seed once (a `static bool`/`dispatch_once`), or drop the PRNG entirely and fill the 16 bytes with
  `arc4random_buf` — it is in libSystem, so this adds no dependency and the "dependency-free variant"
  rationale in the file header still holds.
- Confidence: high

### 7. [BUG] `O_CLOEXEC` passed to `fcntl(F_SETFL)` does nothing — the sockets are not close-on-exec despite the comment
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/misc.c:188-197`, `:238`, `:358`
- Evidence:
  ```c
  // For Linux we could just give SOCK_CLOEXEC to socket(), but that won't work
  // with MacOS, so we have to use fcntl()
  flags = fcntl(fd, F_GETFL, 0);
  ret = fcntl(fd, F_SETFL, flags | O_NONBLOCK | O_CLOEXEC);
  ```
- Why it matters: `F_SETFL` only sets file *status* flags; close-on-exec is a *descriptor* flag set with
  `F_SETFD`/`FD_CLOEXEC`, so every RTSP/data socket stays open across any `exec` this process makes. The
  comment states the opposite of what the code achieves, which is worse than no comment.
- Fix: keep the `F_SETFL` call for `O_NONBLOCK` only and add `fcntl(fd, F_SETFD, FD_CLOEXEC);` next to it.
- Confidence: high

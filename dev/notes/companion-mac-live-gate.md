# Companion App — Mac-Only Live Gate (Phase 1)

*Run this checklist before merging T1–T9 to main. The gate passes only when R4 (firewall)
shows no per-launch prompts on a Developer-ID build, and all boxes below are checked.
Two builds run here: mock (fastest discovery validation) and native (Bonjour/network).*

---

## 1. Build and verify binary identity

- [ ] **Build the app**
  ```bash
  cd /Users/alechenderson/Projects/AirPlay\ Controller
  scripts/make-app.sh build/
  ```

- [ ] **Verify which binary is running** (multiple Audiouter.app copies exist on this Mac;
  the strings trick proves you're testing the right one)
  ```bash
  strings build/Audiouter.app/Contents/MacOS/AudiouterApp | grep -i "Audiouter 0.1.0" | head -1
  ```
  Expected: one line with the version marker. Note the binary location for the next step.

---

## 2. Default state: companion server OFF (not listening)

- [ ] **Launch with mock backend** (safest for first run; no network/firewall exposure)
  ```bash
  AIRPLAY_BACKEND=mock open build/Audiouter.app
  ```

- [ ] **Confirm server NOT listening** (should be empty; no `_audiouter._tcp` advertised)
  ```bash
  dns-sd -B _audiouter._tcp
  ```
  Expected: times out or shows "no results" after ~5 seconds. Kill with Ctrl+C.

- [ ] **Confirm companion toggle is OFF** in Settings › General. Toggle off explicitly to be sure.

---

## 3. Enable via Settings toggle → server appears

- [ ] **Enable the checkbox** in Settings › General › "Allow control from iPhone on this network"

- [ ] **Verify server now advertises** (should appear in the browse list immediately)
  ```bash
  dns-sd -B _audiouter._tcp
  ```
  Expected: one entry `_audiouter._tcp.local.` with `Audiouter` or `Alec's Mac` (the host
  name). Note the full advertised name for the protocol poke below. Kill with Ctrl+C.

- [ ] **Disable the checkbox** in Settings › General

- [ ] **Verify server disappears** from dns-sd browse (should go empty again)
  ```bash
  dns-sd -B _audiouter._tcp
  ```

---

## 4. Environment override behavior (explicit knob policy)

- [ ] **Override ON via env** (default OFF, explicit opt-in)
  ```bash
  AUDIOUTER_COMPANION=1 AIRPLAY_BACKEND=mock open build/Audiouter.app
  ```
  Verify server advertises (`dns-sd -B _audiouter._tcp`); Settings toggle shows ON.

- [ ] **Override OFF via env** (reverts to OFF despite Settings, explicit opt-out for testing)
  ```bash
  AUDIOUTER_COMPANION=0 open build/Audiouter.app
  ```
  Verify server does NOT advertise (`dns-sd -B _audiouter._tcp` empty). Quit and close app.

---

## 5. **R4 FIREWALL CHECK — Merge blocker**

Close all Audiouter instances. This is the critical risk: a per-launch Application
Firewall prompt means the code is not shipping.

- [ ] **On a Developer-ID signed build**, launch with native backend and companion ON
  (this is your real production signing; ad-hoc builds will differ)
  ```bash
  AUDIOUTER_COMPANION=1 AIRPLAY_BACKEND=native open build/Audiouter.app
  ```

- [ ] **Watch for macOS Application Firewall prompt** at launch. A Developer-ID
  signature should auto-allow. If a **"Do you want the application AudiouterApp to
  accept incoming connections?"** dialog appears:
  - **STOP. Do not merge. File the blocker.** A per-launch prompt is a shipping
    blocker (D1/D8 requires always-on when enabled; per-launch breaks UX). Report
    the exact prompt wording and whether it appears on every launch or only the first.
  - If it's the **first launch only**, "Allow" and relaunch to confirm it does not
    re-prompt. If it re-prompts every time: **STOP**.

- [ ] **No prompt expected.** Developer-ID signature + hardened runtime should auto-allow.
  Confirm no prompt appears, then close the app.

---

## 6. Protocol poke — websocat or fallback

Companion server uses Bonjour + NWListener + WebSocket (JSON messages). Verify a poke
reaches it and gets a snapshot response.

**If websocat is installed:**

- [ ] **Keep Audiouter open** (Settings › General toggle ON, mock backend is fine)
  and note the advertised server name from `dns-sd -B _audiouter._tcp` (usually the
  host name, e.g., "Alec's Mac").

- [ ] **Discover the advertised WebSocket port** and connect
  ```bash
  websocat ws://localhost:PORT
  ```
  (Replace PORT with the ephemeral port shown by `dns-sd`. The TXT record carries it.)

- [ ] **Send the hello handshake**. Paste this exactly:
  ```json
  {"v": 1, "type": "hello", "payload": {"clientName": "TestClient", "protoVersion": 1}}
  ```
  Expected response: a frame starting with `"type":"welcome"` containing a `snapshot`
  with devices, groups, settings, etc. If you see this, protocol is working.

- [ ] **Trigger a state change in the popover** (e.g., toggle a speaker selected) and
  **expect a state frame** from the server immediately:
  ```json
  {"v": 1, "type": "state", "payload": {"snapshot": {...}}}
  ```

- [ ] **Close websocat** (Ctrl+C).

**If websocat is not installed:**

- [ ] **Run the AudiouterProtocol test suite** instead (proves wire format round-trips)
  ```bash
  cd AudiouterProtocol && swift test
  ```
  Expected: all CompanionMessageTests pass (hello, welcome, command, state, goodbye
  round-trips + all 18 command cases).

---

## 7. Snapshot-vs-popover spot check (state parity)

Verify the server's snapshot matches what the popover shows. If websocat worked, you
already have a snapshot JSON from step 6; otherwise, review from the AppDelegate's
CompanionSnapshotBuilder logs.

- [ ] **Popover open** with a few speakers selected, at least one group, one routed app

- [ ] **Eyeball these fields in the snapshot**:
  - `serverName` (your Mac's display name)
  - `devices[]` with at least one `isSelected: true` device
  - `groups[]` if you created a group
  - `appRoutes[]` if any app is routed
  - `mainOutMasterVolume` (matches the Master slider value in the popover)
  - `settings.connectVolume` and `startBufferMs` (should match Settings › Audio values)

- [ ] **Change one volume in the popover** (e.g., adjust a device slider) and **confirm
  the snapshot reflects it** (via websocat state frame or logs; if using test suite,
  this was covered).

---

## 8. Wrap-up: tests green + go-ahead required

- [ ] **Run the full test suite**
  ```bash
  cd /Users/alechenderson/Projects/AirPlay\ Controller
  scripts/run-tests.sh
  ```
  Expected: all tests pass, including CompanionMessageTests, CompanionSnapshotBuilderTests,
  CompanionCommandDispatcherTests, CompanionServerTests, CompanionEndToEndTests.

- [ ] **Run AudiouterProtocol tests** explicitly (not in the standard suite)
  ```bash
  cd AudiouterProtocol && swift test
  ```

- [ ] **Quit Audiouter** (Cmd+Q)

- [ ] **Report results to the session** before any merge attempt. Main is merge-only;
  no merge without Alec's explicit go-ahead. Include:
  - R4 firewall result (expected: no per-launch prompt on Developer-ID build)
  - Any websocat discoveries or protocol anomalies
  - Test suite pass/fail
  - Binary identity confirmed (strings check)

---

## Notes

- **Mock vs. native:** steps 1–4 use mock (no network needed). Step 5 switches to native
  for the R4 firewall verification, which is the critical path.
- **Multiple app copies:** the strings check in step 1 proves you're testing the build
  from this session, not an installed or stale copy.
- **Firewall on ad-hoc builds:** ad-hoc signatures may prompt; Developer-ID should
  auto-allow. If the ad-hoc prompt appears, it is expected and OK — the shipping build
  uses Developer ID.
- **Demo backend:** AIRPLAY_BACKEND=mock is the app's explicit demo-mode policy (never
  a silent fallback). It's perfect for low-friction testing.

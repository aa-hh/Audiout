# Companion App — Mac-Only Live Gate (Phase 1)

*Run this checklist before merging the Mac side to main. The gate passes only when R4
(firewall) shows no per-launch prompts on a Developer-ID build, and all boxes below are
checked. Two builds run here: mock (fastest discovery validation) and native
(Bonjour/network).*

*Updated 2026-07-27 for the review-fix wave and the per-phone approval gate (D2 REVISED):
step 4 now checks the checkbox cannot lie, step 6 needs a `clientID` and expects an
approval alert, step 6b covers approval memory / denial / revoke, and step 8 checks the
approvals file. No phone required — websocat stands in for one throughout.*

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
  Verify server advertises (`dns-sd -B _audiouter._tcp`). In Settings › General the
  checkbox must show **ON, greyed out, with an explanatory line** naming the override —
  it must NOT show OFF while the server runs, and clicking it must do nothing. (This was
  a real bug found in review: the checkbox used to lie. If it lies again, that's a
  regression, not a quirk.)

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

- [ ] **Send the hello handshake**. Paste this exactly (the `clientID` must be a real
  UUID — any one you invent is fine, but reuse the SAME one later in step 6b):
  ```json
  {"v": 1, "type": "hello", "payload": {"clientID": "11111111-2222-3333-4444-555555555555", "clientName": "TestClient", "protoVersion": 1}}
  ```
  Expected FIRST response: `"type":"awaitingApproval"` — because this identity is
  unknown, the Mac is now prompting you. **A native alert should appear on the Mac**
  naming "TestClient". Click **Allow**. Expected SECOND response: a frame starting with
  `"type":"welcome"` containing a `snapshot` with devices, groups, settings, etc.

  If the alert never appears but you get a `welcome` immediately, the approval gate is
  not engaged — **stop and report**, that's the whole privacy feature bypassed.

- [ ] **Trigger a state change in the popover** (e.g., toggle a speaker selected) and
  **expect a state frame** from the server immediately:
  ```json
  {"v": 1, "type": "state", "payload": {"snapshot": {...}}}
  ```

- [ ] **Close websocat** (Ctrl+C).

### 6b. Approval memory, denial, and revoke

- [ ] **Reconnect with the SAME clientID** from step 6. Expected: **no prompt this time**
  — straight to `welcome`. The Mac remembers approved phones.

- [ ] **Settings › General now lists it.** A "Remembered iPhones" list should show
  "TestClient — Allowed" under the companion checkbox.

- [ ] **Revoke it** (minus button on that row). Expected: the live websocat connection
  is dropped, and the row disappears.

- [ ] **Connect with a DIFFERENT clientID** (change one digit) and click **Don't Allow**
  on the alert. Expected: `goodbye` with reason `notApproved`, connection closes, and
  the row appears as "TestClient — Denied". Reconnecting with that same id must be
  refused **without re-prompting** (a denied phone must not be able to nag you).

- [ ] **Revoke the denied row** so the gate is clean for the next test.

- [ ] **Untick the companion checkbox while a client is connected.** Expected: the
  client receives `goodbye` with reason `disabled` before the socket closes (not a bare
  connection drop — the phone uses this to settle quietly instead of redialling).

**If websocat is not installed:**

- [ ] **Run the AudiouterProtocol test suite** instead (proves wire format round-trips)
  ```bash
  cd AudiouterProtocol && swift test
  ```
  Expected: all CompanionMessageTests pass (hello, welcome, awaitingApproval, command,
  state, goodbye round-trips + all 19 command cases). Note this does NOT exercise the
  approval alert — that part of the gate is skipped, so say so when reporting.

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
  CompanionCommandDispatcherTests, CompanionServerTests, CompanionEndToEndTests,
  CompanionApprovalStoreTests, CompanionCommandRateLimiterTests.

  **Watch for flakes.** One unidentified failure occurred in a single full-suite run
  during development (machine heavily loaded), not reproduced in nine runs since.
  Several liveness tests are timing-sensitive. If you see a failure, capture the test
  NAME before re-running — that identification is the valuable part.

- [ ] **Confirm the approvals file was written**
  ```bash
  cat ~/Library/Application\ Support/Audiouter/companion-approvals.json
  ```
  Expected: a `{"schemaVersion":1,...}` envelope. It should be EMPTY of entries if you
  revoked everything in step 6b.

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

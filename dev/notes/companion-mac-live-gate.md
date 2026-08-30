# Companion App — Mac-Only Live Gate (Phase 1)

*Run this checklist before merging the Mac side to main. The gate passes only when R4
(firewall) shows no per-launch prompts on a Developer-ID build, and all boxes below are
checked. Two builds run here: mock (fastest discovery validation) and native
(Bonjour/network).*

*Updated 2026-07-27 for the review-fix wave and the per-phone approval gate (D2 REVISED):
step 4 now checks the checkbox cannot lie, step 6 needs a `clientID` and expects an
approval alert, step 6b covers approval memory / denial / revoke, and step 8 checks the
approvals file. No phone required — dev/notes/wspoke.py (pure-stdlib Python) stands in for one throughout.*

---

## 1. Build and verify binary identity

- [ ] **Build the app — FROM THE WORKTREE, not the main checkout.** The primary
  checkout sits on `main`, which has no companion code at all; building there
  produces an app with no Bonjour service and no checkbox, and every later step
  fails for the wrong reason.
  ```bash
  cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/companion-app-research-e89998"
  ./scripts/make-app.sh
  ```
  Every command below assumes this directory.

- [ ] **Verify the build actually contains the companion code.** Several
  Audiout.app copies exist on this Mac and they share a bundle id, so proving
  identity matters. Check for companion symbols — NOT a version string, which
  lives in `Info.plist` and never appears in the executable:
  ```bash
  strings build/Audiout.app/Contents/MacOS/AudioutApp | grep -c "_audiout._tcp"
  ```
  Expected: `1` or more. If it prints `0`, you built the wrong tree — go back to
  the previous step. (Belt and braces: `strings … | grep -c CompanionServer`
  should be non-zero too.)

- [ ] **Confirm it is Developer-ID signed** — the firewall check in step 5 is only
  meaningful on a signed build.
  ```bash
  codesign -dvvv build/Audiout.app 2>&1 | grep -c "Authority=Developer ID Application"
  ```
  Expected: `1`. (Needs `-dvvv` — the authority chain isn't printed at `-dv`.)
  An ad-hoc build will prompt for firewall access regardless and tells you
  nothing about what users would see.

---

## 2. Default state: companion server ON (advertising)

T22 (`e5f0b7c6`, Alec 2026-08-06) flipped an UNSET setting from OFF to ON, so a
fresh profile advertises at launch without being asked. The Local Network grant
is the consent; asking twice for the same thing was the reason.

- [ ] **Launch with mock backend** (safest for first run; no real speakers touched)
  ```bash
  AIRPLAY_BACKEND=mock open build/Audiout.app
  ```

- [ ] **Confirm the server IS listening** — one `_audiout._tcp` instance named
      after this Mac, on each live interface.
  ```bash
  dns-sd -B _audiout._tcp
  ```
  Expected: an `Add` row within a second or two. Kill with Ctrl+C. Nothing at all
  means either the setting is persisted OFF from earlier testing (`defaults read
  <bundle-id> companion.allowRemoteControl` — unset is ON), or you built a tree
  without the companion code, which `strings … | grep -c '_audiout._tcp'` settles.

- [ ] **Confirm the toggle reads ON** in Settings › General, matching what the
      network says. A checkbox disagreeing with the listener is the bug this
      section exists to catch, in either direction.

- [ ] **Then untick it** and confirm the advertisement disappears — the OFF path
      still has to work, it is just no longer where you start.

---

## 3. Enable via Settings toggle → server appears

- [ ] **Enable the checkbox** in Settings › General › "Allow control from iPhone on this network"

- [ ] **Verify server now advertises** (should appear in the browse list immediately)
  ```bash
  dns-sd -B _audiout._tcp
  ```
  Expected: one entry `_audiout._tcp.local.` with `Audiout` or `Alec's Mac` (the host
  name). Note the full advertised name for the protocol poke below. Kill with Ctrl+C.

- [ ] **Disable the checkbox** in Settings › General

- [ ] **Verify server disappears** from dns-sd browse (should go empty again)
  ```bash
  dns-sd -B _audiout._tcp
  ```

---

## 4. Environment override behavior (explicit knob policy)

- [ ] **Override ON via env** (redundant with the default since T22, which flipped
      an unset setting to ON — this step now proves the override AGREES with the
      default rather than opting in from OFF)
  ```bash
  AUDIOUT_COMPANION=1 AIRPLAY_BACKEND=mock open build/Audiout.app
  ```
  Verify server advertises (`dns-sd -B _audiout._tcp`). In Settings › General the
  checkbox must show **ON, greyed out, with an explanatory line** naming the override —
  it must NOT show OFF while the server runs, and clicking it must do nothing. (This was
  a real bug found in review: the checkbox used to lie. If it lies again, that's a
  regression, not a quirk.)

- [ ] **Override OFF via env** (reverts to OFF despite Settings, explicit opt-out for testing)
  ```bash
  AUDIOUT_COMPANION=0 open build/Audiout.app
  ```
  Verify server does NOT advertise (`dns-sd -B _audiout._tcp` empty). Quit and close app.

---

## 5. **R4 FIREWALL CHECK — Merge blocker**

Close all Audiout instances. This is the critical risk: a per-launch Application
Firewall prompt means the code is not shipping.

- [ ] **On a Developer-ID signed build**, launch with native backend and companion ON
  (this is your real production signing; ad-hoc builds will differ)
  ```bash
  AUDIOUT_COMPANION=1 AIRPLAY_BACKEND=native open build/Audiout.app
  ```

- [ ] **Watch for macOS Application Firewall prompt** at launch. A Developer-ID
  signature should auto-allow. If a **"Do you want the application AudioutApp to
  accept incoming connections?"** dialog appears:
  - **STOP. Do not merge. File the blocker.** A per-launch prompt is a shipping
    blocker (D1/D8 requires always-on when enabled; per-launch breaks UX). Report
    the exact prompt wording and whether it appears on every launch or only the first.
  - If it's the **first launch only**, "Allow" and relaunch to confirm it does not
    re-prompt. If it re-prompts every time: **STOP**.

- [ ] **No prompt expected.** Developer-ID signature + hardened runtime should auto-allow.
  Confirm no prompt appears, then close the app.

---

## 6. Protocol poke — no websocat needed

Companion server uses Bonjour + NWListener + WebSocket (JSON messages). Verify a poke
reaches it, triggers the approval prompt, and returns a snapshot.

**`websocat` is NOT required and is not installed here.** `dns-sd -B` only lists the
service *name*, never the port — and `nc`/`curl` can't speak the WebSocket handshake.
Use the dependency-free Python client checked in at
`dev/notes/wspoke.py` (pure stdlib, does the WS upgrade + framing itself). *(Verified
live 2026-07-27: this is exactly how the gate was passed.)*

- [ ] **Keep Audiout open**, companion toggle ON.

- [ ] **Resolve the actual companion port** (browse gives the name, `-L` resolves the
  port — substitute your advertised name from `dns-sd -B _audiout._tcp`):
  ```bash
  dns-sd -L "$(scutil --get ComputerName)" _audiout._tcp local
  # → "…can be reached at <host>.local.:PORT"  — note PORT, then Ctrl+C
  ```

- [ ] **Send a hello as an UNKNOWN phone** (any fixed UUID; reuse it in 6b):
  ```bash
  python3 dev/notes/wspoke.py <PORT> AAAA1111-BBBB-2222-CCCC-333344445555
  ```
  Expected: `HANDSHAKE: … 101 Switching Protocols`, then `<- AWAITING APPROVAL`, and
  **a native alert appears on the Mac** naming the client. Click **Allow**. (The script
  waits 45 s; if you don't click in time it just exits — the approval is still saved,
  and 6b's re-poke will show the welcome.)

  If a `welcome` arrives with NO alert, the approval gate is bypassed — **stop and
  report**, that's the whole privacy feature defeated.

### 6b. Approval memory, denial, and revoke

- [ ] **Reconnect with the SAME clientID** from step 6. Expected: **no prompt this time**
  — straight to `welcome`. The Mac remembers approved phones.

- [ ] **Settings › General now lists it.** A "Remembered iPhones" list should show
  "TestClient — Allowed" under the companion checkbox.

- [ ] **Revoke it** (minus button on that row). Expected: the live connection
  is dropped, and the row disappears.

- [ ] **Connect with a DIFFERENT clientID** (change one digit) and click **Don't Allow**
  on the alert. Expected: `goodbye` with reason `notApproved`, connection closes, and
  the row appears as "TestClient — Denied". Reconnecting with that same id must be
  refused **without re-prompting** (a denied phone must not be able to nag you).

- [ ] **Revoke the denied row** so the gate is clean for the next test.

- [ ] **Untick the companion checkbox while a client is connected.** Expected: the
  client receives `goodbye` with reason `disabled` before the socket closes (not a bare
  connection drop — the phone uses this to settle quietly instead of redialling).

**Supplement (does NOT replace the live poke above):** the AudioutProtocol suite
proves the wire format round-trips, but exercises no socket and no approval alert.
It is no longer in this repo — `AudioutProtocol` is an external package dependency
now (`aa-hh/audiout-shared`), and SwiftPM never runs a *dependency's* tests, so
this step cannot be run from here at all. Run it in a checkout of that repo:
```bash
git clone https://github.com/aa-hh/audiout-shared.git && cd audiout-shared && swift test
```
Expected: all CompanionMessageTests pass (hello, welcome, awaitingApproval, command,
state, goodbye + every command case).

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
  the snapshot reflects it** (re-poke with wspoke.py, or watch the log; if using test suite,
  this was covered).

---

## 8. Wrap-up: tests green + go-ahead required

- [ ] **Run the full test suite**
  ```bash
  cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/companion-app-research-e89998"
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
  cat ~/Library/Application\ Support/Audiout/companion-approvals.json
  ```
  Expected: a `{"schemaVersion":1,...}` envelope. It should be EMPTY of entries if you
  revoked everything in step 6b.

- [ ] **Run AudioutProtocol tests** explicitly — they are NOT in this repo's suite
  and cannot be: the package is an external dependency (`aa-hh/audiout-shared`),
  and SwiftPM does not run a dependency's tests.
  ```bash
  git clone https://github.com/aa-hh/audiout-shared.git && cd audiout-shared && swift test
  ```

- [ ] **Quit Audiout** (Cmd+Q)

- [ ] **Report results to the session** before any merge attempt. Main is merge-only;
  no merge without Alec's explicit go-ahead. Include:
  - R4 firewall result (expected: no per-launch prompt on Developer-ID build)
  - Any protocol anomalies from the poke
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

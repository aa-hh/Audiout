# AirPlay 2 receiver harness — setup guide (T-HARNESS-RESEARCH-1)

Goal: turn ahh's second machine into a real AirPlay 2 receiver (`shairport-sync`
built `--with-airplay-2` + `nqptp`) that our extracted engine can be verified
against, with receiver-side PCM captured to a file for a silent PASS/FAIL verdict
(the Phase-0 `dev/verify-0f2-e2e.sh` idiom).

This doc is research + a setup guide only. It does not touch the second machine —
that machine is unidentified as of this writing (OS unknown). All sections below
are written to cover the likely cases; skip to the one that matches once ahh
confirms the machine.

Sources fetched directly from upstream for this doc (2026-07-13):
`github.com/mikebrady/shairport-sync` → `AIRPLAY2.md`, `BUILD.md`,
`CONFIGURATION FLAGS.md`, `scripts/shairport-sync.conf`; `github.com/mikebrady/nqptp`
→ `README.md`, `nqptp-shm-structures.h`, `nqptp.service.in`.

---

## 0. Feasibility verdict (read this first)

| OS | Feasible as AP2 receiver? | Why |
|---|---|---|
| **Linux (Debian/Ubuntu/generic)** | **Yes** — primary target | Fully supported by upstream; `nqptp` binds 319/320 via a dedicated low-privilege systemd user, no conflict with anything else on that host. |
| **Raspberry Pi OS** | **Yes** — same instructions | Raspberry Pi OS is Debian-based; the upstream `BUILD.md` covers "Debian / Raspberry Pi OS / Ubuntu" as one section, identical commands. This is upstream's own reference platform (a Pi B is the stated minimum spec). |
| **macOS (a second Mac)** | **No — confirmed infeasible, in upstream's own words** | See below. |
| **This Mac (same machine as the sender)** | **No**, independent of OS question | `nqptp` needs exclusive root-level access to UDP 319/320; our engine's own PTP client needs the same ports on the same host. Two processes can't hold them simultaneously (see `dev/README.md`'s existing "why not run a real AirPlay-2 receiver locally" note — same conclusion, already discovered in Phase 0). |
| **VM (Docker/VirtualBox/Parallels/UTM) on either Mac** | **Discouraged** | Upstream `BUILD.md` §0: *"Note that Shairport Sync does not work well in virtual machines – YMMV."* PTP timing accuracy is exactly the kind of thing a VM's virtualized clock/NIC degrades. Only fall back to this if the second machine truly cannot run bare-metal Linux. |

**The single most likely failure mode:** the second machine turns out to be a
second **Mac** (not Linux/Pi), and someone reflexively tries to run shairport-sync
AP2 mode on it the same way `fake-speakers.sh` runs AirPlay-1 on this Mac today.
It will not work — not a config problem, a hard architectural one. Quoting
`AIRPLAY2.md` directly:

> "Shairport Sync can not run in AirPlay 2 mode on a Mac because NQPTP, on which
> it relies, needs ports 319 and 320, which are already used by macOS."

macOS itself reserves 319/320 for its own PTP-ish services; there's no `sudo`
workaround. **If the second machine is a Mac, it cannot be the AP2 receiver as-is.**
Options in that case, in order of preference:
1. Install Linux on it (dual-boot, or wipe if it's a spare/dev box) — turns it into
   the fully-supported case.
2. Boot Linux from a USB stick / external SSD, no OS reinstall needed — same result,
   less commitment. A Raspberry Pi OS or Ubuntu USB installer works.
3. If neither is acceptable, fall back to a **Raspberry Pi** or any cheap spare
   Linux box (a Pi B is upstream's stated minimum — nearly anything qualifies) as a
   *third* machine, and treat the second Mac as out of scope for this harness.
4. Last resort, degraded coverage: the AirPlay-1/NTP-only local verify already
   built in Phase 0 (`dev/verify-0f2-e2e.sh` against the Homebrew shairport-sync on
   this same Mac) — proves the send path and PCM delivery but **not PTP**, since
   Homebrew's shairport-sync build here is AirPlay-1-only (confirmed: it ignores
   custom RTSP ports and has no `nqptp`). Keep this as the standing fallback/smoke
   test regardless — see §5.

If the second machine turns out to be Linux or Raspberry Pi OS already, skip
straight to §1/§2 below and this is a short, well-trodden setup.

---

## 1. Requirements per OS

### 1a. Linux (Debian / Ubuntu / generic) and Raspberry Pi OS — same requirements

Both are covered by the identical upstream instructions (`BUILD.md` treats
"Debian / Raspberry Pi OS / Ubuntu" as one section). Requirements:

- A "recent (2018 onwards)" Debian/Ubuntu/Raspberry Pi OS install. Upstream's
  stated minimum power level is "at least as powerful as a Raspberry Pi B."
- **Not a VM** (see §0 table) — bare metal or a Pi is what upstream tests against.
- Full/root access on the box (for `apt install`, `make install`, and to enable the
  `nqptp` and `shairport-sync` systemd services).
- **UDP ports 319 and 320 free and unfirewalled**, exclusively for `nqptp`. No
  other PTP daemon (`ptpd`, `chronyd` with PTP, `linuxptp`) can be running.
- A wired or Wi-Fi network interface on the **same L2 subnet** as this Mac, with
  Wi-Fi Power Management **off** if it's Wi-Fi-connected (see §4).
- Build toolchain + dev libraries (exact `apt` list in §2a) — this is a
  from-source build; there is no `apt install shairport-sync` path that includes
  AirPlay 2 support (Debian/Ubuntu's own repo package is typically an older
  AirPlay-1-only build, same situation as Homebrew on macOS).

### 1b. macOS (second Mac) — AirPlay 2 receiver mode is out

Per §0: shairport-sync AP2 mode cannot run on any Mac (this one or a second one),
because `nqptp` cannot get 319/320 — macOS itself holds them. This is **not** the
same "root vs. no-root" problem as same-machine contention with our sender; it's
that **macOS the OS** occupies those ports for its own use regardless of what else
is running. A second Mac does not fix this. (For completeness: macOS **is**
supported as an AirPlay 2 *source* — "AirPlay 2 support for audio sources on...Macs
from macOS 10.15 (Catalina) onwards" — but that's the opposite role from what we
need; we need a *receiver*.)

If the second machine is confirmed to be a Mac, do not attempt this path — go to
§0's fallback list.

---

## 2. Exact install steps per OS

### 2a. Linux / Raspberry Pi OS — from source (package route does not give AP2)

Run these **on the second machine**, over SSH from this Mac or at its own
terminal. One-liners only — no backslash continuations (paste-proof for zsh or
bash either side).

**Step 0 — update:**

```sh
sudo apt update && sudo apt upgrade -y
```

**Step 1 — install build deps (full AirPlay-2 package list, from upstream `BUILD.md`):**

```sh
sudo apt install --no-install-recommends -y build-essential git autoconf automake libtool libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev libplist-dev libsodium-dev uuid-dev libgcrypt-dev xxd libplist-utils libavutil-dev libavcodec-dev libavformat-dev
```

If the machine is Ubuntu 24.10 / Debian 13 ("Trixie") or newer, upstream also
requires `systemd-dev`; check before installing (upstream flags a backports
report of it damaging some systems):

```sh
sudo apt install --dry-run --no-install-recommends systemd-dev
```

If that dry-run looks sane for the target release, install for real:

```sh
sudo apt install --no-install-recommends -y systemd-dev
```

**Step 2 — build and install `nqptp` first (shairport-sync's AP2 mode depends on it):**

```sh
git clone https://github.com/mikebrady/nqptp.git ~/nqptp && cd ~/nqptp && autoreconf -fi && ./configure --with-systemd-startup && make
```

```sh
sudo make install
```

```sh
sudo systemctl enable nqptp && sudo systemctl start nqptp
```

Verify it's alive:

```sh
systemctl status nqptp --no-pager
```

**Step 3 — build and install `shairport-sync` with `--with-airplay-2`:**

```sh
git clone https://github.com/mikebrady/shairport-sync.git ~/shairport-sync && cd ~/shairport-sync && autoreconf -fi
```

```sh
./configure --sysconfdir=/etc --with-alsa --with-soxr --with-avahi --with-ssl=openssl --with-systemd-startup --with-airplay-2 --with-stdout
```

Note: `--with-stdout` is added on top of upstream's baseline AP2 configure line —
it is **required** for the file-capture verification backend in §3/§5 and is not
included by default. `--with-alsa` stays so the box can also just play audio
audibly for a sanity-check if needed; it's not required for capture-only use.

```sh
make
```

(Upstream notes ~7+ minutes on a Raspberry Pi B; faster on anything newer.)

```sh
sudo make install
```

This installs the `shairport-sync` systemd service and a sample config at the
`sysconfdir` given above (`/etc/shairport-sync.conf` plus
`/etc/shairport-sync.conf.sample`).

**Step 4 — restart shairport-sync so it picks up the now-running `nqptp`:**

```sh
sudo systemctl restart shairport-sync
```

**Step 5 — confirm the AP2 service is being advertised** (run on the second machine
or from this Mac if `avahi`/`dns-sd` tooling is present):

```sh
avahi-browse -rt _airplay._tcp
```

You should see an entry advertising the receiver over `_airplay._tcp` (AirPlay 2's
service type — distinct from AirPlay 1's `_raop._tcp`).

### 2b. macOS (second Mac) — not applicable

Do not attempt an AP2-mode build here; see §1b/§0. (A second Mac remains usable
for the AirPlay-1 fallback smoke test in §5, exactly like this Mac's
`dev/fake-speakers.sh`, but that's a different, PTP-free path and is not what this
harness needs for real send verification.)

---

## 3. Config for a named receiver + file-capture backend

Config is a `libconfig`-syntax file, default path `/etc/shairport-sync.conf`
(from `--sysconfdir=/etc` above). Create a **dedicated** config for the verify
receiver so it doesn't collide with anything else on that box:

```sh
sudo tee /etc/shairport-sync-verify.conf > /dev/null <<'EOF'
general = { name = "AirPlayEngine Verify Receiver"; };
stdout = { };
diagnostics = { log_verbosity = 1; };
EOF
```

Notes, grounded in upstream's own sample config comments
(`scripts/shairport-sync.conf`):

- `stdout` backend: "directs raw PCM audio output to STDOUT. No interpolation is
  done." Selecting it is implicit — if `output_backend` isn't set in `general`,
  shairport-sync uses the first backend it was built with; since this build was
  configured `--with-stdout` (§2a Step 3) and no other backend is forced, an
  explicit `output_backend = "stdout";` in `general` is the safer, unambiguous
  choice — add it:

```sh
sudo tee /etc/shairport-sync-verify.conf > /dev/null <<'EOF'
general = { name = "AirPlayEngine Verify Receiver"; output_backend = "stdout"; };
stdout = { };
diagnostics = { log_verbosity = 1; };
EOF
```

- **Format is NOT the same as Phase-0's AirPlay-1 fallback.** For AirPlay 2 the
  `stdout`/`pipe` backends default to **S32_LE @ 48000 Hz**, stereo — not the
  S16LE @ 44100 that Phase-0's `dev/verify-0f2-e2e.sh` assumed for the AirPlay-1
  Homebrew build. (Upstream sample config: *"Default is 44100 for classic AirPlay,
  48000 for AirPlay 2"* and *"Default is S16_LE for classic AirPlay, S32_LE for
  AirPlay 2."*) **Any PASS/FAIL PCM verdict script for this harness must decode
  32-bit little-endian samples, not 16-bit** — reusing Phase-0's `rms.py`/inline
  `struct.unpack("<%dh"...)` verbatim will silently misinterpret the byte stream.
  Either pin `stdout = { output_rate = 44100; output_format = "S16_LE"; };` to
  match the old script's assumptions, or (recommended) write the new verdict
  script to unpack `<%di` (32-bit) at 48000 Hz. Pinning is safer for harness
  stability — do that:

```sh
sudo tee /etc/shairport-sync-verify.conf > /dev/null <<'EOF'
general = { name = "AirPlayEngine Verify Receiver"; output_backend = "stdout"; };
stdout = { output_rate = 44100; output_format = "S16_LE"; output_channels = 2; };
diagnostics = { log_verbosity = 1; };
EOF
```

Run it directly (not the systemd unit) so stdout can be redirected to a capture
file, and stderr to a separate log — same idiom as Phase 0's
`dev/verify-0f2-e2e.sh` §3b:

```sh
shairport-sync -c /etc/shairport-sync-verify.conf -v > /tmp/verify-recv.pcm 2> /tmp/verify-recv.log &
```

Stop the systemd-managed instance first if one is already running on that config
path, to avoid two shairport-sync processes both trying to open the AP2 RTSP port:

```sh
sudo systemctl stop shairport-sync
```

(Restart the systemd unit afterward if the box needs to keep serving as a normal
receiver: `sudo systemctl start shairport-sync`.)

---

## 4. Network requirements

AirPlay 2 needs two multicast-dependent things to work between this Mac and the
receiver:

1. **mDNS/Bonjour** (service discovery, `_airplay._tcp`, UDP 5353 multicast) — so
   `NWBrowser` on this Mac (or `avahi-daemon` on the receiver side) finds the
   receiver at all.
2. **PTP** (clock sync, UDP 319/320, multicast/broadcast on the local segment) —
   so the sender's clock and `nqptp`'s clock converge. This is the actual thing
   being verified; if it fails silently, sync will look fine on paper but audio
   will be garbled/desynced or captured PCM will show timing artifacts.

Requirements, in priority order:

- **Same L2 subnet / VLAN.** mDNS and PTP are multicast/link-local; anything that
  routes between the two hosts (a router doing inter-VLAN routing, guest network
  isolation on a mesh Wi-Fi system, etc.) will likely drop one or both. Put both
  machines on the same Wi-Fi network or the same switch segment. Wired Ethernet
  for the receiver is strongly preferred if it's an option — removes Wi-Fi power
  management as a variable entirely (see below).
- **No VPN in the path on either host.** This is a known, previously-hit failure
  mode: **flag explicitly** — ahh's Mac previously had a VPN client running that
  silently swallowed multicast traffic (mDNS and/or PTP), breaking discovery/sync
  without any obvious error. **Before running any harness session, confirm no VPN
  is active on this Mac** (check the menu bar / `scutil --nc list` / `ifconfig`
  for a `utun`/`tun` interface carrying default route) **and none on the receiver
  side** either. A split-tunnel VPN that only routes specific traffic can still be
  fine, but full-tunnel VPNs are the common offender — disconnect it for harness
  runs.
- **No firewall blocking 319/320 or 5353.** On the Linux/Pi receiver, if `ufw`,
  `firewalld`, or `nftables` is active, explicitly allow PTP and mDNS:
  ```sh
  sudo ufw allow 5353/udp
  sudo ufw allow 319/udp
  sudo ufw allow 320/udp
  ```
  (Adjust for whichever firewall tool the box actually uses — check with
  `sudo ufw status` / `sudo firewall-cmd --state` first.) macOS's own firewall
  (this Mac, once the engine exists) will separately need to allow the engine
  binary — flagged for `T-HELPER-DESIGN-1`, not this doc.
- **Wi-Fi power management off**, if the receiver is Wi-Fi-connected — upstream's
  `TROUBLESHOOTING.md` explicitly calls this out: sleeping Wi-Fi radios miss
  network-initiated AirPlay requests and desync timing. On a Raspberry Pi:
  ```sh
  sudo iwconfig wlan0 power off
  ```
  (Interface name may differ — check with `ip link`.)

**Pre-flight network check (run before any verification session):**

```sh
ping -c 3 <receiver-ip>
```

```sh
dns-sd -B _airplay._tcp
```

(Or `avahi-browse -rt _airplay._tcp` if run from a Linux host instead.) Both
should succeed with no VPN active and the receiver should appear within a few
seconds. If `ping` works but the browse doesn't, that's the multicast/VPN/subnet
symptom to chase first — not a shairport-sync config problem.

---

## 5. Verification recipe

### 5a. Driving it from this Mac once our engine exists

The shape (per `T-HARNESS-2`, which this doc feeds): our engine CLI (`T-CLI-1`,
`airplay-engine-probe`) sends a known tone or PCM file to the receiver's resolved
`host:port`; the receiver's `stdout` backend writes decoded PCM to
`/tmp/verify-recv.pcm` on the *receiver* machine; we `scp` that file back to this
Mac (or `ssh`+`cat` it over the pipe) and run a Goertzel/RMS verdict script against
it, exactly like Phase 0's `dev/verify-0f2-e2e.sh` inline Python block but with the
32-bit-vs-16-bit fix from §3 accounted for (pinning `S16_LE`/44100 in the receiver
config sidesteps needing a new decoder — reuse the existing 16-bit verdict script
as-is if that pin is in place).

Sketch (fill in once `T-API-1`/`T-CLI-1` exist):

```sh
ssh <user>@<receiver-ip> 'pkill -f "shairport-sync -c /etc/shairport-sync-verify.conf" 2>/dev/null; rm -f /tmp/verify-recv.pcm; nohup shairport-sync -c /etc/shairport-sync-verify.conf -v > /tmp/verify-recv.pcm 2> /tmp/verify-recv.log & sleep 1; echo started'
```

```sh
swift run airplay-engine-probe --host <receiver-ip> --tone 440 --duration 10
```

```sh
scp <user>@<receiver-ip>:/tmp/verify-recv.pcm /Users/alechenderson/Projects/AirPlay\ Controller/dev/.run/verify-recv-ap2.pcm
```

```sh
python3 "/Users/alechenderson/Projects/Audiouter/dev/audiocap/rms.py" "/Users/alechenderson/Projects/Audiouter/dev/.run/verify-recv-ap2.pcm" 2
```

(`rms.py` in its plain, non-`--tones` mode reads 16-bit PCM incorrectly today —
it's written for the audiocap Float32 format. `T-HARNESS-2` should either add an
S16LE reader mode or reuse the inline `struct.unpack("<%dh"...)` pattern from
`dev/verify-0f2-e2e.sh` directly, which already does exactly this for a 16-bit
capture file. Note this as a concrete contract for `T-HARNESS-2`: the verdict
script needs a 16-bit-PCM-aware path, not just the Float32 one `rms.py` has now.)

PASS/FAIL verdict: non-silent (RMS above noise floor, Phase-0 used `1e-4`) +
rate-exact (received frame count roughly matches `duration × 44100`, catching
resampling/pitch bugs) + tone-present (Goertzel at 440 Hz dominant, reusing the
`rms.py --tones` pattern already built in Phase 0 — same present/absent-ratio
logic, just pointed at a known single tone with a "silence" absent-frequency
check instead of a second tone).

### 5b. Clock sanity checks — confirming PTP is actually exchanging

Getting non-silent audio through is necessary but not sufficient — it doesn't
prove PTP is doing its job (AirPlay 2 can still play audio with degraded sync,
just with audible drift/artifacts over a longer capture). Two independent checks,
both grounded in nqptp's own docs:

**Check 1 — nqptp logs show peer activity.** Run `nqptp` in the foreground
temporarily (or read its systemd journal) during a harness session and look for
clock-record activity:

```sh
sudo systemctl stop nqptp && sudo nqptp
```

(Ctrl-C after confirming, then `sudo systemctl start nqptp` to restore normal
operation.) Or, without interrupting the service:

```sh
journalctl -u nqptp -f --no-pager
```

Drive a send from this Mac while watching; you should see clock records appear/
update rather than the log sitting idle. (Exact log line format wasn't in the
docs fetched for this brief — treat "activity correlates with the send session"
as the signal, not a specific string match, until `T-HARNESS-2` observes the
real output and can pin an exact grep pattern.)

**Check 2 — inspect the shared-memory clock interface directly.** This is the
more rigorous check and doesn't require parsing log text. `nqptp` publishes live
clock state via POSIX shared memory, interface name **`/nqptp`**
(`NQPTP_INTERFACE_NAME "/nqptp"`, current `NQPTP_SHM_STRUCTURES_VERSION 10` per
`nqptp-shm-structures.h`), backed by `/dev/shm/nqptp` on Linux. Confirm the
segment exists and is being written to during a send session:

```sh
ls -la /dev/shm/nqptp
```

```sh
stat /dev/shm/nqptp
```

Run `stat` again a few seconds into an active send — the segment's mtime should
be advancing (nqptp writes to it continuously as it tracks the master clock; the
struct includes a `local_time` field updated on every write). A static mtime
during an active session means nqptp isn't seeing PTP traffic from our engine —
i.e., the PTP exchange isn't happening, even if audio is somehow still flowing
(which would itself be a red flag worth investigating separately). A full decode
of the shared-memory struct (`master_clock_id`, `local_to_master_time_offset`,
etc.) is possible but is more machinery than this research task should build —
note it as a nice-to-have for `T-HARNESS-2` if `mtime` alone proves too coarse.

Also cross-check `nqptp -V` on the receiver to confirm the shared-memory
interface version matches what's documented (currently 10) — a version mismatch
between what's installed and what any future tooling expects is a clean, early
failure signal:

```sh
nqptp -V
```

---

## 6. Smoke test that does NOT need our engine (OwnTone, already installed)

Proves the receiver itself works — AP2 mode, real PTP, real audio delivery — using
OwnTone (already running on this Mac per Phase 0/1 setup) as the sender, before
our engine exists at all. This isolates "is the receiver harness correctly set
up" from "does our engine work," which matters because our engine won't exist
until well into this phase.

**Precondition:** OwnTone running on this Mac (`dev/owntone/`, JSON API on
`:3689` — see `dev/README.md`), and the receiver built + configured per §2/§3
above and confirmed advertising via `dns-sd -B _airplay._tcp` (§4).

**Step 1 — confirm OwnTone can see the AP2 receiver.** OwnTone does its own AP2
device discovery; check its outputs list:

```sh
curl -s http://localhost:3689/api/outputs | python3 -c "
import sys, json
for o in json.load(sys.stdin)['outputs']:
    print(o['id'], repr(o['name']), 'type=' + o.get('type', ''))
"
```

Look for a row named `AirPlayEngine Verify Receiver` (the name set in §3) with a
type indicating AirPlay 2 (OwnTone typically reports this as `"AirPlay 2"` in the
type field — confirm the exact string against what's printed, since this wasn't
independently verified against OwnTone's source for this doc).

**Step 2 — select and unmute it:**

```sh
OUT=<paste the id from Step 1>
curl -s -X PUT "http://localhost:3689/api/outputs/set" -H 'Content-Type: application/json' -d "{\"outputs\":[\"$OUT\"]}" -o /dev/null -w "select: %{http_code}\n"
```

```sh
curl -s -X PUT "http://localhost:3689/api/outputs/$OUT" -H 'Content-Type: application/json' -d '{"volume": 70}' -o /dev/null -w "volume: %{http_code}\n"
```

Both should print `204`.

**Step 3 — start the receiver's file-capture instance** (per §3, `stdout` backend
to a file), on the receiver machine:

```sh
ssh <user>@<receiver-ip> 'sudo systemctl stop shairport-sync 2>/dev/null; rm -f /tmp/verify-recv.pcm; nohup shairport-sync -c /etc/shairport-sync-verify.conf -v > /tmp/verify-recv.pcm 2> /tmp/verify-recv.log & sleep 1; echo started; pgrep -fa shairport-sync'
```

Re-check the outputs list (Step 1's `curl`) — the receiver should reappear under
its `_airplay._tcp` name within a few seconds of the process starting (mDNS
re-advertise).

**Step 4 — play something in OwnTone for ~20-30 s**, reusing Phase-0's own
library track:

```sh
curl -s -X PUT  'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"
```

```sh
curl -s -X POST 'http://localhost:3689/api/queue/items/add?uris=library:track:2' -o /dev/null -w "add: %{http_code}\n"
```

```sh
curl -s -X PUT  'http://localhost:3689/api/player/play' -o /dev/null -w "play: %{http_code}\n"
```

```sh
sleep 25
```

**Step 5 — stop and check.**

```sh
curl -s -X PUT 'http://localhost:3689/api/player/stop' -o /dev/null -w "stop: %{http_code}\n"
```

```sh
ssh <user>@<receiver-ip> 'pkill -f "shairport-sync -c /etc/shairport-sync-verify.conf"'
```

```sh
scp <user>@<receiver-ip>:/tmp/verify-recv.pcm "/Users/alechenderson/Projects/Audiouter/dev/.run/verify-recv-owntone-ap2.pcm"
```

```sh
python3 - "/Users/alechenderson/Projects/Audiouter/dev/.run/verify-recv-owntone-ap2.pcm" <<'PY'
import struct, math, sys
data = open(sys.argv[1], "rb").read()
n = len(data) // 2
if n == 0:
    print("receiver PCM EMPTY — FAIL"); sys.exit(1)
s = struct.unpack("<%dh" % n, data[:n*2])
rms = math.sqrt(sum(x*x for x in s) / n) / 32768.0
print(f"bytes={len(data)} frames={n//2} RMS={rms:.5f}")
print("VERDICT: PASS — AP2 receiver got NON-SILENT audio via OwnTone" if rms > 1e-4
      else "VERDICT: FAIL — silent")
PY
```

**Expected:** `VERDICT: PASS`. This proves, independent of our engine: the
receiver builds and runs AP2 mode correctly, PTP is set up well enough for audio
to actually play (not just connect), the network path (mDNS + PTP multicast, no
VPN interference) is sound, and the file-capture backend correctly records what
was sent. Once this passes, any later FAIL from *our* engine against the same
receiver is attributable to the engine, not the harness — which is the entire
point of doing this smoke test first.

**Step 6 — leave things clean:**

```sh
curl -s -X PUT 'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"
```

```sh
ssh <user>@<receiver-ip> 'sudo systemctl start shairport-sync'
```

---

## 7. Information needed from ahh

Before this harness can be stood up for real, confirm:

- [ ] **What machine is it** (model/spare hardware — laptop, desktop, Raspberry
      Pi, mini PC, etc.)?
- [ ] **What OS is currently on it** (or can be put on it)? If it's a second Mac,
      re-read §0/§1b — this changes the plan materially (need Linux/Pi instead,
      or fall back to the AirPlay-1 smoke test only).
- [ ] **Its IP address** on the same network as this Mac (or how to find it —
      `ip addr` on Linux, router admin page, etc.). Confirm it'll be **on the same
      L2 subnet/Wi-Fi network** as this Mac during harness sessions (§4).
- [ ] **SSH access** — hostname/IP, username, and whether key-based auth is set
      up (preferred) or password auth (works, just less convenient for repeated
      scripted `scp`/`ssh` calls in `T-HARNESS-2`). Confirm the account has `sudo`
      for the install steps in §2.
- [ ] **Is it wired or Wi-Fi?** If Wi-Fi, flag the power-management setting
      (§4) as a setup step, not just a troubleshooting afterthought.
- [ ] **Any VPN client installed/active on either this Mac or the receiver
      machine** — explicitly check and disable for harness sessions (§4); this
      already bit a previous session on this Mac.
- [ ] Roughly **how much time to budget** for the from-source build (§2a) — a few
      minutes on modern hardware, 10-15+ on a Raspberry Pi B-class device.

---

## 8. Restated: PTP contention rule (from the plan's grounding)

Engine-PTP (our sender, once it exists and runs its own PTP client per
`T-PTP-1`/`T-HELPER-DESIGN-1`) and any `nqptp` instance **cannot both hold UDP
319/320 live on the same host at the same time.** This is not a problem for the
two-host harness in steady state — our engine's PTP runs on this Mac, `nqptp` runs
on the receiver, different hosts, no contention. It only bites if:

- Someone runs a live smoke test of the engine's own PTP helper *and* the
  Homebrew AirPlay-1 fallback receiver's future AP2 variant on this same Mac
  (not applicable today — Homebrew shairport-sync here has no AP2 support/nqptp
  at all, so this specific collision can't happen yet).
- Two verification sessions are run concurrently on the same Mac in the future
  once the engine's PTP helper (`T-HELPER-DESIGN-1`) is live — serialize live PTP
  sessions, one at a time, same rule the plan already states for `T-HARNESS-2`.

This two-host harness's whole design point is to avoid this contention entirely
by keeping `nqptp` off this Mac permanently.

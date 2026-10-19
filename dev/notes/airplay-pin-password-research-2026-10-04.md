# AirPlay PIN and password receivers: how they authenticate, and how Audiout could support them

Research date 2026-10-04. Read-only; no code changed. Line numbers refer to this worktree.

## Where Audiout stands today

- The vendored sender already contains every protocol path below: `sender/airplay.c` (AirPlay 2), `sender/raop.c` (AirPlay 1), `pair_ap/pair_homekit.c` and `pair_ap/pair_fruit.c`.
- None of it is reachable with a secret. `shims/conffile.c` never returns a per-device config, so `device->password` is always NULL (`airplay.c:4119`, `raop.c:4469`). `shims/db.c` makes `db_speaker_save` a no-op, so a pairing key earned at `airplay.c:3633` is thrown away. `outputs_device_authorize` (`shims/outputs.c:278`) exists but no Swift code calls it.
- The only visible result today is `OUTPUT_STATE_PASSWORD`, which reaches Swift as `AirPlayEngineError.passwordRequired` and `NativeBackend` maps to `.authRequired`.
- The sender's pairing identity is the `libhash` set at `AirPlayEngine.swift:619`, derived from `clientName` plus the per-install seed. A receiver remembers a pairing against that identity, so changing `clientName` or the seed would void every stored pairing.

## 1. Kinds of access control

How a receiver announces each one:

| Kind | Announced by | Sender sees on `GET /info` (`statusFlags`) |
|---|---|---|
| a. AirPlay 1 password | `_raop._tcp` `pw=true` | n/a (RAOP has no `/info` step in OwnTone) |
| b1. Apple TV "Require Code" every time | `sf`/`flags` bit 3 (PINRequired) | bit 3 |
| b2. Apple TV code first time only, and old "Device Verification" | `sf`/`flags` bit 9 (OneTimePairingRequired) | bit 9 |
| b3. Apple TV / HomePod "Require Password" (AirPlay 2) | `pw=true` on `_airplay._tcp`, `flags` bit 7 (PasswordRequired) | bit 7 |
| c. Only People Sharing This Home | `act=2` (pyatv calls it "Current User"); `flags` bit 10 (DeviceWasSetupForHKAccessControl) | refuses or never offers a PIN |
| e. Transient pairing | `features` bit 48 (and 46 HomeKit pairing) | none of bits 3, 7, 9 |

Sources: status flags and TXT keys from the unofficial spec ([status flags](https://openairplay.github.io/airplay-spec/status_flags.html), [service discovery](https://openairplay.github.io/airplay-spec/service_discovery.html), [features](https://openairplay.github.io/airplay-spec/features.html)); `act`/`acl` handling from [pyatv `utils.py`](https://raw.githubusercontent.com/postlund/pyatv/master/pyatv/protocols/airplay/utils.py), which marks `act=2` as unsupported and `acl=1` as pairing disabled. Meanings of `acl` values beyond that are not documented anywhere I found.

Notes per kind:

- **a. AirPlay 1 password.** Plain HTTP Digest auth on RTSP: the receiver answers `401` with `WWW-Authenticate`; the sender retries with an MD5 digest, username `iTunes` (`raop.c` around 905-975, 3819-3830). The password is the secret itself, sent every session. Used by old AirPort Express, shairport-sync in classic mode (its `password` setting "only works for AirPlay and not for AirPlay 2", [man page](https://www.mankier.com/1/shairport-sync)), and many older third-party receivers.
- **b. Apple TV and HomePod settings.** Apple TV offers Everyone / Anyone on the Same Network / Only People Sharing This Home, plus Require Password ([Apple 102324](https://support.apple.com/en-us/102324), [tvOS guide](https://support.apple.com/en-kz/guide/tv/atvb0342111f/18/tvos)). HomePod offers the same three plus Require Password under Home app > Home Settings > Speakers & TV ([HomePod guide](https://support.apple.com/guide/homepod/apdb68d3dec5/homepod)). Older tvOS also had "Require Code First Time Only" ([Roon community](https://community.roonlabs.com/t/enable-apple-tv-airplay-device-password/95392/3)). Apple: "The first time you use AirPlay with your Apple TV, you'll see an onscreen password."
- **c. Home members only.** Not supportable. pyatv returns `Unsupported` for it, and pyatv, Music Assistant and OwnTone all tell users to switch to "Anyone on the Same Network" ([pyatv troubleshooting](https://pyatv.dev/support/troubleshooting/), [Music Assistant](https://www.music-assistant.io/player-support/airplay/), [OwnTone docs](https://owntone.github.io/owntone-server/audio-outputs/airplay/)). Joining needs the iCloud identity of a home member, which a third-party sender does not have.
- **d. Code shown on the device, key kept.** HomeKit normal pairing: the PIN is used once, a long-lived key is stored and reused with `pair-verify`.
- **e. Transient pairing.** Two-step `pair-setup` with the fixed PIN `3939`, nothing stored ([pair_ap README](https://github.com/ejurgensen/pair_ap), `pair_homekit.c:1178`). HomePods and most AirPlay 2 speakers with no restriction use this; this is what Audiout already does for every AirPlay 2 device. An Apple TV that wants a code answers `470` to the transient attempt (`airplay.c:3819`).

Prevalence: no measured numbers exist. Defaults are "Anyone on the Same Network" with no password, so most homes fall in (e). Apple TVs set to require a code are the common protected case; HomePod Require Password and AirPlay 1 passwords are rarer. Treat this as an unverified estimate.

## 2. The protocol flow OwnTone runs

Everything below is in `sender/airplay.c` and already compiled into Audiout.

1. `GET /info`, read `statusFlags` (`airplay.c:3420`), then choose (`airplay.c:3432-3478`):
   - bit 9 set, no stored key: `POST /pair-pin-start` (header `X-Apple-HKP: 3`). The device shows a 4-digit code. Session ends in the waiting-for-PIN state.
   - bit 9 set, stored key: two-step `POST /pair-verify` with the stored key.
   - bit 3 set: delete any stored key, `POST /pair-pin-start` every time.
   - bit 7 set: three-step `POST /pair-setup` using the **password as the PIN** (`airplay.c:3024`), no `pair-pin-start`. Then the key is stored and later sessions use `pair-verify`.
   - none: transient pairing (`X-Apple-HKP: 4`, PIN 3939). If the device answers `470`, switch to `pair-pin-start` (`airplay.c:3558`).
2. User enters the code. OwnTone's web UI (Settings > Remotes & Outputs) sends it as `PUT /api/outputs/{id}` with `{"pin": "1234"}` ([JSON API](https://owntone.github.io/owntone-server/json-api/)). That calls `device_authorize` → `airplay_device_authorize` (`airplay.c:4341`) → three-step `POST /pair-setup` (SRP with the PIN, then Ed25519 key exchange).
3. On success `pair_setup_result` returns a hex string: the sender's 64-byte Ed25519 private key plus the receiver's 32-byte public key, 192 hex characters (`pair_homekit.c:1651-1660`). OwnTone saves it in SQLite, table `speakers`, column `auth_key` ([db.c](https://github.com/owntone/owntone-server/blob/master/src/db.c), `INSERT OR REPLACE INTO speakers (... auth_key ...)`).
4. Every later session: `pair-verify` with that key, then encrypted RTSP from `SETUP` on.
5. AirPlay 1 receivers (`raop.c`): password goes through Digest auth as above. If `OPTIONS` returns `403`, or `sf` bit 9 is set, RAOP runs the older Apple TV "device verification" (`pair_fruit.c`, `pair-pin-start` then `pair-setup`/`pair-verify`), also storing a key.

pyatv covers the same ground: legacy pairing for Apple TV 3, HAP pairing for AirPlay 2, and "Devices requiring password are only supported when using the RAOP protocol" for streaming ([pyatv features](https://pyatv.dev/documentation/supported_features/)).

## 3. Behaviour a product must get right

- **Where the code appears.** Apple TV shows it on screen. Users report about 60 seconds before it expires (one timed report, [Apple Community](https://discussions.apple.com/thread/253990100)); not confirmed by Apple. HomePod has no screen; I found no source for a HomePod "code" mode, and its protection is the Require Password setting, whose password the owner chose. Unknown: whether HomePod speaks anything.
- **Errors to expect.**
  - `401` with `WWW-Authenticate`: AirPlay 1 password missing; a second `401` after sending it means wrong password (`raop.c:3821`, `airplay.c:3307`).
  - `470`: Apple TV refusing transient pairing; needs a PIN.
  - `403` on `OPTIONS` (AirPlay 1): device verification required.
  - `pair-setup` error TLV (type 7): 2 Authentication (wrong PIN or password), 3 Backoff (wait, retry-delay value given), 4 MaxPeers, 5 MaxTries, 6 Unavailable, 7 Busy (`pair_homekit.c:851-865`). A wrong PIN shows up after the proof step, so an incorrect code fails at the second `pair-setup` response.
  - `pair-verify` failure or the first encrypted request timing out: stored key no longer valid. OwnTone clears the key and requires a new pairing (`airplay.c:3101`, `3660`, `3704`).
  - `403` on `GET /info` with no PIN offered: reported against HomePod/tvOS 27 in [OwnTone #2047](https://github.com/owntone/owntone-server/issues/2047) (opened 2026-09-24); one user cleared it by changing the `User-Agent` string. Unresolved and separate from pairing, but it produces the same symptom.
- **Persistence.** A stored HomeKit pairing survives receiver reboots (it is the receiver's own pairing list). A factory reset, removing the device from the home, or a password change voids it; OwnTone's comment at `airplay.c:3099` names "the device reset its pairings" as the expected cause of a failed verify.
- **Settings changed later.** The sender re-reads `statusFlags` on every connect, so switching an Apple TV from "first time" to "every time" moves it to bit 3 and the sender asks again each time. Switching to "Only People Sharing This Home" makes the device unreachable for a third-party sender.
- **Benchmark.** macOS and iOS show a lock on protected receivers in the AirPlay menu and a sheet for the 4-digit code or the password. I found no Apple document describing that sheet beyond the support pages cited.

## 4. Competitors

- **Airfoil (Rogue Amoeba).** Supports password-protected HomePods and Apple TVs since 5.7.2 (2018-03-30). Stores passwords in the Keychain and clears them on factory reset (5.6.4). Handles stale stored passwords and reports wrong passcodes (5.6.4). Re-asks after a wrong password (4.8.4). Passcode field shown unmasked (5.7.0). Source: [Airfoil release notes](https://rogueamoeba.com/support/knowledgebase/releasenotes/?product=Airfoil+for+Mac). The manual does not describe the sheet itself.
- **Music Assistant.** Per-speaker Setup button: "enter the PIN shown on the device's screen. Devices protected with a password ask for the password instead" ([docs](https://www.music-assistant.io/player-support/airplay/)).
- **Roon.** Recommends switching an Apple TV from "Require Code First Time Only" to a password ([Roon community](https://community.roonlabs.com/t/enable-apple-tv-airplay-device-password/95392/3)).
- AirServer and TuneBlade: no primary-source documentation found. Sonos: no evidence it offers an AirPlay password option.

## 5. Recommendation

One flow, built on what is already compiled in:

1. **Connect as now.** On `passwordRequired`, look at why: AirPlay 1 `pw=true` or `statusFlags` bit 7 means ask for a password; bit 3, bit 9 or a `470` means call `pair-pin-start` and ask for the code on the device. The engine needs to report which of the two it is; today both collapse to `OUTPUT_STATE_PASSWORD`.
2. **Ask once, in a sheet** on the speaker row: "Enter the code shown on [TV]" or "Enter this speaker's AirPlay password". Keep the field unmasked for codes.
3. **Wire the C side** through the shims, leaving vendored files untouched: make the per-device password available where `airplay.c:4119`/`raop.c:4469` read it, expose `outputs_device_authorize(device, pin)` to Swift, and replace the `db_speaker_save` no-op with a callback that hands `auth_key` to Swift. Load the key back into `device->auth_key` before connecting.
4. **Store in the Keychain**, one generic-password item per receiver keyed by its `deviceid`: the AirPlay 1 password itself, or the 192-hex-character pairing key for AirPlay 2 (never the PIN; it is single-use). For a bit-7 password device, store both: the password is needed to pair again if the key is voided.
5. **Pair again when** `pair-verify` fails, the first encrypted request times out, a second `401` arrives, or the device advertises bit 3. Clear the stored item and show the sheet again. On `pair-setup` error 3 (Backoff) or 5 (MaxTries), stop and say so rather than retrying.
6. **Never change `libhash` inputs** (`clientName`, install seed) once shipped, or every pairing breaks.
7. **Unsupported, say so plainly:** "Only People Sharing This Home". Tell the user to choose "Anyone on the Same Network" in the Home app, as pyatv and Music Assistant do.

Confidence: high that the flows above are what the vendored code does (read directly). Medium on device behaviour, since it rests on OwnTone code comments, pyatv, and forum reports.

Needs a live test before building:
- Apple TV with "Require Password": does bit 7 plus password-as-PIN `pair-setup` work on current tvOS?
- HomePod with Require Password: same question; no source confirms OwnTone's path works on HomePod.
- Apple TV code mode: actual code lifetime, and whether `pair-pin-start` on current tvOS still shows the code.
- That a stored key survives a receiver reboot and an Audiout restart with the same `libhash`.
- Whether the tvOS 27 `403` on `GET /info` (OwnTone #2047) hits Audiout too.

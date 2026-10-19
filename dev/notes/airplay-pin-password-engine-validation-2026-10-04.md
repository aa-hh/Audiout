# AirPlay PIN and password receivers: what the engine does today

Read-only trace, 2026-10-04, at `d87e4529`. C paths are under
`AirPlayEngine/Sources/CAirPlayEngine/` unless stated.

## Short answer

The vendored C sender already contains every pairing and password handshake.
None of it can run, because the shims feed it no password, no PIN and no saved
key, and Swift has no call that reaches `outputs_device_authorize`. Roadmap 027
says the handshake is missing from the C core; it is present and compiled
(`AirPlayEngine/Package.swift:255-263` compiles `sender`, `evrtsp`, `pair_ap`).

## 1. Pairing library (`pair_ap/`)

Three client types, `pair_ap/pair.h:20-35`:

| Type | Used for | Inputs | Result |
|---|---|---|---|
| `PAIR_CLIENT_FRUIT` | AirPlay 1 (RAOP) Apple TV verification | 4-digit PIN; no device id (`raop.c:4250`) | 128-hex private key string |
| `PAIR_CLIENT_HOMEKIT_NORMAL` | AirPlay 2 PIN or password pairing | PIN or password, our 16-hex sender id | 192-hex string: our private key + receiver public key (`pair_homekit.c:1646-1663`) |
| `PAIR_CLIENT_HOMEKIT_TRANSIENT` | AirPlay 2, no protection | none; PIN forced to `3939` (`pair_homekit.c:1177-1178`) | session secret only, nothing to keep |

- The saved key comes back from `pair_setup_result(&client_setup_keys, ...)` (`pair.c:498`), and goes back in through `pair_verify_new(type, client_setup_keys, ...)` (`pair.c:520`).
- HomeKit also offers an `add_cb` called with the receiver's public key and id after setup (`pair_homekit.c:1630-1631`). The sender passes `NULL` (`airplay.c:3032`) and reads the string instead.
- SRP takes `strlen(pin)` (`pair_homekit.c:1243`), so a password of any length works, despite the "must be 4 chars" comment (`pair.h:81`).
- The library also has a server side (`PAIR_SERVER_HOMEKIT`, `pair_homekit.c:1993`), usable for an in-process client-against-server test.

## 2. How the sender uses it

### AirPlay 2 (`sender/airplay.c`)

- Discovery reads no `pw`, `pk`, `flags` or `sf` from the TXT record. It reads `deviceid`, `features`, `model` (`airplay.c:4066-4215`). The password comes only from config: `cfg_getstr(devcfg, "password")` (`airplay.c:4119-4121`), copied to the session (`airplay.c:1706`).
- The protection decision is made after `GET /info`, from the receiver's `statusFlags` (`airplay.c:3425-3478`):
  - bit 9, one-time pairing: saved key → pair-verify; no key → `POST /pair-pin-start`.
  - bit 3, PIN every time: clears the key, then `pair-pin-start`.
  - bit 7, password: no password → abort with "none given in config" (`airplay.c:3461-3464`); password but no key → pair-setup using the password as the PIN (`airplay.c:3024-3025`); key → pair-verify.
  - none: transient pairing. This is what every working AirPlay 2 speaker uses today.
- A `401` on `SETUP` also retries once with an HTTP digest password header (`airplay.c:3304-3318`, `auth_header_add` at `airplay.c:696`).
- `pair-pin-start` success leaves the session in `AIRPLAY_STATE_AUTH` (`airplay.c:3146-3150`). That reports `OUTPUT_STATE_PASSWORD` (`airplay.c:1080-1081`). So by the time the app shows "Password required", an Apple TV is already showing a PIN on screen.
- The PIN is entered through `airplay_device_authorize(device, pin, cb)` (`airplay.c:4342-4352`), registered as `.device_authorize` (`airplay.c:4543`). It runs pair-setup in a fresh session. On success the key is stored on `device->auth_key` and `db_speaker_save(device)` is called (`airplay.c:3633-3637`); the state becomes `STOPPED`.
- The key is wiped in memory on any rejection (`airplay.c:3101-3107`, `3449`, `3660-3662`, `3703-3705`) without calling `db_speaker_save`.

### AirPlay 1 (`sender/raop.c`)

- Discovery reads `pw` (`raop.c:4448-4476`) and `sf` bit 9 (`raop.c:4479-4484`). The password comes from config only (`raop.c:4469-4470`).
- With `pw=true` and no password, the digest header step returns -2 and the state becomes `RAOP_STATE_PASSWORD` (`raop.c:914-918`, `1154-1160`). A wrong password does the same (`raop.c:3820-3827`).
- A `403` on `OPTIONS` sends `pair-pin-start` (`raop.c:3845-3858`). `raop_device_authorize` runs fruit pair-setup (`raop.c:4272-4290`) and saves the key (`raop.c:4180-4184`). The next start runs pair-verify when a key exists (`raop.c:4631-4640`).

### The shims cut all inputs

- `cfg_gettsec` always returns `NULL` (`shims/conffile.c:176-184`), so `devcfg` is `NULL` and the password is always `NULL`. The comment at `shims/conffile.c:24-28` says per-device values should come through the Swift descriptor; that was never built.
- `db_speaker_save` is a no-op (`shims/db.c:21-25`). Nothing ever sets `auth_key` from outside; `shims/player.c:42-58` does not load one. The key lives only on the C device struct until that struct is freed (`shims/outputs.c:201`).
- `outputs_device_add` copies `password` from each re-announce over the stored one (`shims/outputs.c:142-143`), so a value set directly on the struct would be wiped by the next Bonjour update. It leaves `auth_key` alone.
- `outputs_device_authorize` exists (`shims/outputs.c:278-282`) and is visible to Swift through the umbrella header (`include/CAirPlayEngine.h:35`). No Swift code calls it.

### The pairing identity changes every launch

Our 16-hex id in both pair-setup and pair-verify is `airplay_device_id = libhash` (`airplay.c:4424`, `3030`, `3066`). `libhash` comes from `EngineConfig.installSeed` (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:616-619`), which defaults to a fresh random number (`AirPlayEngine.swift:93`, `109-112`). The app takes the default (`AudioutCore/Sources/AudioutCore/OutputBackend.swift:703-704`). A HomeKit receiver files our key under that id, so a saved key would stop verifying after every relaunch.

## 3. Swift engine layer

- `OutputState.passwordRequired` (`AirPlayTypes.swift:106-107`) is produced only by mapping `OUTPUT_STATE_PASSWORD` (`CompletionRegistry.swift:248`). `addOutput` turns it into `AirPlayEngineError.passwordRequired` (`AirPlayEngine.swift:908`, type at `AirPlayTypes.swift:175`).
- No public call takes a password, PIN or key. `DeviceDescriptor` has name, address, port, kind and `txtRecord` only (`AirPlayTypes.swift:48-87`); `feedDescriptor` copies the TXT verbatim (`AirPlayEngine.swift:693-722`).
- `engine-probe --password` is parsed (`EngineProbeParsing/ProbeArgParsing.swift:251-253`) but the value is thrown away: `txt["pw"] = "true"; _ = pw` (`engine-probe/main.swift:159`). On AirPlay 1 that forces `.passwordRequired`; on AirPlay 2 it does nothing. No `--pin` flag.

## 4. App side

- Discovery passes the whole TXT record through (`NativeDiscovery.swift:747-761`). App code reads only `features` (`NativeDiscovery.swift:625`) and `model` (`NativeBackend.swift:5451-5452`). Nothing reads `pw`, `pk`, `flags`, `sf`, `acl` or `act`.
- Both failure sites map `.passwordRequired` to `ConnectionFailure.Cause.authRequired`: the connect catch (`NativeBackend.swift:3586-3598`) and the state stream (`NativeBackend.swift:5117-5175`). The device is marked unavailable, deselected and parked. Telemetry: `airplay:connect_failed` or `airplay:session_failed` with `cause: authRequired`.
- The user sees "Password required" (`ConnectionState.swift:99`) and copy that names the Mac receiver setting and says entry "isn't supported yet" (`ConnectionState.swift:120-125`).
- `DiagnosisContext.requiresAuth` (`ConnectionState.swift:152`) is set only by tests; no source file builds a `DiagnosisContext`.
- No Keychain code exists. The only `import Security` is code-signature checking (`CodeSignature.swift:2`). The companion approval store is plain JSON with no secret (`CompanionApprovalStore.swift:9-26`), so nothing is reusable for secrets.
- `Device` is not `Codable` (`Device.swift:10`). `routing.json` stores only ids (`RoutingStore.swift:32-34`). Adding a field like `requiresPassword` to `Device` touches no saved file.

## 5. Offline testing

- The fake speaker is Homebrew `shairport-sync` 5.1, classic AirPlay 1 only (`dev/fake-speakers.sh:3-13`). Its sample config offers `password = "secret";` (Homebrew `shairport-sync.conf.sample` line 18). Adding that line to the generated config (`dev/fake-speakers.sh:78-84`) gives an offline AirPlay 1 password receiver. Not tried.
- No fake AirPlay 2 receiver exists. `mock-speakers-demo` and `MockBackend` have no auth case; `CastFakeReceiver` is Cast only.
- Engine-level offline options: `issueOverride` drives `startOp` headless (`AirPlayEngine.swift:1519-1523`), enough to test how an `authorize` call maps results. The `pair_ap` server side can test the PIN handshake and key round trip in-process.
- AirPlay 2 password: the mule Mac's AirPlay Receiver with a password set. The self-filter drops only this Mac's own hostname.

## 6. Conclusions

### (a) What works end to end

- Transient pairing: works today, the default path.
- AirPlay 1 password (`pw=true`, digest): complete in C, needs only the password fed in.
- AirPlay 2 password (`statusFlags` bit 7): complete in C, needs only the password. It pairs again with the password on each connect, so a saved key is optional.
- HomeKit PIN (bits 3 and 9) and AirPlay 1 fruit PIN: the C flow is complete, but it needs a Swift `authorize` call, a key saved and restored across launches, and a stable sender id.

### (b) Minimum changes (proposed names)

Engine:
1. Optional `password` on `DeviceDescriptor`. `feedDescriptor` stores it in a shim table keyed by the Bonjour name. `cfg_gettsec` returns a non-`NULL` section only for names in the table, `cfg_getstr(..., "password")` serves it, and the per-device bool keys (`exclude`, `permanent`, `exclusive`, `airplay2_disable`, `raop_disable`, `ptp_disable`) return 0. Today those reach `conffile_unknown_key`, which asserts when enabled (`shims/conffile.c:63-72`, `233-245`). Files: `AirPlayTypes.swift`, `AirPlayEngine.swift`, `shims/conffile.c`. Vendored C stays untouched, and the value is re-read on every announce, so it survives the merge at `shims/outputs.c:142-143`.
2. `authorize(_ id: OutputID, pin: String) async throws`: a `startOp` wrapper around `outputs_device_authorize`. `.stopped` means paired; `.passwordRequired` means wrong PIN. File: `AirPlayEngine.swift`.
3. A key-saved callback: `db_speaker_save` (`shims/db.c:21`) forwards `(device id, auth_key)` to Swift when `auth_key` is set. Volume saves call it too (`shims/db.h:9`), so forward only on a key change. File: `shims/db.c`, plus a Swift stream.
4. Optional `authKey` on `DeviceDescriptor`, written to `device->auth_key` in the shim when the struct has none. Files: `AirPlayEngine.swift`, a setter in `shims/outputs.c`.

Core:
5. Persist `installSeed` once per install and pass it at `OutputBackend.swift:704`. This is a prerequisite for keys 3 and 4.
6. A Keychain store for passwords and keys, keyed by device id (new file in `AudioutCore/Sources/AudioutCore/`). When the app gets `.authRequired` with a key stored, delete the key, because C has already wiped its copy.
7. Read TXT `flags`/`sf` bits 3, 7, 9 and `pw` in `NativeDiscovery.swift` to tell "type the code on the TV" from "type the password". Expose it on `Device`.
8. Prompt UI off the failure row, then `retryOutput`; update the copy at `ConnectionState.swift:120-125`. Add new analytics events to the `audiout-shared` event list first.

### (c) Needs a live device

- Whether an Apple TV keeps its PIN on screen after the `pair-pin-start` session closes and `authorize` opens a new one. OwnTone does it this way, but that is not proven here.
- Whether a Mac receiver in "Current User" mode sends bit 7 or something no password can fix.
- Whether HomePods or third-party speakers accept password-as-PIN pair-setup.
- AirPort Express MFi `auth-setup` is compiled out (`AIRPLAY_USE_AUTH_SETUP 0`, `airplay.c:73`); its behaviour is unknown.

### Risk, highest first

1. HomeKit PIN: changes 2-8, a changing sender id, no offline receiver.
2. AirPlay 1 fruit PIN: same key plumbing, only for old Apple TVs.
3. AirPlay 2 password: change 1 plus prompt and Keychain. Testable on the mule.
4. AirPlay 1 password: change 1 only. Testable offline with `shairport-sync`.

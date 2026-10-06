# AirPlay password and PIN receivers: the recommendation (2026-10-04)

Ties together three notes written the same day:

- [Wire research](airplay-pin-password-research-2026-10-04.md): what receivers advertise, what each kind needs, what competitors do.
- [Engine validation](airplay-pin-password-engine-validation-2026-10-04.md): what the vendored C code and the Swift wrapper do today, file:line.
- [UI discovery](airplay-pin-password-ui-discovery-2026-10-04.md): where the prompt, the lock hint and "forget" fit on the Mac and the phone.

Roadmap entry 027 already names this work. Its claim that the handshake is missing is wrong: every handshake is compiled in. Only the glue is missing.

## What is true today

- The vendored sender contains all four handshakes: AirPlay 1 digest password, AirPlay 2 password-as-PIN, HomeKit PIN pair-setup with a stored key, and transient pairing (the no-PIN path every unprotected AirPlay 2 speaker uses now).
- Nothing reaches them. The config shim serves no per-device password (`shims/conffile.c:176`). The key-save shim drops the pairing key (`shims/db.c:21`). `outputs_device_authorize` is exported but no Swift code calls it.
- The sender identity the receiver files a pairing under hashes `clientName` with `installSeed`, and the app never sets the seed, so it is random per launch (`AirPlayEngine.swift:93`, `OutputBackend.swift:704`). A stored pairing key would die on relaunch.
- The app already maps the engine's `passwordRequired` to a "Password required" failure under the row with the copy "Entering a password here isn't supported yet" (`ConnectionState.swift:99`, `:125`).
- Discovery reads only the `features` TXT key (`NativeDiscovery.swift:625`). The `flags`/`sf` bits and `pw` that say which kind of protection a speaker has are not read.
- No Keychain code exists anywhere in the app.

## Kinds of receiver, and the verdict

| Receiver setting | Advertised by | Supportable | Offline test |
|---|---|---|---|
| AirPlay 1 password | `_raop` `pw=true` | yes, feed the password | yes, `shairport-sync` with `password` set |
| AirPlay 2 "Require Password" (Apple TV, HomePod, Mac receiver) | `_airplay` `pw=true`, flags bit 7 | yes, feed the password | mule's AirPlay Receiver with a password |
| Apple TV code, first time only | flags bit 9 | yes, PIN once, store key | needs a real Apple TV |
| Apple TV code, every time | flags bit 3 | yes, PIN every join | needs a real Apple TV |
| "Only People Sharing This Home" | `act=2`, flags bit 10 | no, needs a home member's iCloud identity | say so in copy, point at the Home app |

## The one approach

1. Engine: an optional password on `DeviceDescriptor` served through the config shim; an `authorize(id, pin:)` wrapper; a key-saved callback out of `db_speaker_save`; an optional stored key on `DeviceDescriptor` written back before connect. Vendored C stays untouched.
2. Core: persist `installSeed` once per install; a Keychain store keyed by device id holding the password or the pairing key (never the PIN); read `flags`/`sf`/`pw` in discovery so the prompt can say "code on the TV" or "password"; on a rejected stored key, delete it and prompt again; stop on the receiver's back-off error rather than retry.
3. Mac UI: a small sheet modelled on the licence sheet, opened from the failure panel's button ("Enter Code…" / "Enter Password…") or directly on a user-clicked join; wrong entry keeps the sheet open with a result line; a lock glyph beside the name once discovery knows the speaker is protected; "Forget password" in the device detail pane's About section.
4. Phone: send the user to the Mac, matching the existing "Go to {Mac} and click Allow" screen. No protocol change for the first version.

## Build order by risk

1. Password receivers (AirPlay 1 and AirPlay 2 password). Smallest change, testable without hardware. Covers the seed persistence and the Keychain store, which the PIN path then reuses.
2. Apple TV code pairing. Needs the `authorize` call, key save and restore, and a live Apple TV at both settings.

## Still needs a live device

- Whether current tvOS keeps the code on screen while the sender closes the `pair-pin-start` session and opens a new one to send it.
- Whether a HomePod with Require Password accepts the password through pair-setup.
- Whether a stored key survives a receiver reboot and an app relaunch with the persisted seed.
- Whether a Mac receiver in "Current User" mode reports bit 7 or something no password can fix.

## Owner rulings (2026-10-04)

- Build split: passwords first (AirPlay 1 and AirPlay 2 password), Apple TV code pairing as a second PR.
- Mac prompt: the small sheet, kept minimal. No error state is shown until the user has entered a password and it failed.
- Phone: enter the code on the phone in version one (connection snapshot carries the cause and the kind of credential, one command submits it, answered through the existing command result).

# Companion approval secret: design brief (2026-09-02)

Not built. This is the design for the fix to two pre-launch review findings on
the Mac-to-iPhone companion link. Line numbers for `audiout-shared` are from its
HEAD `60849c2` (tag `0.2.1`), not from any working tree.

## Problem

P2: the companion listener is a plaintext WebSocket
(`CompanionServer.swift:291`), and the only thing identifying a phone is the
`clientID` it sends in `hello` (`CompanionServer.swift:724-745`), so a
remembered ID resolves instantly with no prompt
(`CompanionApprovalStore.swift:145-156`) and anyone on the same network who
captures that ID can replay it and be admitted. P3: every approved phone
receives group names, the display names of the apps currently playing, and
device names (`CompanionSnapshotBuilder.swift:122,145,196`), all unencrypted.
The feature is on by default: `allowRemoteControl` returns `true` when unset
(`AppSettings.swift:326,334`).

## Threat model

In scope: a passive eavesdropper or an active peer on the same local network who
holds a `clientID` on its own and replays it. That covers any ID captured before
this fix ships, an ID read out of a phone's `UserDefaults` on a restored backup,
and an ID guessed or copied from anywhere other than a live post-fix connection.

Out of scope, deliberately, and this is the honest limit of the design: an
eavesdropper who captures a `hello` frame sent AFTER this fix ships. That frame
carries the secret next to the ID, so replaying the pair passes the gate with no
prompt, exactly as replaying the ID alone does today. The secret is a bearer
value on a plaintext link and cannot survive being sniffed. A challenge and
response over a server nonce would stop that replay, but a listener who is
present at the moment of approval reads the secret out of the `approvalSecret`
frame and can answer any challenge, so only TLS closes the hole for good; both
are in "Not chosen".
Also out of scope: an attacker with read access to the disk of either device; a
man-in-the-middle who rewrites frames live; and confidentiality of speaker and
app names on the wire, which stays a documented property of the product because
this fix does not encrypt anything.

Goal: a `clientID` on its own never passes the gate without a prompt. Not the
goal, and not achieved: stopping someone who has recorded a whole post-fix
connection.

## Design in one paragraph

When the Mac's user clicks Allow for an unknown phone, the Mac mints 32 random
bytes, stores them on that phone's approval record, and sends them to that phone
on the same connection, just before `welcome`. Every later `hello` from that
phone carries the secret, and the Mac admits it without a prompt only when the
stored and presented secrets match. A remembered phone that presents no secret
or the wrong one is refused with a goodbye reason telling it to start over as a
new phone: mint a new ID, forget the secret, reconnect once, which re-prompts
the user on the Mac.

## Wire changes (audiout-shared, `Sources/AudioutProtocol/CompanionMessage.swift`, HEAD `60849c2`)

Three additive changes, following the shared repo's AGENTS.md rule that a new
case is added rather than an existing encoding changed.

- `hello` (`:25`) gains an optional fourth field `secret: String?`, encoded only
  when non-nil and decoded with `decodeIfPresent`, the same pattern `clientID`
  already uses (`:132`); `PayloadKeys` (`:105`) gains `secret`. An old Mac
  ignores the unknown key, and a new Mac reads absence as nil. This changes the
  Swift case signature, which is source-breaking for both consumers and is
  covered by the pin bump, but it does not change how an old peer decodes an
  existing frame.
- A new server-to-client case `approvalSecret(secret: String)`, with a matching
  `TypeName` entry `approvalSecret` (`:114`). It is sent once, on the connection
  where Allow was clicked, immediately before `welcome` (`:29`). Old phones
  decode it as `.unknown` and ignore it (`MacConnection.swift:332-333`).
- A new constant `CompanionGoodbyeReason.secretMismatch = "secretMismatch"` in
  the enum at `:52-71`, with a doc comment saying: the phone's ID is remembered
  but its secret is missing or wrong, so the phone must forget both and reconnect
  as a new phone.
- `CompanionProto.version` stays `1` (`CompanionProto.swift:16`). An old peer
  handles every new frame by ignoring it, so no existing semantics change, which
  is the bump rule at `:10-15`. Tag the shared package `0.3.0`: additive API,
  source-breaking case signature.
- Secret format, on the wire and on disk: 32 bytes from `SecRandomCopyBytes`,
  encoded as 64 lowercase hex characters. The Mac refuses anything that is not
  exactly 64 hex characters as a mismatch before comparing, and compares in
  constant time.

## Mac side (this repo)

- Storage decision: the secret lives on `CompanionApproval` as `secret: String?`
  inside `companion-approvals.json` (`CompanionApprovalStore.swift:16-31,
  55-56`), not in the Keychain. Reasons: that file already holds the identity
  that gates access, so the secret adds no new class of local exposure; the
  threat model is the local network, not the disk; the app uses no Keychain today
  (no `SecItem*` calls anywhere in `AudioutCore/Sources`) and the licence key
  itself sits in `UserDefaults` (`AppSettings.swift:462-465`); and adding
  Keychain would introduce the first Keychain access prompt for dev-signed
  rebuilds. `currentSchemaVersion` (`:46`) stays `1`: the new field is optional
  and old readers ignore unknown keys, whereas a bump would make older builds
  refuse the whole file at the guard on `:71` and re-prompt for every phone,
  including the denied ones.
- Mint: in `CompanionApprovalController.resolvePrompt` (`:171-184`) when
  `allowed` is true. The record carries the secret, and the decision handed to
  waiters carries it too so the server can send it.
- `ApprovalDecision` (`CompanionServer.swift:81-83`) changes shape. Decision
  recorded here: `.approved` gains an associated value `secretToSend: String?`,
  nil for a remembered phone, and a third case `refusedSecretMismatch` is added
  so the server can send goodbye reason `secretMismatch` instead of
  `notApproved`. No other cases, and no generic reason-carrying `.refused` case.
- Verify: `handleRequest` (`CompanionApprovalStore.swift:145-156`) gains a
  `presentedSecret: String?` parameter, fed from the new hello field through
  `onApprovalRequest` (`CompanionServer.swift:109`, handoff at `:793-796`,
  wiring at `AppDelegate.swift:2381-2386`). Rules, in order:
  1. No record: prompt, unchanged.
  2. Record `denied`: denied, unchanged, no secret needed.
  3. Record `approved`, stored secret equals presented secret: approved
     instantly.
  4. Record `approved` with a stored secret, presented secret missing or
     different: `refusedSecretMismatch`, no prompt, record untouched.
  5. Record `approved` with no stored secret, written before this change: treat
     as unknown and prompt; on Allow the record is replaced by one carrying a
     secret.
- `CompanionServer`: on `.approved(secretToSend: s)` with non-nil `s`, send
  `approvalSecret` and then follow the existing `welcome` path through
  `promote(_:)` (`:509`). On `refusedSecretMismatch`, send
  `goodbye("secretMismatch")` and close, with the same mechanics the
  `notApproved` path uses today.
- Settings > General, "Remembered iPhones"
  (`GeneralSettingsViewController.swift:65`): no UI change. Revoke
  (`CompanionApprovalStore.swift:188-193`) already deletes the record and with it
  the secret.
- Phones already approved when the Mac update lands have records with no secret,
  so they prompt once more; on Allow the new record carries a secret. Denied
  phones stay denied. Nothing has shipped yet (`PRODUCT.md:39`), so this costs
  Alec's own phone one tap.

## Phone side (audiout-remote)

- Storage decision: the secret goes in the iOS Keychain as a generic-password
  item, service `com.audiout.remote.approval-secret`, account = `DiscoveredMac.id`
  (`MacBrowser.swift:27-31`), accessibility
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Reasons: it is a bearer
  credential; the Keychain needs no prompt on iOS; and "this device only" stops a
  restored backup on a second phone from silently impersonating the first, since
  the restored phone has the `UserDefaults` clientID but no secret, hits
  `secretMismatch`, mints a new ID and re-prompts, which is the wanted behaviour.
  One Mac means one secret; several Macs mean several items.
- Send: `MacConnection.swift:256-258` reads the secret for `mac.id` and passes it
  in `hello`.
- Receive: the inbound switch at `MacConnection.swift:296-334` gains
  `.approvalSecret(secret)`, which stores it for `mac.id`. Accept it only while
  the connection is handshaking or awaiting approval; ignore it otherwise.
- Goodbye handling: `ConnectionController.swift:496-511` maps `secretMismatch` to
  `.repairIdentity`, the same class as `invalidClientID` at `:505`. The repair
  path (`:367-376`) additionally deletes the stored secret for that Mac before
  regenerating the ID, and the existing `identityRepairAttempted` guard (`:170`)
  keeps it to one retry.
- `ClientIdentity` (`:16-40`) is unchanged.

## Sequencing across the three repos

1. The `audiout-shared` checkout has uncommitted edits from another session in
   `CompanionCommand.swift`, `CompanionMessage.swift`, `CompanionSnapshot.swift`
   and `CompanionMessageTests.swift`. The protocol change lands on a branch off
   whatever those become; do not build on the dirty tree.
2. audiout-shared: the three wire changes plus tests, `swift test`, tag `0.3.0`,
   push (shared AGENTS.md rules 1 to 3).
3. Mac repo, on a worktree branch: bump `AudioutCore/Package.swift:163` to
   `from: "0.3.0"`, then the store, controller and server changes with their
   tests. An old phone against a new Mac is prompted once (verify rule 5), and
   from then on it is refused silently: its hello carries no secret while the
   record now has one, so rule 4 returns `refusedSecretMismatch` with no prompt,
   and the old phone does not know `secretMismatch`, so `reconnectClass`
   (`ConnectionController.swift:496-511`) drops it into the `.retry` catch-all
   and it redials on backoff forever. That is why the two apps ship together
   (shared AGENTS.md rule 4).
4. Phone repo: bump `project.pbxproj:609` to `minimumVersion = 0.3.0`, let Xcode
   rewrite `Package.resolved`, then the storage, send, receive and goodbye
   changes with their tests.
5. Run the phone-in-hand test below, then merge the Mac and phone branches in the
   same session.

## Test plan

Hermetic, audiout-shared `CompanionMessageTests`: `hello` round-trips with and
without `secret`, and an absent key decodes as nil; `approvalSecret` round-trips;
an old-style hello JSON with no `secret` key still decodes.

Hermetic, Mac `CompanionApprovalStoreTests` (`:13`): the secret persists across
save and load; a schema-version-1 file whose approved record lacks a secret loads
and re-prompts; a denied record without a secret stays denied with no prompt; an
approved record with a matching secret resolves instantly; an approved record
with a wrong secret resolves as `refusedSecretMismatch` with no prompt and the
record unchanged; revoke removes the secret.

Hermetic, Mac `CompanionServerTests` (`:18`, `LoopbackHub` at `:72`,
`connectClient` at `:124`): the Allow path sends `approvalSecret` before
`welcome`; a remembered phone with the right secret gets `welcome` and never
raises `onApprovalRequest`; a replayed hello carrying the ID and no secret gets
`goodbye("secretMismatch")` and never reaches `clients`; a 63-character or
non-hex secret counts as a mismatch.

Hermetic, Mac `CompanionEndToEndTests` (`:27`): one full approve, disconnect and
reconnect cycle carrying the secret.

Hermetic, phone `NetworkingStateTests`: `approvalSecret` is stored and sent in
the next hello; `secretMismatch` deletes the secret, regenerates the ID,
reconnects once and then settles.

Phone in hand (Alec, one Mac and one iPhone on the same Wi-Fi): fresh install,
prompt on the Mac, Allow, connected; kill and relaunch the phone app, connected
with no prompt; revoke in Settings > General "Remembered iPhones", the phone
reconnects and prompts again; replay check, with the phone disconnected, send a
hello JSON carrying only the ID to the Mac's port and confirm
`goodbye("secretMismatch")` with no prompt. That check covers the in-scope
threat only: a hello captured off the wire after the fix ships carries the secret
too, and replaying it whole is expected to be admitted. The recipe for poking the protocol
without websocat is in `dev/notes/companion-mac-live-gate.md:146-151`; it stays
there.

## Not chosen

TLS with trust on first use closes the same replay hole and also gives
confidentiality for the speaker and app names, but it needs certificate
generation and pinning on both sides, a self-signed identity in `NWParameters`,
and pin storage on the phone. That is larger and riskier for the same gate, so it
is deferred.

A signed challenge and response, an HMAC over a server nonce, instead of a bearer
secret: it stops a sniffer who records a post-fix `hello`, because the phone
proves it holds the secret rather than resending it. It does not stop a sniffer
who was listening when the phone was approved, because the secret is still
delivered once in the clear in the `approvalSecret` frame. So it narrows the
out-of-scope case rather than removing it; only TLS removes it. It is not in
this design because it adds a round trip to the handshake on both sides for that
partial gain. It is the follow-up if TLS is not done.

Keychain on the Mac: rejected above. Bumping `CompanionProto.version`: rejected
above.

## Owed to Alec after the build

The phone-in-hand list above. Plus a decision on whether the sentence about
speaker and app names stays on the website privacy page after this fix ships; it
does, unless TLS lands.

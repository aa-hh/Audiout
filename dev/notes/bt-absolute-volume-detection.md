# Detecting Bluetooth absolute volume vs. driver-digital volume on macOS

Research brief, 2026-09-12. Probed live on macOS 27.0 (Darwin 27.0.0) with two Sonos
Bluetooth speakers connected. SDK headers from Xcode-beta MacOSX.sdk.

## Question

When macOS exposes a settable volume property on a Bluetooth output device, can we tell
whether writing it moves the speaker's own hardware volume (AVRCP absolute volume) versus
macOS attenuating digitally in the driver before the A2DP encode? Audiout writes
`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` / `kAudioDevicePropertyVolumeScalar`
(`AudioutCore/Sources/AudioutCore/SystemOutputVolume.swift`) and currently treats
"property settable" as "supported".

## Answer in three lines

macOS tracks this per device (the Bluetooth audio driver keeps an `mIsAbsoluteVolume` flag fed by bluetoothd), but exposes it through no public API — "settable" looks identical either way.
Two discriminators are usable from a signed app: the device's own SDP record (AVRCP Target record, version ≥ 1.4 / category 2 feature bit = claims absolute volume), and a read-back quantization check (absolute-volume devices snap to exact multiples of 1/127 — verified live on both Sonos speakers).
The private driver properties that would answer directly (`kBluetoothAudioDevicePropertySoftwareVolumeEnabled` etc.) are off limits: probing the driver's advertised custom properties crashed coreaudiod three times during this research.

## Findings

### 1. Public Core Audio surface: no discriminator

- `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc') is documented only as
  "the value of the volume control … The actual volume controls this property manipulates
  depends on what the device provides." Nothing about hardware vs. digital.
  — `MacOSX.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AudioHardwareService.h:49-58`
- `kAudioDevicePropertyVolumeScalar` docs say the Float32 range "has a many to one mapping
  with the underlying hardware values" and setting snaps "to the value nearest to what was
  set" — generic to every device, and it is the documented basis for the read-back snapping
  used in finding 3. — `MacOSX.sdk/.../CoreAudio.framework/Headers/AudioHardware.h:1045-1053`
- Nothing in `AudioHardware.h` / `AudioHardwareBase.h` names a "hardware volume" flag.
  Transport type ('blue' / 'blea', `AudioHardwareBase.h:580-582`) identifies Bluetooth but
  says nothing about volume path.
- Live probe: both Sonos devices expose `volm` on output elements 1 and 2 plus 'vmvc',
  all settable. Whether a non-absolute-volume Bluetooth device presents the same controls
  could not be compared — no such device was reachable. **Unverified** whether control
  presence differs at all.

### 2. macOS knows the answer internally — private, not reachable

- `/usr/sbin/bluetoothd` (strings): "Querying capabilities of remote device %s to see if
  they support absolute volume", "Setting absolute volume support to %s", "Setting absolute
  volume to 0x%02x (~%d%%) on device %s", "Received notification for absolute volume
  0x%02x (~%d%%) from device %s", "Failed to re-register for absolute volume change events".
- The Core Audio driver for Bluetooth,
  `/System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver/Contents/MacOS/BTAudioHALPlugin`
  (strings): private device properties `kBluetoothAudioDevicePropertySoftwareVolumeEnabled`,
  `...SoftwareVolumeOnPublish`, `...SoftwareVolumeSupported`; internal state
  "mIsAbsoluteVolume %d"; XPC key `kBTAudioMsgPropertyVolumeIsAbsolute`; "A2DP Received
  initial absolute volume of %f from bluetoothd". So the driver runs one of two volume
  paths — forward to the speaker over AVRCP, or scale in software — and records which.
- These show up as custom properties: the device answers
  `kAudioObjectPropertyCustomPropertyInfoList` ('cust', `AudioServerPlugIn.h`) with ~98
  selectors ('swen', 'svdb', 'btsf', …). A few read fine (e.g. 'btsf' returns a
  `kBluetoothAudioDeviceFeature*` dictionary, 'dcat' returns
  `kBluetoothAudioDeviceCategory = 3`), but the volume-related ones returned
  `kAudioHardwareUnknownPropertyError`, and reading others **crashed coreaudiod** —
  three SIGSEGVs in `BTAudioHALPlugin` via `HALS_UCPlugIn::ObjectGetPropertyData`
  (`/Library/Logs/DiagnosticReports/coreaudiod-2026-09-12-2221*.ips`, 2222*.ips), each one
  tearing down every audio device on the machine. **Do not ship anything that touches
  these selectors.**

### 3. Quantization signature: verified positive, unverified negative

AVRCP absolute volume is a 7-bit value, 0x00–0x7F = 0–127 steps (AVRCP 1.6.2 §6.13; the
0–127 range is also stated in Microsoft's accessory guideline below). Read-back on both
Sonos speakers was an exact multiple of 1/127 every time:

- Move 2: `volm = 0.984252` = 125/127 (error < 1e-6)
- Sonos Move: `volm = 0.275591` = 35/127, and 1.000000 earlier

So on a device where macOS uses absolute volume, `AudioObjectGetPropertyData` after a set
returns the nearest n/127. Positive signal confidence: high (two devices, many reads).
The converse — a software-volume device reading back continuous values — is **unverified**;
no counterexample device was available, and the `VolumeScalar` header text permits any
driver to snap to its own step grid, so a different denominator is possible. Treat
"snaps to n/127" as evidence for absolute volume, not "doesn't snap" as proof against.

### 4. SDP record via IOBluetooth: the capability claim, readable from userspace

What the Bluetooth SIG requires: SetAbsoluteVolume and EVENT_VOLUME_CHANGED are mandatory
for an AVRCP Target of category 2, version 1.4+ (AVRCP 1.6.2 Table 3.1 row 16, §6.13).
The SIG spec PDF is behind a click-through, so the load-bearing citations here are two
implementations plus Microsoft's requirement page, all of which state the same rule:

- Microsoft Bluetooth accessory guidelines (Classic audio): accessories "**shall** indicate
  support of at least Category 2 in the Supported Features attribute of the TG SDP service
  record" and "**shall** implement the Absolute Volume feature of AVRCP 1.6.2 Table 3.1
  row 16 for the TG role".
- BlueZ `profiles/audio/avrcp.c`: `#define AVRCP_FEATURE_CATEGORY_2 0x0002`;
  `avrcp_volume_supported()` returns false when `data->version < 0x0104` or the category 2
  bit is missing from the SDP SupportedFeatures attribute (`SDP_ATTR_SUPPORTED_FEATURES`,
  attribute id 0x0311).
- Android decides the same way (comparative background only): the stack enables absolute
  volume from the remote's AVRCP SDP feature bits, category 2, rather than trusting the
  version number alone.

macOS userspace can read this: `IOBluetoothDevice.services` returns cached
`IOBluetoothSDPServiceRecord`s ("the system requests all of the device's services and
service attributes"), `performSDPQuery:` refreshes them, and
`getServiceRecordForUUID:` with `kBluetoothSDPUUID16ServiceClassAVRemoteControlTarget`
(0x110C, `BluetoothAssignedNumbers.h:645`) selects the Target record; each record is an
attribute dictionary, so SupportedFeatures 0x0311 and the profile descriptor version are
readable. — `MacOSX.sdk/.../IOBluetooth.framework/Headers/objc/IOBluetoothDevice.h:725-799`,
`IOBluetoothSDPServiceRecord.h:20`. Needs the app's Bluetooth permission (TCC) and the
Bluetooth entitlement in a sandboxed build; Audiout already requests Bluetooth for other
features.

Limit: this is the device's *claim*. A speaker that advertises category 2 and then ignores
SetAbsoluteVolume — the exact "advertises but fakes it" case — passes this check. No stack
(macOS, BlueZ, Android) detects that; they all trust the SDP record.

### 5. Behavioral tells that are real but not automatable

- Speaker-side button presses: bluetoothd registers for AVRCP volume-change notifications
  and forwards them to the driver ("Received notification for absolute volume…",
  "A2DPAudioDevice: volume update back to headphone %f" — strings, same binaries as
  finding 2). So on an absolute-volume device, pressing the speaker's own buttons moves
  `kAudioDevicePropertyVolumeScalar` and fires a property listener; a software-volume
  device has no channel for that. Documented nowhere; inferred from binary strings.
  Requires a human to press buttons, so it is a diagnostic, not a runtime check.
- Unified log: the "Setting absolute volume support to %s" line would answer the question
  per device, but `log show` returned nothing from this session (needs admin/Full Disk
  Access) and `OSLogStore` cannot read other processes' logs from a normal app. Diagnostic
  only.
- `ioreg`: searched all classes for AVRCP/absolute-volume/feature keys — nothing. bluetoothd
  does not publish per-device profile data in the I/O Registry on this macOS. (Verified
  empty on 27.0; `/Library/Preferences/com.apple.Bluetooth.plist` has a DeviceCache with
  raw SDP data elements, but it is root-readable system state with no stable contract.)
- `com.apple.BluetoothAudioAgent` defaults domain: does not exist on this machine; the old
  bitpool-tuning keys people cite are from pre-Big Sur macOS. No absolute-volume key found
  anywhere; no Apple documentation of the domain exists. **Unverified beyond this machine.**

### 6. No documented statement exists

Apple publishes nothing on macOS Bluetooth absolute volume — searched developer.apple.com
and the Core Audio / IOBluetooth headers. The discriminating state exists (finding 2) but
is private. So: no public API answers the question directly, and no Apple document says so
either way; the two indirect checks above are the available options.

## What this means for Audiout

Usable from the signed app, in order of value:

1. **SDP category-2 check** (confidence: high, as a *claim* check). Via IOBluetooth: find
   the AVRCP Target record (UUID 0x110C), require profile version ≥ 0x0104 or the 0x0002
   bit in attribute 0x0311. Matches what BlueZ/Android/Windows require. Fails only against
   devices that lie — which is the failure we already know we can't detect anywhere.
2. **n/127 read-back signature** (confidence: medium-high positive, low negative). After
   our own volume write, read `volm` back and check it is an exact n/127 (tolerance ~1e-5).
   Verified on two devices. A non-multiple read-back suggests software volume but was never
   observed against a known-software device, so don't treat it as proof.
3. **Volume-changed listener after speaker button press** (confidence: medium). Only
   meaningful inside a user-facing "press volume-up on your speaker" verification step —
   which is also the only thing that catches the advertises-but-fakes-it devices, since it
   proves the AVRCP round trip end to end.

Not usable:

- The private `kBluetoothAudioDevicePropertySoftwareVolume*` custom properties: reading the
  driver's advertised custom-property list crashed coreaudiod (all system audio dies).
  Never touch selectors outside the documented set on Bluetooth devices.
- Unified log and `ioreg`: nothing readable without admin rights / nothing there at all.
- "Property is settable": confirmed meaningless as a discriminator — settable either way.

## Sources

- `MacOSX.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AudioHardwareService.h` — 'vmvc' semantics (lines 49-74)
- `MacOSX.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/AudioHardware.h` — `kAudioDevicePropertyVolumeScalar` snapping (lines 1045-1075)
- `MacOSX.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/AudioHardwareBase.h` — transport types (lines 560-590)
- `MacOSX.sdk/System/Library/Frameworks/IOBluetooth.framework/Headers/objc/IOBluetoothDevice.h`, `IOBluetoothSDPServiceRecord.h`, `BluetoothAssignedNumbers.h` — SDP access, UUID 0x110C
- `/usr/sbin/bluetoothd`, `/System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver` — binary strings (macOS 27.0)
- `/Library/Logs/DiagnosticReports/coreaudiod-2026-09-12-222*.ips` — crashes from probing custom properties
- Live Core Audio probe, this machine, 2026-09-12 — n/127 read-backs on Sonos Move and Move 2
- [Microsoft Bluetooth accessory guidelines, Classic audio](https://learn.microsoft.com/en-us/windows-hardware/design/accessory-guidelines/bluetooth-accessory-guidelines/bluetooth-accessory-guidelines-classic-audio) — category 2 / Table 3.1 row 16 / 0-127 range requirements
- [BlueZ profiles/audio/avrcp.c](https://github.com/bluez/bluez/blob/master/profiles/audio/avrcp.c) — `AVRCP_FEATURE_CATEGORY_2 0x0002`, `avrcp_volume_supported()`
- [BlueZ patch discussion: determine absolute volume from category 2](https://www.spinics.net/lists/linux-bluetooth/msg115268.html)
- [AOSP system/bt btif_rc](https://android.googlesource.com/platform/system/bt/+/master) — Android decides from SDP feature bits (comparative background)

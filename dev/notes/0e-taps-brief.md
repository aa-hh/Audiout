# Core Audio Process Taps — Implementation Brief (macOS 14.4)

Task T-0e-1. Target: macOS 14.4.1 arm64, Swift 5.10, Xcode. This brief is the transcription
spec for the T-0e-2 capture-CLI prototype. Every API here was verified against the AudioCap
sample source and Apple's Core Audio docs (URLs cited per section). API is new in **macOS 14.2+**
(shipped/publicly usable from 14.4).

Imports for all snippets: `import AudioToolbox` (CoreAudio types + tap/aggregate functions),
`import AVFoundation` (for AVAudioFormat/AVAudioPCMBuffer/AVAudioFile if writing files).
`CATapDescription` is in AudioToolbox.

---

## 0. Key facts up front (deltas vs. plan assumptions)

- **Tap format is NOT guaranteed 48k stereo.** `kAudioTapPropertyFormat` returns an ASBD you
  must READ, not assume. It is Float32, non-interleaved, sample rate = the tapped output
  device's current rate (commonly 48000, but 44100 on some devices). **Channel count depends on
  the CATapDescription variant**: a mono init → 1 ch; a stereo/mixdown init → 2 ch; a bare
  `init(processes:...)` (no mixdown) yields a channel per tapped stream and can be >2. Always read
  the ASBD and build your AVAudioFormat from it — do not hardcode 48000/2.
- **No public permission API.** There is no public call to check/request the AudioCapture TCC
  permission. AudioCap uses a private TCC SPI (guarded by a build flag). We are NOT using private
  TCC APIs (per task). Fallback that works with public API only: the permission prompt fires
  lazily the first time `AudioHardwareCreateProcessTap` (or aggregate start) runs. Plan for a
  first-run prompt, not a pre-flight check.
- **A bare SwiftPM executable has no Info.plist**, so the usage-description string must be embedded
  into the Mach-O via a linker `-sectcreate __TEXT __info_plist` flag (§5). Otherwise the TCC
  dialog has no rationale string and permission may silently fail.

---

## 1. Global system-audio tap (all system audio)

Source: CATapDescription init list — https://developer.apple.com/documentation/coreaudio/catapdescription

Exact convenience initializers (verbatim spelling):

```swift
convenience init(stereoGlobalTapButExcludeProcesses: [AudioObjectID])
convenience init(monoGlobalTapButExcludeProcesses:   [AudioObjectID])
```

- **Capture ALL system audio, exclude nothing** → pass an empty array:
  ```swift
  let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])   // whole-system stereo
  ```
- **Exclude specific processes** → pass their Core Audio process object IDs (NOT raw pids; see §2
  for pid→objectID translation):
  ```swift
  let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcObjID])
  ```
- **Mono variant**: `monoGlobalTapButExcludeProcesses:` — one downmixed channel.
- **Mixdown behavior**: "stereo global" produces a single 2-channel stream that is the mixdown of
  all (non-excluded) processes' output. This is what we want for whole-system capture: one clean
  stereo stream, not per-app streams.

For our all-system-audio scope, `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` is the
primary path. (AudioCap itself demonstrates the per-process mixdown path in §2; the global-exclude
inits are the documented siblings.)

Set these after init (AudioCap pattern, ProcessTap.swift):
```swift
desc.uuid = UUID()                 // needed later for the aggregate sub-tap key
desc.muteBehavior = .unmuted       // see §6
```

---

## 2. Per-process tap (translate pid → object, tap specific processes)

Sources: AudioCap CoreAudioUtils.swift + README;
https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertytranslatepidtoprocessobject

pid_t → Core Audio process `AudioObjectID` via property
`kAudioHardwarePropertyTranslatePIDToProcessObject`, read on the **system object**, with the pid
passed as the qualifier:

```swift
// AudioCap CoreAudioUtils.swift (verbatim logic)
func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var pidQualifier = pid
    var objID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &pidQualifier, // qualifier = the pid
        &size, &objID)
    guard err == noErr, objID != kAudioObjectUnknown else { throw CAError.invalidPID(pid) }
    return objID
}
```

Related enumeration selectors (CoreAudioUtils.swift): `kAudioHardwarePropertyProcessObjectList`
(list all audio processes), `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
`kAudioProcessPropertyIsRunning`.

Tap specific process object(s):

```swift
// AudioCap's actual choice for single-app capture (ProcessTap.swift line 92):
let desc = CATapDescription(stereoMixdownOfProcesses: [processObjID])
// variants:
//   CATapDescription(monoMixdownOfProcesses: [ids])          // 1-ch downmix of those apps
//   CATapDescription(processes: [ids], deviceUID: uid, stream: 0)  // raw, per-stream, no mixdown
//   CATapDescription(excludingProcesses: [ids], deviceUID: uid, stream: 0)
```

Use the `...MixdownOfProcesses` inits to get a predictable 1/2-channel stream. The bare
`init(processes:deviceUID:stream:)` gives raw streams (channel count = sum of tapped streams).

---

## 3. Tap lifecycle (create → format → aggregate → IOProc → start → teardown)

Sources: AudioCap ProcessTap.swift + CoreAudioUtils.swift;
https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)

### 3a. Create the tap
```swift
func AudioHardwareCreateProcessTap(_ inDescription: CATapDescription!,
                                   _ outTapID: UnsafeMutablePointer<AudioObjectID>!) -> OSStatus
```
```swift
var tapID: AudioObjectID = kAudioObjectUnknown
let err = AudioHardwareCreateProcessTap(desc, &tapID)   // err == noErr on success
```

### 3b. Read the format (do NOT assume 48k/2ch)
`kAudioTapPropertyFormat` on the **tap object** returns an `AudioStreamBasicDescription`:
```swift
var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var asbd = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
// asbd → Float32, kAudioFormatFlagIsFloat, typically non-interleaved. mSampleRate &
// mChannelsPerFrame come from here. Build AVAudioFormat(streamDescription:) from asbd.
```

### 3c. Create the aggregate device (dictionary keys, verbatim from AudioCap)
```swift
let outputUID = try systemOutputID.readDeviceUID()   // kAudioHardwarePropertyDefaultSystemOutputDevice → kAudioDevicePropertyDeviceUID
let aggregateUID = UUID().uuidString

let description: [String: Any] = [
    kAudioAggregateDeviceNameKey:          "Tap-\(name)",
    kAudioAggregateDeviceUIDKey:           aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey:     true,     // don't publish device system-wide
    kAudioAggregateDeviceIsStackedKey:     false,
    kAudioAggregateDeviceTapAutoStartKey:  true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [ kAudioSubDeviceUIDKey: outputUID ]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: desc.uuid.uuidString    // ties tap → aggregate
        ]
    ]
]
var aggregateID: AudioObjectID = kAudioObjectUnknown
let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
```
Note: `kAudioSubTapUIDKey` MUST equal the CATapDescription's `uuid.uuidString` — this is the link
between the tap and the aggregate. Read the ASBD (3b) BEFORE creating the aggregate (AudioCap does).

### 3d. Register IOProc on the aggregate
```swift
func AudioDeviceCreateIOProcIDWithBlock(_ outIOProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>!,
    _ inDevice: AudioObjectID, _ inDispatchQueue: DispatchQueue?,
    _ inIOBlock: @escaping AudioDeviceIOBlock) -> OSStatus
```
```swift
let queue = DispatchQueue(label: "capture", qos: .userInitiated)
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
    inNow, inInputData, inInputTime, outOutputData, inOutputTime in
    // see §4
}
```

### 3e. Start
```swift
AudioDeviceStart(aggregateID, procID)
```

### 3f. Teardown — ORDER MATTERS (AudioCap invalidate(), ProcessTap.swift lines 63–86)
```swift
AudioDeviceStop(aggregateID, procID)                 // 1
AudioDeviceDestroyIOProcID(aggregateID, procID)      // 2
AudioHardwareDestroyAggregateDevice(aggregateID)     // 3
AudioHardwareDestroyProcessTap(tapID)                // 4  (tap LAST)
```
Gotcha: destroy the aggregate BEFORE the tap. Destroying the tap first can leave the aggregate
referencing a dead sub-tap. Guard each with `isValid` and log (don't throw) on non-noErr so
teardown always completes.

---

## 4. IOProc block: buffer + timestamp semantics

Source: AudioCap ProcessTapRecorder logic in ProcessTap.swift lines 227–241.

Block type `AudioDeviceIOBlock` signature:
```swift
(_ inNow: UnsafePointer<AudioTimeStamp>,
 _ inInputData: UnsafePointer<AudioBufferList>,     // <-- captured tap audio arrives here
 _ inInputTime: UnsafePointer<AudioTimeStamp>,
 _ outOutputData: UnsafeMutablePointer<AudioBufferList>,   // unused for a tap (leave alone)
 _ inOutputTime: UnsafePointer<AudioTimeStamp>) -> Void
```

- Captured samples are in **`inInputData`** (an `AudioBufferList`). For a stereo non-interleaved
  tap this is 2 buffers of Float32; interleaved → 1 buffer. Frame count = `mDataByteSize /
  (bytesPerFrame)` per the ASBD read in §3b.
- `outOutputData` is not used for a pure tap — do not write to it.
- Timestamps: `inNow` = current host time; `inInputTime` = the timestamp of the presented input
  samples (use `.mHostTime` for wall-clock ordering / sync). For our streaming use, `inInputTime`
  is the sample clock to trust.
- Wrap without copying (AudioCap):
  ```swift
  guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                   bufferListNoCopy: inInputData,   // no copy
                                   deallocator: nil) else { return }
  // consume buf synchronously inside the block; it aliases the CoreAudio buffer.
  ```
- **Realtime constraint**: this block runs on a realtime audio thread. No blocking, no locks, no
  allocation, no `os_log` in the hot path. For streaming, hand samples to a lock-free ring buffer
  and process on another thread. AudioCap writes to an AVAudioFile directly (acceptable for a demo,
  not ideal for realtime).

---

## 5. TCC / permissions (public-API path, no private SPI)

Sources: AudioCap README; AudioRecordingPermission.swift (shows the private path we are AVOIDING);
https://www.polpiella.dev/info-plist-swift-cli/

- **Usage-description key: `NSAudioCaptureUsageDescription`** (string). This key is NOT in Xcode's
  Info.plist dropdown — enter it manually. Without it, the TCC dialog has no rationale and the grant
  can fail.
- **When the prompt fires**: with public API only, it fires **lazily** the first time you actually
  create/start the tap (`AudioHardwareCreateProcessTap` / aggregate start), NOT at launch. There is
  no public pre-flight. (AudioCap's `TCCAccessPreflight`/`TCCAccessRequest` are PRIVATE TCC SPI —
  out of scope for us.)
- **Dialog text**: system "…would like to record this computer's audio." (the app name +
  your `NSAudioCaptureUsageDescription` string). Grant appears in **System Settings → Privacy &
  Security → Screen & System Audio Recording** (a bare CLI shows up under its executable / parent
  terminal identity).
- **Embedding the usage string in a SwiftPM executable** (no app bundle). Add the plist section to
  the Mach-O at link time in `Package.swift`:
  ```swift
  .executableTarget(name: "capture", linkerSettings: [
      .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/capture/Info.plist"   // path to a real plist file
      ])
  ])
  ```
  `Info.plist` contains at minimum:
  ```xml
  <plist version="1.0"><dict>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audiout captures system audio to stream it to AirPlay devices.</string>
    <key>CFBundleIdentifier</key><string>com.you.airplay-capture</string>
  </dict></plist>
  ```
  Do NOT also add Info.plist as a SwiftPM resource — SPM rejects a top-level file named Info.plist.
  This bakes the string into `__TEXT,__info_plist` so TCC reads it at runtime with no external file.
  Caveat: an unsigned/ad-hoc-signed CLI gets a per-binary TCC identity that resets when the binary
  is rebuilt/re-signed — expect to re-grant after rebuilds. For stable identity, sign with a stable
  bundle id / entitlement.
- **Reset for re-testing**:
  ```sh
  tccutil reset AudioCapture            # reset for all apps
  tccutil reset AudioCapture com.you.airplay-capture   # scoped to your bundle id
  ```

---

## 6. Mute behavior (local playback while tapping)

Source: AudioCap ProcessTap.swift line 94;
https://developer.apple.com/documentation/coreaudio/catapdescription (muteBehavior /
CATapMuteBehavior).

Property: `var muteBehavior: CATapMuteBehavior`. Enum cases (spellings used verbatim in AudioCap
Swift code): `.unmuted`, `.muted`, `.mutedWhenTapped`. Default = `.unmuted`.

- `.unmuted` — tapped audio **keeps playing on local speakers** while captured. (Use this if we
  want the user to still hear audio locally while streaming.)
- `.muted` — tapped audio is **silenced locally** (captured only).
- `.mutedWhenTapped` — silenced locally **only while a tap is actively running**; auto-unmutes if
  the tapping process dies/crashes (safety net so audio isn't left permanently muted).

For our app (per spec: local playback silenced while streaming), use **`.mutedWhenTapped`** — it
mutes local output during capture but self-heals on crash. Make it a runtime toggle:
```swift
desc.muteBehavior = silenceLocal ? .mutedWhenTapped : .unmuted
```

---

## 7. Gotchas (honor these — from AudioCap README/issues + CoreAudio norms)

- **Read the ASBD; never hardcode format.** Sample rate follows the default output device; channel
  count follows the CATapDescription variant. (§0, §3b)
- **Teardown order**: Stop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap. Tap dies
  last. (§3f)
- **`kAudioSubTapUIDKey` must match `desc.uuid.uuidString`** exactly, and you must set `desc.uuid`
  before building the aggregate dict. (§3c)
- **Realtime IOProc**: no allocation/locks/logging in the block; use a ring buffer for streaming.
  `bufferListNoCopy` aliases CoreAudio memory — consume it before returning. (§4)
- **Default-device changes / sample-rate changes**: the aggregate is pinned to the output device
  UID captured at setup. If the user switches output devices or the device changes rate, the tap
  stops delivering / format goes stale. Register a HAL listener on
  `kAudioHardwarePropertyDefaultSystemOutputDevice` (and on the tap's format), and on change:
  tear down and rebuild the tap+aggregate. Do not assume a static device.
- **HAL notifications need a run loop.** `AudioObjectAddPropertyListener` callbacks are delivered on
  the run loop of the thread that registered them (or a dispatch queue via
  `AudioObjectAddPropertyListenerBlock`). A bare CLI with no `RunLoop.current.run()` /
  `dispatchMain()` will never receive device-change notifications. Keep a run loop alive.
- **App Nap** can throttle a background/no-UI process and starve the audio thread. For a CLI, take
  an `NSProcessInfo` activity assertion:
  `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "audio capture")`.
- **Permission is lazy (public API).** First tap creation triggers the dialog; handle the
  `AudioHardwareCreateProcessTap` error path (non-noErr) as "not yet granted / denied," surface it,
  and retry after the user grants. (§5)
- **Rebuild churn resets TCC** for an unsigned CLI binary — re-grant after `swift build` if identity
  changed; use `tccutil reset AudioCapture` between test runs. (§5)

---

## Source URLs
- AudioCap sample (canonical): https://github.com/insidegui/AudioCap — files read:
  `AudioCap/ProcessTap/ProcessTap.swift`, `.../CoreAudioUtils.swift`,
  `.../AudioRecordingPermission.swift`, `README.md`
- CATapDescription: https://developer.apple.com/documentation/coreaudio/catapdescription
- AudioHardwareCreateProcessTap: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- TranslatePIDToProcessObject: https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertytranslatepidtoprocessobject
- SwiftPM CLI Info.plist embedding: https://www.polpiella.dev/info-plist-swift-cli/

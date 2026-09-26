# 01 — Verify the wired-output facts on a real Mac

Status: ready-for-human
Type: research

AGENTS.md: "when a fix rests on a claim about live system state, verify that
claim with a real command before writing the fix." Everything in ticket 02
rests on these. Record answers under `## Answer`.

## What to plug in (owner has no USB DAC, 2026-09-26)

A DAC was only ever a stand-in for "a USB-transport output". Anything below
reports `kAudioDeviceTransportTypeUSB` and answers the same questions:

- Apple's USB-C to 3.5 mm adapter, or any USB-C hub/dongle with a headphone
  socket, with wired headphones in it.
- A monitor with speakers connected over USB-C/Thunderbolt (Studio Display,
  LG UltraFine and most USB-C monitors show as USB audio, not HDMI).
- USB-C headphones, a USB conference speaker, or a webcam with a speaker.

If none is to hand, do the jack and HDMI questions now and leave question 3
open; ticket 02's filter is a pure unit-tested table, so the USB arm can land
on the transport constant alone and be confirmed the first time such a device
turns up.

## Run, with headphones in the jack and a display with speakers attached

```bash
system_profiler SPAudioDataType
```

and a throwaway enumerator dump (the `core-audio-diagnostic` executable or a
10-line swift script over `kAudioHardwarePropertyDevices`) printing, per
device: name, UID, `kAudioDevicePropertyTransportType`, output stream count,
`kAudioDevicePropertyDataSource` values, `kAudioDevicePropertyLatency` +
`kAudioDevicePropertySafetyOffset` + `kAudioStreamPropertyLatency` on the
output scope, nominal sample rate, settable volume yes/no.

## Questions

1. Apple Silicon: is "External Headphones" a SEPARATE device from "MacBook Pro
   Speakers" while plugged in, and do both keep output streams? Can both play
   at once from two AVAudioEngines pinned by `setDeviceID`?
2. Intel (if one is reachable, or from the VM notes): single device with a
   data-source flip? Then speakers + jack together is impossible there and the
   row model must show ONE row whose name follows the data source.
3. USB output (any stand-in above): transport constant, UID stability across
   replug, reported latency in ms, settable HAL volume?
4. HDMI/DisplayPort: transport constant, reported latency (expected ~0, the
   TV's real delay is invisible), settable volume (expected no).
5. With the DAC as the system default, select one AirPlay speaker + "This Mac"
   in the shipping build: does the Mac's copy come out of the DAC or the
   built-in speakers? (Feeds ticket 06.)

## Answer

(pending)

# 01 — Verify the wired-output facts on a real Mac

Status: ready-for-human (partial: Q1, Q3, Q4 answered)
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

Partial, 2026-09-26, owner's MacBook Pro (Apple Silicon), headphones in the
jack, no display, USB device or DAC attached. Dump from
`swift .scratch/local-wired-outputs/hal-dump.swift`.

1. **Yes, separate devices.** "External Headphones" (UID
   `BuiltInHeadphoneOutputDevice`, transport `'bltn'`, 1 output stream,
   reported 4.8 ms) sits beside "MacBook Pro Speakers" (UID
   `BuiltInSpeakerDevice`, `'bltn'`, 1 stream, 7.8 ms). Each has one data
   source named after itself, so there is no flip on this machine. Both
   settable HAL volume on the main element. Two `AVAudioEngine`s pinned to the
   two device ids ran together for 2 s with a silent source: 178 and 172
   render passes. Proven by render passes, not by ear.
2. Open. No Intel Mac reached. Ticket 02 keeps the data-source-name fallback.
3. **USB: `'usb '`.** Stand-in: a Pioneer XDJ-1000MK2 on a USB hub. UID
   `AppleUSBAudioEngine:Pioneer DJ Corporation:XDJ-1000MK2:1141000:1`,
   reported 2.1 ms, 48 kHz, no settable HAL volume (software gain only).
   UID stable across an unplug/replug.
4. **HDMI: `'hdmi'`**, even through a USB-C to HDMI adapter (the adapter does
   not turn it into USB). LG TV, UID `1E6D0100-0000-0000-011C-010380A05A78`,
   reported 8.5 ms (the TV's own processing delay is invisible, as expected),
   48 kHz, no settable HAL volume.
5. Open. Needs an audible run with the shipping build; headphones as the
   default reproduce it, so no DAC is needed.

Found along the way, for ticket 02: the default output during this run was
"Audiout BT Wake" (`com.audiout.Audiout.btwake.aggregate`), and a second
aggregate `com.audiout.Audiout.shots.aggregate` also existed. Both are
transport `'grup'` wrapping the built-in speakers. So "drop the default's UID,
resolved through our aggregate" must resolve through ANY aggregate that is the
default (read its sub-device list), not only the one UID this bundle owns; the
`'grup'` transport filter already keeps all of them out of the row list.

AudioObjectIDs are not stable: the same devices moved (speakers 72 -> 75,
headphones 108 -> 124) between two dumps an hour apart after hotplugs. Key
rows by UID only, and re-resolve the id from the UID before every pin. After the XDJ replug its
id went 136 -> 124, the number the headphones held an hour earlier: ids are
reused across different devices, so a cached id can pin the WRONG device.

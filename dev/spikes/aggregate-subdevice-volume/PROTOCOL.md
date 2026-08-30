# aggregate-subdevice-volume — live test protocol

The question `volprobe.swift` settles: once an Audiout aggregate is the
system default output and is actually feeding it, does the Mac's own
built-in speaker still respond to its hardware volume knob, or has the
aggregate made that knob a dead letter?

For one MacBook Pro M1, Touch Bar, no physical volume keys, plus AirPlay
speakers.

## Steps

1. `bash scripts/purge-stale-ptp-helpers.sh` (dry run, no sudo). If it lists
   anything, run it again with `--apply` and enter the sudo password at the
   prompt. See `AGENTS.md:126-135`.

2. `swiftc dev/spikes/aggregate-subdevice-volume/volprobe.swift -o dev/spikes/aggregate-subdevice-volume/volprobe`

3. Fresh-identity build:

   ```
   APP_NAME="Audiout VolProbe v1" BUNDLE_ID="com.audiout.Audiout.volprobev1" bash scripts/make-app.sh
   ```

   Then open `build/Audiout VolProbe v1.app`. A bare `make-app.sh` would
   overwrite the live `/Applications` copy — do not use it here.

4. Grant the prompts, start music, select one AirPlay speaker so whole-system
   routing arms.

5. Confirm the default output is this build's aggregate. It appears in Sound
   settings as "Audiout VolProbe v1", not "Audiout" — the display name is
   derived from the bundle (`AggregateOutputDevice.swift:118-124`, written by
   `scripts/make-app.sh:628`). The authority is the probe's printed UID
   (`com.audiout.Audiout.volprobev1.aggregate`), not the visible name.
   `system_profiler SPAudioDataType | grep -B3 "Default Output Device: Yes"`
   cross-checks it. If the probe lists a second Audiout-shaped aggregate,
   that is the old spike leftover (`com.audiout.spike.aggregate`) and is not
   the one under test.

6. Run `./dev/spikes/aggregate-subdevice-volume/volprobe`, listen while it
   waits, press Return.

7. Report the probe's printed lines plus which sentence was true.

## The two sentences, verbatim

Knob still applies:
> "The music coming out of the Mac's own speakers got clearly louder or
> quieter the moment the probe changed the number, and went back when it
> restored it."

Knob does not apply:
> "The music coming out of the Mac's own speakers stayed at exactly the same
> loudness the whole time, even though the probe reported that it wrote the
> new number and read it back."

## Interrupt note

Ctrl-C or closing the terminal before pressing Return leaves the built-in
speakers at the probe's value. Put it back with the exact line the probe
printed: `./dev/spikes/aggregate-subdevice-volume/volprobe <target-UID> <original-scalar>`.

## Closing note

The AirPlay speakers' loudness is irrelevant — only the Mac's own speakers
matter.

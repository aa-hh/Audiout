# Glossary

Canonical vocabulary for Audiout. Code, docs, and UI copy use these terms; when a
term here conflicts with a term in the wild, this file wins or gets amended — never
both meanings at once.

- **Hardware volume**: a Bluetooth speaker's own volume level, the one its physical
  buttons move. Reached from macOS through Core Audio's virtual-main-volume property;
  on speakers that support Bluetooth absolute volume this moves the real knob, on
  others macOS applies it digitally in the driver (the two are indistinguishable
  from the API).
- **Software gain**: attenuation Audiout applies to the samples before they leave the
  Mac. Cheap, instant, stepless; never touches the device.
- **Hardware-controlled speaker**: a Bluetooth speaker whose per-device slider writes
  hardware volume instead of software gain. Per-device opt-out toggle, on by default
  where the volume property is settable. Main and Group levels stay software gain on
  such a speaker; mute stays software gain 0.
- **Registered**: an install holding a licence key the licence server honours. A
  live trial key counts. Source builds with no licence server are neither
  registered nor unregistered; the words do not apply to them.
- **Unregistered**: an install with a licence server and no key the server honours:
  a trial that has ended, a key refunded or revoked, or no key at all. Since
  2026-09-26 an unregistered install keeps running with every feature but plays on
  one speaker at a time; before that date it met a blocking key window at launch.
  A trial that started offline and has not yet reached the server is not
  unregistered.
- **Trial**: the 14 clean days a new install gets before it is unregistered. Ends
  by the calendar, never by use. One per Mac.
- **Selected Speakers**: the set of destinations the mixer's Main Out plays to when
  it targets them. This Mac's own output is a member like any other. Membership is
  not the same as receiving audio: routing is decided by Main Out.
- **Note**: the popover's single message slot below the mixer. One note at a time,
  by precedence: a failure happening now outranks a standing condition. A note
  carries at most one button and, since 2026-09-26, may carry one underlined text
  action to its left; both stay vertically centred when the text wraps.

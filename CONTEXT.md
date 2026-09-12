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

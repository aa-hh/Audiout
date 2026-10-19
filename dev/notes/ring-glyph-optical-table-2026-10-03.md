# Speaker-row glyphs: optical size and centring table (2026-10-03)

Size: each glyph is sized so its visual weight, (√ink area)^0.25 × (√ink bounding-box area)^0.75, matches `hifispeaker.fill` at 18 pt. Area alone inflated outline and two-tone glyphs; the box alone ignored how solid a glyph is (the Bluetooth complaint).
Centre: the glyph moves so the point halfway between its ink box centre and its ink centre of mass sits on the ring centre. Offsets are in pt, rounded to 0.25, applied after centring the image in the icon box as today; + x = right, + y = up.
Limits: it then shrinks in 0.25 pt steps until it is at least 2.0 pt clear of the ring's inner edge (30 pt ring, 2.4 pt stroke; Main Audio's 34 pt ring) and fits the 26 pt icon box unshrunk. Cast keeps box centring because the full shift cost it 1.75 pt. Render: `ring-fixes-v2-2026-10-03.png`.

| Symbol | Used for | Point size | x offset (pt, + = right) | y offset (pt, + = up) | Clearance to ring inner edge (pt) | Review size |
|---|---|---|---|---|---|---|
| `hifispeaker.fill` | AirPlay speaker, Sonos (reference); icon picker | 18 | 0 | 0 | 3.1 | 18 |
| `homepod.fill` | HomePod; icon picker | 19 | 0 | 0 | 3.5 | 17.5 |
| `appletv.fill` | Apple TV; icon picker | 16 | 0 | 0 | 3.7 | 16.5 |
| `wifi.router.fill` | AirPort Express; icon picker | 14.75 | +0.25 | +1.25 | 2.5 | 15 |
| `laptopcomputer` | This Mac; icon picker | 14.25 | 0 | +0.25 | 2.1 | 15.5 |
| `tv.and.hifispeaker.fill` | Cast | 14.25 | 0 | -0.5 | 2.2 | 15 |
| `radio.fill` | Bluetooth, unknown product; icon picker | 14 | 0 | +0.75 | 3.7 | 14.5 |
| `headphones` | Bluetooth headset; icon picker | 17.5 | 0 | +0.5 | 3.4 | 16 |
| `car.fill` | Bluetooth car | 16.25 | 0 | +0.25 | 2.2 | 15.5 |
| `airpods` | AirPods; icon picker | 17.75 | 0 | -1 | 3.5 | 16.5 |
| `airpodspro` | AirPods Pro; icon picker | 17.25 | +0.25 | 0 | 2.7 | 15 |
| `airpodsmax` | AirPods Max | 17.25 | 0 | +0.5 | 3.7 | 15.5 |
| `airpods.gen3` | AirPods 3 | 16.75 | 0 | -0.5 | 3.7 | 15.5 |
| `airpods.gen4` | AirPods 4 | 17 | 0 | -0.5 | 3.4 | 16 |
| `beats.powerbeatspro` | Powerbeats Pro | 15 | 0 | 0 | 2.1 | 14.5 |
| `beats.earphones` | Powerbeats, Beats Flex, BeatsX | 16.5 | 0 | -1.25 | 3.2 | 15 |
| `beats.fit.pro` | Beats Fit Pro | 14.25 | 0 | +0.25 | 2.1 | 14.5 |
| `beats.studiobud.right` | Beats Studio Buds | 20.75 | +0.75 | +0.5 | 4.4 | 18 |
| `beats.headphones` | Beats Studio, Beats Solo | 18.25 | 0 | +0.25 | 2.8 | 16 |
| `hifispeaker.arrow.forward.fill` | Main Audio (34 pt ring) | 16.75 | +0.5 | 0 | 5.7 | 17 |
| `hifispeaker.2.fill` | Icon picker | 14.5 | 0 | -0.5 | 2.4 | 14 |
| `homepod.2.fill` | Icon picker | 15 | 0 | -0.5 | 3.0 | 13.5 |
| `tv.fill` | Icon picker | 14.25 | 0 | -0.25 | 3.4 | 14.5 |
| `speaker.wave.2.fill` | Icon picker | 17.5 | +0.75 | 0 | 3.8 | 18 |
| `speaker.wave.3.fill` | Icon picker | 15.5 | +0.5 | +0.25 | 2.6 | 14.2 |
| `music.note` | Icon picker | 21.25 | 0 | 0 | 2.1 | 18 |
| `music.note.house.fill` | Icon picker | 15 | 0 | +0.5 | 4.2 | 14.5 |
| `house.fill` | Icon picker | 15.25 | 0 | +0.5 | 4.2 | 14.5 |
| `bed.double.fill` | Icon picker | 15.75 | 0 | 0 | 2.0 | 16 |
| `sofa.fill` | Icon picker | 14 | 0 | -0.25 | 2.7 | 14 |
| `fork.knife` | Icon picker | 19.25 | -0.25 | -0.25 | 2.0 | 18 |
| `desktopcomputer` | Icon picker | 15.5 | 0 | 0 | 2.1 | 15 |
| `guitars.fill` | Icon picker | 14.5 | -0.25 | +1 | 2.4 | 14 |
| `gamecontroller.fill` | Icon picker | 14.5 | 0 | 0 | 2.1 | 14.5 |

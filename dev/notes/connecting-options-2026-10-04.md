# Connecting on the Mixer rail: seven directions (2026-10-04)

Image: `connecting-options.png` (2x). Renderer: `main.swift` in this folder (`swiftc -O main.swift -o render && ./render connecting-options.png`).

Each strip shows three rows: Kitchen playing, TV connecting, Den connected and not playing. The line is always gold. In options 1 to 7 the connecting glyph ring and its dot are drawn dashed in `rim` grey instead of `ember`. That takes ember out of the connecting state entirely. Gold stays on the rail and grey stays on the row, which is the same split a connected row already shows.

## Contrast on the popover ground (measured with the real tokens)

| Ink | Light (#FAFAFB) | Dark (#15171A) |
|---|---|---|
| `gold` | 1.77:1 (1.65 on the playing row's wash) | 9.74:1 |
| `glow` | 1.77:1 (it is the same hex as gold in light) | 13.22:1 |
| `rim` | 4.78:1 | 3.86:1 |
| `ember` (today) | 5.82:1 | 3.58:1 |
| system spinner (`secondaryLabelColor`) | 3.92:1 | 6.09:1 |

In light, every gold-only mark sits at 1.77:1. Making the stroke more visible doesn't fix that. What works is putting the state in a shape that still reads at low contrast: a break, an opening, a fill. The filled member disc is also 1.77:1 and already reads, because it is a filled area rather than a 1.6 pt line.

## Options

| # | What it is | What it tells the user | Light / dark | Reduce Motion | With the gold line and the connect pulse | Cost | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | A `glow` bead runs DOWN the line into the connecting node every 1.6 s | "Audio is on its way to this speaker" | Light: the bead is only a thicker gold stroke, since `glow` = `gold` (1.77:1). Dark: clear (13.2:1) | Needs a static form, so it falls back to option 4 | The bead goes down while connecting, then the existing pulse runs back up on connect. But AGENTS.md says connecting "never" shows in the segment feeding the node, so this overturns that rule. `runConnectPulse` also lets only one bead run at a time (`guard pulseLayer == nil`), so a looping bead would block the real pulse unless it gets its own layer | M | No. Weak in light, breaks a standing rule, and puts motion on the whole wire |
| 2 | The node becomes a solid gold 270° arc over a faint track, turning once a second | "Working on it" (progress) | A solid arc reads better than 2.6 pt dashes, and the opening reads by shape. Still 1.77:1 in light | The arc stops with its opening toward the incoming line, which still says "not closed" | The arc closes and fills on connect, then the existing pulse departs from the now-filled node. The line is untouched | M. `MembershipBusView` draws in `draw(_:)` with no layer; it needs a `CAShapeLayer` plus the same Reduce Motion handling `HaloRingView.reconcileBreathing` has | Good |
| 3 | The line stops 9 pt short of the connecting node above and below (3 pt today); the node is a plain gold circle | "Not joined to the line yet" | Reads by shape, so contrast doesn't matter | Already static | The line keeps its colour and only its length changes, which fits the ruling's wording. On connect the break closes and the pulse departs | S. One branch on `.connecting` for the gap in the `wireRuns` stop loop, plus the node stroke | Strong. Cheapest legible option |
| 4 | Hollow gold circle with a 6 pt gold disc at its centre | "Partly there" | The disc is a fill, so it reads like the member disc | Already static | No conflict | S | No. It looks exactly like a selected macOS radio button, which says "chosen", not "connecting" |
| 5 | The rail node is a plain gold circle; the glyph ring keeps today's dashed breathing, in `rim` grey | "The row is busy; the rail just marks the slot" | Ring 4.78 / 3.86:1, good. In light the rail node differs from a member only by being unfilled | Static dashed ring, as today | No conflict | S. A colour token swap in `HaloRingView` plus the node stroke | Viable minimal change, but the rail itself says little |
| 6 | A mini system spinner (`NSProgressIndicator`, spinning style) inside the node | "Connecting", in the system's own words | 3.92 / 6.09:1, best of all | From memory, the system spinner keeps turning under Reduce Motion; we can't change that | A grey object on a gold line, outside the gold system the owner asked for | S. A subview in `MembershipBusView` | Most legible, least on-brand. Keep it as the fallback if gold fails in testing |
| 7 | Option 3's break plus option 2's turning arc | "Not joined yet" (shape) and "working on it" (motion) | The break carries it in light; the arc adds motion | The break plus a still arc opening toward the line | As 2 and 3: the arc closes, the break closes, the pulse runs up | M | Recommended |

### Platform convention (from memory of macOS 14 to 26, not checked)

- Control Centre, Sound module: picking an AirPlay output shows a small spinner where the checkmark goes until it connects.
- Bluetooth module and menu: I believe the device's round icon shows activity while connecting; I can't recall the exact form.
- System Settings › Sound: I don't recall any connecting indicator in the output list.

The common thread is a grey spinner at the selection mark, which is option 6.

### Considered and not drawn

- **Gold at reduced opacity with a `panel`-coloured halo.** The halo is the same colour as the ground, so it adds no contrast against it. It only helps where the node overlaps the line.
- **Thicker dashes.** This breaks the 2026-10-03 ruling that weight never carries state (`ringStrokeWidth` everywhere).
- **Round dots instead of dashes** (2.2 pt dots). Still 1.77:1. Marginally better than dashes, with the same weakness.
- **Dashes marching along the segment into the node.** Same rule conflict as option 1. Not rendered.

## Recommendation

Option 7. The break in the line says "not joined yet" through shape alone, so it survives light mode's 1.77:1 gold and Reduce Motion with no extra work. The turning arc adds the "working on it" motion in gold, and it resolves into the existing connect pulse with no special-case code.

If cost matters more, ship option 3 alone (size S) and add the arc later.

Either way, the connecting glyph ring changes from dashed `ember` to dashed `rim`. That retires ember from the connecting state. It needs the DESIGN.md "Connection Ring and Status Dot" paragraph and the AGENTS.md "rail line is one colour" rule reworded: the line's length changes for a connecting node, but its colour never does.

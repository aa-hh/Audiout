# F → F2: delight pass

Owner's notes on F (2026-10-07): the system checkboxes do not fit the design language, and the tab is missing colour. Topology, copy and the no-status ruling are F's, unchanged.

## 1. The membership control

- The stock checkbox is replaced by the node the app already draws for "this speaker is in": `MembershipRowView` in its `.editor` form, whose `MembershipBusView` node sits over the real `NSButton` wearing `InvisibleSwitchCell`. The only change to the row is that no `BusRailOverlayView` is mounted, so the node stands alone with no line and no detour arc. The control the row becomes is therefore an existing one, drawn without its rail. VoiceOver, keyboard and target/action are the stock button's.
- States, all from the node's own vocabulary: in the scene = the filled 15 pt `gold` disc, with its 1 pt `ember` edge in light (gold on paper is 1.77:1); not in the scene = the hollow 11 pt ring in `railDormant`; in the scene but unreachable = the dimmed member node (`socket` fill, 3 pt `gold` rim, `emphasizesDimmedMemberRim`), with the row's own "Unavailable" at the trailing edge. Gold here is selection, one of gold's four jobs in DESIGN.md; nothing on the tab reads it as audio because nothing else on the tab is gold.
- The whole row is the hit target, as the editor's rows are today. Hover grows the node by `busNodeHoverGrowDuration` (0.12 s), the existing behaviour. The toggle: the ring fills from its centre to the disc, and the disc drains back to the ring, over `Tokens.Motion.collapseRevealDuration` (0.15 s) on the fold clock, the one clock the app's reveals run on. Reduce Motion lands the end state at once.

## 2. Where colour went

- **Identity, magenta.** `GroupIdentityGlowView` now sits behind every scene glyph in the sidebar, mounted small the way the Main Audio row mounts it behind a 26 pt icon, and behind the header well at its 60 pt size as before. Every scene glows the same magenta: DESIGN.md's rule is that magenta is group identity, never state, and one hue for all groups.
- **Selection, gold.** The membership node above; and on the empty page, "Add scene…" is the gold `ProminentButton`, because a call to action is gold's job and the empty page has exactly one. F had dropped it as "no call to action on a configuration tab"; that reading confused activation with action.
- **Warm inks.** The "Speakers" title and the saved-as-you-go note are `label2`, the sidebar title and captions `labelCool`, as the Speakers tab sets them. The scene name on the page is `label`.
- **No per-scene colour.** DESIGN.md fences the only per-item identity palette (the six permission hues) to the Setup spine and says a new surface wanting one "asks for its own decision, it does not borrow". The magenta glow already answers "this is a group"; a second colour per scene would be a new identity system with nothing to measure it against. Not taken.
- The hover wash and the sidebar selection pill stay neutral: a wash is never gold.

## 3. The one touch

When a member is toggled, the count ticks in two places at once: the page caption ("3 speakers" → "4 speakers") and the selected sidebar row's caption, each digit rolling over the fold clock's 0.15 s with the node's fill. The save is already instant; the tick is what makes it feel certain, because the list you came from visibly already knows. Second-visit material: nobody notices it the first time, and it never gets in the way. Reduce Motion swaps the number with no roll. Nothing else celebrates.

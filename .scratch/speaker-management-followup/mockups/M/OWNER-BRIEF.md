# Direction M: owner brief (Alec, 2026-10-04, verbatim then facts)

## Owner's words
"Okay, so for the speakers tab system audio is fine I think the speakers design though needs to be at the top because it doesn't fit where it is right now. System audio needs to be its own thing. Like, that is the main out, right? So, that needs to be kind of the thing that people can go and control clearly and they see what it is, right? So, that should maybe I mean almost have its own title and be highlighted in the same way that speakers is. And then you have a second section that is external speakers and then that has the speakers button that you currently have.

Then the two sections below speakers should be seen as like subsections related directly to the external speakers category that you've just created. This section should be called shown in the mixer because below it's hidden less playing or always shown in mixer kind of thing. Yeah. use a copy agent to figure out the best way, but it should be essentially stating this is shown in the mixer and then hidden unless playing or is another section. Aside from that, I think the sidebars is fine although I would actually go with a less depressing brown for the dots. Maybe we use the connected Design language, so the color for connected, the rim color, we apply that there. Yeah, so the dot becomes the connected status dot beside list items. unconnected is just the rim of the dot (can be thicker stroke than normal if necessary for accessibility.

Alright, then for the speakers overview The current one that I have does not add up. It says eight found, eight away, which I guess is my total of speakers, and then it's not clear what is a way, and then, like, I wouldn't, yeah, I think that like it looks really good like this. But maybe we should have a overview of the airplay ones you have connected the bluetooth ones you have connected the cast ones you have connected the black the mac well the mac would always be connected and then another one another row essentially for away or undiscoverable devices,

I don't think we need a done-looking status, it takes up space. I would actually just have maybe rather shimmers on the numbers when you're looking to find how many they are, and have them load in individually as you find out exactly how many there is of each one in each category (available, away)"

## Where things stand (shipped on PR #271, branch claude/speakers-nav, HEAD 95f5fa60)
Worktree: /Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/speakers-nav (read-only for design agents; a few uncommitted code edits are there, do not touch them).
- Surface: fixed 653 pt wide window; header strip tabs Mixer · Scenes · Speakers · Settings. The Speakers tab = sidebar (210 pt) + content pane.
- Sidebar today (AudioutCore/Sources/AudioutWindowUI/SidebarViewController.swift): roots in order: header "System Audio" -> "Main Audio" row; the "Speakers" plate (a highlighted rounded row with chevron, PlateRowView, opens the Speakers overview page); header "In the Mixer" -> speaker rows; header "Hidden unless playing" (folds) -> speaker rows; bottom bar "+ Add scene". Each speaker row: presence dot (SidebarPresenceDotView: found = filled Tokens.Color.ember, away = 1.5 pt ember ring, playing = gold fill + 1 pt ember ring, lost = exclamationmark.triangle in Tokens.Color.failure), device icon, name. A hidden speaker that is playing gets the caption "In the Mixer while it plays".
- Main Audio page: MainOutDetailViewController (the system output / "main out").
- Speakers overview page (AudioutCore/Sources/AudioutWindowUI/SpeakersPageViewController.swift): header icon well + "Speakers" + a caption that is the search result ("Looking… · N found so far" / green check "All N speakers found" / "Done looking · ● F found · ○ A away"); one card: counts by kind (AirPlay, Bluetooth, Cast, This Mac, Unknown; counts include away and lost speakers), then one-line rows only when true (Bluetooth access off; N can't be found + Forget; Pair Bluetooth speaker… always). The owner says the numbers don't add up ("8 found, 8 away") and "away" is unclear: found/away exclude This Mac and lost speakers, while the kind counts include everything.
- Search "done" = DiscoverySettleTracker settle (0.5 s quiet, 10 s ceiling). Analytics speaker:library_counted fires once per launch then (keep it).
- Previous mockups and briefs: ../K, ../K2, ../L (L = the current page), ../PRIOR-ART.md, ../PRIOR-ART-EQ.md, ../CRITIQUE.md.
- Design system: DESIGN.md at the worktree root, AudioutCore/Sources/AudioutSharedUI/Tokens.swift. Warm Signal. Gold only for audio. The Equalizer green token is fenced to the Mixer row. The Mixer rows' connection language: find what colour/rim the Mixer uses for a CONNECTED speaker (DeviceRowView, HaloRing*, MembershipBusView node, Tokens connected/rail/ring colours) — the owner wants the sidebar dots to use that.
- Standing rulings: no page re-lists the sidebar's speakers; no "Hide speakers not in any scene"; problem rows only when true; plain words, no invented terms; stock AppKit + SF Symbols, Warm Signal colours.

## Open reading the shape agents must settle and flag
"the dot becomes the connected status dot": (a) filled = connected to Audiout right now (streaming), rim = not; or (b) filled = reachable/available on the network, rim = away. Today's dots mean (b) plus a separate playing state. Recommend one, show both in the mockup if cheap, flag for the owner.

## Output location
All design outputs go under this folder (M/). Mockups are self-contained HTML (light + dark via data-theme on <html>), rendered to PNG with headless Chrome:
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --force-device-scale-factor=2 --window-size=1400,1000 --screenshot=<png> file://<html>
Dark: write a copy injecting <script>document.documentElement.setAttribute("data-theme","dark");</script> before </body>.
The Write tool may refuse this path; write through Bash with a quoted heredoc.

## Owner ruling (later, same day)
"filled means reachable on the network. Maybe on this screen you don't have to show them in red, so they're either just connected or not."
So the sidebar dot has two states only: filled (connected colour) = reachable on the network; rim only = not reachable (away or never found). No red warning glyph in the sidebar.

## Owner rulings after the critique (2026-10-04)
- Overview: Unavailable stays the FIFTH count in the strip (critique recommended its own row; owner chose the fifth count).
- Sidebar reachability mark: neither the ring nor "no dot". The Mixer already uses a hollow grey ring (Tokens.Color.rim, 1.5 pt) for "connected, silent" and gold for playing (RouteArmedDotView.swift:181-186, HaloRingView.swift:243-249), so the sidebar must not reuse the ring for "not reachable". Owner asked for a discovery: prior art, a sheet of shapes/colours, and two divergent directions that break away from the dot pattern. Filled = reachable on the network (ruling stands); no red in the sidebar (ruling stands).

## Owner ruling on the reachability mark (2026-10-04)
Chosen: direction C (`dot-discovery/direction-c/BRIEF.md`): no mark on any row; inside each visibility group reachable speakers first, then a quiet divider row (`antenna.radiowaves.left.and.right.slash` + "N unavailable" + rule) and the unreachable speakers in the Mixer's cool dim ink (labelCool / labelCool2). Overview's fifth count "Unavailable" uses the same glyph and equals the sum of the dividers. Rejected: disc+dash, disc+slashed-signal, icon-on-square (B).
Open owner calls carried from the harden/clarify passes (use their defaults, list them for the owner): 10 s wait before Forget appears; middle-truncated sidebar names; "Hidden unless in use" vs the owner's "Hidden unless playing"; no state line on Main Audio.

## Owner rulings (2026-10-04, late)
- Speaker and Main Audio pages: cool greys (go cool).
- GREEN is the Speakers tab's accent, the way gold is the Mixer's primary. Owner asked where else green could go; a colorize pass decides (watch the clash: Tokens.Color.equalizer green = equalizer engaged in the Mixer row and on the speaker page's EQ summary mark).
- iPhone hides what the Mac's Mixer hides, with a count line: YES (build after #271: audiout-shared field, Mac, iPhone).
- New event speaker:privacy_settings_opened (access: local_network) for the Local Network row's button: YES (audiout-shared row first).
- iPhone: LONG PRESS on a Mixer-page speaker row opens the speaker's options, just like right-click on the Mac (Hide from Mixer / Show in Mixer / Show even when unavailable, etc.). Replaces the adapt pass's "leave out Hide/Show"; needs a protocol command and a way to show hidden speakers again (the "N hidden" line becomes tappable).

## Owner rulings on the green pass (2026-10-04, night)
"the design decisions for the amount of green were a little bit heavy-handed. I don't like the speaker tab highlight in the header. I liked actually having the green equalizer lines when it's been selected."
- NO green tab highlight in the header strip (and so no gold on the Mixer tab either): the header stays neutral as today.
- KEEP the green equalizer engaged mark on the speaker page (do not remove it; equalizerEngagedMarkImage stays public).
- The other three touches (Available counts, Pair + glyph, Ready/Connected word) are undecided: owner wants one mock-up of the whole setup as it would ship, then he'll say which to keep. Draw all three, each labelled.
- Ruled after FINAL-GREEN-2 (2026-10-04): all three touches KEPT.

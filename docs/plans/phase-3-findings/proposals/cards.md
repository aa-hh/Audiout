# Redesigning the Devices card and the Applications card

In the popover, the **Devices** card and the **Applications** card sit
stacked one directly under the other, styled the exact same way — same
rows, same sliders, same kind of dropdown/checkbox on the right. But they
control two genuinely different things. Checking a box in Devices changes
which speakers get the Mac's overall audio — "what plays everywhere."
The picker in Applications does something else entirely: it grabs the
audio from one specific app and sends it to a device of its own choosing,
*regardless* of what's checked in Devices. Nothing on screen tells you
these two controls don't talk to each other. You can check a speaker in
Devices, then separately pick a different speaker for one app in
Applications, and the app has no way of knowing that was intentional —
it just looks like two unrelated things happened to the same list.

## Why this is genuinely hard

Both of these are real, needed features, and that's the actual tension —
this isn't a bug to fix, it's two legitimately different jobs sharing one
screen. "Devices" answers "what should everything play out of, by
default." "Applications" answers a completely different question: "make
an exception for just this one app." You need both: a main set of
speakers for everything, but also the ability to say "except my music
app, which should quietly go to the office speaker while calls stay on
the main speakers." Merging the two into one control would remove the
exception feature entirely. Splitting them onto separate screens would
lose the "everything at a glance" convenience that makes a popover useful
in the first place. Any real fix has to keep both jobs doable while
making it obvious, at a glance, that they *are* two different jobs.

## Option A — Make the split unmistakable, in place

Keep both cards exactly where they are, but redesign how the second one
presents itself so your eye can't read it as a continuation of the
first. Rename "Applications" to something more self-explanatory, like
"Send an app somewhere else," add a one-line explainer underneath it
("Independent of the speakers selected above"), and give the card a
visibly different look — a different tint, or a small "override" badge —
so it registers as a different kind of control, not a third row of the
same list.

**Upside:**
- The smallest possible change — nothing moves, no new screens.
- Both features stay exactly as easy to find as they are today.
- Cheap to try, and easy to walk back if it doesn't help.

**Downside:**
- It labels the split better but doesn't explain *why* a speaker is
  doing something you didn't ask it to — it separates the two cards
  without connecting them.
- Depends on the user actually reading a new label; if they skim past it
  (which is exactly what happened in testing), it may not register.

## Option B — Show the relationship, not just the label

Instead of relying on better separation, show the connection right where
it happens. When an app is being redirected to a device, put a small tag
directly on that device's row in the Devices card — e.g., next to
"Office" you'd see a small "+ Music" note — so it's immediately visible
that a speaker you didn't check in Devices is nonetheless playing
something, and why.

**Upside:**
- Answers the actual question you ran into — "why is this speaker
  playing something I didn't select" — right on the screen where it
  happens, instead of expecting you to remember a rule.
- Makes the two cards feel like one coherent, honest picture of what's
  actually playing where, without pretending they're the same
  mechanism.

**Downside:**
- Adds more information to rows that are already fairly busy — needs a
  careful, restrained treatment or it turns into clutter.
- More work to build, since the tag has to stay live and update the
  instant a route changes.

## Option C — Don't show it by default; make it a deliberate step

Most people will never redirect a single app to a different speaker —
it's a power feature. Rather than permanently stacking "Applications"
right under "Devices" as if it's equally central, move it behind a
clearly-labeled action you choose to open — "Send an app to a different
speaker…" — instead of it always taking up room in the main view.

**Upside:**
- The common case — most people, most of the time — sees a simpler
  popover with just the speakers they actually use.
- Removes the "these look like the same list" confusion by removing the
  adjacency altogether, not just re-styling it.

**Downside:**
- Anyone actively using an app redirect (like the "Music → Office"
  example from your own walkthrough) loses at-a-glance visibility into
  something they rely on regularly.
- Adds an extra click for a feature that, for the people who use it,
  tends to get used often.

## Recommendation

**Option B.** The confusion you actually hit wasn't "I didn't realize
these were two sections" — it was "I can't tell why a speaker is doing
something I didn't ask it to do," and only Option B puts that answer on
the screen at the moment it matters, instead of just labeling the
problem more clearly or hiding it.

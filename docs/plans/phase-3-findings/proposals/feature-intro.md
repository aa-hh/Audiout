# Feature Introduction — Design Proposal

## The gap

Today, onboarding (`AudiouterOnboardingUI`) exists to secure three OS
permissions — System Audio, Local Network, Remote Control — and nothing
else. Its one screen is a header, a paragraph reassuring the user about the
audio-recording prompt, a card of three permission rows, and a Done button.
Once the user clicks Done, they land straight in the popover
(`PopoverController`) with no introduction to what they're looking at: a
"System" card with a Main Out volume/device row, a "Selected Devices" list
of discovered speakers, and an "Applications" card for per-app routing —
plus a small header icon that opens the separate Groups/Mixer window, which
is the *only* place groups can be created. Nothing in the app has ever told
a first-time user that groups exist, that they can send one app to one
speaker while everything else stays local, or what any popover section is
for. This is the root cause behind two narrower findings already being
fixed as symptoms — G1-N4 (no discoverable "create a group" affordance) and
G1-N5 (onboarding copy needs a pass) — but fixing those two doesn't answer
the structural question: the app has never had a mechanism for teaching its
own capabilities at all. This document lays out three ways to build one.

## Option A — Extend onboarding with a brief feature-tour step

Add one more screen to the existing onboarding flow, after the permission
card and before Done: a short, visual walk-through of what Audiouter
actually does — "send audio to more than one speaker at once," "group
speakers together," "send a single app somewhere else while everything
else stays on your Mac" — three or four beats, each with a small
illustration or icon, culminating in the same Done button that exists
today.

**Upside.** Every single user sees it exactly once, at the moment they're
most primed to learn the app (they just installed it and are still paying
attention) — there's no discoverability problem because nothing needs to
be discovered, it's simply shown. It reuses the onboarding window's
existing chrome (`OnboardingWindowController`, `NSVisualEffectView`
background, fixed content width, Done-button pattern), so the engineering
cost is mostly new content views, not new infrastructure. It also gives
the app a natural place to set expectations before the user ever opens the
popover, which is a better sequence than explaining a feature after the
user is already confused by it.

**Downside.** It's a forced, one-shot detour — a user who is impatient to
just get their music playing has to click through slides about features
they may not care about yet (someone with one speaker doesn't need to hear
about groups right now). Anything explained here and then not immediately
usable is likely to be forgotten by the time the user actually needs it —
telling someone about groups before they've even seen a device list is
abstract, not concrete. It also makes onboarding longer, which cuts against
the permission flow's own goal of getting through TCC prompts quickly
without losing the user's patience.

## Option B — Contextual, first-use hints inside the popover

Leave onboarding permission-only. Instead, teach each feature exactly where
and when it becomes relevant, inside the popover itself, one time each.
Concretely: the first time the Applications card is empty, show inline
text explaining what per-app routing does and how to add an app (a "+" hint
where the footer control already lives); the first time the Groups-editor
window is opened with zero groups, show equivalent inline copy on the
empty state ("No groups — click here to create one," per Alec's proposed
fix for G1-N4) instead of a bare empty list. Each hint is a small, dismiss-
once row or empty-state string driven by a persisted "has this been seen"
flag (mirroring how `AppSettings.hasCompletedSetup` already gates
onboarding), not a modal or a separate screen.

**Upside.** Explanation appears exactly where the feature lives and exactly
when it's relevant — a user only learns about groups when they're looking
at the (empty) place groups would appear, so the concept is concrete
instead of abstract. Nothing is forced on a user who doesn't need it: if
someone adds a device and never opens Applications, they never see the
per-app explanation, and that's fine because they never needed it. It
directly closes G1-N4 and doesn't touch onboarding's already-tuned
permission flow at all, so the two efforts don't collide.

**Downside.** It requires touching several different surfaces individually
(the Applications card empty state, the Groups window empty state, possibly
the Main Out device selector) rather than one flow, so the design and
engineering cost is spread out and harder to review as one unit — and it's
easy to cover some surfaces and quietly miss others (e.g. what teaches a
user that Main Out's device dropdown can target a saved group?). It also
depends on the user actually visiting each empty state at all; a user who
never opens the Groups window still never learns groups exist, so coverage
isn't guaranteed the way a forced tour's is.

## Option C — A lightweight in-app "How Audiouter Works" page reachable from Help

Build a single static (or near-static) reference screen — reachable from a
"How Audiouter Works" item in the status-bar menu or Settings — that lays
out what each popover section does and what groups/per-app routing are for,
written and laid out once, referenced whenever the user wants it (including
long after first run, e.g. after a macOS update or if they forgot). It is
never shown automatically; it's opt-in, the same way a Help menu is.

**Upside.** By far the cheapest to build — no new state to persist, no
"have they seen this" tracking, no timing decisions about when to
interrupt the user, and no interaction with the onboarding flow at all. It
also survives past first-run: unlike a one-time tour or hint, it's there
for a user who churns back in months later and forgot what a "group" is,
which neither Option A nor B provides once their one-time flag has fired.

**Downside.** It only helps a user who already knows to look for help, and
new users overwhelmingly don't go looking for documentation before they've
even tried the thing — so as a *first-run* fix (which is what G1-N7a is
actually about) this option alone is weak. It is best understood as a
complement to A or B, not a replacement: it's a good permanent reference,
but it doesn't solve "a first-time user finishes onboarding having never
been told groups exist" by itself, since nothing points them to it.

## Recommendation

Ship Option B first — contextual, first-use hints at the two concrete gaps
Alec already flagged (empty Applications, empty Groups) — because it is
both the cheapest slice to build right now (it piggybacks on the empty-state
fixes G1-N4 already needs) and, done well, the most effective for a genuinely
new user, since it teaches each feature at the moment it's concrete rather
than as abstract slide-copy several clicks earlier; but be honest that it
does not guarantee full coverage the way a forced tour does, so if Alec
wants every new user to leave first-run knowing groups and per-app routing
exist *regardless of which cards they happen to open*, that guarantee only
comes from Option A's forced tour step, at the cost of a longer, partly
unwanted onboarding flow — and Option C's reference page is worth adding
either way, cheaply, as the permanent fallback neither A nor B provides once
their one-time moment has passed.

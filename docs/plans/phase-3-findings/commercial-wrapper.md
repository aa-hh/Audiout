# Commercial wrapper — discovery audit (Phase 3, R2)

Audiouter is a pure-AppKit menu-bar app, GPL-2.0-or-later, about to move from
ad-hoc-signed personal builds to a paid, direct-download, Developer-ID-signed
and notarized public release. This audit gap-analyzes everything *around* the
app that a paying customer expects and that doesn't exist yet: updates, crash
signal, docs, a website, licensing paperwork, support, and a release process.
Recommendations only — nothing here is drafted or built.

## Method

Read `AGENTS.md` (repo root), `scripts/make-app.sh` in full, and
`scripts/Audiouter.entitlements` in full to ground every signing/entitlement
claim below in what the build actually does today. Ran `git grep` across
`*.swift` for About/credits/NOTICE/menu handling, checked `NOTICE`, `LICENSE`,
`README.md`, and `AirPlayEngine/docs/license-inventory.md` for the current
attribution surface, and checked repo state (`git tag`, `gh release list`,
`gh repo view`) for release/versioning history. Verified the GitHub remote
(`aa-hh/Audiouter`) is currently **private**. Used web search/fetch for
current facts on Sparkle 2, MetricKit, Sentry, KSCrash, GPL distribution
obligations, and Rogue Amoeba's docs approach — cited inline.

Grounding facts from the build that shape every recommendation below:

- **Not sandboxed.** `scripts/Audiouter.entitlements` has no
  `com.apple.security.app-sandbox` key at all — only hardened-runtime flags
  (`disable-library-validation=true`, `allow-dyld-environment-variables=false`,
  `allow-unsigned-executable-memory=false`, `allow-jit=false`). This matters
  directly for Sparkle (§1): sandboxed apps need XPC services and mach-lookup
  entitlements; non-sandboxed apps don't.
- **`disable-library-validation=TRUE` is a deliberate ad-hoc-signing
  workaround**, not a permanent posture. The comment in both files says
  Developer ID would allow re-enabling it once bundled Homebrew dylibs carry a
  real Team ID signature instead of an ad-hoc one. Whoever owns Developer-ID
  signing should revisit this entitlement when the cert lands — it's a
  hardened-runtime weakening that's currently justified only by ad-hoc
  signing's lack of a Team ID.
- **No Xcode project.** The app is a SwiftPM executable
  (`swift build --package-path AudiouterCore -c release --product
  AudiouterApp`) hand-wrapped into a `.app` by a bash script. Every "just add
  it in Xcode" integration story (Sparkle's SPM instructions, most tutorials)
  needs translating into a `Package.swift` dependency + explicit bundle/sign
  steps in `make-app.sh`, since there's no build-phase automation to lean on.
- **Versioning is hardcoded.** `APP_VERSION="0.1.0"` and `BUILD_NUMBER="1"`
  are literal strings at the top of `make-app.sh` (lines 23-24) — not derived
  from a git tag, not incremented anywhere. No `CHANGELOG`, no git tags besides
  one unrelated `recovered-stash`, no GitHub releases exist yet.
- **No About window customization, no in-app NOTICE/credits surface.**
  `git grep` found no `orderFrontStandardAboutPanel`, no `AboutPanelOptionKey`,
  no Credits.rtf handling anywhere in the Swift sources. The default AppKit
  "About Audiouter" panel (whatever `NSApplication` synthesizes from
  Info.plist) is all a user would see today — it won't show GPL notice or
  third-party attribution.
- **GitHub repo is currently private** (`gh repo view` confirms
  `"isPrivate":true`). This is a live decision point for §5 and §6, not
  a fact to take for granted going forward.

---

## 1. Auto-updates

**Sparkle 2** is the standard choice for direct-download Mac apps outside the
App Store. Facts specific to this codebase:

- **License**: Sparkle 2's `LICENSE` is MIT-style permissive (attribution
  notice preserved, no copyleft) — safe to bundle inside a GPL-2.0-or-later
  app; MIT code can flow into a GPL project, the reverse can't
  ([Sparkle LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)).
  Sparkle also bundles bsdiff/bspatch (BSD-2-Clause) and an Ed25519
  implementation (MIT-style) for its binary-delta and EdDSA signing — all
  GPL-compatible. Whatever attribution mechanism the app adopts for its
  existing NOTICE (see §5) should gain a Sparkle entry.
- **Non-sandboxed = the easy path.** Per
  [Sparkle's sandboxing docs](https://sparkle-project.org/documentation/sandboxing/):
  *"If you do not sandbox your application, you should skip this guide unless
  you are interested in Removing the XPC Services."* Since
  `Audiouter.entitlements` carries no `app-sandbox` key, Audiouter can skip
  the Installer XPC service, the Downloader XPC service, and the
  `-spks`/`-spki` mach-lookup entitlements entirely — those exist only to let
  a sandboxed app talk to an unsandboxed installer helper, which is moot here.
  This significantly shrinks the integration compared to a sandboxed (e.g.
  App-Store-adjacent) app.
- **No-Xcode-project integration is real work, not a checkbox.** Sparkle
  ships as an SPM binary target
  ([swiftpackageindex.com/sparkle-project/Sparkle](https://swiftpackageindex.com/sparkle-project/Sparkle)),
  so `AudiouterCore/Package.swift` can depend on it like any other package —
  that part is easy. The gap is everything Xcode's build phases normally do
  for you: `make-app.sh` would need new steps to (a) copy
  `Sparkle.framework` into `Contents/Frameworks/`, (b) set an `-rpath` linker
  flag (`-Wl,-rpath,@loader_path/../Frameworks`) so the binary finds it at
  runtime, (c) codesign the framework itself before signing the outer bundle
  — Sparkle ships a `bin/codesign_embedded_executable` helper for exactly
  this, and the inside-out signing order matters the same way it already does
  for the bundled Homebrew dylibs in this script (see the "WHY ORDER MATTERS"
  comment around line 247). This is a natural extension of code that already
  exists (`bundle-dylibs.sh` + the inside-out signing loop), not new
  architecture — but it is new lines, tested against a real update cycle.
- **EdDSA appcast signing**: run `bin/generate_keys` once (stores the private
  key in the signing machine's login Keychain, prints a public key to embed
  as `SUPublicEDKey` in Info.plist), then `bin/generate_appcast` on each
  release folder auto-signs every archive
  ([Sparkle docs](https://sparkle-project.org/documentation/)). This is a
  release-time step, not a runtime one — it belongs in the release checklist
  (§7), run from whatever machine holds the signing key (probably not this
  worktree).
- **Notarization interacts with every single release, not just the first
  one.** Gatekeeper's signature check fires on files carrying the quarantine
  attribute; a Sparkle-delivered update lands with that attribute set on the
  download machine, so **every appcast entry must point at an already
  notarized-and-stapled archive** — there's no "notarize once, update forever"
  shortcut. That means the release checklist (§7) needs a notarize+staple
  step per release, not per major version. Source:
  [Sparkle publishing docs](https://sparkle-project.org/documentation/publishing/),
  [Christian Tietze's 2022 notarization workflow writeup](https://christiantietze.de/posts/2022/07/mac-app-notarization-workflow-in-2022/).
- **Alternative — "new version available" banner + manual download.** A
  lightweight in-app check (fetch a JSON/plist with the latest version number,
  compare to `CFBundleShortVersionString`, show a banner linking to the
  download page) is maybe 50-100 lines of Swift with zero new dependencies,
  zero XPC/entitlement surface, and zero appcast/EdDSA machinery. It leans on
  infrastructure the website (§4) needs anyway (a hosted version file).

**Recommendation**: Ship the manual "new version available" check for launch,
add full Sparkle post-launch once the release cadence is proven.
Upside (manual): ships fast, no new dependency inside a GPL app that
otherwise vendors nothing beyond OwnTone-derived sources, no XPC/signing
surface to get wrong on a from-scratch bundling script, easy to reason about
for a solo maintainer. Downside (manual): friction for the user (download +
reinstall by hand each time), no delta updates, no rollback story, and it's
work you'll likely redo as Sparkle later anyway. Upside (Sparkle): the
standard, trusted, one-click update experience paying customers expect from
this class of app (SoundSource, Bartender, etc. all use it), delta updates,
signature verification of the update itself. Downside (Sparkle): real
integration cost given no Xcode project (new `make-app.sh` steps, inside-out
signing to get right, an EdDSA key to generate and protect), and it adds a
notarize-and-staple obligation to *every* release rather than just the
first, which raises the cost of a rushed patch release.

---

## 2. Crash reporting

Constraints from the brief: privacy-conscious owner, wants small dependency
footprint, but a paid app needs *some* crash signal — silence from a paying
customer's crash is a lost customer, not just a lost data point.

- **MetricKit**: has existed on macOS since macOS 12
  ([MetricKit docs](https://developer.apple.com/documentation/MetricKit)),
  and can capture crash diagnostics via `MXCrashDiagnostic` for hang/crash/CPU
  data that in-process handlers can't always see. But there's a documented,
  unresolved gap for exactly Audiouter's distribution model: **Apple's own
  crash-diagnostics *delivery* system (the part that surfaces reports in
  Xcode Organizer) only works for App-Store-delivered apps**; several
  developers report open questions about whether MetricKit's 24-hour payload
  delivery on macOS requires App Store/TestFlight distribution at all for a
  Developer-ID-only, direct-download app
  ([Chime: MetricKit Crash Reporting](https://www.chimehq.com/blog/metrickit-crash-reporting),
  [Chime: MeterReporter](https://www.chimehq.com/blog/meterreporter)). Since
  Audiouter is exactly that case (Developer ID direct download, no App
  Store), MetricKit is not a verified-working option here without a live
  spike — flag as *unproven*, not *ruled out*.
- **Sentry (sentry-cocoa)**: free tier exists, then usage-based pricing by
  event/transaction/attachment volume (see
  [sentry.io/pricing](https://sentry.io/for/cocoa/) for current tiers — exact
  numbers weren't pinned down by search and should be checked at signup
  time). Sentry is dropping CocoaPods distribution at end of June 2026 in
  favor of SPM or a prebuilt XCFramework
  ([sentry-cocoa GitHub](https://github.com/getsentry/sentry-cocoa)), which
  fits this project's SPM-only build. It's the highest-signal option
  (symbolicated stack traces, breadcrumbs, release tracking, dashboards) but
  it is a network call home on every crash and (depending on config) on
  ordinary telemetry — a real privacy posture decision for an app whose own
  audio-permission prompt explicitly promises "never sent anywhere else."
  That promise is about audio content, not diagnostics, but a customer who
  read it carefully may reasonably expect the same spirit to extend to crash
  data; if Sentry is adopted, the audio-usage-description precedent (say
  plainly what's collected and why, in the user's words) should extend to a
  crash-reporting opt-in, not silent-by-default telemetry.
- **KSCrash**: an actively maintained (2.0 released), self-hostable,
  open-source crash reporter with pluggable report destinations — you own
  where reports go, no vendor. It's iOS-first in framing but supports Apple
  platforms broadly; **macOS-specific maturity wasn't independently
  confirmed** in this pass (PLCrashReporter — Microsoft-maintained,
  `iOS/macOS/tvOS` explicitly — is the more macOS-proven open-source
  alternative:
  [PLCrashReporter](https://github.com/microsoft/plcrashreporter)). Either
  requires standing up *something* to receive reports (a server, or at
  minimum an email inbox they get mailed to) — that's the real cost, not the
  library.
- **"Ask users to send `~/Library/Logs/DiagnosticReports`" with an in-app
  helper button**: essentially free to build (a button that opens that
  folder in Finder, or reads and pre-fills an email with the relevant
  `.ips` file), zero dependencies, zero telemetry, fully consistent with the
  privacy stance already visible in this codebase's permission strings. The
  cost is entirely on response rate — most users who hit a crash won't go
  digging for a log file and emailing it unprompted, so this yields much
  lower crash visibility than any of the above, especially for silent/rare
  crashes nobody thinks to report.

**Recommendation**: Ship the "helper button + email" path at launch; treat
Sentry as the first upgrade once there's a support inbox to route reports
into, not before. Upside (helper button): zero new dependencies in a GPL
app, zero telemetry-by-default (matches the existing privacy voice in
`AUDIO_CAPTURE_USAGE`/`LOCAL_NETWORK_USAGE`), nothing to code-sign or notarize
differently. Downside: crash visibility is opt-in and manual — most crashes
will go unreported, which is a real risk for a paid app in its first weeks
when undiscovered bugs are most likely. Upside (Sentry, later): automatic,
symbolicated, and comprehensive — the gold standard for actually knowing your
crash rate. Downside: it's a standing network dependency and a privacy
posture change that should be disclosed, not silently added; and its cost
scales with users, which is backwards for a bootstrap launch.

---

## 3. Help/docs surface

Audiouter's routing model (Main Out vs. Selected Devices vs. per-app routing,
per `docs/plans/phase-3-findings/copy.md`'s terminology audit) is genuinely
non-obvious — this isn't a simple on/off utility, it needs *some* explanation
surface. Rogue Amoeba's SoundSource (the closest comparable: a paid,
non-App-Store, menu-bar audio-routing utility) ships a full product manual
plus a support knowledge base, with an in-app Help-menu link and email
support responsive within about 24 hours
([Rogue Amoeba SoundSource manuals](https://rogueamoeba.com/support/manuals/soundsource/),
[Rogue Amoeba support knowledgebase](https://rogueamoeba.com/support/knowledgebase/?showCategory=SoundSource)).
That's the mature end of the spectrum for a company with a support team;
Audiouter is a solo-maintainer launch and doesn't need to match that scope
day one.

The minimum credible set for a $30-50 utility, in priority order:

1. **One well-made "How Audiouter works" page** explaining the three-tier
   routing model in plain language (Main Out / Selected Devices / per-app),
   hosted on the website (§4) and linked from the in-app Help menu. This is
   the single highest-leverage doc — it's the concept every other feature
   sits on top of, and `copy.md`'s own findings (e.g. "Current Device" vs
   "This Mac", "No Redirect" vs "Mac Only") show the in-app terminology
   itself isn't fully settled yet, which is exactly the kind of confusion a
   short explainer page defuses regardless of which terms ship.
2. **Tooltips on the non-obvious controls** (per-app routing rows, group
   creation, the buffer/latency setting under Audio → Advanced) — cheap,
   already the native AppKit idiom, and catches the "what does this button
   do" moment before it becomes a support email.
3. **A Help menu item linking out** to the page in (1) plus a "Contact
   Support" item (mailto: or a page, see §6) — standard NSApplication Help
   menu, minimal AppKit work.

Explicitly **not** needed at launch: a searchable knowledge base, video
walkthroughs, or a multi-page manual — those are what SoundSource has grown
into over years, not a launch requirement.

**Recommendation**: Ship (1) the single explainer page + (3) Help menu
links at launch; treat tooltips (2) as ongoing polish, not a gate.
Upside: one well-scoped writing task instead of an open-ended documentation
project; directly answers the question new users will actually have.
Downside: a single static page can't cover edge cases (per-device volume
quirks, group behavior when a speaker drops offline) — expect some of that
to land as support-email FAQs that should get folded back into the page over
time.

---

## 4. Website / download page

Minimum viable surface for a paid, direct-download app:

- **Landing page**: what it does, screenshot(s), the routing-model pitch,
  a price, a Buy/Download button. Can be a single static page.
- **Download link**: points at the current notarized `.dmg`/`.zip` — the
  same artifact the release checklist (§7) produces.
- **Purchase integration**: this task defers provider choice to R1
  (Paddle/Gumroad/FastSpring/etc.) — noting only the interface point this
  page needs: a checkout link or embed, and a way to hand the buyer either
  a download link or a license key/receipt after payment. (Briefly, for
  R1's reference: Paddle and Lemon Squeezy charge ~5%+$0.50/transaction,
  Gumroad ~10%+$0.50, FastSpring is custom/higher-volume pricing — Paddle
  Billing notably dropped native license-key support that Paddle Classic
  had, so a one-time-purchase model may need a third-party licensing layer
  like LicenseSeat on top of any of these
  ([buildmvpfast.com Paddle alternatives 2026](https://www.buildmvpfast.com/alternatives/paddle),
  [LicenseSeat](https://licenseseat.com/licensing-for-macos-apps)) — R1
  owns the actual decision.)
- **Release notes page**: even a single reverse-chronological page fed by
  the changelog discipline in §7 — this is also what a manual
  "new version available" check (§1) can link to.
- **Support contact**: an email address or a link to wherever support lands
  (§6), visible on the page, not just buried in the app.
- **Static-site options**: given the whole site is landing page + docs +
  release notes + (possibly) an appcast, a static site generator or even a
  handful of hand-written pages is enough — no backend needed except
  whatever the payment provider hosts for checkout. GitHub Pages is a
  concrete, zero-cost option that also solves the appcast-hosting problem in
  one place (see next point) — but note the GitHub repo is **currently
  private**; GitHub Pages for a private repo needs a paid GitHub plan, or
  the docs/marketing site needs to live in a separate (public) repo from the
  private source.
- **What Sparkle needs hosted, if adopted (§1)**: `appcast.xml` at a stable
  public URL (referenced from the app's `SUFeedURL`), plus each release's
  notarized archive. This can be automated with GitHub Actions running
  `generate_appcast` and publishing to GitHub Pages
  ([blog.rampatra.com walkthrough](https://blog.rampatra.com/automatically-generate-appcast-xml-and-dmg-files-for-your-mac-app-updates),
  [Sparkle discussion #2308](https://github.com/sparkle-project/Sparkle/discussions/2308)),
  or hand-maintained if Sparkle is deferred per §1's recommendation — in
  which case this need doesn't exist yet.

**Recommendation**: A single static site (landing + docs + release notes)
on GitHub Pages or an equivalent free static host, with the payment
provider's own hosted checkout handling the transaction (no custom backend).
Upside: near-zero infrastructure cost and maintenance, matches a solo
maintainer's bandwidth, and the same site later hosts the appcast if Sparkle
lands. Downside: GitHub Pages specifically needs either the source repo made
public or the site split into its own public repo — a decision this task
flags but doesn't make (see §5/§6 on repo visibility); a fully custom domain
+ hosting stack would look more "real" but is more to maintain for no
functional gain at this stage.

---

## 5. EULA / licensing page implications of GPL

This is the section where the commercial wrapper and the existing legal
posture (GPL-2.0-or-later, `NOTICE` file, `AirPlayEngine/docs/license-inventory.md`)
collide, so it needs the most care.

- **What GPL-2.0 requires when you distribute binaries for a fee**: you may
  charge money for the software itself, but every recipient must receive (or
  have a standing, honored offer to receive) the **complete corresponding
  source code**, and must retain the freedom to redistribute and modify it —
  GPL forbids layering restrictions on top (no NDA, no "you may not
  redistribute this copy") ([GNU GPLv2 FAQ](https://www.gnu.org/licenses/old-licenses/gpl-2.0-faq.en.html)).
  Concretely: **charging $30-50 for a `.dmg` download is fine under GPL**,
  but the moment that happens, the source must actually be available to
  anyone who receives the binary — either publicly (the simplest compliant
  answer) or via a credible written offer. This is where the **repo being
  private today is a live tension**, not a settled fact: a private repo with
  a paid public binary is not GPL-compliant unless there's a working written-
  offer mechanism in its place. That's a decision for the project owner, not
  this audit, but it needs to be made before the paid release, not after.
- **What a "commercial license page" can and cannot say**: GPL doesn't
  prevent *dual licensing* (the same codebase offered under GPL to some
  users and a separate paid/proprietary license to others) — MySQL, Qt, and
  more recently Sentry/Plausible/Cal.com under AGPL all do this
  ([Vircon Legal: Dual Licensing](https://virconlegal.com/term/dual-licensing-open-source-commercial/)).
  But that only works if **the project owns 100% of the copyright** it's
  relicensing — and Audiouter explicitly does not: `NOTICE` and
  `AirPlayEngine/docs/license-inventory.md` document vendored GPL-2.0-or-later
  code from the OwnTone project (`airplay.c`, `rtp_common.c`, etc.), plus
  BSD-2-Clause and MIT components. **A commercial/proprietary license for
  Audiouter as a whole is not legally available** without OwnTone's
  copyright holders' consent for their GPL-licensed portions — a "buy a
  commercial license to go proprietary" page, the classic dual-license
  pattern, is off the table as written. What *is* fully available under GPL:
  charging money for the binary itself (a "buy the built app, or build it
  yourself from source for free" framing — this is exactly what e.g.
  many GPL-licensed macOS utilities do), which is a legitimate and much
  simpler story to put on a licensing page.
- **In-app NOTICE/attribution surface — currently nothing exists.** `git
  grep` across all Swift sources found zero hits for
  `orderFrontStandardAboutPanel`, `AboutPanelOptionKey`, `Credits.rtf`, or
  any custom About-window handling — the app relies on whatever AppKit
  synthesizes by default from `Info.plist` (app name, version, copyright
  string if one's added to the plist). That default panel does **not**
  surface GPL notice, source-availability information, or the three-license
  attribution `NOTICE` already documents in detail. **This is a real gap**:
  a paid app that vendors GPL/BSD/MIT code and says nothing about it in the
  UI is both a poor look for a $30-50 purchase and arguably under-delivering
  on the GPL's spirit (not its strict letter — GPL doesn't mandate an
  in-app Credits screen, only that source be available on request/download).

**Recommendation**: Before the paid release, resolve repo visibility (make
the source public, or stand up a genuine written-offer mechanism) and add a
custom About panel / Credits surface that at minimum states "GPL-2.0-or-later,
source available at [link]" plus the existing three-license attribution.
Do **not** attempt a proprietary "commercial license" tier without
first confirming what rights OwnTone's license actually grants for that.
Upside: makes the paid release actually GPL-compliant (not just habitually
assumed to be) and turns an existing well-maintained `NOTICE` file into
something a customer can actually see, which reads as trustworthy for a
privacy-conscious audience. Downside: a public repo is a bigger decision than
it looks — competitors can read the code, and issues/PRs become public-facing
overhead (see §6) — but the alternative (staying private while selling a GPL
binary) is a compliance risk, not a style choice.

---

## 6. Support channel

- **Email**: the baseline every paid app needs — visible on the website
  (§4), the in-app Help menu (§3), and receipts from the payment provider.
  Low overhead to start (a mailbox), scales to a helpdesk tool later if
  volume warrants it.
- **GitHub Issues**: only viable if the repo goes public (§5's compliance
  question already forces this decision anyway). If it does, Issues doubles
  as a public bug tracker and a lightweight support channel for technically
  literate users — but a solo maintainer should expect it to surface
  duplicate reports and feature requests that read like support tickets, not
  just bugs, and needs *some* triage cadence or it looks abandoned within
  weeks.
- **Rogue Amoeba's model** (email support, target ~24-hour response,
  supplemented by a knowledge base) is the credible reference point for what
  "amazingly responsive" indie support looks like
  ([Rogue Amoeba support](https://rogueamoeba.com/support/knowledgebase/?showCategory=SoundSource))
  — but that's a small company with a support rotation, not one person.

**Recommendation**: Email as the primary, advertised channel at launch;
GitHub Issues as a secondary channel *only if and once* the repo is public
(§5), explicitly framed as "bugs and feature requests," not general support.
Upside: sets one clear expectation for paying customers (email = "I paid,
help me"), keeps GitHub Issues for the lower-stakes, technically-literate
crowd who'd use it anyway. Downside: a solo maintainer answering email
support alone will feel the response-time pressure quickly, especially
right after a launch spike — worth deciding up front what response-time
promise (if any) gets stated publicly, since an unstated expectation still
gets judged against Rogue Amoeba's 24 hours by comparison-shopping
customers.

---

## 7. Release pipeline glue

What `scripts/make-app.sh` already does well: builds release-config,
assembles the bundle, writes a correct Info.plist (including the two TCC
usage strings with defensive `plutil -extract` verification), optionally
bundles Homebrew dylibs for a Homebrew-less target Mac, strips extended
attributes that break codesign, and ad-hoc-signs with hardened runtime plus
a real verification pass (`--verify --strict`, a hardened-runtime-flag grep,
an entitlements-embedded grep, and a `--deep` nested-code verify). That's a
genuinely careful, defensive script — the gaps are entirely in what's
*around* it, not in it:

- **Versioning is hardcoded, not sourced from anything**:
  `APP_VERSION="0.1.0"` / `BUILD_NUMBER="1"` are literal strings at the top of
  the script (lines 23-24). Nothing increments `BUILD_NUMBER` per build or
  derives `APP_VERSION` from a git tag — a real release process needs both to
  change per shipped version, and a monotonically increasing `BUILD_NUMBER`
  specifically matters for Sparkle (§1), which keys update detection off
  `CFBundleVersion`.
- **No changelog discipline exists**: no `CHANGELOG.md`, no git tags besides
  one unrelated `recovered-stash`, no GitHub releases (`gh release list`
  returned empty). This needs to start now, before the first paid release,
  or release notes (§4) have nothing to draw from.
- **No Developer-ID signing or notarization step exists yet** — by design,
  per the task brief ("cert arriving now; everything so far ad-hoc signed").
  The script's codesign section is explicitly commented as "Phase 2 swaps
  this for a real signing identity + notarization" (line 227-228) — that
  swap, plus `xcrun notarytool submit` / `xcrun stapler staple`, is the
  single largest concrete gap between what exists today and a shippable
  release artifact.
- **Missing entirely**: a DMG/ZIP packaging step (make-app.sh produces a
  bare `.app`, not a distributable archive), and the
  `disable-library-validation` re-evaluation flagged above once Developer ID
  signing is live.

**Release checklist skeleton** (build → sign → notarize → staple → appcast →
upload), gap-flagged against what exists today:

1. Bump `APP_VERSION` / `BUILD_NUMBER` in `make-app.sh` — **missing**: no
   mechanism ties this to a git tag or changelog entry today.
2. `swift build -c release` + assemble bundle — **exists**, working.
3. Update `NOTICE`/Credits surface if dependencies changed — **missing**: no
   in-app surface exists yet at all (§5).
4. Codesign with Developer ID + hardened runtime — **partially exists**: the
   hardened-runtime signing and verification logic is all there; only the
   identity swap from ad-hoc (`--sign -`) to a real Developer ID cert is
   missing, plus revisiting `disable-library-validation`.
5. Package as `.dmg`/`.zip` — **missing** entirely.
6. `notarytool submit` + wait for approval — **missing** entirely.
7. `stapler staple` the notarized archive — **missing** entirely.
8. Sign the archive with Sparkle's EdDSA key + regenerate `appcast.xml` (only
   if Sparkle is adopted per §1) — **missing**, N/A if the manual-check
   alternative ships instead.
9. Upload archive + release notes + (if applicable) appcast to the website
   (§4) — **missing**: no website exists yet.
10. Tag the release in git, write the changelog entry — **missing**: no
    changelog convention exists yet.

**Recommendation**: Extend `make-app.sh` (or a new sibling script that calls
it) to own steps 1-7 as one command, with Developer-ID signing and
notarization as the first and most urgent addition — everything else in this
document depends on there being a real, notarized, distributable artifact.
Upside: turns "ship a release" from a multi-step manual ritual (error-prone
for a solo maintainer, especially under launch-week pressure) into one
command matching the care already put into the ad-hoc signing/verification
logic. Downside: it's real scripting work on top of an already careful
script, and the notarization step introduces a new external dependency
(Apple's notary service latency/availability) into the release critical
path that doesn't exist in today's ad-hoc flow.

---

## Suggested build order

**Blocks the paid release** (release cannot credibly ship without these):

1. Developer-ID signing + notarization + stapling in the release script
   (§7) — nothing else matters without a legitimately distributable artifact.
2. Resolve GPL source-availability compliance — either make the repo public
   or stand up a written-offer mechanism (§5). This is a legal precondition
   of charging money for GPL-covered binaries, not a polish item.
3. Landing page + download link + payment integration interface point (§4)
   — there's no way to sell the app without it.
4. Versioning + a minimal changelog discipline (§7) — release notes (§4) and
   any update-check mechanism (§1) both depend on this existing.
5. A support email, advertised on the site and in the app (§6).
6. The single "How Audiouter works" explainer page + Help-menu link (§3) —
   the routing model is confusing enough that shipping without any
   explanation invites a wave of avoidable support email on day one.
7. An in-app About/Credits surface stating GPL-2.0-or-later + source link
   (§5) — follows directly from #2; a paid app selling GPL software should
   say so where the user can see it.

**Can follow release** (real, but not launch-blocking):

- Full Sparkle integration (§1) — ship the manual "check for updates" banner
  first; upgrade once release cadence is proven.
- Any crash-reporting SDK beyond the manual helper-button path (§2) —
  ship the low-cost option first, add Sentry once there's a support inbox to
  route reports into.
- Tooltips and expanded docs beyond the single explainer page (§3).
- GitHub Issues as a secondary support channel (§6) — depends on #2 above
  (repo going public) already having happened.
- A "commercial license" page — **not available at all** as a proprietary
  dual-license tier without OwnTone's consent (§5); if pursued later it
  needs its own legal review, not just a webpage.

## Top 5 by user impact

1. **Developer-ID signing + notarization** (§7) — without this, Gatekeeper
   blocks the app for every customer on first launch; nothing else in this
   document matters if the binary won't open.
2. **The "How Audiouter works" explainer page** (§3) — the routing model
   (Main Out / Selected Devices / per-app) is the single biggest source of
   likely confusion for a first-time paying user; this is the cheapest fix
   with the highest clarity payoff.
3. **A real update path, even the manual-check version** (§1) — paying
   customers expect to be told when a fix exists; silence here reads as an
   abandoned app after the first bug report.
4. **GPL compliance (source availability)** (§5) — this is the one item on
   this list that isn't just about user experience: getting it wrong is a
   legal exposure for the owner, and it's entangled with the repo-visibility
   decision every other public-facing surface (§4, §6) also depends on.
5. **Support email, visible everywhere** (§6) — for a $30-50 purchase, "how
   do I reach a human" is a trust signal customers check before buying, not
   just after something breaks.

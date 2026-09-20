# Preliminary code review brief (read-only)

Repo root: /Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/unslop-code-ca8d54
You are one reviewer on a team doing the FIRST-EVER whole-codebase review of Audiout, a native AppKit
macOS app (Swift 6, strict concurrency) that sends system audio to AirPlay 2 / Bluetooth speakers.

DO NOT EDIT ANY FILE. You report findings only. Use Bash (cat, sed -n, grep, find) to read.

Before reading code in a folder, read the nearest AGENTS.md (root AGENTS.md, then the folder's).
They record intentional traps and constraints; something that looks wrong may be documented as
deliberate. If a finding contradicts an AGENTS.md rule, cite the rule and say the doc wins unless
the code is plainly broken.

## The bar
"Perfect code that is reliable and understandable to any reviewer without much context."
Judge every file as if a competent Swift/AppKit engineer who has never seen this repo opens it cold.

## What to hunt, in priority order

1. BUG class (report every one, any size):
   - Swallowed errors: `try?` on a call whose failure the user would feel; empty `catch {}`;
     `catch { }` that only logs at debug level when the caller needed the error; `_ = ` discarding a
     Result/Bool that signals failure; `if let ... else { return }` that silently drops a state
     transition; a `guard` that returns from the middle of a multi-step mutation leaving partial
     state.
   - Force unwraps / `as!` / `fatalError` / `precondition` on data that comes from the network,
     disk, the OS, or another process (crash on bad input).
   - Concurrency: main-actor assumptions not enforced by the type system; `nonisolated(unsafe)`;
     `@unchecked Sendable`; locks held across await; data races across the audio thread boundary;
     Task {} launched without a handle where cancellation matters.
   - Retain cycles (closures capturing self strongly in long-lived stored callbacks), observers
     never removed, timers never invalidated.
   - Placeholder / TODO / FIXME / stub bodies / unfinished branches that ship.
   - Off-by-one, unit mix-ups (ms vs s vs ns, frames vs samples vs bytes), sign errors — anything
     you can PROVE from the code, not suspect.
2. SUBSTANCE class:
   - Over-engineering: protocols with one conformer, generic machinery with one use, injection
     seams nothing injects, configuration nothing configures, layers that only forward.
   - Duplication: the same logic hand-copied in 2+ places (give both locations).
   - Files or types too large to review cold (state the line count and a natural split).
   - Dead code: unused functions/types/properties, `#if false`, commented-out code, unreachable
     branches. Verify with grep before claiming unused.
   - Code that ignores the surrounding repo's conventions (naming, error style, logging style,
     how neighbours do the same thing). Name the neighbour it should match.
   - Comments that are wrong, stale (describe old behaviour), narrate a call chain, restate the
     line, or carry decision/ticket/date archaeology that belongs in git — BUT this repo
     deliberately writes long "why" comments citing SPEC sections; those are fine. Flag only
     comments that are wrong, stale, or narrate WHAT rather than WHY.
   - Readability: functions >80 lines doing several things; nested closures 4+ deep; boolean
     parameter soup; magic numbers with no name; misleading names (a name that promises less or
     more than the body does).
3. COSMETIC class: emoji in source (UI string copy is a product decision — note but don't argue),
   chat-voice comments ("Now we...", "Let's..."), generic names (`handle`, `process`, `data`,
   `manager` without a noun), leftover debugging scaffolding.

## Do NOT report
- Style-only nits a formatter would fix.
- Long Apple API names.
- Test file length by itself.
- Things you did not verify (if you assert "unused", you grepped; if you assert "race", you
  traced both accessors and named them).

## Output format (strict)
Write your report to the file named in your task prompt, Markdown, in this exact shape:

# <area name> — review

## Verdict (3–5 sentences)
Overall state of this area for a cold reviewer, and the single highest-impact change.

## Findings
One entry per finding, ordered most severe first. Each entry:

### <N>. [BUG|SUBSTANCE|COSMETIC] <one-line claim>
- Where: `path/from/repo/root.swift:LINE` (one or more)
- Evidence: 2–6 lines quoted from the code, or the grep output that proves it
- Why it matters: 1–2 sentences, concrete consequence
- Fix: 1–3 sentences, the minimal change that makes it look like the code around it
- Confidence: high | medium

Cap at 25 findings per area; if you have more, keep the 25 most severe and add a "## Also noted"
list of one-liners with file:line.

## Counts
BUG: n · SUBSTANCE: n · COSMETIC: n · files read: n / files in area: n

Quote real code. A cold reviewer must be able to open the file at the line and see what you saw.
No praise sections, no preamble.

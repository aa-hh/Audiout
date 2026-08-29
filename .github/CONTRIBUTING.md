# Contributing to Audiout

Thanks for looking. Audiout is a small project with one maintainer, so the most
useful thing you can do is file a clear bug report.

## Reporting a bug

Open an [issue](https://github.com/aa-hh/Audiout/issues/new/choose) and use the
bug template. The three things that make a report actionable:

- **Your Mac and macOS version**, and whether you bought the app or built it.
- **Your speakers** — make and model. AirPlay behaviour varies wildly between
  a HomePod, a Sonos and a smart TV, and "it drops out" means different things
  on each.
- **What you did, what happened, what you expected.** If audio dropped or fell
  out of sync, say roughly how long after starting playback.

## Suggesting a feature

Also an issue — use the feature template. Say what you were trying to do, not
just what control you want added. The problem is more useful than the solution.

## Sending code

Open an issue before writing anything substantial, so you don't spend a weekend
on something that conflicts with work already in flight.

If you do send a pull request, enable the repo's guards once per clone with
`git config core.hooksPath .githooks`, then make sure the compile check
(`scripts/build.sh`) and the test suite (`scripts/run-tests.sh`) both pass
before you open it.

See [docs/BUILDING.md](../docs/BUILDING.md) for toolchain setup and
[AGENTS.md](../AGENTS.md) for how the codebase is laid out and which rules apply
where.

By contributing you agree your work is licensed under
[GPL-2.0-or-later](../LICENSE), the same as the rest of the project.

## What is out of scope

- **Video.** Audiout is audio only, deliberately.
- **Windows or Linux.** It is built on Core Audio and AppKit.
- **Removing the licence prompt.** You are legally free to do it in your own
  build — the GPL guarantees that and it isn't begrudged — but such a patch
  won't be merged here.

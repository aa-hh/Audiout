# 15 — make-app.sh: clean its temp dirs; snapshot tools: exit non-zero when a render fails

Status: ready-for-agent
Wave: 3
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings scripts #4, scripts #5

`make-app.sh` leaks five `mktemp -d` directories per icon build; the snapshot executables exit 0 even when `renderPNG` fails.

## Done when

One trap removes the temp dirs on any exit. Each snapshot tool's `renderPNG` failure propagates to a non-zero exit. shellcheck clean.

## Test seam

shellcheck scripts/make-app.sh; a snapshot tool run with an unwritable output path exits non-zero

## Verification

```bash
shellcheck scripts/make-app.sh
```

## Findings (verbatim from the area reports)

### 4. [BUG] `make-app.sh` leaks five `mktemp -d` directories on every run that builds an icon

- Where: `scripts/make-app.sh:649`, `:694`, `:729`, `:741`, `:784`
- Evidence: `grep -n 'ACTOOL_TMP\|XCASSETS_DIR\|ACTOOL_LD_TMP\|VERIFY_SWIFT\|ICONSET_DIR'` shows each
  variable assigned from `mktemp -d` and then only read — no `rm -rf` and no trap covers them. The
  script's other temp dir is cleaned (`:351`, `:357`, `:410` for `$STAGE`), so the omission is
  inconsistent with its own practice.
- Why it matters: `ICONSET_DIR` alone holds ten PNGs resized from two ~2.5 MB 1024x1024 sources, and
  `XCASSETS_DIR` holds forty. In a repo whose main recorded incident is the disk reaching zero bytes
  free — the reason `housekeeping.sh` exists at all — a build script that leaks tens of megabytes
  per invocation works against the thing it calls on line 289.
- Fix: add each to the existing EXIT trap, or `rm -rf` each at the end of its own block.
- Confidence: high

### 5. [BUG] `renderPNG` failures never reach the exit code — every snapshot tool exits 0 unconditionally

- Where: `AudioutCore/Sources/popover-snapshot/main.swift:1032` and `:1124`; same shape in
  `window-snapshot/main.swift:495`, `onboarding-snapshot/main.swift:303`,
  `settings-snapshot/main.swift:254`
- Evidence:
  ```swift
  // popover-snapshot/main.swift:96-135 (renderPNG)
  guard let data = rep.representation(using: .png, properties: [:]) else {
      print("  FAIL  could not encode PNG for \(url.lastPathComponent)")
      return
  }
  do { try data.write(to: url) ... } catch { print("  FAIL  write ...: \(error)") }
  ```
  `func run() -> Int32` has ten `return 0` statements and no other value; the last line is
  `exit(MainActor.assumeIsolated { run() })`.
- Why it matters: a run that wrote nothing — wrong output directory, full disk, encode failure —
  exits 0 and looks green to any script or agent that checks the status rather than reading the
  transcript. The repo has a named trap for exactly this class ("a non-matching `--filter` passes
  green"), and `run-tests.sh:386-392` goes out of its way to solve the same problem for the suite.
- Fix: have `renderPNG` return `Bool` and `run()` return 1 when any capture failed.
- Confidence: high

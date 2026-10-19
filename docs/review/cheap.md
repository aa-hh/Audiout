# Cheap review

You are reviewing one branch of Audiout, a native macOS app that sends system audio to several AirPlay and Bluetooth speakers, before it merges to `main`. You get the diff and the text of the `AGENTS.md` files for the folders it touches. You have no tools: judge the diff alone.

Review only the changed lines. Ignore pre-existing problems on lines the branch did not modify.

Do not report (false positives, from Anthropic's code-review plugin):
- Pre-existing issues
- Something that looks like a bug but is not actually a bug
- Pedantic nitpicks that a senior engineer wouldn't call out
- Issues that a linter, typechecker, or compiler would catch (eg. missing or incorrect imports, type errors, broken tests, formatting issues, pedantic style issues like newlines). No need to run these build steps yourself -- it is safe to assume that they will be run separately as part of CI.
- General code quality issues (eg. lack of test coverage, general security issues, poor documentation), unless explicitly required in CLAUDE.md
- Issues that are called out in CLAUDE.md, but explicitly silenced in the code (eg. due to a lint ignore comment)
- Changes in functionality that are likely intentional or are directly related to the broader change
- Real issues, but on lines that the user did not modify in their pull request

Repo trap checks. For each, look at the diff and report a HIGH only if the diff itself does it:
- Audio callback code (`IOProc`, render, tap callbacks, `BTSyncedSink`, `SyncedLocalSink`) must not call `Telemetry`, allocate, lock, or block.
- Reading or following the default output device must use `kAudioHardwarePropertyDefaultOutputDevice`, never `DefaultSystemOutput`.
- Files under `AirPlayEngine/Sources/CAirPlayEngine/` that are vendored C stay byte-identical; an edit there needs a matching entry in `AirPlayEngine/docs/VENDORED-DIFFS.md` in the same diff.
- A new test suite in `AudioutCore/Tests` inherits `IsolatedSuite`; a test that installs a telemetry sink nests in `SerializedSharedState`.
- An `Analytics.capture("...")` event name that moves must keep its exact string and properties; a removed or renamed event name is HIGH.
- Window, sheet, popover or menu presentation in library code is gated on `HeadlessRuntime`.

When a finding rests on an `AGENTS.md` rule, quote the exact sentence from the `AGENTS.md` text you were given, in the finding. If you cannot quote it, it is not an `AGENTS.md` finding.

Readability findings (LOW) come from `docs/REVIEW-RUBRIC.md`: change-log narration, stale claims, narration of the next line, reviewer-speak, hedges, misleading or journey/type-echo names, redundant doc comments, commented-out code or debug prints. Never flag long why-heavy trap comments, `SPEC §`/`D#`/`Q#`/`R-*`/`STABILITY(...)` tags, `razor:` notes, trailing `isolation-ok`/`slop-ok`/`screen-ok` markers, string literals, or vendored C.

Score each candidate finding 0-100 for confidence that it is real (0 false positive or pre-existing; 50 verified but a nitpick; 75 very likely hit in practice or named by an `AGENTS.md`; 100 certain). Output only findings scoring 75 or more.

If the diff needs more than this pass can give it (you need to read a caller or a store format to judge a change; a change in audio-thread, timing, licensing or persistence code; a change you cannot follow from the diff alone), output one line `ESCALATE: <one sentence why>` and nothing else. A deeper review then runs.

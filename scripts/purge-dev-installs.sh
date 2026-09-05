#!/bin/bash
# purge-dev-installs.sh — dev-only tool: erase every trace of every NON-SHIPPING
# Audiout build from this Mac, and leave the shipping build untouched.
#
# WHY THIS EXISTS: CLAUDE.md requires every hand-off build to carry its OWN
# bundle id ("Audiout Sync v2" / com.audiout.Audiout.syncv2, ...) because
# macOS pins TCC grants to bundle id + code signature, so reusing an id after a
# rebuild produces stale grants and silent denials. That rule is correct and
# stays — but each of those throwaway ids leaves permanent residue behind:
#
#   - a preferences domain in ~/Library/Preferences
#   - TCC grants (audio capture, Bluetooth, local network) in the privacy DB,
#     visible forever as a dead row in System Settings › Privacy & Security
#   - a PUBLIC aggregate audio device, which persists in the system audio
#     settings and keeps showing up in Sound settings and Audio MIDI Setup
#     long after the app that made it is deleted
#   - an always-on ROOT PTP-helper launchd daemon
#   - possibly its own Application Support / Caches / saved-state directories
#
# It also removes two things that are nobody's build residue but everybody's
# problem: USER LAUNCH AGENTS under either product name (the shipping app
# installs none — see section 5), and dev tooling that an earlier session
# wrote into the app's own data directories.
#
# None of that is removed by dragging the .app to the Trash. This script is the
# uninstaller for all of it.
#
# It also clears the preference-domain files leaked by the TEST SUITES. Each
# `swift test` run creates per-test UserDefaults suites and never removes them,
# so ~/Library/Preferences accumulates tens of thousands of tiny plists that
# every `defaults` call and every cfprefsd lookup then has to walk past.
#
# THIS IS A DEV TOOL, NOT SHIPPING CODE.
#
# SAFETY:
#   - Dry run by default. With no flags this script only LISTS what it would
#     remove. It mutates nothing.
#   - --apply is required to remove anything.
#   - The SHIPPING identity is a hardcoded literal (PROD_BUNDLE_ID below), not
#     a variable a caller can override. Every id-driven step re-checks it
#     immediately before acting and hard-aborts on a match. Do not make it
#     configurable — that literal IS the safety boundary.
#   - Every id-driven step is additionally scoped to the "com.audiout."
#     namespace, so a bug in the discovery logic still cannot reach another
#     vendor's data.
#   - ~/Library/Application Support/Audiout/ (saved groups, per-app routes,
#     device icons, BT sync trims) belongs to the SHIPPING build and is never
#     touched. Neither is ~/Library/Logs/Audiout/ — every build writes
#     telemetry to that one shared path, so no line in it can be attributed to
#     a dev build and none of it is safe to attribute away from the shipping
#     one. ONE exception each, added 2026-09-05: a loose `*.sh` or a
#     `perfwatch*` entry directly inside either is dev tooling by
#     construction, because the app writes only `.json` files and an
#     `app-icons/` directory of `.png`s into the first and only
#     `telemetry.jsonl` into the second.
#   - The PRE-RENAME data directory (~/Library/Application Support/Audiouter/)
#     is LISTED BUT NEVER DELETED, however dead it looks. See section 9.
#
# Usage:
#   scripts/purge-dev-installs.sh            # list everything it would remove
#   scripts/purge-dev-installs.sh --apply    # actually remove it (needs sudo
#                                            # for the root PTP daemons only)
#   scripts/purge-dev-installs.sh --help

set -euo pipefail

# --- The safety boundary. A literal, deliberately not overridable. -----------
PROD_BUNDLE_ID="com.audiout.Audiout"
PROD_AGGREGATE_UID="com.audiout.Audiout.aggregate"   # AggregateOutputDevice.shippingUID
PROD_HELPER_LABEL="com.audiout.Audiout.ptphelper"    # make-app.sh HELPER_LABEL
PROD_APP_SUPPORT="Audiout"                             # GroupStore.defaultDirectory
# Nothing outside this namespace is ever a candidate, whatever discovery finds.
NAMESPACE="com.audiout."
# The same boundary for the one discovery step that greps rather than globs. Its
# dots must be escaped or they are wildcards: unescaped, `com.audiout.` matches
# the PRE-RENAME `com.audiouter.…` ids, which discovery then hands to
# `assert_not_prod`, which correctly refuses them and aborts the whole run.
NAMESPACE_RE="com\\.audiout\\."

# The pre-rename product name. Nothing in the shipping app reads or writes
# anything under it — GroupStore.defaultDirectory derives the folder name
# "Audiout" (AudioutCore/Sources/AudioutCore/GroupStore.swift:110) and no
# source outside a comment mentions the old name at all — so its residue is
# dead. That does NOT make it deletable: on a Mac that predates the rename the
# old data directory can still hold the only copy of the user's saved groups,
# which nothing ever migrated. Section 9 lists it and refuses to remove it.
OLD_NAMESPACE="com.audiouter."
OLD_APP_SUPPORT="Audiouter"

# Preference-domain prefixes leaked by the test suites — one plist per suite
# per test per run, forever. Historical target names are included because the
# residue outlives the rename that retired them.
TEST_PREF_PREFIXES=(
  AudioutCoreTests
  AudioutTests
  AudioControlSetupTests
  AudioControlTests
  OnboardingUITests
  AudioutUITests
  AudioutedTests
)

# Dev harness / snapshot-tool preference domains. These are process-name
# domains (an unbundled `swift run` binary keys UserDefaults by process name,
# not by bundle id), so they can't be found by the com.audiout.* scan.
HARNESS_PREF_DOMAINS=(
  AudioutApp
  popover-harness
  window-harness
  popover-snapshot
  settings-snapshot
  window-snapshot
  onboarding-snapshot
  mock-speakers-demo
)

usage() {
  cat <<'EOF'
Usage: purge-dev-installs.sh [--apply|--help]

Removes every trace of every NON-SHIPPING Audiout build from this Mac:
preference domains, TCC privacy grants, persistent aggregate audio devices,
root PTP-helper daemons, per-build support/cache/saved-state directories, and
stray .app bundles. Also clears the preference-domain files leaked by the test
suites, any user launch agent under either product name, and dev tooling left
inside the app's data directories.

The shipping build (com.audiout.Audiout) and its saved settings in
~/Library/Application Support/Audiout/ are never touched, and neither is the
pre-rename data directory ~/Library/Application Support/Audiouter/ — that one
is listed with a warning and left for you to check by hand.

  (no flags)   Dry run (default). List everything that would be removed.
               Mutates nothing.
  --apply      Actually remove it. Booting out the root PTP-helper daemons
               needs sudo, so you will be prompted for your password.
  --help       Show this message.
EOF
}

APPLY=0
case "${1:-}" in
  "") : ;;
  --apply) APPLY=1 ;;
  --help|-h) usage; exit 0 ;;
  *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFS="$HOME/Library/Preferences"

# Defense in depth: called immediately before every destructive id-driven
# operation, even though discovery already filtered. A script that can wipe
# TCC grants and audio devices should never trust a filter exactly once.
assert_not_prod() {
  case "$1" in
    "$PROD_BUNDLE_ID"|"$PROD_AGGREGATE_UID"|"$PROD_HELPER_LABEL")
      echo "    internal error: '$1' is the SHIPPING identity — refusing to touch it" >&2
      exit 1
      ;;
    "$NAMESPACE"*) : ;;
    *)
      echo "    internal error: '$1' is outside the '$NAMESPACE' namespace — refusing to touch it" >&2
      exit 1
      ;;
  esac
}

# `find -delete` rather than a glob: the test-suite residue runs to tens of
# thousands of files, well past what one `rm` argv can hold.
count_files() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

removed_anything=0

# ============================================================================
# 1. Dev bundle ids
# ============================================================================
# Union of every surface a dead dev build can still be named in — its
# preferences file, its root helper daemon, its support directory, and any
# surviving .app bundle. A build can appear in any one of those with no trace
# in the others (its .app deleted but its daemon still registered; or the
# reverse, an .app that was launched once and left a TCC row but no prefs), so
# all four are searched and the results unioned.
echo "==> Discovering non-shipping bundle ids"

# .app bundles are identified by the id INSIDE them, never by filename — a dev
# build can be called anything, and the shipping build must be spared even if
# it has been renamed or moved. Worktrees each have their own build/ and this
# script may be run from any of them, so resolve the main checkout and sweep
# every build directory under it.
GIT_COMMON="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
REPO_ROOT="${GIT_COMMON:+$(dirname "$GIT_COMMON")}"

dev_apps=()
for dir in \
  "${REPO_ROOT:+$REPO_ROOT/build}" \
  "${REPO_ROOT:+$REPO_ROOT/.claude/worktrees}" \
  /Applications \
  "$HOME/Applications" \
  "$HOME/Desktop" \
  "$HOME/Downloads"
do
  [ -d "$dir" ] || continue
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null || true)"
    case "$id" in
      "$PROD_BUNDLE_ID") continue ;;          # shipping build — leave it alone
      "$NAMESPACE"*) dev_apps+=("$id|$app") ;;
      *) continue ;;                          # not ours
    esac
  done <<< "$(find "$dir" -maxdepth 4 -name "*.app" -type d 2>/dev/null || true)"
done

DEV_IDS="$(
  {
    find "$PREFS" -maxdepth 1 -name "${NAMESPACE}*.plist" 2>/dev/null \
      | sed "s|.*/||; s|\.plist$||"
    launchctl print system 2>/dev/null \
      | grep -oE "${NAMESPACE_RE}[A-Za-z0-9_.-]+\.ptphelper" \
      | sed 's|\.ptphelper$||'
    find "$HOME/Library/Application Support" -maxdepth 1 -name "${NAMESPACE}*" 2>/dev/null \
      | sed "s|.*/||"
    [ "${#dev_apps[@]}" -gt 0 ] && printf '%s\n' "${dev_apps[@]}" | cut -d'|' -f1
  } | sort -u | grep -v "^${PROD_BUNDLE_ID}\$" || true
)"

dev_ids=()
if [ -n "$DEV_IDS" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] && dev_ids+=("$id")
  done <<< "$DEV_IDS"
fi

if [ "${#dev_ids[@]}" -eq 0 ]; then
  echo "    none found"
else
  echo "    ${#dev_ids[@]} found:"
  for id in "${dev_ids[@]}"; do echo "      $id"; done
fi
echo

# ============================================================================
# 2. Per-id state: preferences, TCC grants, support/cache/state directories
# ============================================================================
echo "==> Per-build state (preferences, TCC grants, support directories)"
if [ "${#dev_ids[@]}" -gt 0 ]; then
  for id in "${dev_ids[@]}"; do
    assert_not_prod "$id"
    echo "    $id"
    echo "        prefs domain, TCC grants (audio capture / Bluetooth / local network)"

    # Per-id directories. Missing ones are the common case — a build that only
    # ever ran once leaves prefs and a TCC row but no support directory.
    # No ~/Library/Containers entry: the app ships without the app-sandbox
    # entitlement (scripts/Audiout.entitlements), so it never gets a
    # container. Add one here if that ever changes.
    for dir in \
      "$HOME/Library/Application Support/$id" \
      "$HOME/Library/Caches/$id" \
      "$HOME/Library/HTTPStorages/$id" \
      "$HOME/Library/Saved Application State/$id.savedState"
    do
      [ -e "$dir" ] && echo "        $dir"
    done

    if [ "$APPLY" -eq 1 ]; then
      # `defaults delete` first so cfprefsd drops its in-memory copy; deleting
      # the file alone lets the daemon write it straight back out.
      defaults delete "$id" >/dev/null 2>&1 || true
      rm -f "$PREFS/$id.plist"
      find "$PREFS/ByHost" -maxdepth 1 -name "$id.*.plist" -delete 2>/dev/null || true
      # `reset All` covers every service this app has ever asked for without
      # this script having to track the list.
      tccutil reset All "$id" >/dev/null 2>&1 || true
      rm -rf \
        "$HOME/Library/Application Support/$id" \
        "$HOME/Library/Caches/$id" \
        "$HOME/Library/HTTPStorages/$id" \
        "$HOME/Library/Saved Application State/$id.savedState"
      removed_anything=1
    fi
  done
else
  echo "    nothing to remove"
fi
echo

# ============================================================================
# 3. Persistent aggregate audio devices
# ============================================================================
# Each dev build creates a PUBLIC aggregate named after itself
# (AggregateOutputDevice.productUID = "<bundle id>.aggregate"). Public means
# persistent: it survives the app's deletion and keeps appearing in Sound
# settings and Audio MIDI Setup. AudioHardwareDestroyAggregateDevice is the
# only thing that removes one; there is no shell equivalent, hence the inline
# Swift.
echo "==> Persistent aggregate audio devices"

AGG_SWIFT="$(mktemp -t audiout-agg).swift"
trap 'rm -f "$AGG_SWIFT"' EXIT
cat > "$AGG_SWIFT" <<'SWIFT'
import CoreAudio
import Foundation

// argv: <prod-uid-to-spare> <namespace-prefix> [--apply]
let spareUID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let namespace = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let apply = CommandLine.arguments.contains("--apply")

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var out: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &out) == noErr,
          let value = out?.takeRetainedValue() else { return nil }
    return value as String
}

// An aggregate is exactly a device carrying the sub-device-list property;
// there is no device-class selector that distinguishes one.
func isAggregate(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectHasProperty(id, &addr)
}

var defaultOutputAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)

func defaultOutputDevice() -> AudioObjectID {
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, 0, nil, &size, &id)
    return id
}

func setDefaultOutputDevice(_ id: AudioObjectID) -> Bool {
    var value = id
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &defaultOutputAddr, 0, nil, size, &value) == noErr
}

func builtInOutputDevice() -> AudioObjectID? {
    allDevices().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == "BuiltInSpeakerDevice" }
}

var found = 0
for id in allDevices() where isAggregate(id) {
    guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
    // Same two-part boundary the shell enforces, re-checked here so a bad
    // argument can't widen what this process is able to destroy.
    guard uid.hasPrefix(namespace), uid.hasSuffix(".aggregate"), uid != spareUID else { continue }
    found += 1
    let name = stringProperty(id, kAudioObjectPropertyName) ?? "(unnamed)"
    guard apply else {
        print("    \(name) [\(uid)]")
        continue
    }

    // A dev build can leave its aggregate selected as the system output, and
    // it stays selected after the .app is deleted. CoreAudio then refuses to
    // destroy it — AudioHardwareDestroyAggregateDevice returns noErr and the
    // device is simply still there on the next enumeration. Move the system
    // back to the built-in speakers first, which is also what the user wants:
    // otherwise this script would leave them pointed at a device it deleted.
    if defaultOutputDevice() == id {
        guard let builtIn = builtInOutputDevice(), setDefaultOutputDevice(builtIn) else {
            print("    SKIPPED (is the current system output, could not switch away): \(name) [\(uid)]")
            continue
        }
        print("    system output was \(name) — switched to MacBook Pro Speakers")
    }

    let err = AudioHardwareDestroyAggregateDevice(id)
    print(err == noErr ? "    removed: \(name) [\(uid)]"
                       : "    FAILED (\(err)): \(name) [\(uid)]")
}
if found == 0 { print("    none found") }
SWIFT

AGG_ARGS=("$PROD_AGGREGATE_UID" "$NAMESPACE")
[ "$APPLY" -eq 1 ] && AGG_ARGS+=("--apply")
# Compiling this each run costs a couple of seconds. That is the right trade
# for a rarely-run cleanup tool versus carrying another executable target.
# razor: if it ever needs to run often, promote it to a Package.swift target.
swift "$AGG_SWIFT" "${AGG_ARGS[@]}" 2>/dev/null || echo "    (could not enumerate — is the Swift toolchain available?)"
[ "$APPLY" -eq 1 ] && removed_anything=1
echo

# ============================================================================
# 4. Root PTP-helper daemons
# ============================================================================
# Delegated rather than reimplemented: purge-stale-ptp-helpers.sh already owns
# the launchd enumeration and its label-suffix safety filter. --keep spares the
# shipping daemon.
echo "==> Root PTP-helper launchd daemons"
if [ "$APPLY" -eq 0 ]; then
  "$SCRIPT_DIR/purge-stale-ptp-helpers.sh" --keep "$PROD_HELPER_LABEL"
elif sudo -n true 2>/dev/null; then
  "$SCRIPT_DIR/purge-stale-ptp-helpers.sh" --apply --keep "$PROD_HELPER_LABEL"
  removed_anything=1
else
  # Booting out a root-domain launchd job requires root, with no way around
  # it. Rather than fire 36 identical "no tty present" failures when this runs
  # without a terminal (an agent session, a CI job), name the one command that
  # needs a password and let the rest of the sweep finish.
  echo "    SKIPPED — no sudo. Everything else below still ran."
  echo "    Run this yourself to clear them:"
  echo "      $SCRIPT_DIR/purge-stale-ptp-helpers.sh --apply --keep $PROD_HELPER_LABEL"
fi
echo

# ============================================================================
# 5. User launchd agents
# ============================================================================
# The shipping app installs NO launch agent. Its only launchd job is the root
# PTP-helper LaunchDaemon that SMAppService registers from inside the .app
# bundle (make-app.sh, "Installing LaunchDaemons plist"), and that lands in the
# system domain, not here. So there is no shipping identity to spare in this
# directory: EVERY plist under ~/Library/LaunchAgents carrying either product
# name is dev residue, unconditionally.
#
# Why this section exists (owner's call, 2026-09-05): com.audiouter.perfwatch,
# a dev performance watchdog no session ever committed, was found still running
# after 6 days 22 hours. It was installed under the OLD product name, so the
# rename hid it, and nothing had ever looked in this directory.
echo "==> User launchd agents (${NAMESPACE}* / ${OLD_NAMESPACE}*)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
agent_plists=()
while IFS= read -r plist; do
  [ -n "$plist" ] && agent_plists+=("$plist")
done <<< "$(find "$LAUNCH_AGENTS" -maxdepth 1 \
  \( -name "${NAMESPACE}*.plist" -o -name "${OLD_NAMESPACE}*.plist" \) 2>/dev/null | sort)"

if [ "${#agent_plists[@]}" -eq 0 ]; then
  echo "    none found"
else
  for plist in "${agent_plists[@]}"; do
    label="$(basename "$plist" .plist)"
    # Defense in depth, same reasoning as assert_not_prod: the find pattern
    # already constrained this, and a step that boots out launchd jobs should
    # not trust one filter.
    case "$label" in
      "$NAMESPACE"*|"$OLD_NAMESPACE"*) : ;;
      *) echo "    internal error: '$label' is outside both namespaces — refusing" >&2; exit 1 ;;
    esac
    echo "    $label"
    echo "        $plist"
    if [ "$APPLY" -eq 1 ]; then
      # `|| true`: bootout exits non-zero whenever the label is not currently
      # loaded — an orphaned plist, or one already unloaded by hand. That is
      # the normal case here, not a failure, and the plist still has to go.
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
      rm -f "$plist"
      removed_anything=1
    fi
  done
fi
echo

# ============================================================================
# 6. Test-suite preference residue
# ============================================================================
echo "==> Leaked test-suite preference domains"
leaked_total=0
for prefix in "${TEST_PREF_PREFIXES[@]}"; do
  n="$(count_files "$PREFS" "$prefix.*.plist")"
  if [ "$n" -gt 0 ]; then
    echo "    $prefix.*  —  $n file(s)"
    leaked_total=$((leaked_total + n))
    [ "$APPLY" -eq 1 ] && find "$PREFS" -maxdepth 1 -name "$prefix.*.plist" -delete 2>/dev/null || true
  fi
done

# Anonymous per-test suites: `UserDefaults(suiteName: "test-\(UUID())")`. The
# full UUID shape is required in the match so this can never reach a real
# domain that merely starts with "test-".
n="$(find -E "$PREFS" -maxdepth 1 -regex ".*/test-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.plist" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n" -gt 0 ]; then
  echo "    test-<UUID>  —  $n file(s)"
  leaked_total=$((leaked_total + n))
  [ "$APPLY" -eq 1 ] && find -E "$PREFS" -maxdepth 1 -regex ".*/test-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.plist" -delete 2>/dev/null || true
fi

# The snapshot tools use the same UUID-suffixed scheme, keyed by tool name.
for tool in onboarding-snapshot settings-snapshot window-snapshot popover-snapshot; do
  n="$(find -E "$PREFS" -maxdepth 1 -regex ".*/$tool-[0-9A-F-]{36}\.plist" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    echo "    $tool-<UUID>  —  $n file(s)"
    leaked_total=$((leaked_total + n))
    [ "$APPLY" -eq 1 ] && find -E "$PREFS" -maxdepth 1 -regex ".*/$tool-[0-9A-F-]{36}\.plist" -delete 2>/dev/null || true
  fi
done

[ "$leaked_total" -eq 0 ] && echo "    none found"
[ "$APPLY" -eq 1 ] && [ "$leaked_total" -gt 0 ] && removed_anything=1
echo

# ============================================================================
# 7. Dev harness preference domains
# ============================================================================
echo "==> Dev harness / snapshot-tool preference domains"
harness_found=0
for domain in "${HARNESS_PREF_DOMAINS[@]}"; do
  if [ -e "$PREFS/$domain.plist" ]; then
    echo "    $domain"
    harness_found=1
    if [ "$APPLY" -eq 1 ]; then
      defaults delete "$domain" >/dev/null 2>&1 || true
      rm -f "$PREFS/$domain.plist"
      removed_anything=1
    fi
  fi
done
[ "$harness_found" -eq 0 ] && echo "    none found"
echo

# ============================================================================
# 8. Stray .app bundles
# ============================================================================
# Identified by the bundle id inside each one, never by filename — a dev build
# can be called anything, and the shipping build must be spared even if it has
# been renamed or moved.
echo "==> Non-shipping .app bundles"
if [ "${#dev_apps[@]}" -eq 0 ]; then
  echo "    none found"
else
  for entry in "${dev_apps[@]}"; do
    id="${entry%%|*}"
    app="${entry#*|}"
    assert_not_prod "$id"
    echo "    $app  [$id]"
    if [ "$APPLY" -eq 1 ]; then
      rm -rf "$app"
      removed_anything=1
    fi
  done
fi
echo

# ============================================================================
# 9. Pre-rename residue, and dev tooling inside the data directories
# ============================================================================
# The app was called Audiouter before it was called Audiout. Preference domains
# and log directories under the old name are dead weight and go. The old DATA
# directory does NOT go: nothing migrated it, so on a Mac that predates the
# rename it can still be the only copy of the user's saved groups. Losing
# someone's groups to a tidy-up would be a far worse bug than leaving a stale
# folder on disk, so this section lists it, says why, and stops.
#
# What it does remove from a data directory — either name — is a loose `*.sh`
# or a `perfwatch*` entry sitting directly inside it. The app writes only
# `.json` files and an `app-icons/` directory there, so nothing of that shape
# can be the app's; it is a dev script somebody dropped into the live data
# folder. Same for the watchdog's stack dumps under ~/Library/Logs/*/perfwatch.
echo "==> Pre-rename residue and dev tooling in the data directories"
old_found=0

# --- Old-name preference domains -------------------------------------------
while IFS= read -r plist; do
  [ -n "$plist" ] || continue
  domain="$(basename "$plist" .plist)"
  case "$domain" in
    "$OLD_NAMESPACE"*) : ;;
    *) echo "    internal error: '$domain' is not an old-name domain — refusing" >&2; exit 1 ;;
  esac
  echo "    prefs domain $domain"
  old_found=1
  if [ "$APPLY" -eq 1 ]; then
    defaults delete "$domain" >/dev/null 2>&1 || true
    rm -f "$plist"
    find "$PREFS/ByHost" -maxdepth 1 -name "$domain.*.plist" -delete 2>/dev/null || true
    removed_anything=1
  fi
done <<< "$(find "$PREFS" -maxdepth 1 -name "${OLD_NAMESPACE}*.plist" 2>/dev/null | sort)"

# --- Watchdog stack-capture directories under the live log paths ------------
for wd in "$HOME/Library/Logs/$PROD_APP_SUPPORT/perfwatch" \
          "$HOME/Library/Logs/$OLD_APP_SUPPORT/perfwatch"
do
  if [ -e "$wd" ]; then
    echo "    $wd"
    old_found=1
    if [ "$APPLY" -eq 1 ]; then
      rm -rf "$wd"
      removed_anything=1
    fi
  fi
done

# --- Old-name log directory -------------------------------------------------
# Unlike ~/Library/Logs/Audiout/, this one cannot be shared with the shipping
# build: the shipping build writes the new name. Telemetry only, so it goes
# whole.
OLD_LOGS="$HOME/Library/Logs/$OLD_APP_SUPPORT"
if [ -e "$OLD_LOGS" ]; then
  echo "    $OLD_LOGS"
  old_found=1
  if [ "$APPLY" -eq 1 ]; then
    rm -rf "$OLD_LOGS"
    removed_anything=1
  fi
fi

# --- Loose dev scripts inside either data directory -------------------------
for support in "$HOME/Library/Application Support/$OLD_APP_SUPPORT" \
               "$HOME/Library/Application Support/$PROD_APP_SUPPORT"
do
  [ -d "$support" ] || continue
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    echo "    $entry"
    old_found=1
    if [ "$APPLY" -eq 1 ]; then
      rm -rf "$entry"
      removed_anything=1
    fi
  done <<< "$(find "$support" -mindepth 1 -maxdepth 1 \
    \( -name "*.sh" -o -name "perfwatch*" \) 2>/dev/null | sort)"
done

# --- The old data directory itself: listed, warned about, never removed -----
OLD_SUPPORT="$HOME/Library/Application Support/$OLD_APP_SUPPORT"
if [ -d "$OLD_SUPPORT" ]; then
  keepers="$(find "$OLD_SUPPORT" -mindepth 1 -maxdepth 1 \
    ! -name "*.sh" ! -name "perfwatch*" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$keepers" -gt 0 ]; then
    old_found=1
    echo "    $OLD_SUPPORT"
    echo "        !! LEFT ALONE — $keepers item(s) in it are not dev tooling."
    echo "        !! Nothing migrated this directory when the app was renamed, so on an"
    echo "        !! older Mac it can hold the ONLY copy of groups.json / app-routes.json"
    echo "        !! / device-eq.json. This script will never delete it. Look inside,"
    echo "        !! then move or remove it by hand."
  fi
fi

[ "$old_found" -eq 0 ] && echo "    none found"
echo

# ============================================================================
# Done
# ============================================================================
if [ "$APPLY" -eq 0 ]; then
  echo "==> Dry run — nothing was changed. Re-run with --apply to remove the above."
  exit 0
fi

# cfprefsd caches preference domains in memory and rewrites deleted files from
# that cache. Without this restart the plists come straight back.
killall cfprefsd 2>/dev/null || true

if [ "$removed_anything" -eq 1 ]; then
  echo "==> Done."
  echo "    Sound settings and Audio MIDI Setup may need a moment to drop the"
  echo "    removed aggregate devices."
else
  echo "==> Done — nothing needed removing."
fi

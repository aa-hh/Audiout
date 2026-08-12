#!/usr/bin/env python3
"""Throwaway exploration driver (branch claude/light-separation-options).

For each separation option: patch the real sources, build the real
window-snapshot tool, render the real Groups "edit group" screen in light
mode, crop to the content pane, restore the sources. Not shipped.

The crop drops the sidebar and toolbar because stock system artwork
(source-list selection pill, toolbar segmented control) renders in the HOST's
appearance on this Darwin 27 machine even with NSApp.appearance pinned - see
the brief's "what I could not verify". The content pane is 100% custom-drawn
Warm Signal surface, which is exactly the subject.
"""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
TOKENS = ROOT / "AudiouterCore/Sources/AudiouterSharedUI/Tokens.swift"
SECTION = ROOT / "AudiouterCore/Sources/AudiouterWindowUI/GroupedSectionView.swift"
OUT = ROOT / "dev/notes/light-separation-options"
BIN = ROOT / "AudiouterCore/.build/arm64-apple-macosx/debug/window-snapshot"
SCRATCH = pathlib.Path("/tmp/light-sep-render")

HAIRLINE_BASE = 'light: 0xD0CDC3, lightHighContrast: 0x76716B'
WELL_BASE = 'warmDynamic(name: "well", dark: 0x100D0A, light: 0xE8E6DC)'

# The section's paint, as shipped. Replaced wholesale per option.
PAINT_BASE = """        Tokens.Color.well.setFill()
        shape.fill()
        Tokens.Color.hairline.setStroke()
        shape.lineWidth = Self.borderWidth
        shape.stroke()"""

PAINT_SHADOW = """        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.20)
        sh.shadowBlurRadius = 8
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.set()
        Tokens.Color.panel.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()"""

PAINT_FLAT = """        Tokens.Color.panel.setFill()
        shape.fill()"""


def patch(path, old, new):
    text = path.read_text()
    assert old in text, f"anchor not found in {path.name}: {old[:60]!r}"
    path.write_text(text.replace(old, new, 1))


OPTIONS = {
    # name: (list of (file, old, new))
    "00-baseline": [],
    "01-hairline-stronger": [
        (TOKENS, HAIRLINE_BASE, 'light: 0xC4C0B4, lightHighContrast: 0x76716B')],
    "01b-hairline-strongest": [
        (TOKENS, HAIRLINE_BASE, 'light: 0xB8B3A6, lightHighContrast: 0x76716B')],
    "02-recess-deeper-well": [
        (TOKENS, WELL_BASE,
         'warmDynamic(name: "well", dark: 0x100D0A, light: 0xDEDACD)')],
    "03-shadow-elevation": [(SECTION, PAINT_BASE, PAINT_SHADOW)],
    "04-inset-geometry-only": [(SECTION, PAINT_BASE, PAINT_FLAT)],
    "05-recess-plus-stronger-hairline": [
        (TOKENS, HAIRLINE_BASE, 'light: 0xC4C0B4, lightHighContrast: 0x76716B')],
}

SCREENS = ["mixer-3-edit-group-light", "mixer-4-device-detail-light"]
CROP = ("1073", "826", "125", "420")  # height width offsetTop offsetLeft


def run(name, edits):
    backups = {}
    for path, old, new in edits:
        if path not in backups:
            backups[path] = path.read_text()
        patch(path, old, new)
    try:
        subprocess.run(
            ["bash", "scripts/build.sh", "--product", "window-snapshot"],
            cwd=ROOT, check=True, env={**__import__("os").environ,
                                       "AUDIOUTER_BUILD_LOCAL": "1"},
            stdout=subprocess.DEVNULL)
        shutil.rmtree(SCRATCH, ignore_errors=True)
        SCRATCH.mkdir(parents=True)
        subprocess.run([str(BIN), str(SCRATCH)], check=True,
                       stdout=subprocess.DEVNULL)
        for screen in SCREENS:
            tag = "edit-group" if "edit-group" in screen else "device-detail"
            dest = OUT / f"{name}--{tag}.png"
            subprocess.run(["sips", "-c", CROP[0], CROP[1],
                            "--cropOffset", CROP[2], CROP[3],
                            str(SCRATCH / f"{screen}.png"), "--out", str(dest)],
                           check=True, stdout=subprocess.DEVNULL)
            print(f"  wrote {dest.name}")
    finally:
        for path, text in backups.items():
            path.write_text(text)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    wanted = sys.argv[1:] or list(OPTIONS)
    for name in wanted:
        print(f"== {name}")
        run(name, OPTIONS[name])

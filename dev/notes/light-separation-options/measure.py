#!/usr/bin/env python3
"""Throwaway exploration tool (branch claude/light-separation-options).

Computes WCAG 2.x relative-luminance contrast ratios for the light-mode
surface-separation options explored in ../light-separation-options-2026-08-12.md.
Not shipped, not imported by anything. Delete with the branch.
"""

RE_HEX = 0


def srgb_to_lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(hexv):
    r, g, b = (hexv >> 16) & 0xFF, (hexv >> 8) & 0xFF, hexv & 0xFF
    return 0.2126 * srgb_to_lin(r) + 0.7152 * srgb_to_lin(g) + 0.0722 * srgb_to_lin(b)


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def over(fg, alpha, bg):
    """Composite fg at `alpha` over opaque bg; return the resulting hex."""
    out = 0
    for sh in (16, 8, 0):
        f, b = (fg >> sh) & 0xFF, (bg >> sh) & 0xFF
        out |= int(round(f * alpha + b * (1 - alpha))) << sh
    return out


def h(v):
    return "#%06X" % v


# ---------------------------------------------------------------- instruments
INSTRUMENTS = {
    "gold":          0xA67C1E,
    "ember":         0x9C7E3C,
    "ringConnected": 0xA08C66,   # provisional - being retuned concurrently
    "caution":       0xB3701C,
    "failure":       0xBB3A2F,
    "faderThumb":    0x8A7A62,
    "faderRim":      0x9E8D6B,
}

# macOS stock light label colours are black at fixed alphas.
MAC_TEXT = {"label": 0.85, "secondaryLabel": 0.50, "tertiaryLabel": 0.26}
# iOS companion authored inks.
IOS_TEXT = {"label": 0x1E1C1C, "label2": 0x706464, "label3": 0x5F5A54}

FLOOR_SURFACE = 1.10   # MembershipWellContrastTests
FLOOR_SEP = 1.25       # separator
FLOOR_INSTRUMENT = 3.0  # WCAG 1.4.11
FLOOR_BODY = 4.5


def mark(v, floor):
    return "PASS" if v >= floor - 5e-3 else "FAIL"


def surfaces_table(name, g):
    print(f"\n### {name}")
    print(f"  canvas {h(g['canvas'])}  canvasHi {h(g['canvasHi'])}  panel {h(g['panel'])} "
          f" raised {h(g['raised'])}  well {h(g['well'])}  hairline {h(g['hairline'])}")
    print(f"  {'pair':28} {'ratio':>7}  {'floor':>6}  verdict")
    pairs = [
        ("canvas <-> panel", g["canvas"], g["panel"], FLOOR_SURFACE),
        ("panel <-> raised", g["panel"], g["raised"], FLOOR_SURFACE),
        ("panel <-> well", g["panel"], g["well"], FLOOR_SURFACE),
        ("raised <-> well", g["raised"], g["well"], FLOOR_SURFACE),
        ("canvas <-> well", g["canvas"], g["well"], FLOOR_SURFACE),
        ("panel <-> hairline", g["panel"], g["hairline"], FLOOR_SEP),
        ("canvas <-> hairline", g["canvas"], g["hairline"], FLOOR_SEP),
        ("well <-> hairline", g["well"], g["hairline"], FLOOR_SEP),
    ]
    for label, a, b, fl in pairs:
        r = ratio(a, b)
        print(f"  {label:28} {r:6.2f}:1  {fl:5.2f}  {mark(r, fl)}")


def content_table(g, platform="mac"):
    grounds = [(k, g[k]) for k in ("canvas", "panel", "raised", "well")]
    print(f"  {'instrument':14} " + "".join(f"{k:>10}" for k, _ in grounds) + "   worst")
    for iname, ihex in INSTRUMENTS.items():
        rs = [ratio(ihex, gv) for _, gv in grounds]
        worst = min(rs)
        print(f"  {iname:14} " + "".join(f"{r:9.2f} " for r in rs)
              + f"  {worst:5.2f} {mark(worst, FLOOR_INSTRUMENT)}")
    if platform == "mac":
        for tname, alpha in MAC_TEXT.items():
            rs = [ratio(over(0x000000, alpha, gv), gv) for _, gv in grounds]
            worst = min(rs)
            fl = FLOOR_BODY if tname != "tertiaryLabel" else 3.0
            print(f"  {tname:14} " + "".join(f"{r:9.2f} " for r in rs)
                  + f"  {worst:5.2f} {mark(worst, fl)}")
    else:
        for tname, thex in IOS_TEXT.items():
            rs = [ratio(thex, gv) for _, gv in grounds]
            worst = min(rs)
            fl = FLOOR_BODY if tname != "label3" else 3.0
            print(f"  {tname:14} " + "".join(f"{r:9.2f} " for r in rs)
                  + f"  {worst:5.2f} {mark(worst, fl)}")


W = 0xFBFBF9  # Circuit bg/normal - the flat near-white ground, held fixed

OPTIONS = {
    "00 baseline Mac (flat ground + hairline)": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xD0CDC3),
    "00b baseline iOS (stepped ladder)": dict(
        canvas=0xF4F2EA, canvasHi=0xF7F5EF, panel=0xFCFBF7, raised=0xFFFFFF,
        well=0xEDEAE0, hairline=0xD0CDC3),
    "01 hairline only, stronger edge": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xC4C0B4),
    "01b hairline only, two weights (container edge)": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xB8B3A6),
    "02 recess-led, well as today": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xD0CDC3),
    "02b recess-led, deeper well": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xDEDACD, hairline=0xD0CDC3),
    "02c recess-led, deepest well that keeps gold >= 3:1": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE6E3D8, hairline=0xD0CDC3),
    "03 shadow elevation (fills unchanged)": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xD0CDC3),
    "04 inset geometry (fills unchanged)": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xD0CDC3),
    "05 hairline + inset + recess (combination)": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE6E3D8, hairline=0xC4C0B4),
    "06 iOS adopts the flat ground + stronger hairline": dict(
        canvas=W, canvasHi=W, panel=W, raised=W, well=0xE8E6DC, hairline=0xC4C0B4),
}


def well_window():
    """The well is squeezed from BOTH sides. Solve for the legal band."""
    print("\n\n== THE `well` IS SQUEEZED FROM BOTH SIDES ==")
    print("  Lighter than the upper bound -> fails the 1.10:1 surface floor.")
    print("  Darker than the lower bound  -> gold drops under the 3:1 instrument floor.")
    print("  Sweeping a neutral greige ramp off the ground #FBFBF9:")
    print(f"  {'well':>9}  {'vs ground':>10}  {'gold':>6}  {'raised/well':>12}  window")
    lo_ok, hi_ok = None, None
    for step in range(0, 40):
        # walk the Circuit greige direction: -1 R, -1 G, -1.4 B per step
        r = 0xFB - step
        g = 0xFB - step
        b = 0xF9 - int(round(step * 1.45))
        wv = (max(r, 0) << 16) | (max(g, 0) << 8) | max(b, 0)
        sep = ratio(wv, W)
        gd = ratio(INSTRUMENTS["gold"], wv)
        rw = ratio(W, wv)  # raised is the same white as the ground
        ok = sep >= FLOOR_SURFACE and gd >= FLOOR_INSTRUMENT and rw >= 1.15
        if ok and lo_ok is None:
            lo_ok = wv
        if ok:
            hi_ok = wv
        if step % 2 == 0 or ok:
            print(f"  {h(wv):>9}  {sep:9.3f}:1  {gd:5.2f}  {rw:11.3f}:1  "
                  f"{'LEGAL' if ok else ''}")
    print(f"\n  Legal band for `well`: {h(lo_ok)} .. {h(hi_ok)}  "
          f"({ratio(lo_ok, W):.3f}:1 .. {ratio(hi_ok, W):.3f}:1 off the ground)")
    print("  Today's shipping well #E8E6DC sits at 1.208:1 - already inside it,")
    print("  near the middle. There is roughly a tenth of a contrast point of")
    print("  travel in the whole mechanism. Recession cannot carry the model.")


def hairline_roles():
    """Two weights of the SAME mechanism: container edge vs internal divider."""
    print("\n\n== ROLE-DIFFERENTIATED HAIRLINE (the proposed answer) ==")
    print("  Nothing in this app is ever DRAWN ON a hairline - it is only ever")
    print("  a 1pt stroke or divider fill. So moving it costs zero instrument")
    print("  contrast and zero text contrast. It is the only free lever here.")
    print(f"  {'role':22} {'hex':>9}  {'vs ground':>10}  {'vs well':>9}  floor  verdict")
    for role, hv in (("container edge", 0xC4C0B4), ("internal divider", 0xD0CDC3)):
        rg, rw = ratio(hv, W), ratio(hv, 0xE8E6DC)
        print(f"  {role:22} {h(hv):>9}  {rg:9.3f}:1  {rw:8.3f}:1  {FLOOR_SEP:5.2f}"
              f"  {mark(min(rg, rw), FLOOR_SEP)}")
    print("\n  Edge:divider luminance-step ratio (how legible the NESTING cue is):")
    for a, b in ((0xC4C0B4, 0xD0CDC3), (0xB8B3A6, 0xD0CDC3)):
        print(f"    {h(a)} over {h(b)}: {ratio(a, b):.3f}:1")


def shadow_study():
    print("\n\n== 03 SHADOW STUDY: black at alpha over the flat ground #FBFBF9 ==")
    print("  A shadow separates WITHOUT moving any fill, so it costs text nothing.")
    print("  Question is only: what alpha reaches the 1.10:1 surface floor, and")
    print("  is that alpha still invisible as a grey smudge?")
    print(f"  {'alpha':>6}  {'composited':>11}  {'ratio vs ground':>16}  verdict")
    for a in (0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.12, 0.15, 0.20, 0.40):
        c = over(0x000000, a, W)
        r = ratio(c, W)
        print(f"  {a:6.2f}  {h(c):>11}  {r:15.3f}:1  {mark(r, FLOOR_SURFACE)}")
    print("\n  Peak (darkest) pixel only. A Gaussian-blurred shadow's peak is a")
    print("  fraction of the nominal alpha, so the ACTUAL contrast is lower still.")
    print("  Rough peak factors for a shadow of blur radius r offset by dy:")
    for blur, dy, factor in ((4, 1, 0.42), (8, 2, 0.30), (17, 4, 0.17)):
        for a in (0.10, 0.20, 0.40):
            eff = a * factor
            c = over(0x000000, eff, W)
            print(f"    blur {blur:2}pt dy {dy}  nominal {a:.2f} -> peak {eff:.3f} "
                  f"= {h(c)}  {ratio(c, W):.3f}:1  {mark(ratio(c, W), FLOOR_SURFACE)}")


def well_sweep():
    print("\n\n== 02 RECESS SWEEP: how deep can the well go before gold breaks? ==")
    print("  Gold #A67C1E is the binding instrument (it fills the bus node drawn")
    print("  inside well-filled GroupedSectionViews).")
    print(f"  {'well':>9}  {'vs ground':>10}  {'gold':>7}  {'ember':>7}  {'ring':>7}"
          f"  {'faderThumb':>11}  verdict")
    for wv in (0xEDEAE0, 0xE8E6DC, 0xE6E3D8, 0xE3E0D4, 0xDEDACD, 0xD8D3C4,
               0xD0CDC3, 0xC8C3B4):
        sep = ratio(wv, W)
        g = ratio(INSTRUMENTS["gold"], wv)
        e = ratio(INSTRUMENTS["ember"], wv)
        rc = ratio(INSTRUMENTS["ringConnected"], wv)
        ft = ratio(INSTRUMENTS["faderThumb"], wv)
        worst = min(g, e, rc, ft)
        print(f"  {h(wv):>9}  {sep:9.3f}:1  {g:6.2f}  {e:6.2f}  {rc:6.2f}"
              f"  {ft:10.2f}  {mark(worst, FLOOR_INSTRUMENT)}"
              f"{'  (surface floor FAIL)' if sep < FLOOR_SURFACE else ''}")


def hairline_sweep():
    print("\n\n== 01 HAIRLINE SWEEP: separator contrast on the flat ground ==")
    print(f"  {'hairline':>9}  {'vs ground':>10}  {'vs well #E8E6DC':>16}  verdict")
    for hv in (0xE7E6DF, 0xD8D5CB, 0xD0CDC3, 0xC9C5B9, 0xC4C0B4, 0xBCB7A9,
               0xB8B3A6, 0xB0AB9C, 0xA8A294):
        r = ratio(hv, W)
        rw = ratio(hv, 0xE8E6DC)
        print(f"  {h(hv):>9}  {r:9.3f}:1  {rw:15.3f}:1  {mark(r, FLOOR_SEP)}")


if __name__ == "__main__":
    print("=" * 78)
    print("LIGHT-MODE SURFACE SEPARATION - measured (WCAG 2.x relative luminance)")
    print("Floors: surface 1.10:1 | separator 1.25:1 | instrument 3:1 | body 4.5:1")
    print("=" * 78)
    for name, g in OPTIONS.items():
        surfaces_table(name, g)
        plat = "ios" if "iOS" in name else "mac"
        print(f"  -- content on those grounds ({plat}) --")
        content_table(g, plat)
    hairline_sweep()
    well_sweep()
    shadow_study()

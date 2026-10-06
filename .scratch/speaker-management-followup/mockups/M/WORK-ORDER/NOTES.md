# WORK-ORDER mockup: the Speakers tab as work-order-M.md builds it

`mockup.html` is one file; `#light` or `#dark` on the URL picks the theme. `mockup.png` and `mockup-dark.png` are headless Chrome at 2x, window 1560 × 3879.

Panels: 1 main window after the search, Overview selected (steps 7–12, 15, 20–22). 2 six Overview states (steps 18, 20–23). 3a Sonos Move shaped, 3b TV flat, 3c isaac on the can't-be-found list, 3d isaac before the list fills (steps 25–27). 4 Main Audio in cool greys (step 28). 5 selected rows on both pills (steps 11, 14). 6 Forget menu and sheet (steps 13, 32).

Where the work order differs from FINAL or FINAL-GREEN-2, and what is drawn:
- Window 713 pt, not FINAL's 653; card 475, strip 447, kind tiles 92.4, Unavailable 77.4 (Verified facts).
- Header strip neutral as in FINAL-GREEN-2, not FINAL's traffic lights and icon-only tabs (Out of scope list).
- FINAL-GREEN-2's three open green touches are kept: Available and kind counts above 0 (step 22), the Pair plus (step 21), Ready and Connected (step 26). FINAL had none.
- Add-scene bar has no line above it (step 15); FINAL-GREEN-2 drew one.
- The moving highlight crosses the 503 pt pane (step 23); FINAL used 443.
- Dark plate fill is 5 % (step 11); FINAL used 4.25 %.
- Overview rows run counts, can't be found, Local Network, Bluetooth, Pair (step 21). FINAL's states already matched.
- Panel 5: FINAL said a selected unreachable row still speaks ", unavailable". ION Speaker is on the list, so under step 11 it speaks ", can't be found". That sentence is dropped.
- Panel 6: FINAL said a selection with nothing on the list beeps. Step 13 has no beep call, so the caption says no sheet opens. Sheet text is unchanged under step 32.
- 3c and 3d were drawn by no source. They follow `DeviceDetailViewController` (title-line summary, no Reset, the "Kept for when … is found again." note, `Forget “Name”…`) plus steps 25–27.
- 3c and 3d show the green equalizer mark on an unreachable speaker, because the mark follows the stored tone (`refreshEQTitleRow`). The work order leaves that as it is.
- Main Audio: pages-greys drew "+3 dB", blank readouts, a blue slider fill and an enabled Reset on a flat curve. This uses FINAL-GREEN-2's readouts and grey fill, and dims Reset as `MainOutDetailViewController.refreshResetEnabled` does.

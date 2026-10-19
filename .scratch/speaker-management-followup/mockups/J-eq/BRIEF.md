# J-eq: the detail page

**Changed from J.** The Equalizer opens by default in its `.well` with the shipped `EQEditorView` controls: Bass, Treble, Balance (L/R, "Center"), Loudness, Advanced folded. The title row adds a summary ("Flat" / "Bass 3 dB, Loudness on" / "4 bands set") and Reset, dimmed when flat. Kind and status fold into the subtitle ("AirPlay 2 · Available"). The Scenes and About titles go; one bare list holds Show in Mixer and Scenes as links.

**Mark is green.** `DeviceRowView.updateEQButton` fills the door with `Tokens.Color.equalizer` (#41B07A / #007835); DESIGN.md's gold seat is stale.

**Not applied.** The shipped sentence, wrapped (it truncates today); the summary ends "Not applied".

**Unavailable (Bedroom).** Editor live, since EQ is stored per speaker; a third sentence, "Not applied while Bedroom is unavailable", in the same slot.

**Can't be found (Study).** Summary only, "Kept for when Study is found again". Forget… sits in the 22 pt action band; its alert names the scene count. Today the pane hides the EQ without a live device; it needs the stored value.

**Open question.** Research ranked a collapsed row first; this opens it.

**Height, pt (571 between toolbar and footer).** 28 + identity 96 + 20 + title 22 + 6 + well 165 (14 + 20·3 + 16 + 8·4 + 29 + 14) + 20 + list 69 + 20 = 446. Spare 125 covers the "Not applied" sentence (36) and a Bluetooth Volume row (29). Advanced open adds ~182 and scrolls, as today.

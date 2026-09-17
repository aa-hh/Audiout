# Surface shell: cut the first-open wait, put the screen name where the title goes

Status: ready-for-agent
Closes: A2, A3

Owner's rulings, 2026-09-17.

- **A2 (P1)** `SurfaceSplashView.swift:37, 43`, `AppSurfaceController.swift:229-238, 410`
  — first open shows nothing for up to `revealCeiling` 0.6 s, then holds the mark over
  the mixer for `holdDuration` 0.7 s up to `ceilingDuration` 2.7 s, plus a 0.25 s fade.
  **Ruling:** the splash was meant to cover loading, not to be an entrance — cut it to
  whatever the loading actually needs. **First step is measurement:** find what the
  0.6 s deferral is hiding (discovery? first layout? row mount?) and how long it really
  takes on a cold launch. If the panel can open live with rows arriving under the
  user's cursor, delete `SurfaceSplashView` and the reveal deferral. If something
  genuinely cannot be shown yet, keep a hold no longer than that measurement and let
  every control stay live behind it. Record the measured number in the file.
- **A3** `SurfaceToolbar.swift:181, 486-517` — "Audiout" in ClashDisplay-Semibold 17 pt
  is pinned to the window centre line via `centeredItemIdentifiers`, where macOS puts
  the window title. **Ruling:** replace it with the current screen's name ("Mixer" /
  "Scenes" / "Settings"), keeping ClashDisplay-Semibold at 17 pt — same face, same
  weight, same position as the wordmark has now. No wordmark on the surface; identity
  stays with the menu-bar glyph, the status menu and About.

# Groups window (AudioutWindowUI) — scoping report

## What exists today
- Fixed split 210 sidebar + pane (SurfaceLayout.swift:13-21). Pane ground WarmPanelView panel fill. Popover beak bubble same token.
- Sidebar deliberately WARM: SidebarWarmSurfaceView.swift:106 sidebarWarmTint at 0.30 over Liquid Glass (macOS 26+) or opaque below / Reduce Transparency. Shared with Settings sidebar → two-screen decision.
- Pinned Groups row = plate raised + hairline at radius 8 (SidebarViewController.swift:749-753); trailing gold marker (:668) = sidebar's only gold.
- GroupedSectionView: .card = raised + containerEdge at 10; .bare = hairline dividers (:92-122). containerEdge ALREADY ON MAIN (merge 7111b425 + 3c483563) — nothing to fold in.
- Group cards DON'T use that container: own card raised + HAIRLINE stroke, gold stroke when live Main Out (GroupsOverviewViewController.swift:699-706). 17pt bare glyph, no seat (:600). Member chips iconSeatFill + containerEdge; dashed hairline overflow.
- Empty state text only + dashed "New Group" tile with hairline ring (:132-137, :864). Copy locked by test.
- GroupsPaneLayout = single geometric parity source (28/20/6/22/14; contentLeadingInset 38.5 half-point trap).
- DeviceIconWellView icon seat: iconSeatFill; edge gold (active Main Out) / ember (idle rail origin) / containerEdge; pencil badge; glyph tinted label.
- MembershipRowView: bare secondaryLabel glyph, no seat (:154); unavailable → inkTertiary.
- IconPicker: selected = 1.5pt gold RING at radius 7, others bare buttons no seat (IconPickerViewController.swift:255-266); preview tile canvas + hairline.
- Type stock; TEXT COLOUR FROZEN (GroupsWindowTextColorLockTests, 2026-07-25 decision). No shadows.
- Six radii: 10, 8, 7, 6, 12, 14.

## Where it breaks iOS rules
- Rule 1: sidebar permanently warm = navigation furniture saying "sounding".
- Light flat ground: raised #F2F0EA lifts by fill in light; iOS collapses raised into ground in light.
- "containerEdge on any card": four cards still stroke hairline (group card :704, new-group tile :864, sidebar plate :751, picker preview :531).
- No cool ink at all (idle names/glyphs warm/stock).
- Rule 4: no GroupIdentityGlow; partySignalDeep's only consumers are the sync wizard's reference plate.
- Group Row: iOS 44pt raised seat + containerEdge + labelCool glyph, live = 1.5pt gold ring on seat + gold 12% wash; Mac = no seat, live = whole border gold (edge doing a wash's job).
- Empty State: iOS = emitter field in "Dinner party" magenta ramp + GoldCTALabel.
- Icon picker inverted: iOS selected = gold FILL + inkOnFill, unselected = well + hairline + labelCool glyph.
- Editor member rows: iOS 24pt well+hairline tile + gold checkmark; Mac neither.
- Shapes: six radii vs three.

## Worth keeping
- GroupsPaneLayout parity enum.
- Flat light ground (already one hex).
- GroupedSectionView two-weight edge (= iOS pair; finish applying it).
- "Bordered + pencil = editable" (iOS cites it as the Mac's vocabulary).
- Membership rail gold/ember per-row truth (Mac-only, conformant).
- "Group your speakers" headline (identical to iOS).
- Device detail + Main Audio panes' stock treatment (iOS "don't dress Settings" reasoning).

## Options
### A: Cool the chassis, finish the edge rank — RECOMMENDED, Effort S
- DELETE SidebarWarmSurfaceView + both call sites (SidebarViewController:115, SettingsSidebarViewController:45); retire sidebarWarmTint. System sidebar material is already cool-neutral (#F0F0F0). Repoint four hairline cards → containerEdge. Collapse radii to three.
- Risk: SidebarWarmSurfaceTests (5) delete; GroupsWindowTextColorLockTests:96 + MembershipWellContrastTests:166 list sidebarWarmTint in banned arrays → must remove or won't compile. Loses the Reduce Transparency opaque path (served the tint).
- CONFLICT with Settings agent's "keep the warm sidebar" recommendation.
### B: A + iOS component grammar — viable, Effort L, AFTER tokens
- 44pt raised+containerEdge seat + cool glyph on group card; live = gold 12% wash + 1.5pt gold seat ring. Picker → filled gold / recessed well binary. 24pt glyph tile in MembershipRowView. Cool ink pair for idle names/glyphs.
- Needs cool light chassis first, or cool ink on warm greige reads as a mistake.
- Risk: GroupsWindowTextColorLockTests fails wholesale (exists to block exactly this); GroupsOverviewViewControllerTests:127 memberChipGlyphIsTintedLabel; AppSurfaceControllerTests width guard; MembershipRailTests aPinnedRowNeverResizesItself + seven-device scroll; IconPickerTests test_ringRefreshCount must keep firing.
- Deps: labelCool tokens; light ground hue; explicit ruling that frozen-text lock is superseded.
### C: B + magenta identity glow + emitter-field empty state — NOT one step, Effort XL
- Static radial partySignalDeep glow (22% dark / 10% light) behind every group seat; empty state = emitter field magenta ramp + gold CTA. Metal EmitterFieldView must MOVE from OnboardingUI to SharedUI + take a ramp parameter (Package.swift).
- Glow cheap + rule-bearing; field move is its own task after B.

## Specific answers
- containerEdge: on main; apply consistently (4 sites).
- Detail panes: bare fact rows follow iOS PanelRow (panel card, containerEdge, drawn as content background); identity header = iOS editor header (already matches minus glyph tint); EQ card has no iOS counterpart → keep .card, bound by containerEdge + no shadow.
- Icon seat glow: iOS says yes; but Mac magenta already = wizard reference speaker ("names WHICH speaker") → two identity subjects. Not resolved.
- Creation sheet + picker map cleanly; picker gold stops being "the one exception" (iOS blesses gold for selection).
- window-snapshot: 14 PNGs in dev/notes/window-snapshots/ are REVIEW ARTEFACTS, no test reads them → visual change breaks NO test, silently stales images. Cannot regenerate on macOS 27 (NSVisualEffectView fills opaque under displayIgnoringOpacity; fix c985e661 on claude/snapshot-light-on-dark-host unmerged). Executor: state folder is stale in PR, don't run tool, Alec's eye = only verification.

## Open questions
1. Magenta: group identity (iOS) vs wizard reference plate vs both ("which one, never what state") vs decline the glow?
2. Frozen-text-colour lock (GroupsWindowTextColorLockTests, 2026-07-25) vs temperature rule (ink carries state) — superseded for Groups, or keep stock ink?
3. Sidebar tint shared with Settings: drop on both, or Groups alone?

## Files touched
SharedUI: SidebarWarmSurfaceView, Tokens, WarmPanelView, MembershipBusView. SettingsUI: SettingsSidebarViewController. WindowUI: SidebarViewController, GroupsOverviewViewController, GroupedSectionView, GroupsPaneLayout, GroupEditorViewController, GroupCreationSheetController, IconPickerViewController, MembershipRowView, DeviceIconWellView, DeviceDetailViewController, MainOutDetailViewController, AGENTS.md. (C) OnboardingUI/EmitterFieldView → SharedUI, Package.swift. Tests: GroupsWindowTextColorLockTests, MembershipWellContrastTests, SidebarWarmSurfaceTests, GroupsOverviewViewControllerTests, GroupsHeaderParityTests, MembershipRailTests, IconPickerTests. dev/notes/window-snapshots/ stale.

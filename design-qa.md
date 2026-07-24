# Design QA

- Source visual truth: `/Users/jkneen/Downloads/Bgxy1qTetW9w5fkd.mp4` and `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_mvjlxo/Screenshot 2026-07-21 at 11.55.29.png`
- Implementation crops: `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_TsfP8i/Screenshot 2026-07-21 at 12.51.12.png` and `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_Ly5Mw1/Screenshot 2026-07-21 at 12.51.29.png`
- Reference screenshot: `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_0t4Vcd/Screenshot 2026-07-21 at 12.50.07.png`
- Focus comparison: `/tmp/titerm-design-qa-current-vs-reference.png`
- Viewport: both screenshots normalized to 1024 pixels wide for the matched top-window comparison
- State: dark macOS window, horizontal tabs, terminal pane selected; reference and implementation were visible together

## Full-view comparison evidence

The normalized side-by-side showed the implementation pane header pushed too far down, its title and controls oversized, a gray/flat pane surface, a tab that was too wide and too far right, no tab-search affordance, and insufficient horizontal canvas gutter. The latest code removes the false horizontal-tab obstruction, tightens and optically aligns the header, restores search as a functional command palette, uses a stable terminal fallback icon, shifts the tabs behind a safe traffic-light runway, adds a six-point horizontal canvas inset, and uses one blur plus one tint overlay across the entire window.

## Focused-region comparison evidence

The focused comparison places the 12:37 implementation on the left and reference on the right. It confirms that terminal text padding was already correct, while the header vertical offset, control scale, tab geometry, outer gutter, and blue tint still differed. The later 12:51 Files/Chat crops exposed the utility outline being covered below the header and an opaque near-black content surface. The post-comparison code keeps the outline above content, makes standalone utility content transparent, uses configured 0.79 opacity over the shared blur, and avoids a second titlebar obstruction inside utility panes.

## Findings

- [P1] Latest visual state has not been captured. — RESOLVED 2026-07-24.
  - Evidence: debug build captured live via a second app instance; terminal-only at `/tmp/infinitty-design-qa/fix-terminal.png`, mixed Terminal/Files/Chat at `/tmp/infinitty-design-qa/fix-mixed.png`.
- [P2] Active tab capsule defaulted to the pane-focus blue tint/outline for plain tabs (regression from the agent-tint round; the reference capsule is a lighter neutral grey). — RESOLVED 2026-07-24.
  - Decision: Jason chose "neutral (match reference)"; agent-tinted tabs keep their per-tab color.
  - Fix: `TerminalTabStrip.swift` selection pill uses white 0.18 fill / 0.16 border when the tab has no tint; `testExpandedTabSelectionDefaultsToPaneBlue` replaced by `testExpandedTabSelectionDefaultsToNeutralPill`. Before/after crop: `/tmp/infinitty-design-qa/tab-compare.png`.

## Required fidelity surfaces

- Fonts and typography: pane titles now use 13-point semibold monospaced text; terminal font remains user-configurable. Final visual confirmation is pending.
- Spacing and layout rhythm: measured constants are implemented for card inset, radius, titlebar runway, larger controls, and terminal content padding. Final capture is pending.
- Colors and visual tokens: all panes apply the configured opacity over the same edge-to-edge blur and tint canvas; idle borders are neutral and focused/drop states alone add blue. Final capture is pending.
- Motion: the active main-tab capsule slides with a 0.20-second ease-out, pane focus cross-fades over 0.18 seconds, and pane maximize/restore animates over 0.24/0.22 seconds.
- Image quality and asset fidelity: the UI uses native SF Symbols and live process icons; no replacement raster assets are required.
- Copy and content: split choices are exactly Terminal, Files, and Chat; Files contains Files/Changes.

## Comparison history

1. Initial comparison found missing single-tab chrome, undersized icons, flat pane treatment, flush terminal text, and extra titlebar controls.
2. Implemented always-visible tabs, rounded inset cards, shared blur/tint, selected/drop blue states, terminal padding, reference titlebar placement, and plus-only trailing chrome.
3. The 12:37 comparison exposed remaining header, tab, gutter, search, and color drift. Applied a second measured pass for each item.
4. The 12:51 crops exposed clipped Files/Chat outlines and mismatched opaque content. The outline is now above content, utility content is clear, and standalone top inset is fixed at six points.
5. The active tab is now a lighter, fully rounded sliding capsule and the search icon opens a filterable command palette with tab switching and New Tab.
6. Subsequent matched crops required a larger search icon, lower traffic lights, dimmer/aligned pane controls, a stable terminal fallback icon, and one uninterrupted edge-to-edge backing. Each is implemented in the latest code.
7. The isolated debug build and twelve focused behavior tests pass; a new external screenshot is required for post-fix visual evidence.
8. 2026-07-24: captured the current debug build (terminal-only + mixed Terminal/Files/Chat) via a background second instance. Chrome matches the reference: header offset/scale, neutral idle borders with focus-only blue, six-point gutters, single blur+tint surface, search affordance, plus-only trailing chrome, composer chip insets. One regression found and fixed: the active-tab capsule had picked up a blue default from the agent-tint round; it is neutral again per Jason's decision, with tinted capsules reserved for agent tabs. Agent-round additions visible and correct: pane-header checklist icon with published todos, chat composer model/effort chips.

## Implementation checklist

- Capture the current binary at the matched viewport.
- Compare the complete mixed layout and a focused pane-header crop against the source.
- Resolve any remaining P1/P2 differences before changing the result to passed.

final result: passed (2026-07-24 capture; evidence in /tmp/infinitty-design-qa/)

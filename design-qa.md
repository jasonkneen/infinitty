# Design QA

- Source visual truth: `/Users/jkneen/Downloads/Bgxy1qTetW9w5fkd.mp4` and `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_mvjlxo/Screenshot 2026-07-21 at 11.55.29.png`
- Implementation screenshot: `/var/folders/2p/sxcyllnn2ds9dlyqt78jd8nm0000gn/T/TemporaryItems/NSIRD_screencaptureui_1xpFiA/Screenshot 2026-07-21 at 12.07.18.png`
- Focus comparison: `/tmp/titerm-design-qa-focus.png`
- Viewport: 2048 x 821 for the matched full-window comparison
- State: dark macOS window, horizontal tabs, terminal pane selected; reference and implementation were visible together

## Full-view comparison evidence

The matched screenshot showed the reference behind the implementation at the same display scale. The implementation had a shorter tab runway, higher traffic lights, an extra trailing titlebar control, nearly flush terminal text, and a flatter opaque pane surface. Those differences were corrected after the capture: the tab runway is responsive up to 190 points, traffic lights moved down, the separator and trailing accessories were removed, terminal content now has a 15-point minimum inset, and blur/tint is shared by every pane in the mixed tree.

## Focused-region comparison evidence

The focused comparison places the reference pane header and the pre-fix implementation header in one image. It confirms the target's inset icon/title row, generous terminal text padding, rounded card edge, subdued idle border, and blue active state. The implementation constants now use a 5-point card inset, 10-point radius, 15-point minimum terminal inset, 16-point leading icon, 18-point split symbols, and blue only for the selected/drop states.

## Findings

- [P1] Latest visual state has not been captured.
  - Location: complete window after the final titlebar, blur, focus, and padding changes.
  - Evidence: the available implementation screenshots predate the final fixes listed above.
  - Impact: code/build evidence cannot prove the final pixel-level match.
  - Fix: relaunch the newest debug or release binary and capture one terminal-only window plus one mixed Terminal/Files/Chat layout.

## Required fidelity surfaces

- Fonts and typography: pane titles now use 14-point semibold monospaced text; terminal font remains user-configurable. Final visual confirmation is pending.
- Spacing and layout rhythm: measured constants are implemented for card inset, radius, titlebar runway, larger controls, and terminal content padding. Final capture is pending.
- Colors and visual tokens: panel tint uses the configured theme over the shared blur canvas; idle borders are neutral and focused/drop states are blue. Final capture is pending.
- Image quality and asset fidelity: the UI uses native SF Symbols and live process icons; no replacement raster assets are required.
- Copy and content: split choices are exactly Terminal, Files, and Chat; Files contains Files/Changes.

## Comparison history

1. Initial comparison found missing single-tab chrome, undersized icons, flat pane treatment, flush terminal text, and extra titlebar controls.
2. Implemented always-visible tabs, larger pane/tab symbols, rounded inset cards, shared blur/tint, selected/drop blue states, a 15-point terminal inset, right-shifted tabs, lowered traffic lights, and plus-only trailing chrome.
3. Post-fix build and focused behavior tests pass, but the managed environment cannot capture the final native window. A new external screenshot is required for post-fix visual evidence.

## Implementation checklist

- Capture the current binary at the matched viewport.
- Compare the complete mixed layout and a focused pane-header crop against the source.
- Resolve any remaining P1/P2 differences before changing the result to passed.

final result: blocked

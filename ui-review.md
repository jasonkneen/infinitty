# Chat Pane UI Review — Vertical Real Estate Audit

Joint report by Fable (Claude) and Sol (Codex), 2026-08-05.

Scope: the built-in Chat interface — AppKit chrome in titerm (`UtilityPaneView`,
`PaneHeaderView`) and the SwiftUI panel in the sibling ShadKit checkout
(`AIAssistantPanel`, `AssistantRunDeck`). No Swift source files were edited;
this is a proposal document.

---

## 1. Current top-of-pane stack (before the first message is visible)

| # | Element | File | Height |
|---|---------|------|--------|
| 1 | Pane top inset + `PaneHeaderView` + content gap | `titerm/Sources/InfinittyKit/PaneChrome.swift:103-119`, `UtilityPaneView.swift:185-208` | **44pt** (6 + 32 + 6) |
| 2 | `AssistantRunStatusStrip` + separator | `titerm/Sources/InfinittyKit/ShadcnAssistantHost.swift:260-280,356-405` | **~33pt** |
| 3 | `threadBar` + separator — thread title/switcher + **second** "+" button | `ShadKit/Sources/AIElementsUI/AssistantPanel.swift:317-346` | **45pt** |
| 4 | `rosterBar` + separator — "Agents" label + agent chips | `ShadKit/Sources/AIElementsUI/AssistantPanel.swift:348-374` | **37pt** |

The 44pt thread row is not 28pt: its `.iconSM` New Chat button is 32pt tall
and receives 6pt padding above and below. The normal single-agent top stack is
therefore approximately **159pt from the pane's outer top edge to the
transcript**, or **147pt of visible control rows** when the two 6pt AppKit
insets are excluded.

The resting composer independently consumes approximately **118pt**. The
transcript then adds 16pt top/bottom insets and 32pt between top-level message
items.

## 2. Redundancy findings

1. **Duplicate "+ new chat"** — `UtilityPaneView` puts one in the 32pt pane
   header (`UtilityPaneView.swift:120-133`), and `threadBar` renders another
   because `showsHeader == false` (`AssistantPanel.swift:336-342`). One can go.
2. **Duplicate mode indicator** — the status strip's "CHAT/TERMINAL" text
   (`modeLabel`) repeats what the composer's chat/terminal segmented
   `modeControl` already shows.
3. **Model + effort shown twice** — the status strip shows model & "Effort X";
   the composer pickers show the same selections ~200px lower.
4. **Roster bar shows for a single agent** — condition is
   `!model.roster.isEmpty`; with one agent it still consumes 37pt. The chip is
   not purely informational, however: it is also the agent's enable/disable
   control and must remain reachable in any compact replacement.
5. **Status strip is always visible** — even at READY/idle it burns a row to
   say "READY".

## 3. Agreed change plan

### P1 — Merge the status strip into the thread bar (~45pt saved)

One combined adaptive row: thread title · activity badge · usage. Model,
effort, and mode labels drop out entirely (already shown in the composer).
Optionally, when idle (`phase == .ready`) the activity badge can hide, letting
the row shrink further.

The two bars currently live in different modules and are private, so this
needs a proper ShadKit top-bar/accessory API rather than copying
thread-selection logic into titerm. The existing thread-selection callback
(`AssistantPanel.swift:306`) and per-thread tool reset
(`ShadcnAssistantHost.swift:530`) must remain intact.

Risk: `AssistantRunStatusSnapshot` has focused tests (`accessibilityValue`,
`visibleTokenLabel`) — merging the strip must keep the snapshot type intact.
The merged row must also keep approval, active-tool, failure, queue, usage,
cost, and enabled-agent state; these are not duplicated elsewhere. Preserve
horizontal overflow behavior so status text cannot displace the thread
switcher.

Do not apply the status strip's current
`.accessibilityElement(children: .combine)` to a row containing a thread
picker or buttons; VoiceOver must continue to expose those as separate
actions.

### P2 — Remove the duplicate New Chat control (presentation-aware)

Titerm's utility pane already supplies one (`UtilityPaneView.swift:120`). Do
not remove the ShadKit button globally: popover, standalone, and legacy
presentations can depend on it. Each presentation should expose exactly one
accessible New Chat control. Use an explicit presentation/configuration flag
such as `hasExternalNewChatAction`, and retain the legacy fallback covered by
`INFINITTY_LEGACY_CHAT=1`.

### P3 — Collapse the roster into the combined top bar (~37pt saved)

Use an "Agent" / "2 agents" menu or chip instead of a dedicated row. Merely
hiding the row when `roster.count == 1` is **unsafe**: the chip is the only
enable/disable control, and the runtime explicitly tells users to click it to
re-enable a disabled agent (`ChatEnsemble.swift:55`). At minimum, any
visibility rule must preserve disabled-agent recovery. A compact menu is
cleaner and saves the full row. Drop the "Agents" label either way — chips
are self-describing.

### P4 — Titerm-specific compact transcript metrics (16pt per turn gap)

`ShadKit/Sources/AIElementsUI/Conversation.swift:29` uses 32pt between every
message and 16pt around the transcript. Make those configurable and use
~16pt turn spacing in `AIAssistantPanel` — saves **16pt per message gap**.

User and attributed-agent bubbles use 12pt vertical padding
(`Message.swift:84`); reducing to 8pt saves another **8pt per bubble**. Keep
ShadKit's public defaults unchanged so galleries and other consumers do not
unexpectedly become denser.

Persisted timestamps/actions add at least 30pt beneath assistant messages
(`Chatbot.swift:90`). Hover/overlay metadata could reclaim this later, but it
needs careful keyboard and VoiceOver handling.

### P5 — Compact the composer (~24pt saved)

Outer-padding change alone (`top x3→x2, bottom x4→x2_5`) saves ~10pt. A
fuller local adjustment — 8pt outer top/bottom, 4pt footer padding, and a
30pt editor — reduces the resting composer from roughly **118pt to 94pt**.

Constraints: do not shrink typography; retain fixed sizing/layout priority
and enough room for the overlaid 28pt Chat/Terminal control
(`AssistantPanel.swift:618`). Moving that control into the footer would
permit further compaction.

### P6 — Keep the shared AppKit pane header at 32pt for now

Reducing it to 28pt saves only 4pt but requires resizing/repositioning the
30pt New Chat button, 28pt Channel connector, and shared controls
(`PaneChrome.swift:1296`, `UtilityPaneView.swift:207`).

Hosting the SwiftUI status inside this AppKit header is **not recommended**:
it would complicate popover/standalone status, pane dragging,
rename/context-menu event handling, narrow-width layout, and accessibility.
An `NSHostingView` covering the title region could capture the mouse events
used for dragging, rename, zoom, and context menus. If this direction is ever
revisited, it needs an explicit drag region or event forwarding.

Related a11y bug found: the header announces every title as "Terminal pane,"
including Chat (`PaneChrome.swift:1105`).

### P7 — Optional small AppKit cleanup

The utility layout subtracts the top inset on both sides of the
header/content boundary. If that 6pt breathing gap is not intentional, it can
be removed independently (`UtilityPaneView.swift:198`).

## 4. Expected result

For the common single-thread chat:

- Combined/adaptive top bar: **~45pt saved**
- Roster collapsed into menu: **~37pt saved**
- Composer compaction: **~24pt saved**
- Transcript spacing: **16pt saved per turn gap**
- Bubble padding: **8pt saved per padded message**

The fixed top area can realistically fall from approximately **159pt to
76pt**, reclaiming about **80pt** before message-density improvements. In an
idle, single-thread state where the adaptive row can disappear entirely, the
saving approaches **115pt** — with no information genuinely lost (everything
removed is duplicated elsewhere or foldable into a menu).

## 5. Correctness issue discovered (separate from space work)

`ShadKit/Sources/AIElementsUI/Conversation.swift:15` initializes `isAtBottom`
to `true`, but the offset preference callback at line 68 does nothing. As
written, streaming always scrolls to the bottom and the "jump to latest"
button can never appear. Repair this when modifying conversation layout.

## 6. Required regression coverage

- Exactly one accessible New Chat action in utility-pane, popover, standalone,
  and legacy presentations; activating it must create/select the new thread.
- A disabled sole agent remains visible and can be re-enabled.
- Ready state can compact or hide, while queued, thinking, tool use, approval,
  tool/run failure, usage, and cost remain visible and accessible.
- Thread switching still invokes `onSelectThread` and clears per-thread tool
  state correctly.
- At compact header sizes, every AppKit control frame remains within
  `paneHeader.bounds` and is pressable.
- A 320×500 hosted panel keeps a multiline transcript, composer, mode control,
  and footer visible.
- Conversation pinning respects manual history scrolling and makes the
  jump-to-latest action reachable.

## 7. Validation status

- No Swift source files were edited during this review; only this report was
  created.
- ShadKit: 30 focused tests passing.
- Titerm: selected run reported 136 passes and one pre-existing failure
  (`Tests/InfinittyKitTests/NavigationTests.swift:2012`); the focused
  chat/status/model suites passed.
- Note: changes span two repos (titerm + `../ShadKit` path dependency), so
  both must build together.

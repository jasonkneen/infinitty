# Scope: native SwiftUI canvas (ReactFlow-equivalent) for ShadcnAIKit

**Status:** proposal, nothing built.
**Date:** 2026-07-29

## Why this is a project, not a component port

The seven AI Elements canvas files total ~5 KB and contain almost no logic —
they are Tailwind skins over `@xyflow/react`:

| File | What it actually does |
|---|---|
| `canvas.tsx` | Sets 6 props on `<ReactFlow>` and adds `<Background>` |
| `node.tsx` | A shadcn `Card` with `<Handle>` on left/right |
| `edge.tsx` | Two edge renderers using `getBezierPath` / `getSimpleBezierPath` |
| `connection.tsx` | One cubic path + a circle, drawn while dragging |
| `controls.tsx`, `panel.tsx`, `toolbar.tsx` | Restyle `Controls` / `Panel` / `NodeToolbar` |

Everything they lean on — the viewport, the interaction model, node/edge state,
handle geometry, path maths, hit testing — is ReactFlow. Porting the skin is a
day. Porting what it stands on is the work, and it is the only way to get the
"inheritable, customisable, all kinds of custom nodes" behaviour asked for.

## Layering

Each layer is independently testable and useful on its own.

```
5  AIElementsCanvas   Node card chrome, Edge.Animated/.Temporary, Connection, Controls, Panel, Toolbar
4  CanvasChrome       Controls, Panel, MiniMap, NodeToolbar, NodeResizer
3  CanvasRendering    Background, edge layer, node layer, selection/marquee overlay
2  CanvasInteraction  Pan, zoom, node drag, marquee select, connect gesture, keyboard
1  CanvasGeometry     Transforms, edge path builders, handle anchors, bounds, fitView
0  CanvasModel        CanvasNode, CanvasEdge, Viewport, changes, connection validation
```

Ships as a fourth library product, `CanvasUI`, depending only on `ShadcnUI`, so
consumers who don't want a graph editor don't pay for it.

## Layer 0 — model

Mirrors ReactFlow's shape so ported code reads the same (per the standing
"same interfaces" preference).

```swift
public struct CanvasNode<Data>: Identifiable {
    public var id: String
    public var type: String            // key into the node registry
    public var position: CGPoint
    public var data: Data
    public var size: CGSize?           // measured after first layout
    public var isSelected: Bool
    public var isDraggable: Bool
    public var parentID: String?       // sub-flows / grouping
    public var zIndex: Int
}

public struct CanvasEdge: Identifiable {
    public var id: String
    public var source: String
    public var target: String
    public var sourceHandle: String?
    public var targetHandle: String?
    public var type: String            // "bezier" | "smoothstep" | "step" | "straight"
    public var isAnimated: Bool
    public var isSelected: Bool
    public var label: String?
    public var markerEnd: CanvasMarker?
}

public struct CanvasViewport: Equatable {
    public var translation: CGSize
    public var zoom: CGFloat           // clamped to minZoom...maxZoom
}
```

Changes follow ReactFlow's reducer model (`onNodesChange` +
`applyNodeChanges`) so callers own state:

```swift
public enum CanvasNodeChange {
    case position(id: String, CGPoint, isDragging: Bool)
    case select(id: String, Bool)
    case remove(id: String)
    case dimensions(id: String, CGSize)
    case add(CanvasNode<Data>)
}
```

**Nontrivial:** `dimensions` exists because edges cannot be routed until nodes
have measured themselves. First frame has no geometry; edges must degrade
rather than snap into place. Handled by deferring edge layout one pass and
animating in.

## Layer 1 — geometry

Pure functions, no views. The highest test-value layer.

- `bezierPath`, `simpleBezierPath`, `smoothStepPath`, `stepPath`,
  `straightPath` — direct ports of ReactFlow's `getXPath` helpers, including
  its control-point offset curve (`calculateControlOffset`), otherwise curves
  visibly differ.
- `handleAnchor(node:position:)` — the offset logic in `edge.tsx`'s
  `getHandleCoordsByPosition` (origin top-left, so Right adds full handle
  width). Reproduce exactly or arrowheads sit wrong.
- `fitView(nodes:padding:)`, `screenToFlow`, `flowToScreen`.

## Layer 2 — interaction (the hard part)

| Gesture | Notes |
|---|---|
| Pan | AI Elements sets `panOnDrag={false}, panOnScroll` — trackpad scroll pans, drag does marquee. Needs `NSEvent.scrollWheel`; SwiftUI has no scroll-delta gesture. |
| Zoom | Pinch + ⌘-scroll. `MagnificationGesture` is too coarse; needs `NSEvent.magnify` with anchor-preserving zoom about the cursor. |
| Node drag | Single and multi-select; snap-to-grid; must not fight the pan recogniser. |
| Marquee | `selectionOnDrag` — drag on empty canvas draws a selection rect. |
| Connect | Drag from a handle, live `Connection` line, valid-target highlighting, `isValidConnection`, drop-to-connect or cancel. |
| Keyboard | Delete/Backspace, ⌘A, arrow nudge. |

**Nontrivial:** an `NSViewRepresentable` event tap is required. SwiftUI cannot
express precise trackpad pan/zoom, and gesture priority between pan, marquee,
node drag and connect must be resolved in one place or they steal from each
other. This is where the schedule risk sits.

**Nontrivial:** text fields inside nodes. Any node containing an editable
control needs the canvas gestures to yield while it has focus, or typing gets
eaten. Solved with a focus-aware gesture gate.

## Layer 3 — rendering and performance

- **Edges in one `Canvas`** (`GraphicsContext`), not one `View` per edge. A few
  hundred `Path` views tanks SwiftUI; a single immediate-mode pass does not.
- **Nodes as real SwiftUI views**, positioned by `.offset`, so they can host
  arbitrary interactive content. Cull to the visible rect once node count is
  high.
- **Edge hit testing** against stroked paths (`path.contains` on an outset
  copy), since edges are drawn, not laid out.
- Background: dots / lines / cross variants, drawn in the same `Canvas`.

## Layer 4 — custom nodes (the extensibility ask)

Swift has no JSX, and subclassing `View` isn't a thing, so "inheritable" maps
onto **protocol + registry + composable chrome** — which gives the same result
with better type safety.

```swift
public protocol CanvasNodeView: View {
    associatedtype Data
    init(node: CanvasNode<Data>, context: CanvasNodeContext)
}

// Registry, the analogue of ReactFlow's `nodeTypes={{ custom: MyNode }}`
var registry = CanvasNodeRegistry<MyData>()
registry.register("prompt") { PromptNode(node: $0, context: $1) }
registry.register("tool")   { ToolNode(node: $0, context: $1) }
```

Custom nodes compose the same chrome AI Elements' `node.tsx` provides, so they
inherit the look for free and override only what they need:

```swift
struct PromptNode: CanvasNodeView {
    let node: CanvasNode<MyData>
    let context: CanvasNodeContext

    var body: some View {
        CanvasNodeCard(handles: .init(target: true, source: true)) {
            CanvasNodeHeader {
                CanvasNodeTitle(node.data.title)
                CanvasNodeDescription(node.data.subtitle)
            } action: {
                ShadcnButton(icon: ShadcnIcon.dotsHorizontal, size: .iconXS) {}
            }
            CanvasNodeContentView {
                AIPromptInput(text: $text, onSubmit: {})   // fully interactive
            }
            CanvasNodeFooter { ShadcnBadge("ready", variant: .secondary) }
        }
    }
}
```

`CanvasNodeCard` is a straight port of `node.tsx` — shadcn `Card`, `w-sm`,
`rounded-md p-0`, header/footer `bg-secondary` with dividers, handles on left
and right. Handle count/position is configurable rather than the fixed
target-left/source-right pair the React version hardcodes.

Same pattern for edges (`CanvasEdgeRenderer`), so `Edge.Animated` and
`Edge.Temporary` are just two registered types.

## Phasing

Each phase ends somewhere demonstrable.

| Phase | Contents | Est. |
|---|---|---|
| 1 | Model + geometry + static render (no interaction). Gallery shows a fixed graph. | ~600 LOC |
| 2 | Pan/zoom/fitView via the event tap. Feels like a canvas. | ~700 LOC |
| 3 | Selection, node drag, marquee, delete. Editable. | ~600 LOC |
| 4 | Handles + connect gesture + validation. Graphs become authorable. | ~500 LOC |
| 5 | Chrome (Controls/Panel/MiniMap/Toolbar) + AI Elements skin + registry polish. | ~700 LOC |

**~3,100 LOC plus ~400 of tests.** Phases 1–2 are predictable; phase 2's event
tap and phase 4's gesture arbitration carry the uncertainty.

## What I would not build

- **Sub-flows / node grouping** (`parentId` nesting) unless asked — significant
  extra coordinate-space work for a feature the AI Elements demos don't use.
- **`NodeResizer`** — cheap to add later, not needed for AI graphs.
- **Undo/redo** — belongs to the host app's state, not the canvas.
- **SVG-accurate `animateMotion`** — the travelling dot in `Edge.Animated`
  becomes a `TimelineView` sampling the path, which is equivalent, not
  identical.

## Testability

Layers 0–1 are pure and get real coverage: path builders pinned against
ReactFlow's own output for fixed inputs, handle-anchor offsets, `fitView`
framing, change reducers. Layers 2–4 get harness screenshots of the sort used
for the rest of this port; gesture arbitration is verified by driving synthetic
`NSEvent`s rather than by eye.

## Recommendation

Worth doing if the canvas is a product surface (agent workflow graphs, v0-style
node editors). It is not worth doing to tick off the last seven AI Elements
files — those exist only to skin a library we would be writing from scratch.

If it goes ahead, build phases 1–3 first and reassess: a pannable, zoomable,
selectable graph with custom node content covers most of what an AI workflow
view needs, and phase 4's connect gesture is the point where cost climbs.

import { createRoot } from "react-dom/client";
import { useState } from "react";
import { defineCatalog } from "@json-render/core";
import { schema } from "@json-render/react/schema";
import {
  Renderer,
  JSONUIProvider,
  defineRegistry,
  useBoundProp,
  useAction,
} from "@json-render/react";
import { z } from "zod";

// Forward everything to the native side; the Swift bridge defines
// window.infinitty / webkit message handlers. Console fallback keeps the
// page debuggable in a plain browser.
const post = (message) => {
  try {
    if (window.infinitty) return window.infinitty.post(message);
    return window.webkit.messageHandlers.infinittyui.postMessage(message);
  } catch (_) {
    console.log("infinitty-ui-event", message);
  }
};

export const ACTION_NAMES = [
  "submit", "cancel", "select", "open", "run", "refresh", "custom",
];

const catalog = defineCatalog(schema, {
  components: {
    Stack: {
      props: z.object({
        direction: z.enum(["row", "column"]).nullish(),
        gap: z.number().nullish(),
        align: z.string().nullish(),
        wrap: z.boolean().nullish(),
      }),
      description: "Layout container; children flow row or column (default column)",
    },
    Card: {
      props: z.object({
        title: z.string().nullish(),
        description: z.string().nullish(),
      }),
      description: "Card container with optional title and description",
    },
    Text: {
      props: z.object({
        content: z.string(),
        variant: z.enum(["title", "heading", "body", "caption", "code"]).nullish(),
        color: z.string().nullish(),
      }),
      description: "A run of text",
    },
    Badge: {
      props: z.object({
        label: z.string(),
        tone: z.enum(["neutral", "accent", "success", "warning", "danger"]).nullish(),
      }),
      description: "Small status pill",
    },
    Button: {
      props: z.object({
        label: z.string(),
        action: z.string().nullish(),
        variant: z.enum(["primary", "secondary", "danger"]).nullish(),
      }),
      description: "Button; set `action` (or wire on.press) to notify the agent",
    },
    Input: {
      props: z.object({
        value: z.union([z.string(), z.record(z.string(), z.unknown())]).nullish(),
        label: z.string().nullish(),
        placeholder: z.string().nullish(),
      }),
      description: "Text input; bind value with { $bindState: \"/path\" }",
    },
    Checkbox: {
      props: z.object({
        checked: z.union([z.boolean(), z.record(z.string(), z.unknown())]).nullish(),
        label: z.string(),
      }),
      description: "Checkbox; bind checked with { $bindState: \"/path\" }",
    },
    Progress: {
      props: z.object({
        value: z.number(),
        label: z.string().nullish(),
      }),
      description: "Progress bar; value 0-1 (or 0-100)",
    },
    List: {
      props: z.object({}),
      description: "Vertical list container for ListItem children",
    },
    ListItem: {
      props: z.object({
        title: z.string(),
        subtitle: z.string().nullish(),
        done: z.boolean().nullish(),
      }),
      description: "List row with optional done state",
    },
    Metric: {
      props: z.object({
        label: z.string(),
        value: z.union([z.string(), z.number()]),
        delta: z.string().nullish(),
      }),
      description: "Big number with a label",
    },
    CodeBlock: {
      props: z.object({
        code: z.string(),
        language: z.string().nullish(),
      }),
      description: "Monospace code block",
    },
    Image: {
      props: z.object({
        src: z.string(),
        alt: z.string().nullish(),
        height: z.number().nullish(),
      }),
      description: "Image from an http(s) or data: URL",
    },
    Divider: {
      props: z.object({}),
      description: "Horizontal separator",
    },
  },
  actions: Object.fromEntries(ACTION_NAMES.map((name) => [
    name, { description: `Forwarded to the agent as a "${name}" ui event` },
  ])),
});

const { registry } = defineRegistry(catalog, {
  components: {
    Stack: ({ props, children }) => (
      <div
        style={{
          display: "flex",
          flexDirection: props.direction === "row" ? "row" : "column",
          gap: (props.gap ?? 10) + "px",
          alignItems: props.align ?? "stretch",
          flexWrap: props.wrap ? "wrap" : "nowrap",
        }}
      >
        {children}
      </div>
    ),
    Card: ({ props, children }) => (
      <section className="card">
        {props.title && <h3>{props.title}</h3>}
        {props.description && <p className="muted">{props.description}</p>}
        {children}
      </section>
    ),
    Text: ({ props }) => {
      const variant = props.variant ?? "body";
      if (variant === "code") return <code className="inline">{props.content}</code>;
      const Tag = variant === "title" ? "h2" : variant === "heading" ? "h4" : "p";
      return (
        <Tag
          className={variant === "caption" ? "muted caption" : undefined}
          style={props.color ? { color: props.color } : undefined}
        >
          {props.content}
        </Tag>
      );
    },
    Badge: ({ props }) => (
      <span className={`badge tone-${props.tone ?? "neutral"}`}>{props.label}</span>
    ),
    Button: ({ props, emit }) => {
      const dispatch = useAction(props.action ?? "custom");
      return (
        <button
          className={`btn ${props.variant ?? "secondary"}`}
          onClick={() => {
            emit("press");
            if (props.action) dispatch?.({ label: props.label });
          }}
        >
          {props.label}
        </button>
      );
    },
    Input: ({ props, bindings }) => {
      const [value, setValue] = useBoundProp(props.value, bindings?.value);
      return (
        <label className="field">
          {props.label && <span className="muted caption">{props.label}</span>}
          <input
            placeholder={props.placeholder ?? ""}
            value={value ?? ""}
            onChange={(event) => setValue(event.target.value)}
          />
        </label>
      );
    },
    Checkbox: ({ props, bindings }) => {
      const [checked, setChecked] = useBoundProp(props.checked, bindings?.checked);
      return (
        <label className="field row">
          <input
            type="checkbox"
            checked={!!checked}
            onChange={(event) => setChecked(event.target.checked)}
          />
          <span>{props.label}</span>
        </label>
      );
    },
    Progress: ({ props }) => {
      const fraction = props.value > 1 ? props.value / 100 : props.value;
      const percent = Math.min(Math.max(fraction, 0), 1) * 100;
      return (
        <div className="field">
          {props.label && <span className="muted caption">{props.label}</span>}
          <div className="track"><div className="fill" style={{ width: percent + "%" }} /></div>
        </div>
      );
    },
    List: ({ children }) => <div className="list">{children}</div>,
    ListItem: ({ props, children }) => (
      <div className="list-item">
        <span className={props.done ? "tick done" : "tick"}>
          {props.done ? "✓" : "○"}
        </span>
        <div>
          <div className={props.done ? "muted strike" : undefined}>{props.title}</div>
          {props.subtitle && <div className="muted caption">{props.subtitle}</div>}
          {children}
        </div>
      </div>
    ),
    Metric: ({ props }) => (
      <div className="metric">
        <div className="muted caption">{props.label}</div>
        <div className="metric-value">{props.value}</div>
        {props.delta && <div className="muted caption">{props.delta}</div>}
      </div>
    ),
    CodeBlock: ({ props }) => (
      <pre className="code"><code>{props.code}</code></pre>
    ),
    Image: ({ props }) => (
      <img
        src={props.src}
        alt={props.alt ?? ""}
        style={{ maxWidth: "100%", height: props.height ? props.height + "px" : "auto" }}
      />
    ),
    Divider: () => <hr />,
  },
});

const actionHandlers = Object.fromEntries(ACTION_NAMES.map((name) => [
  name, (params) => post({ type: "action", name, params: params ?? null }),
]));

function App({ spec }) {
  return (
    <JSONUIProvider
      registry={registry}
      initialState={spec.state ?? {}}
      handlers={actionHandlers}
      onStateChange={(changes) => post({ type: "state", changes })}
    >
      <Renderer spec={spec} registry={registry} />
    </JSONUIProvider>
  );
}

function Failure({ message }) {
  return <pre className="code">json-render error: {message}</pre>;
}

window.__hostState = "bundle-loaded";
const root = createRoot(document.getElementById("root"));

function render(spec) {
  try {
    if (!spec || typeof spec !== "object" || !spec.root || !spec.elements) {
      throw new Error("spec must be {root, elements, state?}");
    }
    root.render(<App spec={spec} />);
    window.__hostState = "rendered";
  } catch (error) {
    window.__hostState = "render-failed: " + String(error && error.message || error);
    root.render(<Failure message={String(error && error.message || error)} />);
  }
}

// Swift injects window.__INITIAL_SPEC__ before this bundle runs, and can push
// replacement specs later via window.__setSpec(...).
window.__setSpec = render;
render(window.__INITIAL_SPEC__);

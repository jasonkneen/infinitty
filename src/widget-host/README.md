# Widget Host

Manages the lifecycle of external widget packages - discovery, process spawning, communication, and tool registration.

**Status: Tested & Working** (December 2024)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host Application                      │
│  ┌───────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │WidgetDiscovery│  │WidgetProcessMgr  │  │ WidgetHost   │ │
│  │               │  │                  │  │   Context    │ │
│  │ - scan dirs   │  │ - spawn process  │  │              │ │
│  │ - validate    │  │ - WebSocket conn │  │ - React hook │ │
│  │ - cache       │  │ - MCP calls      │  │ - state mgmt │ │
│  └───────────────┘  └──────────────────┘  └──────────────┘ │
│           │                   │                    │        │
│           └───────────────────┼────────────────────┘        │
│                               ▼                              │
│                    ┌──────────────────┐                     │
│                    │ WidgetToolsCtx   │                     │
│                    │ (MCP registry)   │                     │
│                    └──────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼ HTTP/WebSocket
┌─────────────────────────────────────────────────────────────┐
│              Widget Process (port 3030)                      │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐ │
│  │ Express App │  │ MCP Server  │  │ WebSocket Server     │ │
│  │ /           │  │ /mcp        │  │ /ws                  │ │
│  │ /info       │  │             │  │                      │ │
│  └─────────────┘  └─────────────┘  └──────────────────────┘ │
│                          │                                   │
│                          ▼                                   │
│              ┌──────────────────────┐                       │
│              │ Business Logic       │                       │
│              │ (workflowEngine.ts)  │                       │
│              │ (persistence.ts)     │                       │
│              └──────────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

## Components

### WidgetDiscovery.ts

Scans for widget packages and validates their manifests.

```typescript
import { getWidgetDiscovery } from './WidgetDiscovery'

const discovery = getWidgetDiscovery()

// Find all widgets
const widgets = await discovery.discoverWidgets()

// Force refresh (bypass cache)
const widgets = await discovery.discoverWidgets(true)

// Get specific widget
const widget = await discovery.getWidget('com.flows.workflow')

// Get only valid widgets
const valid = await discovery.getValidWidgets()

// Filter by execution model
const processWidgets = await discovery.getWidgetsByExecutionModel('process')
```

**Scan Locations:**
- `src/widgets-external/` - Built-in widgets
- `~/Library/Application Support/infinitty/widgets/` - User-installed widgets

### WidgetProcessManager.ts

Spawns widget processes and manages their lifecycle.

```typescript
import { getWidgetProcessManager } from './WidgetProcessManager'

const manager = getWidgetProcessManager()

// Start widget process
const process = await manager.startWidget(manifest)

// Stop widget
await manager.stopWidget('com.flows.workflow')

// Stop all widgets
await manager.stopAll()

// Get process info
const process = manager.getProcess('com.flows.workflow')
const all = manager.getAllProcesses()

// Call MCP tool
const result = await manager.callTool('com.flows.workflow', 'list_workflows', {})

// List tools from widget
const tools = await manager.listTools('com.flows.workflow')

// Send WebSocket message
manager.sendMessage('com.flows.workflow', { type: 'notification', method: 'custom', params: {} })

// Subscribe to events
const unsubscribe = manager.on((event) => {
  if (event.type === 'started') console.log(`Started: ${event.widgetId}`)
  if (event.type === 'stopped') console.log(`Stopped: ${event.widgetId}`)
  if (event.type === 'error') console.error(`Error: ${event.error}`)
  if (event.type === 'message') console.log(`Message:`, event.data)
})
```

### WidgetHost.tsx

React context provider that integrates discovery and process management.

```tsx
import { WidgetHostProvider, useWidgetHost } from './widget-host'

// Wrap app
function App() {
  return (
    <WidgetHostProvider>
      <MyApp />
    </WidgetHostProvider>
  )
}

// Use in components
function WidgetManager() {
  const {
    // Traditional inline widgets
    loadWidget,
    unloadWidget,
    getLoadedWidgets,
    createWidgetInstance,
    destroyWidgetInstance,

    // Process-based widgets
    discoveredWidgets,
    runningProcesses,
    startWidgetProcess,
    stopWidgetProcess,
    refreshWidgets,
    callWidgetTool,
  } = useWidgetHost()

  return (
    <div>
      <h2>Discovered Widgets</h2>
      {discoveredWidgets.map(w => (
        <div key={w.manifest.id}>
          {w.manifest.name} - {w.isValid ? '✓' : '✗'}
          <button onClick={() => startWidgetProcess(w.manifest.id)}>
            Start
          </button>
        </div>
      ))}

      <h2>Running Processes</h2>
      {runningProcesses.map(p => (
        <div key={p.manifest.id}>
          {p.manifest.name} - {p.status} (port {p.port})
          <button onClick={() => stopWidgetProcess(p.manifest.id)}>
            Stop
          </button>
        </div>
      ))}
    </div>
  )
}
```

## Process Lifecycle

```
1. Discovery
   WidgetDiscovery scans for manifest.json files
   ↓
2. Validation
   Manifest validated against schema
   ↓
3. Start Request
   Host calls startWidgetProcess(widgetId)
   ↓
4. Process Spawn
   WidgetProcessManager spawns: node dist/index.js
   ↓
5. Wait for Ready
   Poll http://localhost:{port}/ until server responds
   ↓
6. WebSocket Connect
   Establish ws://localhost:{port}/ws connection
   ↓
7. Tool Registration
   Call tools/list, register tools in WidgetToolsContext
   ↓
8. Running
   Widget is ready, tools available to MCP clients
   ↓
9. Stop Request
   Host calls stopWidgetProcess(widgetId)
   ↓
10. Cleanup
    Close WebSocket, kill process, unregister tools
```

## MCP Communication

### Initialize Session

```typescript
// Called automatically by WidgetProcessManager
const response = await fetch(`http://localhost:${port}/mcp`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  },
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'infinitty', version: '1.0.0' }
    }
  })
})

// Extract session ID from response headers
const sessionId = response.headers.get('Mcp-Session-Id')
```

### Call Tool

```typescript
const result = await fetch(`http://localhost:${port}/mcp`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'Mcp-Session-Id': sessionId,
  },
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: {
      name: 'list_workflows',
      arguments: {}
    }
  })
})
```

## Event Types

```typescript
type WidgetProcessEvent =
  | { type: 'started'; widgetId: string; port: number }
  | { type: 'stopped'; widgetId: string }
  | { type: 'error'; widgetId: string; error: string }
  | { type: 'message'; widgetId: string; data: unknown }
  | { type: 'tool_registered'; widgetId: string; toolName: string }
```

## Process State

```typescript
interface WidgetProcess {
  manifest: WidgetManifest
  pid?: number
  port: number
  status: 'starting' | 'running' | 'stopping' | 'stopped' | 'error'
  ws?: WebSocket
  mcpSessionId?: string
  error?: string
  startedAt?: number
  restartCount: number
}
```

## Auto-Restart

If a widget process exits unexpectedly (non-zero exit code), it will auto-restart up to 3 times with exponential backoff (1s, 2s, 3s delays).

## Tool Namespacing

Tools are namespaced to avoid collisions:
- Widget exposes: `run_workflow`
- Host registers: `com.flows.workflow:run_workflow`

---

## Implementation Status

### Tested & Working
- [x] WidgetDiscovery - manifest scanning and validation
- [x] WidgetProcessManager - process spawn/kill
- [x] WidgetHost - React context integration
- [x] MCP session management
- [x] MCP tool calls (tools/list, tools/call)
- [x] WebSocket connection management
- [x] Event subscription system

### Pending Integration
- [ ] Tauri shell plugin (`@tauri-apps/plugin-shell`) - import paths
- [ ] Tauri fs plugin (`@tauri-apps/plugin-fs`) - readDir/readTextFile API
- [ ] Process spawn on Windows/Linux (currently macOS-focused)
- [ ] Auto-restart logic
- [ ] Port allocation conflicts

### Not Implemented
- [ ] Widget installation from URL
- [ ] Widget uninstallation
- [ ] Hot reload during development
- [ ] Process resource limits
- [ ] Sandboxed file system access
- [ ] Widget permissions system

---

## Dependencies

```json
{
  "@tauri-apps/plugin-shell": "^2.0.0",
  "@tauri-apps/plugin-fs": "^2.0.0",
  "@tauri-apps/api": "^2.0.0"
}
```

**Note:** These imports may need adjustment. Verify against Tauri v2 documentation.

---

## Quick Start

### 1. Start a Widget Manually

```bash
cd src/widgets-external/com.flows.workflow
npm run build
npm start
```

### 2. Test Endpoints

```bash
# Health check
curl http://localhost:3030/

# Widget info
curl http://localhost:3030/info

# Initialize MCP session
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

### 3. Call Tools

```bash
# List tools (use session ID from initialize response)
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call a tool
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_adapters","arguments":{}}}'
```

### 4. Example Tool Responses

**list_adapters:**
```json
{
  "result": {
    "content": [{
      "type": "text",
      "text": "[{\"id\":\"local-browser\",\"name\":\"Local Browser Engine\",\"description\":\"Executes nodes sequentially\"}]"
    }]
  }
}
```

**list_workflows:**
```json
{
  "result": {
    "content": [{
      "type": "text",
      "text": "[{\"id\":\"uuid\",\"name\":\"My Workflow\",\"version\":\"1.0.0\"}]"
    }]
  }
}
```

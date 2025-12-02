# External Widgets Architecture

## Overview

External widgets are isolated, versioned packages that run as separate processes and communicate with the host application via WebSocket and MCP (Model Context Protocol).

**Status: Tested & Working** (December 2024)

## Directory Structure

```/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widgets-external/com.flows.workflow
src/widgets-external/
├── README.md                    # This file
└── com.flows.workflow/          # Workflow widget package
    ├── manifest.json            # Widget metadata & capabilities
    ├── package.json             # npm dependencies
    ├── tsconfig.json            # TypeScript configuration
    ├── src/
    │   ├── index.ts             # Entry point (starts server)
    │   ├── server.ts            # MCP + WebSocket server
    │   ├── types.ts             # Shared type definitions
    │   ├── workflowEngine.ts    # Execution adapters
    │   ├── persistence.ts       # File storage
    │   └── Component.tsx        # React UI (for host rendering)
    └── dist/                    # Compiled output
```

## Widget Naming Convention

Use reverse domain notation: `com.{company}.{widget-name}`

Examples:
- `com.flows.workflow`
- `com.flows.terminal-recorder`
- `org.community.markdown-preview`

## manifest.json Schema

```json
{
  "$schema": "https://flows.local/schemas/widget-manifest-v1.json",
  "id": "com.example.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "description": "What this widget does",
  "main": "./dist/index.js",
  "ui": "./dist/Component.js",
  "executionModel": "process",
  "port": 3030,
  "activationEvents": ["onStartup"],
  "contributes": {
    "tools": [
      {
        "name": "tool_name",
        "description": "What the tool does"
      }
    ]
  }
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique identifier (reverse domain notation) |
| `name` | Yes | Display name |
| `version` | Yes | Semver version |
| `description` | No | Widget description |
| `main` | Yes | Server entry point |
| `ui` | No | React component for UI |
| `executionModel` | No | `process` (default), `inline`, or `webworker` |
| `port` | No | Default port for server (auto-allocated if not set) |
| `activationEvents` | No | When to start the widget |
| `contributes.tools` | No | MCP tools exposed by widget |

## Execution Models

### Process (Recommended)
Widget runs as a separate Node.js process. Communicates via WebSocket + HTTP/MCP.

```
Host App ──WebSocket──> Widget Process (port 3030)
         ──HTTP/MCP───>
```

### Inline
Widget code runs in the host's renderer process. Direct function calls.

### WebWorker
Widget runs in a Web Worker. Communicates via postMessage.

## Server Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Health check, returns widget info |
| `/info` | GET | Widget metadata and capabilities |
| `/mcp` | POST | MCP JSON-RPC requests |
| `/mcp` | GET | MCP SSE for streaming |
| `/mcp` | DELETE | Close MCP session |
| `/ws` | WebSocket | Real-time bidirectional communication |

## MCP Protocol (v1.24.0)

### Required Headers

```
Content-Type: application/json
Accept: application/json, text/event-stream
Mcp-Session-Id: <session-id>  (after initialize)
```

### Initialize Session

```bash
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "my-client", "version": "1.0.0"}
    }
  }'
```

Response includes `Mcp-Session-Id` header for subsequent requests.

### List Tools

```bash
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

### Call Tool

```bash
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "list_adapters",
      "arguments": {}
    }
  }'
```

## Creating a New Widget

### 1. Create Directory Structure

```bash
mkdir -p src/widgets-external/com.mycompany.mywidget/src
cd src/widgets-external/com.mycompany.mywidget
```

### 2. Initialize Package

```bash
npm init -y
npm install express cors ws zod @modelcontextprotocol/sdk@^1.24.0
npm install -D typescript @types/node @types/express @types/ws @types/cors
```

### 3. Create manifest.json

```json
{
  "id": "com.mycompany.mywidget",
  "name": "My Widget",
  "version": "1.0.0",
  "main": "./dist/index.js",
  "executionModel": "process",
  "port": 3031,
  "contributes": {
    "tools": []
  }
}
```

### 4. Create package.json

```json
{
  "name": "com.mycompany.mywidget",
  "version": "1.0.0",
  "type": "module",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.24.0",
    "cors": "^2.8.5",
    "express": "^4.19.2",
    "ws": "^8.16.0",
    "zod": "^3.23.8"
  }
}
```

### 5. Create tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

### 6. Create Server (src/server.ts)

```typescript
import express from "express";
import cors from "cors";
import { randomUUID } from "crypto";
import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

const wsClients = new Set<WebSocket>();

function createMcpServer() {
  const server = new McpServer({
    name: "com.mycompany.mywidget",
    version: "1.0.0",
  });

  // Register a tool
  server.registerTool(
    "my_tool",
    {
      title: "My Tool",
      description: "Does something useful",
      inputSchema: z.object({
        param: z.string().optional(),
      }),
    },
    async (input) => {
      const { param } = input as { param?: string };
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ result: param || "default" }),
          },
        ],
      };
    }
  );

  return server;
}

export async function startServer(port = 3031) {
  const app = express();
  const httpServer = createServer(app);

  app.use(express.json());
  app.use(cors({ origin: "*" }));

  // WebSocket
  const wss = new WebSocketServer({ server: httpServer, path: "/ws" });
  wss.on("connection", (ws) => {
    wsClients.add(ws);
    ws.on("close", () => wsClients.delete(ws));
  });

  // MCP sessions
  const transports = new Map<string, StreamableHTTPServerTransport>();
  const servers = new Map<string, McpServer>();

  app.post("/mcp", async (req, res) => {
    const sessionId = req.header("Mcp-Session-Id");
    let transport: StreamableHTTPServerTransport;
    let server: McpServer;

    if (sessionId && transports.has(sessionId)) {
      transport = transports.get(sessionId)!;
      server = servers.get(sessionId)!;
    } else {
      const newSessionId = randomUUID();
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => newSessionId,
      });
      server = createMcpServer();
      await server.connect(transport);
      transports.set(newSessionId, transport);
      servers.set(newSessionId, server);
      res.setHeader("Mcp-Session-Id", newSessionId);
    }

    await transport.handleRequest(req, res, req.body);
  });

  // Health check
  app.get("/", (_req, res) => {
    res.json({ ok: true, widget: "com.mycompany.mywidget" });
  });

  httpServer.listen(port, () => {
    console.log(`Widget running on http://localhost:${port}`);
  });
}
```

### 7. Create Entry Point (src/index.ts)

```typescript
import { startServer } from "./server.js";

const port = Number(process.env.PORT) || 3031;
console.log(`Starting widget on port ${port}...`);
startServer(port);
```

### 8. Build & Test

```bash
npm run build
npm start

# Test health
curl http://localhost:3031/

# Test MCP
curl -X POST http://localhost:3031/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

## Host Integration

### WidgetDiscovery

Scans `src/widgets-external/*/manifest.json` for available widgets.

```typescript
import { getWidgetDiscovery } from './widget-host'

const discovery = getWidgetDiscovery()
const widgets = await discovery.discoverWidgets()
```

### WidgetProcessManager

Spawns and manages widget processes.

```typescript
import { getWidgetProcessManager } from './widget-host'

const manager = getWidgetProcessManager()

// Start a widget
await manager.startWidget(manifest)

// Call a tool
const result = await manager.callTool('com.flows.workflow', 'list_workflows', {})

// Stop a widget
await manager.stopWidget('com.flows.workflow')
```

### WidgetHost React Context

```typescript
import { useWidgetHost } from './widget-host'

function MyComponent() {
  const {
    discoveredWidgets,
    runningProcesses,
    startWidgetProcess,
    stopWidgetProcess,
    callWidgetTool
  } = useWidgetHost()
}
```

## Data Storage

Widgets persist data to:
- `~/.infinitty/workflows/` - Workflow files
- `~/.infinitty/widgets/{widget-id}/` - Widget-specific data

## MCP Tool Registration

When a widget process starts, the host:
1. Calls `tools/list` to discover available tools
2. Registers tools in the global WidgetToolsContext
3. Tools become available to MCP clients (e.g., Claude)

Tool names are namespaced: `{widget-id}:{tool-name}`

Example: `com.flows.workflow:run_workflow`

---

## Implementation Status

### Tested & Working
- [x] Widget package structure
- [x] manifest.json schema
- [x] MCP SDK v1.24.0 integration
- [x] Server with WebSocket + MCP
- [x] MCP session management
- [x] Tool registration (registerTool API)
- [x] Tool execution (tools/call)
- [x] Workflow persistence to disk
- [x] DAG execution engine
- [x] TypeScript build
- [x] WidgetDiscovery
- [x] WidgetProcessManager
- [x] WidgetHost context

### Pending Integration
- [ ] Tauri shell plugin for process spawning
- [ ] Component.tsx rendering in host
- [ ] Auto-restart on crash
- [ ] Port conflict resolution

---

## Example: com.flows.workflow

The workflow widget provides visual workflow design and execution.

### Tools

| Tool | Description | Input |
|------|-------------|-------|
| `list_adapters` | List execution adapters | none |
| `run_workflow` | Execute a workflow | `adapterId`, `context` |
| `save_workflow` | Save to disk | `name`, `nodes`, `connections` |
| `load_workflow` | Load from disk | `id` |
| `list_workflows` | List all saved | `filter?` |
| `delete_workflow` | Delete from disk | `id` |

### Adapters

| Adapter | Status | Description |
|---------|--------|-------------|
| `local-browser` | Working | In-process DAG scheduler |
| `vercel-workflow` | Stub | Vercel AI SDK integration |
| `crewai` | Stub | CrewAI multi-agent |
| `langflow` | Stub | LangFlow external |
| `flowise` | Stub | FlowiseAI external |
| `openai` | Stub | OpenAI Assistants |
| `agentuity` | Stub | Agentuity framework |

### Workflow File Format

```json
{
  "id": "uuid",
  "name": "My Workflow",
  "version": "1.0.0",
  "nodes": [
    {
      "id": "node-1",
      "type": "input",
      "data": { "label": "Start" }
    }
  ],
  "connections": [
    { "source": "node-1", "target": "node-2" }
  ],
  "executionConfig": {
    "adapter": "local-browser"
  },
  "createdAt": "2024-01-01T00:00:00.000Z",
  "updatedAt": "2024-01-01T00:00:00.000Z"
}
```

Files stored in: `~/.infinitty/workflows/{id}.workflow.json`

### Test Commands

```bash
cd src/widgets-external/com.flows.workflow

# Build
npm run build

# Start server
npm start

# Health check
curl http://localhost:3030/

# Get info
curl http://localhost:3030/info

# Initialize MCP session (save the Mcp-Session-Id header)
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'

# List tools
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call list_adapters
curl -X POST http://localhost:3030/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_adapters","arguments":{}}}'
```

import express from "express";
import cors from "cors";
import { randomUUID } from "crypto";
import { WebSocketServer, WebSocket } from "ws";
import { createServer } from "http";
import { z } from "zod";
import path from "path";
import { spawn } from "child_process";
import { fileURLToPath } from "url";

// ESM __dirname equivalent
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { ExecutionContext } from "./types.js";
import { AVAILABLE_ADAPTERS, runWorkflowWithAdapter } from "./workflowEngine.js";
import {
  saveWorkflow,
  loadWorkflow,
  deleteWorkflow,
  listWorkflows,
  type SaveWorkflowInput,
} from "./persistence.js";

// WebSocket clients for broadcasting
const wsClients = new Set<WebSocket>();

function broadcastToClients(event: string, data: unknown): void {
  const message = JSON.stringify({
    type: "notification",
    method: event,
    params: data,
    timestamp: Date.now(),
  });

  for (const client of wsClients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  }
}

// Create the MCP server and register tools
function createMcpServer() {
  const server = new McpServer({
    name: "com.flows.workflow",
    version: "1.0.0",
  });

  // Tool: List available adapters
  server.registerTool(
    "list_adapters",
    {
      title: "List workflow adapters",
      description: "Return the available workflow execution adapters",
    },
    async () => {
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(AVAILABLE_ADAPTERS.map((a) => ({
              id: a.id,
              name: a.name,
              description: a.description,
            })), null, 2),
          },
        ],
      };
    }
  );

  // Tool: Run a workflow
  server.registerTool(
    "run_workflow",
    {
      title: "Run workflow",
      description: "Execute a workflow graph using the chosen adapter",
      inputSchema: z.object({
        adapterId: z.string(),
        context: z.object({
          nodes: z.array(z.any()),
          connections: z.array(z.any()),
          inputs: z.record(z.any()).optional(),
        }),
      }),
    },
    async (input) => {
      const { adapterId, context } = input as {
        adapterId: string;
        context: ExecutionContext;
      };

      const nodeEvents: {
        nodeId: string;
        status: string;
        result?: unknown;
      }[] = [];

      await runWorkflowWithAdapter(adapterId, context, (nodeId, status, result) => {
        nodeEvents.push({ nodeId, status, result });

        // Broadcast to WebSocket clients
        broadcastToClients("workflow/nodeStatus", { nodeId, status, result });
      });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ adapterId, nodeEvents }, null, 2),
          },
        ],
      };
    }
  );

  // Tool: Save workflow
  server.registerTool(
    "save_workflow",
    {
      title: "Save workflow",
      description: "Save a workflow to persistent storage",
      inputSchema: z.object({
        id: z.string().optional(),
        name: z.string(),
        version: z.string().optional(),
        description: z.string().optional(),
        nodes: z.array(z.any()),
        connections: z.array(z.any()),
        executionConfig: z
          .object({
            adapter: z.string(),
            timeout: z.number().optional(),
          })
          .optional(),
        tags: z.array(z.string()).optional(),
      }),
    },
    async (input) => {
      const doc = await saveWorkflow(input as SaveWorkflowInput);
      broadcastToClients("workflow/saved", { id: doc.id, name: doc.name });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ id: doc.id, name: doc.name, version: doc.version }),
          },
        ],
      };
    }
  );

  // Tool: Load workflow
  server.registerTool(
    "load_workflow",
    {
      title: "Load workflow",
      description: "Load a workflow from persistent storage",
      inputSchema: z.object({
        id: z.string(),
      }),
    },
    async (input) => {
      const { id } = input as { id: string };
      const doc = await loadWorkflow(id);

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(doc, null, 2),
          },
        ],
      };
    }
  );

  // Tool: List workflows
  server.registerTool(
    "list_workflows",
    {
      title: "List workflows",
      description: "List all saved workflows",
      inputSchema: z.object({
        filter: z.string().optional(),
      }),
    },
    async (input) => {
      const { filter } = input as { filter?: string };
      const workflows = await listWorkflows(filter);

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(workflows, null, 2),
          },
        ],
      };
    }
  );

  // Tool: Delete workflow
  server.registerTool(
    "delete_workflow",
    {
      title: "Delete workflow",
      description: "Delete a saved workflow",
      inputSchema: z.object({
        id: z.string(),
      }),
    },
    async (input) => {
      const { id } = input as { id: string };
      await deleteWorkflow(id);
      broadcastToClients("workflow/deleted", { id });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ deleted: true, id }),
          },
        ],
      };
    }
  );

  return server;
}

// HTTP + WebSocket + MCP server
export async function startServer(port = Number(process.env.PORT) || 3030) {
  const app = express();
  const httpServer = createServer(app);

  app.use(express.json());
  app.use(
    cors({
      origin: "*",
      allowedHeaders: ["Content-Type", "Mcp-Session-Id", "mcp-session-id"],
      exposedHeaders: ["Mcp-Session-Id"],
    })
  );

  // WebSocket server for real-time communication with host
  const wss = new WebSocketServer({ server: httpServer, path: "/ws" });

  wss.on("connection", (ws) => {
    console.log("[WebSocket] Client connected");
    wsClients.add(ws);

    ws.on("message", async (data) => {
      try {
        const message = JSON.parse(data.toString());
        console.log("[WebSocket] Received:", message.method);

        // Handle tool calls via WebSocket
        if (message.type === "request" && message.method) {
          const response = {
            type: "response",
            id: message.id,
            result: { received: true, method: message.method },
            timestamp: Date.now(),
          };
          ws.send(JSON.stringify(response));
        }
      } catch (err) {
        console.error("[WebSocket] Error handling message:", err);
      }
    });

    ws.on("close", () => {
      console.log("[WebSocket] Client disconnected");
      wsClients.delete(ws);
    });

    ws.on("error", (err) => {
      console.error("[WebSocket] Error:", err);
      wsClients.delete(ws);
    });

    // Send initial connection message
    ws.send(
      JSON.stringify({
        type: "notification",
        method: "widget/connected",
        params: { widgetId: "com.flows.workflow", version: "1.0.0" },
        timestamp: Date.now(),
      })
    );
  });

  // MCP session management - create one transport per session
  const transports = new Map<string, StreamableHTTPServerTransport>();
  const servers = new Map<string, McpServer>();

  // MCP POST endpoint
  app.post("/mcp", async (req, res) => {
    try {
      const headerSession = (req.header("Mcp-Session-Id") ||
        req.header("mcp-session-id")) as string | undefined;

      let transport: StreamableHTTPServerTransport;
      let server: McpServer;

      if (headerSession && transports.has(headerSession)) {
        transport = transports.get(headerSession)!;
        server = servers.get(headerSession)!;
      } else {
        // Create new session
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
    } catch (error) {
      console.error("[MCP] Error handling request:", error);
      if (!res.headersSent) {
        res.status(500).json({ error: "Internal MCP server error" });
      }
    }
  });

  // MCP GET endpoint (SSE)
  app.get("/mcp", async (req, res) => {
    try {
      const headerSession = (req.header("Mcp-Session-Id") ||
        req.header("mcp-session-id")) as string | undefined;

      if (!headerSession || !transports.has(headerSession)) {
        res.status(400).json({ error: "Missing or invalid Mcp-Session-Id" });
        return;
      }

      const transport = transports.get(headerSession)!;
      await transport.handleRequest(req, res);
    } catch (error) {
      console.error("[MCP] Error handling SSE:", error);
      if (!res.headersSent) {
        res.status(500).json({ error: "Internal MCP SSE error" });
      }
    }
  });

  // Session cleanup
  app.delete("/mcp", async (req, res) => {
    const headerSession = (req.header("Mcp-Session-Id") ||
      req.header("mcp-session-id")) as string | undefined;

    if (!headerSession || !transports.has(headerSession)) {
      res.status(400).json({ error: "Missing or invalid Mcp-Session-Id" });
      return;
    }

    const transport = transports.get(headerSession)!;
    const server = servers.get(headerSession)!;

    await transport.close();
    await server.close();

    transports.delete(headerSession);
    servers.delete(headerSession);
    res.status(204).send();
  });

  // Health check
  app.get("/", (_req, res) => {
    res.json({
      ok: true,
      widget: "com.flows.workflow",
      version: "1.0.0",
      endpoints: {
        mcp: "/mcp",
        websocket: "/ws",
        parse: "/parse",
      },
    });
  });

  // Simple REST endpoint for parsing skills to Mermaid
  app.post("/parse", async (req, res) => {
    const { path: sourcePath } = req.body as { path?: string };

    if (!sourcePath) {
      res.status(400).json({ error: "Missing 'path' in request body" });
      return;
    }

    const toflowsCli = path.join(__dirname, "../packages/toflows/dist/cli.js");

    const child = spawn("node", [toflowsCli, "auto", sourcePath], {
      cwd: path.dirname(sourcePath),
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    child.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    child.on("close", (code) => {
      if (code !== 0) {
        res.status(500).json({ error: stderr || "Failed to parse", code });
      } else {
        res.json({ mermaid: stdout.trim(), path: sourcePath });
      }
    });

    child.on("error", (err) => {
      res.status(500).json({ error: err.message });
    });
  });

  // Widget info endpoint
  app.get("/info", async (_req, res) => {
    const workflows = await listWorkflows();
    res.json({
      id: "com.flows.workflow",
      version: "1.0.0",
      adapters: AVAILABLE_ADAPTERS.map((a) => ({
        id: a.id,
        name: a.name,
        description: a.description,
      })),
      savedWorkflows: workflows.length,
    });
  });

  return new Promise<void>((resolve) => {
    httpServer.listen(port, () => {
      console.log(`[com.flows.workflow] Server running on http://localhost:${port}`);
      console.log(`  MCP endpoint: http://localhost:${port}/mcp`);
      console.log(`  WebSocket: ws://localhost:${port}/ws`);
      resolve();
    });
  });
}

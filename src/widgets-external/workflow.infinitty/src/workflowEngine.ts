import type { ExecutionContext, NodeStatus, WorkflowAdapter } from "./types.js";

// Simple helper to simulate async delay
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// 1. Local in-memory adapter (topological execution in-process)
class LocalBrowserAdapter implements WorkflowAdapter {
  id = "local-browser";
  name = "Local Browser Engine";
  description = "Executes nodes sequentially with a simple DAG scheduler";

  async execute(
    context: ExecutionContext,
    onStatus: (id: string, s: NodeStatus, r?: unknown) => void
  ): Promise<Record<string, unknown>> {
    const { nodes, connections } = context;
    const results: Record<string, unknown> = {};

    // Build dependency graph
    const graph = new Map<string, string[]>();
    const inDegree = new Map<string, number>();

    for (const node of nodes) {
      graph.set(node.id, []);
      inDegree.set(node.id, 0);
      onStatus(node.id, "pending");
    }

    for (const conn of connections) {
      // Support both {from: {nodeId}, to: {nodeId}} and {source, target} formats
      const from = conn.from?.nodeId ?? conn.source;
      const to = conn.to?.nodeId ?? conn.target;
      if (from && to) {
        graph.get(from)?.push(to);
        inDegree.set(to, (inDegree.get(to) ?? 0) + 1);
      }
    }

    // Queue for topological sort (nodes with 0 dependencies)
    const queue: string[] = nodes
      .filter((n) => (inDegree.get(n.id) ?? 0) === 0)
      .map((n) => n.id);

    while (queue.length > 0) {
      const nodeId = queue.shift()!;
      const node = nodes.find((n) => n.id === nodeId);
      if (!node) continue;

      onStatus(nodeId, "running");

      try {
        await delay(500);

        let output: unknown = { timestamp: Date.now() };

        switch (node.type) {
          case "input":
            output = { value: node.data?.value ?? "Test Input" };
            break;
          case "llm":
            output = { response: "Simulated LLM Response", tokens: 150 };
            break;
          case "code":
            output = { result: "Code executed successfully" };
            break;
          default:
            output = { ok: true, nodeType: node.type };
        }

        results[nodeId] = output;
        onStatus(nodeId, "completed", output);

        const neighbors = graph.get(nodeId) ?? [];
        for (const neighborId of neighbors) {
          inDegree.set(neighborId, (inDegree.get(neighborId) ?? 0) - 1);
          if (inDegree.get(neighborId) === 0) {
            queue.push(neighborId);
          }
        }
      } catch (err) {
        onStatus(nodeId, "error", { error: String(err) });
      }
    }

    return results;
  }
}

// 2. Stub adapters for external systems.
// These simulate behaviour for now; you can replace the internals with real APIs
// (Vercel AI SDK, CrewAI, LangFlow, Flowise, OpenAI, Agentuity, etc).

class StubAdapter implements WorkflowAdapter {
  constructor(
    public id: string,
    public name: string,
    public description: string
  ) {}

  async execute(
    context: ExecutionContext,
    onStatus: (id: string, s: NodeStatus, r?: unknown) => void
  ): Promise<Record<string, unknown>> {
    const results: Record<string, unknown> = {};
    for (const node of context.nodes) {
      onStatus(node.id, "running");
      await delay(400);
      const output = {
        adapter: this.id,
        nodeId: node.id,
        nodeType: node.type,
        message: `Simulated execution for ${node.title}`,
      };
      results[node.id] = output;
      onStatus(node.id, "completed", output);
    }
    return results;
  }
}

export const AVAILABLE_ADAPTERS: WorkflowAdapter[] = [
  new LocalBrowserAdapter(),
  new StubAdapter("vercel-workflow", "Vercel AI SDK", "Executes using Vercel AI SDK / Workflow DevKit"),
  new StubAdapter("crewai", "CrewAI", "Delegates tasks to a crew of autonomous agents"),
  new StubAdapter("langflow", "LangFlow", "Executes a flow on an external LangFlow instance"),
  new StubAdapter("flowise", "FlowiseAI", "Executes a flow on an external Flowise instance"),
  new StubAdapter("openai", "OpenAI Assistants", "Runs the workflow as an OpenAI Assistants thread"),
  new StubAdapter("agentuity", "Agentuity", "Executes using the Agentuity agent framework"),
];

export function getAdapter(adapterId: string): WorkflowAdapter {
  const found = AVAILABLE_ADAPTERS.find((a) => a.id === adapterId);
  if (!found) {
    throw new Error(`Unknown adapter: ${adapterId}`);
  }
  return found;
}

export async function runWorkflowWithAdapter(
  adapterId: string,
  context: ExecutionContext,
  onStatus: (nodeId: string, status: NodeStatus, result?: unknown) => void
): Promise<{ results: Record<string, unknown> }> {
  const adapter = getAdapter(adapterId);
  const results = await adapter.execute(context, onStatus);
  return { results };
}

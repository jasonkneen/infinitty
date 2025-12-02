// Workflow Types - Shared between server and client

export type NodeType = "input" | "process" | "output" | "condition" | "llm" | "code" | "tool";

export interface Position {
  x: number;
  y: number;
}

export interface Port {
  id: string;
  type: "input" | "output";
  label: string;
}

export interface Node {
  id: string;
  type: string;  // Flexible type - NodeType or custom
  title?: string;
  position?: Position;
  ports?: Port[];
  data?: Record<string, unknown>;
}

export interface ConnectionEndpoint {
  nodeId: string;
  portId: string;
}

export interface Connection {
  id?: string;
  // Standard format
  from?: ConnectionEndpoint;
  to?: ConnectionEndpoint;
  // Simplified format (source/target strings)
  source?: string;
  target?: string;
}

export interface ExecutionContext {
  nodes: Node[];
  connections: Connection[];
  inputs?: Record<string, unknown>;
}

export type NodeStatus = "pending" | "running" | "completed" | "error";

export interface WorkflowAdapter {
  id: string;
  name: string;
  description: string;
  execute: (
    context: ExecutionContext,
    onNodeStatusChange: (nodeId: string, status: NodeStatus, result?: unknown) => void
  ) => Promise<Record<string, unknown>>;
}

// Workflow Document - For persistence
export interface WorkflowDocument {
  id: string;
  name: string;
  version: string;
  description?: string;
  nodes: Node[];
  connections: Connection[];
  createdAt: string;  // ISO8601
  updatedAt: string;  // ISO8601
  author?: {
    name: string;
    email?: string;
  };
  tags?: string[];
  executionConfig?: {
    adapter: string;
    timeout?: number;
  };
}

export interface WorkflowMetadata {
  id: string;
  name: string;
  version: string;
  description?: string;
  updatedAt: string;
  tags?: string[];
}

// Widget Communication Messages
export interface WidgetMessage {
  type: 'request' | 'response' | 'notification';
  id?: string;
  method: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; message: string };
  timestamp: number;
}

export interface NodeStatusEvent {
  nodeId: string;
  status: NodeStatus;
  result?: unknown;
  timestamp: number;
}

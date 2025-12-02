import * as fs from "fs/promises";
import * as path from "path";
import { randomUUID } from "crypto";
import type { WorkflowDocument, WorkflowMetadata, Node, Connection } from "./types.js";

// Default storage directory
const WORKFLOWS_DIR = process.env.WORKFLOWS_DIR ||
  path.join(process.env.HOME || "~", ".infinitty", "workflows");

// Ensure workflows directory exists
async function ensureDir(): Promise<void> {
  try {
    await fs.mkdir(WORKFLOWS_DIR, { recursive: true });
  } catch (err) {
    // Ignore if already exists
  }
}

function getWorkflowPath(id: string): string {
  return path.join(WORKFLOWS_DIR, `${id}.workflow.json`);
}

export interface SaveWorkflowInput {
  id?: string;
  name: string;
  version?: string;
  description?: string;
  nodes: Node[];
  connections: Connection[];
  executionConfig?: {
    adapter: string;
    timeout?: number;
  };
  tags?: string[];
}

export async function saveWorkflow(input: SaveWorkflowInput): Promise<WorkflowDocument> {
  await ensureDir();

  const now = new Date().toISOString();
  const id = input.id || randomUUID();

  // Check if updating existing
  let existingDoc: WorkflowDocument | null = null;
  try {
    existingDoc = await loadWorkflow(id);
  } catch {
    // New workflow
  }

  const doc: WorkflowDocument = {
    id,
    name: input.name,
    version: input.version || "1.0.0",
    description: input.description,
    nodes: input.nodes,
    connections: input.connections,
    createdAt: existingDoc?.createdAt || now,
    updatedAt: now,
    tags: input.tags,
    executionConfig: input.executionConfig,
  };

  const filePath = getWorkflowPath(id);
  await fs.writeFile(filePath, JSON.stringify(doc, null, 2), "utf-8");

  console.log(`[Persistence] Saved workflow: ${id} (${doc.name})`);
  return doc;
}

export async function loadWorkflow(id: string): Promise<WorkflowDocument> {
  const filePath = getWorkflowPath(id);

  try {
    const content = await fs.readFile(filePath, "utf-8");
    const doc = JSON.parse(content) as WorkflowDocument;
    console.log(`[Persistence] Loaded workflow: ${id} (${doc.name})`);
    return doc;
  } catch (err) {
    throw new Error(`Workflow not found: ${id}`);
  }
}

export async function deleteWorkflow(id: string): Promise<void> {
  const filePath = getWorkflowPath(id);

  try {
    await fs.unlink(filePath);
    console.log(`[Persistence] Deleted workflow: ${id}`);
  } catch (err) {
    throw new Error(`Failed to delete workflow: ${id}`);
  }
}

export async function listWorkflows(filter?: string): Promise<WorkflowMetadata[]> {
  await ensureDir();

  try {
    const files = await fs.readdir(WORKFLOWS_DIR);
    const workflows: WorkflowMetadata[] = [];

    for (const file of files) {
      if (!file.endsWith(".workflow.json")) continue;

      try {
        const filePath = path.join(WORKFLOWS_DIR, file);
        const content = await fs.readFile(filePath, "utf-8");
        const doc = JSON.parse(content) as WorkflowDocument;

        // Apply filter if provided
        if (filter && !doc.name.toLowerCase().includes(filter.toLowerCase())) {
          continue;
        }

        workflows.push({
          id: doc.id,
          name: doc.name,
          version: doc.version,
          description: doc.description,
          updatedAt: doc.updatedAt,
          tags: doc.tags,
        });
      } catch {
        // Skip invalid files
      }
    }

    // Sort by updated date, newest first
    workflows.sort((a, b) =>
      new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()
    );

    console.log(`[Persistence] Listed ${workflows.length} workflows`);
    return workflows;
  } catch (err) {
    console.error("[Persistence] Failed to list workflows:", err);
    return [];
  }
}

export async function exportWorkflow(id: string): Promise<string> {
  const doc = await loadWorkflow(id);
  return JSON.stringify(doc, null, 2);
}

export async function importWorkflow(json: string): Promise<WorkflowDocument> {
  const doc = JSON.parse(json) as WorkflowDocument;

  // Generate new ID to avoid conflicts
  doc.id = randomUUID();
  doc.updatedAt = new Date().toISOString();

  return saveWorkflow(doc);
}

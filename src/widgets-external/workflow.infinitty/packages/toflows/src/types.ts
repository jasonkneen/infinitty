/**
 * Mermaid diagram output - the universal interchange format
 */

export interface MermaidDiagram {
  /** The Mermaid diagram source code */
  source: string
  /** Diagram type (flowchart, stateDiagram, etc.) */
  type: MermaidDiagramType
  /** Metadata about the source */
  metadata: DiagramMetadata
}

export type MermaidDiagramType =
  | 'flowchart'
  | 'stateDiagram'
  | 'classDiagram'
  | 'sequenceDiagram'
  | 'erDiagram'
  | 'mindmap'

export interface DiagramMetadata {
  sourceType: SourceType
  sourcePath: string
  generatedAt: string
  version: string
  /** Original data for round-trip editing */
  originalData?: unknown
}

export type SourceType =
  | 'skill'
  | 'skills-directory'
  | 'agent'
  | 'mcp-schema'
  | 'workflow'
  | 'filesystem'

/**
 * ReactFlow-compatible types (for widget rendering)
 * These are generated FROM Mermaid, not directly from parsers
 */

export interface FlowNode {
  id: string
  type: string
  position: { x: number; y: number }
  data: Record<string, unknown>
  parentId?: string
  style?: Record<string, unknown>
}

export interface FlowEdge {
  id: string
  source: string
  target: string
  sourceHandle?: string
  targetHandle?: string
  type?: string
  label?: string
  animated?: boolean
  data?: Record<string, unknown>
}

export interface FlowGraph {
  nodes: FlowNode[]
  edges: FlowEdge[]
  metadata: DiagramMetadata
}

/**
 * Skill-specific types
 */

export interface SkillFrontmatter {
  name: string
  description: string
  [key: string]: unknown
}

export interface SkillPrinciple {
  name: string
  content: string
}

export interface SkillRouting {
  response: string
  workflow: string
}

export interface SkillReference {
  name: string
  path: string
  description?: string
}

export interface SkillWorkflow {
  name: string
  path: string
  purpose?: string
}

export interface ParsedSkill {
  frontmatter: SkillFrontmatter
  principles: SkillPrinciple[]
  intake?: string
  routing: SkillRouting[]
  references: SkillReference[]
  workflows: SkillWorkflow[]
  rawContent: string
}

/**
 * Parser interface - all parsers implement this
 * Now outputs Mermaid instead of FlowGraph directly
 */

export interface Parser<T> {
  parse(sourcePath: string): Promise<T>
  toMermaid(parsed: T): MermaidDiagram
}

/**
 * Exporter interface - converts Mermaid back to source format
 */

export interface Exporter<T> {
  fromMermaid(diagram: MermaidDiagram): T
  write(data: T, targetPath: string): Promise<void>
}

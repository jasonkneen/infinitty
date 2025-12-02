/**
 * ReactFlow-to-Mermaid Generator
 *
 * Converts ReactFlow nodes and edges back into Mermaid syntax.
 * This enables round-trip editing: edit visually, export back to Mermaid.
 */

import type { FlowGraph, FlowNode, FlowEdge } from '../types.js'

interface GeneratorOptions {
  direction?: 'TB' | 'LR' | 'BT' | 'RL'
  includeStyles?: boolean
  includeComments?: boolean
}

/**
 * Convert ReactFlow graph to Mermaid flowchart syntax
 */
export function reactFlowToMermaid(
  graph: FlowGraph,
  options: GeneratorOptions = {}
): string {
  const {
    direction = 'TB',
    includeStyles = true,
    includeComments = true,
  } = options

  const lines: string[] = []

  // Header
  lines.push(`flowchart ${direction}`)
  lines.push('')

  // Collect class definitions from node data
  if (includeStyles) {
    const classDefs = collectClassDefs(graph.nodes)
    if (classDefs.length > 0) {
      if (includeComments) lines.push('  %% Node styles')
      lines.push(...classDefs)
      lines.push('')
    }
  }

  // Group nodes by parent (for subgraphs)
  const rootNodes: FlowNode[] = []
  const subgraphNodes = new Map<string, FlowNode[]>()
  const subgraphDefs = new Map<string, FlowNode>()

  for (const node of graph.nodes) {
    if (node.type === 'group') {
      subgraphDefs.set(node.id, node)
      continue
    }

    if (node.parentId) {
      if (!subgraphNodes.has(node.parentId)) {
        subgraphNodes.set(node.parentId, [])
      }
      subgraphNodes.get(node.parentId)!.push(node)
    } else {
      rootNodes.push(node)
    }
  }

  // Generate subgraphs first
  for (const [sgId, sgDef] of subgraphDefs) {
    const label = String(sgDef.data.label || sgId)
    lines.push(`  subgraph ${sgId}["${escapeLabel(label)}"]`)

    const children = subgraphNodes.get(sgId) || []
    const sgDirection = sgDef.data.direction as string | undefined
    if (sgDirection) {
      lines.push(`    direction ${sgDirection}`)
    }

    for (const node of children) {
      lines.push(`    ${generateNodeLine(node)}`)
    }

    lines.push('  end')
    lines.push('')
  }

  // Generate root nodes
  if (rootNodes.length > 0) {
    if (includeComments && rootNodes.length > 0) lines.push('  %% Root nodes')
    for (const node of rootNodes) {
      lines.push(`  ${generateNodeLine(node)}`)
    }
    lines.push('')
  }

  // Generate edges
  if (graph.edges.length > 0) {
    if (includeComments) lines.push('  %% Connections')
    for (const edge of graph.edges) {
      lines.push(`  ${generateEdgeLine(edge)}`)
    }
    lines.push('')
  }

  return lines.join('\n')
}

/**
 * Generate a single node line
 */
function generateNodeLine(node: FlowNode): string {
  const label = String(node.data.label || node.id)
  const nodeType = node.data.nodeType as string | undefined

  let line = `${node.id}["${escapeLabel(label)}"]`

  if (nodeType && nodeType !== 'default') {
    line += `:::${nodeType}`
  }

  return line
}

/**
 * Generate a single edge line
 */
function generateEdgeLine(edge: FlowEdge): string {
  const edgeType = edge.data?.edgeType as string | undefined
  let arrow = '-->'

  if (edgeType === 'dotted' || edge.animated) {
    arrow = '-.->'
  } else if (edgeType === 'thick') {
    arrow = '==>'
  }

  if (edge.label) {
    return `${edge.source} ${arrow}|"${escapeLabel(edge.label)}"| ${edge.target}`
  }

  return `${edge.source} ${arrow} ${edge.target}`
}

/**
 * Collect class definitions from nodes
 */
function collectClassDefs(nodes: FlowNode[]): string[] {
  const classDefs: string[] = []
  const seen = new Set<string>()

  for (const node of nodes) {
    const nodeType = node.data.nodeType as string | undefined
    const style = node.data.style as Record<string, string> | undefined

    if (nodeType && !seen.has(nodeType) && style && Object.keys(style).length > 0) {
      seen.add(nodeType)
      const styleStr = Object.entries(style)
        .map(([key, value]) => {
          // Convert camelCase back to kebab-case
          const kebabKey = key.replace(/([A-Z])/g, '-$1').toLowerCase()
          return `${kebabKey}:${value}`
        })
        .join(',')
      classDefs.push(`  classDef ${nodeType} ${styleStr}`)
    }
  }

  return classDefs
}

/**
 * Escape special characters in labels
 */
function escapeLabel(label: string): string {
  return label
    .replace(/"/g, "'")
    .replace(/\n/g, '\\n')
}

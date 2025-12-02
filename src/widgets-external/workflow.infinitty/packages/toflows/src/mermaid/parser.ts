/**
 * Mermaid-to-ReactFlow Parser
 *
 * Converts Mermaid flowchart syntax into ReactFlow nodes and edges.
 * This is the "render" side of the Rosetta Stone.
 */

import type { FlowGraph, FlowNode, FlowEdge, DiagramMetadata } from '../types.js'

interface ParsedMermaidNode {
  id: string
  label: string
  shape: 'rect' | 'rounded' | 'circle' | 'diamond' | 'hexagon' | 'parallelogram'
  className?: string
}

interface ParsedMermaidEdge {
  source: string
  target: string
  label?: string
  type: 'solid' | 'dotted' | 'thick'
}

interface ParsedMermaidSubgraph {
  id: string
  label: string
  nodes: string[]
  direction?: 'TB' | 'LR' | 'BT' | 'RL'
}

interface ParsedMermaid {
  direction: 'TB' | 'LR' | 'BT' | 'RL'
  nodes: Map<string, ParsedMermaidNode>
  edges: ParsedMermaidEdge[]
  subgraphs: Map<string, ParsedMermaidSubgraph>
  classDefs: Map<string, string>
}

/**
 * Parse Mermaid flowchart source into ReactFlow graph
 */
export function mermaidToReactFlow(
  mermaidSource: string,
  metadata?: Partial<DiagramMetadata>
): FlowGraph {
  const parsed = parseMermaid(mermaidSource)
  return convertToReactFlow(parsed, metadata)
}

/**
 * Parse Mermaid source into intermediate representation
 */
function parseMermaid(source: string): ParsedMermaid {
  const lines = source.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('%%'))

  const result: ParsedMermaid = {
    direction: 'TB',
    nodes: new Map(),
    edges: [],
    subgraphs: new Map(),
    classDefs: new Map(),
  }

  let currentSubgraph: string | null = null
  const subgraphStack: string[] = []

  for (const line of lines) {
    // Skip empty lines and comments
    if (!line || line.startsWith('%%')) continue

    // Flowchart declaration
    if (line.startsWith('flowchart') || line.startsWith('graph')) {
      const dirMatch = line.match(/(?:flowchart|graph)\s+(TB|LR|BT|RL|TD)/i)
      if (dirMatch) {
        result.direction = dirMatch[1].toUpperCase() as 'TB' | 'LR' | 'BT' | 'RL'
      }
      continue
    }

    // ClassDef
    const classDefMatch = line.match(/classDef\s+(\w+)\s+(.+)/)
    if (classDefMatch) {
      result.classDefs.set(classDefMatch[1], classDefMatch[2])
      continue
    }

    // Subgraph start
    const subgraphMatch = line.match(/subgraph\s+(\w+)(?:\["([^"]+)"\])?/)
    if (subgraphMatch) {
      const id = subgraphMatch[1]
      const label = subgraphMatch[2] || id
      result.subgraphs.set(id, {
        id,
        label,
        nodes: [],
        direction: undefined,
      })
      if (currentSubgraph) {
        subgraphStack.push(currentSubgraph)
      }
      currentSubgraph = id
      continue
    }

    // Subgraph end
    if (line === 'end') {
      currentSubgraph = subgraphStack.pop() || null
      continue
    }

    // Direction within subgraph
    const dirMatch = line.match(/direction\s+(TB|LR|BT|RL)/i)
    if (dirMatch && currentSubgraph) {
      const sg = result.subgraphs.get(currentSubgraph)
      if (sg) {
        sg.direction = dirMatch[1].toUpperCase() as 'TB' | 'LR' | 'BT' | 'RL'
      }
      continue
    }

    // Parse edges: A --> B, A -->|label| B, A -- text --> B, etc.
    const edgeMatch = line.match(
      /(\w+)(?:\["[^"]*"\])?\s*(-->|---|-\.->|==>|--\s*[^>]*\s*-->?)\s*(?:\|"?([^"|]+)"?\|)?\s*(\w+)/
    )
    if (edgeMatch) {
      const [, source, arrow, label, target] = edgeMatch
      let edgeType: 'solid' | 'dotted' | 'thick' = 'solid'
      if (arrow.includes('-.')) edgeType = 'dotted'
      if (arrow.includes('==')) edgeType = 'thick'

      result.edges.push({
        source,
        target,
        label: label?.trim(),
        type: edgeType,
      })

      // Ensure nodes exist
      ensureNode(result, source, currentSubgraph)
      ensureNode(result, target, currentSubgraph)
      continue
    }

    // Parse standalone nodes: A["Label"], A["Label"]:::class
    const nodeMatch = line.match(/^(\w+)(?:\["([^"]+)"\])?(?:::(\w+))?$/)
    if (nodeMatch) {
      const [, id, label, className] = nodeMatch
      if (!result.nodes.has(id)) {
        result.nodes.set(id, {
          id,
          label: label || id,
          shape: 'rect',
          className,
        })
      } else if (label || className) {
        const node = result.nodes.get(id)!
        if (label) node.label = label
        if (className) node.className = className
      }

      // Add to current subgraph
      if (currentSubgraph) {
        const sg = result.subgraphs.get(currentSubgraph)
        if (sg && !sg.nodes.includes(id)) {
          sg.nodes.push(id)
        }
      }
      continue
    }
  }

  return result
}

function ensureNode(
  result: ParsedMermaid,
  id: string,
  currentSubgraph: string | null
): void {
  if (!result.nodes.has(id)) {
    result.nodes.set(id, {
      id,
      label: id,
      shape: 'rect',
    })
  }

  if (currentSubgraph) {
    const sg = result.subgraphs.get(currentSubgraph)
    if (sg && !sg.nodes.includes(id)) {
      sg.nodes.push(id)
    }
  }
}

/**
 * Convert parsed Mermaid to ReactFlow format
 */
function convertToReactFlow(
  parsed: ParsedMermaid,
  metadata?: Partial<DiagramMetadata>
): FlowGraph {
  const nodes: FlowNode[] = []
  const edges: FlowEdge[] = []

  // Layout configuration
  const isHorizontal = parsed.direction === 'LR' || parsed.direction === 'RL'
  const NODE_WIDTH = 180
  const NODE_HEIGHT = 60
  const HORIZONTAL_GAP = 50
  const VERTICAL_GAP = 80
  const SUBGRAPH_PADDING = 40

  // Calculate positions using a simple layered approach
  const nodePositions = calculatePositions(parsed, {
    nodeWidth: NODE_WIDTH,
    nodeHeight: NODE_HEIGHT,
    horizontalGap: HORIZONTAL_GAP,
    verticalGap: VERTICAL_GAP,
    isHorizontal,
    subgraphPadding: SUBGRAPH_PADDING,
  })

  // Create subgraph nodes (as group nodes in ReactFlow)
  for (const [sgId, sg] of parsed.subgraphs) {
    if (sg.nodes.length === 0) continue

    const childPositions = sg.nodes
      .map(id => nodePositions.get(id))
      .filter((p): p is { x: number; y: number } => p !== undefined)

    if (childPositions.length > 0) {
      const minX = Math.min(...childPositions.map(p => p.x)) - SUBGRAPH_PADDING
      const minY = Math.min(...childPositions.map(p => p.y)) - SUBGRAPH_PADDING - 30
      const maxX = Math.max(...childPositions.map(p => p.x)) + NODE_WIDTH + SUBGRAPH_PADDING
      const maxY = Math.max(...childPositions.map(p => p.y)) + NODE_HEIGHT + SUBGRAPH_PADDING

      nodes.push({
        id: sgId,
        type: 'group',
        position: { x: minX, y: minY },
        data: {
          label: sg.label,
          nodeType: 'subgraph',
          width: maxX - minX,
          height: maxY - minY,
        },
      })
    }
  }

  // Create nodes
  for (const [id, node] of parsed.nodes) {
    const pos = nodePositions.get(id) || { x: 0, y: 0 }

    // Find parent subgraph
    let parentId: string | undefined
    for (const [sgId, sg] of parsed.subgraphs) {
      if (sg.nodes.includes(id)) {
        parentId = sgId
        break
      }
    }

    // Get style from classDef
    let nodeStyle = {}
    if (node.className && parsed.classDefs.has(node.className)) {
      nodeStyle = parseClassDefStyle(parsed.classDefs.get(node.className)!)
    }

    nodes.push({
      id,
      type: getReactFlowNodeType(node),
      position: pos,
      parentId,
      data: {
        label: cleanLabel(node.label),
        nodeType: node.className || 'default',
        style: nodeStyle,
      },
    })
  }

  // Create edges
  for (const edge of parsed.edges) {
    edges.push({
      id: `${edge.source}-${edge.target}`,
      source: edge.source,
      target: edge.target,
      label: edge.label,
      type: edge.type === 'solid' ? 'smoothstep' : 'step',
      animated: edge.type === 'dotted',
      data: {
        edgeType: edge.type,
      },
    })
  }

  return {
    nodes,
    edges,
    metadata: {
      sourceType: metadata?.sourceType || 'workflow',
      sourcePath: metadata?.sourcePath || 'mermaid',
      generatedAt: new Date().toISOString(),
      version: '0.1.0',
      ...metadata,
    },
  }
}

/**
 * Simple layout algorithm for positioning nodes
 */
function calculatePositions(
  parsed: ParsedMermaid,
  config: {
    nodeWidth: number
    nodeHeight: number
    horizontalGap: number
    verticalGap: number
    isHorizontal: boolean
    subgraphPadding: number
  }
): Map<string, { x: number; y: number }> {
  const positions = new Map<string, { x: number; y: number }>()

  // Build adjacency list
  const children = new Map<string, Set<string>>()
  const parents = new Map<string, Set<string>>()

  for (const node of parsed.nodes.keys()) {
    children.set(node, new Set())
    parents.set(node, new Set())
  }

  for (const edge of parsed.edges) {
    children.get(edge.source)?.add(edge.target)
    parents.get(edge.target)?.add(edge.source)
  }

  // Find roots (nodes with no parents)
  const roots: string[] = []
  for (const [id, parentSet] of parents) {
    if (parentSet.size === 0) {
      roots.push(id)
    }
  }

  // If no roots found, use all nodes
  const startNodes = roots.length > 0 ? roots : Array.from(parsed.nodes.keys())

  // BFS to assign layers
  const layers = new Map<string, number>()
  const queue = startNodes.map(id => ({ id, layer: 0 }))
  const visited = new Set<string>()

  while (queue.length > 0) {
    const { id, layer } = queue.shift()!
    if (visited.has(id)) continue
    visited.add(id)
    layers.set(id, layer)

    for (const child of children.get(id) || []) {
      if (!visited.has(child)) {
        queue.push({ id: child, layer: layer + 1 })
      }
    }
  }

  // Handle any unvisited nodes
  for (const id of parsed.nodes.keys()) {
    if (!layers.has(id)) {
      layers.set(id, 0)
    }
  }

  // Group by layer
  const layerGroups = new Map<number, string[]>()
  for (const [id, layer] of layers) {
    if (!layerGroups.has(layer)) {
      layerGroups.set(layer, [])
    }
    layerGroups.get(layer)!.push(id)
  }

  // Position nodes
  const { nodeWidth, nodeHeight, horizontalGap, verticalGap, isHorizontal } = config

  for (const [layer, nodeIds] of layerGroups) {
    nodeIds.forEach((id, idx) => {
      const x = isHorizontal
        ? layer * (nodeWidth + horizontalGap)
        : idx * (nodeWidth + horizontalGap)
      const y = isHorizontal
        ? idx * (nodeHeight + verticalGap)
        : layer * (nodeHeight + verticalGap)

      positions.set(id, { x, y })
    })
  }

  return positions
}

function getReactFlowNodeType(node: ParsedMermaidNode): string {
  // Map Mermaid shapes to ReactFlow node types
  switch (node.shape) {
    case 'rounded':
      return 'default'
    case 'circle':
      return 'input'
    case 'diamond':
      return 'default' // Would need custom node for diamond
    default:
      return 'default'
  }
}

function parseClassDefStyle(styleDef: string): Record<string, string> {
  const style: Record<string, string> = {}
  const parts = styleDef.split(',')

  for (const part of parts) {
    const [key, value] = part.split(':').map(s => s.trim())
    if (key && value) {
      // Convert Mermaid style keys to CSS
      const cssKey = key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())
      style[cssKey] = value
    }
  }

  return style
}

function cleanLabel(label: string): string {
  // Remove emoji prefixes but keep them in data if needed
  return label.replace(/\\n/g, '\n')
}

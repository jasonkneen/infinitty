/**
 * ELK Layout Engine
 *
 * Uses ELK.js (Eclipse Layout Kernel) to auto-arrange ReactFlow nodes.
 * This provides professional graph layout algorithms for clean, readable diagrams.
 */

import ELK from 'elkjs/lib/elk.bundled.js'
import type { FlowGraph, FlowNode, FlowEdge, DiagramMetadata } from '../types.js'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const elk = new (ELK as any)()

export interface ElkLayoutOptions {
  /** Layout algorithm: 'layered' (default), 'force', 'stress', 'mrtree', 'radial' */
  algorithm?: 'layered' | 'force' | 'stress' | 'mrtree' | 'radial'
  /** Primary direction: 'DOWN' (default), 'UP', 'LEFT', 'RIGHT' */
  direction?: 'DOWN' | 'UP' | 'LEFT' | 'RIGHT'
  /** Spacing between nodes (default: 50) */
  nodeSpacing?: number
  /** Spacing between layers/ranks (default: 50) */
  layerSpacing?: number
  /** Default node width (default: 172) */
  nodeWidth?: number
  /** Default node height (default: 36) */
  nodeHeight?: number
  /** Padding inside groups/subgraphs (default: 20) */
  groupPadding?: number
}

/**
 * Apply ELK layout to a FlowGraph
 *
 * @param graph - The input FlowGraph (nodes and edges)
 * @param options - Layout configuration options
 * @returns FlowGraph with updated node positions
 */
export async function applyElkLayout(
  graph: FlowGraph,
  options: ElkLayoutOptions = {}
): Promise<FlowGraph> {
  const {
    algorithm = 'layered',
    direction = 'DOWN',
    nodeSpacing = 50,
    layerSpacing = 50,
    nodeWidth = 172,
    nodeHeight = 36,
    groupPadding = 20,
  } = options

  // Build ELK graph structure
  const elkGraph = buildElkGraph(graph, {
    nodeWidth,
    nodeHeight,
    groupPadding,
  })

  // Configure layout options
  elkGraph.layoutOptions = {
    'elk.algorithm': `org.eclipse.elk.${algorithm}`,
    'elk.direction': direction,
    'elk.spacing.nodeNode': String(nodeSpacing),
    'elk.layered.spacing.nodeNodeBetweenLayers': String(layerSpacing),
    'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
    'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
  }

  // Run layout
  const layoutedGraph = await elk.layout(elkGraph)

  // Apply positions back to FlowGraph
  return applyPositions(graph, layoutedGraph)
}

interface ElkNode {
  id: string
  width: number
  height: number
  children?: ElkNode[]
  layoutOptions?: Record<string, string>
}

interface ElkEdge {
  id: string
  sources: string[]
  targets: string[]
}

interface ElkGraph {
  id: string
  children: ElkNode[]
  edges: ElkEdge[]
  layoutOptions?: Record<string, string>
}

interface BuildOptions {
  nodeWidth: number
  nodeHeight: number
  groupPadding: number
}

/**
 * Convert FlowGraph to ELK graph format
 */
function buildElkGraph(graph: FlowGraph, options: BuildOptions): ElkGraph {
  const { nodeWidth, nodeHeight, groupPadding } = options

  // Group nodes by parent
  const rootNodes: FlowNode[] = []
  const childrenMap = new Map<string, FlowNode[]>()
  const groupNodes = new Map<string, FlowNode>()

  for (const node of graph.nodes) {
    if (node.type === 'group') {
      groupNodes.set(node.id, node)
      continue
    }

    if (node.parentId) {
      if (!childrenMap.has(node.parentId)) {
        childrenMap.set(node.parentId, [])
      }
      childrenMap.get(node.parentId)!.push(node)
    } else {
      rootNodes.push(node)
    }
  }

  // Build ELK nodes
  const elkChildren: ElkNode[] = []

  // First add group nodes with their children
  for (const [groupId, groupNode] of groupNodes) {
    const children = childrenMap.get(groupId) || []
    elkChildren.push({
      id: groupId,
      width: nodeWidth * 2,
      height: nodeHeight * Math.max(children.length, 1) + groupPadding * 2,
      children: children.map(child => ({
        id: child.id,
        width: getNodeWidth(child, nodeWidth),
        height: getNodeHeight(child, nodeHeight),
      })),
      layoutOptions: {
        'elk.padding': `[top=${groupPadding},left=${groupPadding},bottom=${groupPadding},right=${groupPadding}]`,
      },
    })
  }

  // Add root nodes
  for (const node of rootNodes) {
    elkChildren.push({
      id: node.id,
      width: getNodeWidth(node, nodeWidth),
      height: getNodeHeight(node, nodeHeight),
    })
  }

  // Build ELK edges
  const elkEdges: ElkEdge[] = graph.edges.map((edge, idx) => ({
    id: `e${idx}`,
    sources: [edge.source],
    targets: [edge.target],
  }))

  return {
    id: 'root',
    children: elkChildren,
    edges: elkEdges,
  }
}

/**
 * Get node width from node data or default
 */
function getNodeWidth(node: FlowNode, defaultWidth: number): number {
  if (node.data.width) return Number(node.data.width)

  // Estimate width based on label length
  const label = String(node.data.label || node.id)
  const estimatedWidth = label.length * 8 + 40
  return Math.max(defaultWidth, Math.min(estimatedWidth, 300))
}

/**
 * Get node height from node data or default
 */
function getNodeHeight(node: FlowNode, defaultHeight: number): number {
  if (node.data.height) return Number(node.data.height)

  // Check for multiline labels
  const label = String(node.data.label || '')
  const lines = label.split('\\n').length
  return Math.max(defaultHeight, lines * 20 + 16)
}

interface LayoutedElkNode {
  id: string
  x?: number
  y?: number
  width?: number
  height?: number
  children?: LayoutedElkNode[]
}

interface LayoutedElkGraph {
  id: string
  children?: LayoutedElkNode[]
}

/**
 * Apply ELK layout positions back to FlowGraph
 */
function applyPositions(original: FlowGraph, layouted: LayoutedElkGraph): FlowGraph {
  // Build position map from layouted graph
  const positionMap = new Map<string, { x: number; y: number; width?: number; height?: number }>()

  function extractPositions(nodes: LayoutedElkNode[], offsetX = 0, offsetY = 0) {
    for (const node of nodes) {
      const x = (node.x || 0) + offsetX
      const y = (node.y || 0) + offsetY

      positionMap.set(node.id, {
        x,
        y,
        width: node.width,
        height: node.height,
      })

      // Recurse into children with offset
      if (node.children) {
        extractPositions(node.children, x, y)
      }
    }
  }

  if (layouted.children) {
    extractPositions(layouted.children)
  }

  // Apply positions to original nodes
  const layoutedNodes: FlowNode[] = original.nodes.map(node => {
    const pos = positionMap.get(node.id)
    if (pos) {
      return {
        ...node,
        position: { x: pos.x, y: pos.y },
        ...(node.type === 'group' && pos.width && pos.height
          ? { style: { ...(node.style || {}), width: pos.width, height: pos.height } }
          : {}),
      }
    }
    return node
  })

  return {
    nodes: layoutedNodes,
    edges: original.edges,
    metadata: original.metadata,
  }
}

/**
 * Convenience function to layout a graph with standard options
 */
export async function layoutGraph(
  graph: FlowGraph,
  direction: 'vertical' | 'horizontal' = 'vertical'
): Promise<FlowGraph> {
  return applyElkLayout(graph, {
    algorithm: 'layered',
    direction: direction === 'vertical' ? 'DOWN' : 'RIGHT',
    nodeSpacing: 40,
    layerSpacing: 60,
  })
}

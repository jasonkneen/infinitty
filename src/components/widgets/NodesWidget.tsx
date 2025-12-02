import { useState, useCallback, useRef, useEffect, useMemo, type MouseEvent, useId } from 'react'
import { useTerminalSettings } from '../../contexts/TerminalSettingsContext'
import type { TerminalTheme } from '../../config/terminal'
import { useWidgetTools, type WidgetTool } from '../../contexts/WidgetToolsContext'
import { Cpu, Database, Zap, GitBranch, MessageSquare, Code, Plus, Trash2, Play, FileJson, Wrench } from 'lucide-react'
import {
  type NodeType,
  type AttributeSchema,
  type ToolGroup,
  NODE_UI_SCHEMAS,
  TOOL_DEFINITIONS,
  getToolsByGroup,
  parseNodeData,
  validateNodeData,
  serializeNodeData,
  deserializeNodeData,
} from '../../schemas/nodeSchemas'

// --- Workflow Adapter Pattern ---

// Execution status union type
type NodeExecutionStatus = 'pending' | 'running' | 'completed' | 'error'

// Node status change result with typed output/error
export interface NodeStatusChangeResult {
  output?: unknown
  error?: string
  [key: string]: unknown
}

export interface ExecutionContext {
  nodes: Node[]
  connections: Connection[]
  inputs?: Record<string, unknown>
}

export interface NodeExecutionResult {
  nodeId: string
  status: 'completed' | 'error'
  output?: unknown
  error?: string
  logs?: string[]
}

// Status change callback handler type
type NodeStatusChangeHandler = (
  nodeId: string,
  status: NodeExecutionStatus,
  result?: NodeStatusChangeResult
) => void

export interface WorkflowAdapter {
  id: string
  name: string
  description: string
  endpoint?: string
  execute: (
    context: ExecutionContext,
    onNodeStatusChange: NodeStatusChangeHandler
  ) => Promise<Record<string, unknown>>
}

// Helper to handle API calls with fallback to simulation
async function executeWithFallback(
  adapterName: string,
  endpoint: string,
  context: ExecutionContext,
  onStatus: NodeStatusChangeHandler,
  simulationFn: () => Promise<void>
): Promise<Record<string, unknown>> {
  try {
    console.log(`[${adapterName}] Attempting to connect to ${endpoint}...`)
    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), 2000) // Quick timeout to check if API exists

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(context),
      signal: controller.signal
    })
    clearTimeout(timeoutId)

    if (!response.ok) throw new Error(`API Error: ${response.statusText}`)

    // Assume streaming response or immediate JSON result
    // For this implementation, we'll assume a JSON stream or final result
    const result = await response.json() as Record<string, unknown>

    // Update statuses based on backend result
    if (result.nodeStatuses && typeof result.nodeStatuses === 'object') {
      Object.entries(result.nodeStatuses).forEach(([nodeId, statusData]) => {
        const status = statusData as Record<string, unknown>
        const statusValue = status.status as NodeExecutionStatus | undefined
        const errorValue = typeof status.error === 'string' ? status.error : undefined
        if (statusValue) {
          onStatus(nodeId, statusValue, { output: status.output, error: errorValue })
        }
      })
    }
    return result

  } catch (error) {
    console.warn(`[${adapterName}] API connection failed (${String(error)}). Falling back to simulation.`)
    await simulationFn()
    return {}
  }
}

// 1. Local Browser Adapter (Simple topological execution)
class LocalBrowserAdapter implements WorkflowAdapter {
  id = 'local-browser'
  name = 'Local Browser Engine'
  description = 'Executes nodes sequentially in the browser main thread'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    const { nodes, connections } = context
    const results: Record<string, unknown> = {}

    // Build dependency graph
    const graph = new Map<string, string[]>()
    const inDegree = new Map<string, number>()

    nodes.forEach(n => {
      graph.set(n.id, [])
      inDegree.set(n.id, 0)
      onStatus(n.id, 'pending')
    })

    connections.forEach(c => {
      const from = c.from.nodeId
      const to = c.to.nodeId
      graph.get(from)?.push(to)
      inDegree.set(to, (inDegree.get(to) || 0) + 1)
    })

    // Queue for topological sort (nodes with 0 dependencies)
    const queue: string[] = nodes
      .filter(n => (inDegree.get(n.id) || 0) === 0)
      .map(n => n.id)

    while (queue.length > 0) {
      const nodeId = queue.shift()!
      const node = nodes.find(n => n.id === nodeId)!

      onStatus(nodeId, 'running')

      try {
        // Simulate execution delay
        await new Promise(resolve => setTimeout(resolve, 800))

        // Mock execution logic based on type
        const output: Record<string, unknown> = { timestamp: Date.now() }

        if (node.type === 'input') {
          output.value = node.data?.value ?? 'Test Input'
        } else if (node.type === 'llm') {
          output.response = "Simulated LLM Response"
          output.tokens = 150
        } else if (node.type === 'code') {
          output.result = "Code executed successfully"
        }

        results[nodeId] = output
        onStatus(nodeId, 'completed', { output })

        // Add neighbors to queue if their dependencies are met
        const neighbors = graph.get(nodeId) || []
        for (const neighborId of neighbors) {
          inDegree.set(neighborId, (inDegree.get(neighborId) || 0) - 1)
          if (inDegree.get(neighborId) === 0) {
            queue.push(neighborId)
          }
        }
      } catch (err) {
        console.error(err)
        onStatus(nodeId, 'error', { error: String(err) })
      }
    }

    return results
  }
}

// 2. Vercel Workflow Adapter
class VercelWorkflowAdapter implements WorkflowAdapter {
  id = 'vercel-workflow'
  name = 'Vercel AI SDK'
  description = 'Executes using Vercel AI SDK / useworkflow.dev patterns'
  endpoint = '/api/adapters/vercel'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      const steps = context.nodes.map(n => n.id)
      for (const nodeId of steps) {
        onStatus(nodeId, 'running')
        await new Promise(r => setTimeout(r, 600))
        onStatus(nodeId, 'completed', { output: { provider: 'vercel', region: 'edge', duration: '120ms' } })
      }
    })
  }
}

// 3. CrewAI Adapter
class CrewAIAdapter implements WorkflowAdapter {
  id = 'crewai'
  name = 'CrewAI Agents'
  description = 'Delegates tasks to a crew of autonomous agents'
  endpoint = '/api/adapters/crewai'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      for (const node of context.nodes) {
        onStatus(node.id, 'running')
        await new Promise(r => setTimeout(r, 1000))
        if (node.type === 'llm') {
          onStatus(node.id, 'completed', { output: { agent: 'Senior Researcher', thought: 'Analyzing data...', message: 'Analysis complete.' } })
        } else {
          onStatus(node.id, 'completed', { output: { status: 'Task delegated' } })
        }
      }
    })
  }
}

// 4. LangFlow Adapter
class LangFlowAdapter implements WorkflowAdapter {
  id = 'langflow'
  name = 'LangFlow'
  description = 'Executes flow on external LangFlow instance'
  endpoint = '/api/adapters/langflow'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      for (const node of context.nodes) {
        onStatus(node.id, 'running')
        await new Promise(r => setTimeout(r, 400))
        onStatus(node.id, 'completed', { output: { component: node.type, message: 'LangFlow Result' } })
      }
    })
  }
}

// 5. Flowise Adapter
class FlowiseAdapter implements WorkflowAdapter {
  id = 'flowise'
  name = 'FlowiseAI'
  description = 'Executes flow on external Flowise instance'
  endpoint = '/api/adapters/flowise'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      for (const node of context.nodes) {
        onStatus(node.id, 'running')
        await new Promise(r => setTimeout(r, 500))
        onStatus(node.id, 'completed', { output: { node: node.title, message: 'Flowise Output' } })
      }
    })
  }
}

// 6. OpenAI Adapter
class OpenAIAdapter implements WorkflowAdapter {
  id = 'openai'
  name = 'OpenAI Assistants'
  description = 'Runs as an OpenAI Assistant Thread'
  endpoint = '/api/adapters/openai'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      for (const node of context.nodes) {
        onStatus(node.id, 'running')
        await new Promise(r => setTimeout(r, 800))
        if (node.type === 'tool') {
          onStatus(node.id, 'completed', { output: { tool_call_id: 'call_123', message: 'Function Result' } })
        } else {
          onStatus(node.id, 'completed', { output: { role: 'assistant', content: 'Processed step.' } })
        }
      }
    })
  }
}

// 7. Agentuity Adapter
class AgentuityAdapter implements WorkflowAdapter {
  id = 'agentuity'
  name = 'Agentuity'
  description = 'Executes using Agentuity Agent Framework'
  endpoint = '/api/adapters/agentuity'

  async execute(
    context: ExecutionContext,
    onStatus: NodeStatusChangeHandler
  ): Promise<Record<string, unknown>> {
    return executeWithFallback(this.name, this.endpoint, context, onStatus, async () => {
      for (const node of context.nodes) {
        onStatus(node.id, 'running')
        await new Promise(r => setTimeout(r, 700))
        onStatus(node.id, 'completed', { output: { agent_id: 'ag_123', status: 'success' } })
      }
    })
  }
}

const AVAILABLE_ADAPTERS: WorkflowAdapter[] = [
  new LocalBrowserAdapter(),
  new VercelWorkflowAdapter(),
  new CrewAIAdapter(),
  new LangFlowAdapter(),
  new FlowiseAdapter(),
  new OpenAIAdapter(),
  new AgentuityAdapter(),
]

interface Position {
  x: number
  y: number
}

interface Port {
  id: string
  type: 'input' | 'output'
  label: string
}

interface Node {
  id: string
  type: NodeType
  title: string
  position: Position
  ports: Port[]
  data?: Record<string, unknown>
}

interface Connection {
  id: string
  from: { nodeId: string; portId: string }
  to: { nodeId: string; portId: string }
}

const NODE_ICONS: Record<NodeType, typeof Cpu> = {
  input: Database,
  process: Cpu,
  output: Zap,
  condition: GitBranch,
  llm: MessageSquare,
  code: Code,
  tool: Wrench,
}

const NODE_COLORS: Record<NodeType, string> = {
  input: '#3fb950',
  process: '#58a6ff',
  output: '#f85149',
  condition: '#d29922',
  llm: '#bc8cff',
  code: '#39c5cf',
  tool: '#f0883e',
}

// Initial demo nodes
const INITIAL_NODES: Node[] = [
  {
    id: 'node-1',
    type: 'input',
    title: 'User Input',
    position: { x: 50, y: 100 },
    ports: [{ id: 'out-1', type: 'output', label: 'text' }],
  },
  {
    id: 'node-2',
    type: 'llm',
    title: 'GPT-4 Process',
    position: { x: 300, y: 80 },
    ports: [
      { id: 'in-1', type: 'input', label: 'prompt' },
      { id: 'out-1', type: 'output', label: 'response' },
    ],
  },
  {
    id: 'node-3',
    type: 'condition',
    title: 'Check Valid',
    position: { x: 550, y: 100 },
    ports: [
      { id: 'in-1', type: 'input', label: 'data' },
      { id: 'out-1', type: 'output', label: 'yes' },
      { id: 'out-2', type: 'output', label: 'no' },
    ],
  },
  {
    id: 'node-4',
    type: 'output',
    title: 'Success',
    position: { x: 800, y: 50 },
    ports: [{ id: 'in-1', type: 'input', label: 'result' }],
  },
  {
    id: 'node-5',
    type: 'code',
    title: 'Error Handler',
    position: { x: 800, y: 180 },
    ports: [
      { id: 'in-1', type: 'input', label: 'error' },
      { id: 'out-1', type: 'output', label: 'log' },
    ],
  },
]

const INITIAL_CONNECTIONS: Connection[] = [
  { id: 'conn-1', from: { nodeId: 'node-1', portId: 'out-1' }, to: { nodeId: 'node-2', portId: 'in-1' } },
  { id: 'conn-2', from: { nodeId: 'node-2', portId: 'out-1' }, to: { nodeId: 'node-3', portId: 'in-1' } },
  { id: 'conn-3', from: { nodeId: 'node-3', portId: 'out-1' }, to: { nodeId: 'node-4', portId: 'in-1' } },
  { id: 'conn-4', from: { nodeId: 'node-3', portId: 'out-2' }, to: { nodeId: 'node-5', portId: 'in-1' } },
]

interface NodesWidgetProps {
  config?: Record<string, unknown>
}

export function NodesWidget({ config: _config }: NodesWidgetProps) {
  const { settings } = useTerminalSettings()
  const { registerTool, unregisterWidgetTools } = useWidgetTools()
  const widgetId = useId()
  const containerRef = useRef<HTMLDivElement>(null)
  const [nodes, setNodes] = useState<Node[]>(INITIAL_NODES)
  const [connections, setConnections] = useState<Connection[]>(INITIAL_CONNECTIONS)
  const [selectedNode, setSelectedNode] = useState<string | null>(null)
  const [draggingNode, setDraggingNode] = useState<string | null>(null)
  const [dragOffset, setDragOffset] = useState<Position>({ x: 0, y: 0 })
  const [pan, setPan] = useState<Position>({ x: 0, y: 0 })
  const [isPanning, setIsPanning] = useState(false)
  const [panStart, setPanStart] = useState<Position>({ x: 0, y: 0 })
  const [zoom, setZoom] = useState(1)
  const [connectingFrom, setConnectingFrom] = useState<{ nodeId: string; portId: string; portType: 'input' | 'output' } | null>(null)
  const [mousePos, setMousePos] = useState<Position>({ x: 0, y: 0 })
  const [showNodeMenu, setShowNodeMenu] = useState<{ x: number; y: number; fromPort: { nodeId: string; portId: string; portType: 'input' | 'output' } } | null>(null)
  const [menuAnimating, setMenuAnimating] = useState(false)
  const [hasDragged, setHasDragged] = useState(false)
  const dragStartPos = useRef<Position | null>(null)

  // Workflow Execution State
  const [executionStatus, setExecutionStatus] = useState<Record<string, NodeExecutionStatus>>({})
  const [_nodeOutputs, setNodeOutputs] = useState<Record<string, NodeStatusChangeResult>>({})
  const [selectedAdapterId, setSelectedAdapterId] = useState<string>(AVAILABLE_ADAPTERS[0].id)
  const [isExecuting, setIsExecuting] = useState(false)

  const handleRunWorkflow = useCallback(async () => {
    if (isExecuting) return
    setIsExecuting(true)
    setExecutionStatus({})
    setNodeOutputs({})

    const adapter = AVAILABLE_ADAPTERS.find(a => a.id === selectedAdapterId) || AVAILABLE_ADAPTERS[0]
    
    try {
      await adapter.execute(
        { nodes, connections },
        (nodeId, status, result) => {
          setExecutionStatus(prev => ({ ...prev, [nodeId]: status }))
          if (result) {
            setNodeOutputs(prev => ({ ...prev, [nodeId]: result }))
          }
        }
      )
    } catch (error) {
      console.error('Workflow execution failed:', error)
    } finally {
      setIsExecuting(false)
    }
  }, [nodes, connections, selectedAdapterId, isExecuting])

  // Use refs to access current state in tool handlers and avoid stale closures
  const nodesRef = useRef(nodes)
  const connectionsRef = useRef(connections)
  const showNodeMenuRef = useRef(showNodeMenu)
  nodesRef.current = nodes
  connectionsRef.current = connections
  showNodeMenuRef.current = showNodeMenu

  // Register widget tools
  useEffect(() => {
    const tools: WidgetTool[] = [
      {
        name: 'nodes_get_all',
        description: 'Get all nodes in the workflow canvas',
        widgetId,
        widgetType: 'nodes',
        inputSchema: {},
        handler: async () => {
          return nodesRef.current.map(n => ({
            id: n.id,
            type: n.type,
            title: n.title,
            position: n.position,
            ports: n.ports.map(p => ({ id: p.id, type: p.type, label: p.label })),
          }))
        },
      },
      {
        name: 'nodes_get_connections',
        description: 'Get all connections between nodes',
        widgetId,
        widgetType: 'nodes',
        inputSchema: {},
        handler: async () => {
          return connectionsRef.current.map(c => ({
            id: c.id,
            from: c.from,
            to: c.to,
          }))
        },
      },
      {
        name: 'nodes_add',
        description: 'Add a new node to the workflow',
        widgetId,
        widgetType: 'nodes',
        inputSchema: {
          type: 'object',
          properties: {
            nodeType: { type: 'string', enum: ['input', 'process', 'output', 'condition', 'llm', 'code'] },
            title: { type: 'string' },
            x: { type: 'number' },
            y: { type: 'number' },
          },
          required: ['nodeType', 'title'],
        },
        handler: async (args) => {
          const nodeType = args.nodeType as NodeType
          const title = args.title as string
          const x = (args.x as number) ?? 200
          const y = (args.y as number) ?? 200

          const newNode: Node = {
            id: `node-${Date.now()}`,
            type: nodeType,
            title,
            position: { x, y },
            ports: nodeType === 'input'
              ? [{ id: 'out-1', type: 'output', label: 'out' }]
              : nodeType === 'output'
              ? [{ id: 'in-1', type: 'input', label: 'in' }]
              : [
                { id: 'in-1', type: 'input', label: 'in' },
                { id: 'out-1', type: 'output', label: 'out' },
              ],
          }
          setNodes(prev => [...prev, newNode])
          return { success: true, nodeId: newNode.id }
        },
      },
      {
        name: 'nodes_delete',
        description: 'Delete a node by ID',
        widgetId,
        widgetType: 'nodes',
        inputSchema: {
          type: 'object',
          properties: {
            nodeId: { type: 'string' },
          },
          required: ['nodeId'],
        },
        handler: async (args) => {
          const nodeId = args.nodeId as string
          setNodes(prev => prev.filter(n => n.id !== nodeId))
          setConnections(prev => prev.filter(c =>
            c.from.nodeId !== nodeId && c.to.nodeId !== nodeId
          ))
          return { success: true }
        },
      },
      {
        name: 'nodes_connect',
        description: 'Connect two nodes by creating a connection from output to input',
        widgetId,
        widgetType: 'nodes',
        inputSchema: {
          type: 'object',
          properties: {
            fromNodeId: { type: 'string' },
            fromPortId: { type: 'string' },
            toNodeId: { type: 'string' },
            toPortId: { type: 'string' },
          },
          required: ['fromNodeId', 'fromPortId', 'toNodeId', 'toPortId'],
        },
        handler: async (args) => {
          const conn: Connection = {
            id: `conn-${Date.now()}`,
            from: { nodeId: args.fromNodeId as string, portId: args.fromPortId as string },
            to: { nodeId: args.toNodeId as string, portId: args.toPortId as string },
          }
          setConnections(prev => [...prev, conn])
          return { success: true, connectionId: conn.id }
        },
      },
    ]

    // Register all tools
    tools.forEach(tool => registerTool(tool))

    // Cleanup on unmount
    return () => {
      unregisterWidgetTools(widgetId)
    }
  }, [widgetId, registerTool, unregisterWidgetTools])

  // Handle node dragging
  const handleNodeMouseDown = useCallback((e: MouseEvent, nodeId: string) => {
    e.stopPropagation()
    const node = nodes.find(n => n.id === nodeId)
    if (!node) return

    const container = containerRef.current
    if (!container) return

    const rect = container.getBoundingClientRect()
    const relativeX = e.clientX - rect.left
    const relativeY = e.clientY - rect.top

    setDraggingNode(nodeId)
    setHasDragged(false)
    dragStartPos.current = { x: relativeX, y: relativeY }
    setDragOffset({
      x: (relativeX - pan.x) / zoom - node.position.x,
      y: (relativeY - pan.y) / zoom - node.position.y,
    })
  }, [nodes, pan, zoom])

  // Handle port mouse down - start dragging connection
  const handlePortMouseDown = useCallback((e: MouseEvent, nodeId: string, portId: string, portType: 'input' | 'output') => {
    e.stopPropagation()
    e.preventDefault()
    setConnectingFrom({ nodeId, portId, portType })
    setShowNodeMenu(null)
  }, [])

  // Handle port mouse up - complete connection
  const handlePortMouseUp = useCallback((e: MouseEvent, nodeId: string, portId: string, portType: 'input' | 'output') => {
    e.stopPropagation()
    if (connectingFrom && connectingFrom.nodeId !== nodeId) {
      // Determine from/to based on port types
      const isFromOutput = connectingFrom.portType === 'output'
      const isToInput = portType === 'input'

      // Only connect output -> input
      if ((isFromOutput && isToInput) || (!isFromOutput && !isToInput)) {
        const newConnection: Connection = {
          id: `conn-${Date.now()}`,
          from: isFromOutput
            ? { nodeId: connectingFrom.nodeId, portId: connectingFrom.portId }
            : { nodeId, portId },
          to: isFromOutput
            ? { nodeId, portId }
            : { nodeId: connectingFrom.nodeId, portId: connectingFrom.portId },
        }
        setConnections(prev => [...prev, newConnection])
      }
    }
    setConnectingFrom(null)
  }, [connectingFrom])

  // Get recommended nodes based on source node type
  const getRecommendedNodes = useCallback((sourceNodeType: NodeType, portType: 'input' | 'output'): NodeType[] => {
    // If dragging from output, recommend nodes that typically receive data
    if (portType === 'output') {
      switch (sourceNodeType) {
        case 'input': return ['llm', 'process', 'code', 'tool', 'condition']
        case 'llm': return ['output', 'condition', 'process', 'code']
        case 'process': return ['output', 'condition', 'llm', 'code']
        case 'code': return ['output', 'condition', 'process', 'llm']
        case 'condition': return ['output', 'process', 'llm', 'code']
        case 'tool': return ['output', 'condition', 'process', 'llm']
        default: return ['process', 'output', 'condition', 'llm', 'code', 'tool']
      }
    }
    // If dragging from input, recommend nodes that provide data
    return ['input', 'llm', 'process', 'code', 'tool']
  }, [])

  // Add node from menu and connect it
  const addNodeFromMenu = useCallback((type: NodeType) => {
    // Use ref to get current value and avoid stale closure
    const menuState = showNodeMenuRef.current
    if (!menuState) return

    const { x, y, fromPort } = menuState

    // Calculate position in canvas coordinates
    const canvasX = (x - pan.x) / zoom
    const canvasY = (y - pan.y) / zoom

    // Offset based on whether we're connecting to input or output
    const offsetX = fromPort.portType === 'output' ? 50 : -230

    // Get default ports based on type
    let ports: Port[]
    let title = `New ${type}`
    let data: Record<string, unknown> | undefined

    if (type === 'input') {
      ports = [{ id: 'out-1', type: 'output', label: 'out' }]
    } else if (type === 'output') {
      ports = [{ id: 'in-1', type: 'input', label: 'in' }]
    } else if (type === 'tool') {
      const defaultTool = TOOL_DEFINITIONS.find(t => t.id === 'read_file')!
      ports = [
        ...defaultTool.inputs.map((inp, i) => ({ id: `in-${i + 1}`, type: 'input' as const, label: inp })),
        ...defaultTool.outputs.map((out, i) => ({ id: `out-${i + 1}`, type: 'output' as const, label: out })),
      ]
      title = defaultTool.name
      data = { toolGroup: 'filesystem', toolId: 'read_file' }
    } else {
      ports = [
        { id: 'in-1', type: 'input', label: 'in' },
        { id: 'out-1', type: 'output', label: 'out' },
      ]
    }

    const newNode: Node = {
      id: `node-${Date.now()}`,
      type,
      title,
      position: { x: canvasX + offsetX, y: canvasY - 30 },
      ports,
      data,
    }

    // Create connection
    const targetPort = fromPort.portType === 'output'
      ? ports.find(p => p.type === 'input')
      : ports.find(p => p.type === 'output')

    if (targetPort) {
      const newConnection: Connection = {
        id: `conn-${Date.now()}`,
        from: fromPort.portType === 'output'
          ? { nodeId: fromPort.nodeId, portId: fromPort.portId }
          : { nodeId: newNode.id, portId: targetPort.id },
        to: fromPort.portType === 'output'
          ? { nodeId: newNode.id, portId: targetPort.id }
          : { nodeId: fromPort.nodeId, portId: fromPort.portId },
      }
      setConnections(prev => [...prev, newConnection])
    }

    setNodes(prev => [...prev, newNode])
    setSelectedNode(newNode.id)
    setShowNodeMenu(null)
    setMenuAnimating(false)
  }, [pan, zoom])

  // Handle canvas panning
  const handleCanvasMouseDown = useCallback((e: MouseEvent) => {
    const container = containerRef.current
    if (!container) return

    const rect = container.getBoundingClientRect()
    const relativeX = e.clientX - rect.left
    const relativeY = e.clientY - rect.top

    // Close node menu if open
    if (showNodeMenu) {
      setShowNodeMenu(null)
      setMenuAnimating(false)
      return
    }

    if (e.button === 1 || (e.button === 0 && e.altKey)) {
      setIsPanning(true)
      setPanStart({ x: relativeX - pan.x, y: relativeY - pan.y })
    } else {
      setSelectedNode(null)
      setConnectingFrom(null)
    }
  }, [pan, showNodeMenu])

  // Mouse move handler
  useEffect(() => {
    const handleMouseMove = (e: globalThis.MouseEvent) => {
      // Get container bounds for accurate positioning
      const container = containerRef.current
      if (!container) {
        setMousePos({ x: e.clientX, y: e.clientY })
        return
      }
      const rect = container.getBoundingClientRect()
      const relativeX = e.clientX - rect.left
      const relativeY = e.clientY - rect.top
      setMousePos({ x: relativeX, y: relativeY })

      if (draggingNode) {
        // Check if we've moved enough to consider it a drag
        if (dragStartPos.current) {
          const dx = relativeX - dragStartPos.current.x
          const dy = relativeY - dragStartPos.current.y
          if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
            setHasDragged(true)
          }
        }

        const newX = (relativeX - pan.x) / zoom - dragOffset.x
        const newY = (relativeY - pan.y) / zoom - dragOffset.y
        setNodes(prev => prev.map(node =>
          node.id === draggingNode
            ? { ...node, position: { x: newX, y: newY } }
            : node
        ))
      }

      if (isPanning) {
        setPan({ x: relativeX - panStart.x, y: relativeY - panStart.y })
      }
    }

    const handleMouseUp = (e: globalThis.MouseEvent) => {
      // Check if we were connecting and released on empty space
      if (connectingFrom) {
        const container = containerRef.current
        if (container) {
          const rect = container.getBoundingClientRect()
          const relativeX = e.clientX - rect.left
          const relativeY = e.clientY - rect.top

          // Check if we're over a port (handled by port's onMouseUp)
          const target = e.target as HTMLElement
          const isOverPort = target.closest('[data-port]')

          if (!isOverPort) {
            // Show node menu at release position
            const sourceNode = nodes.find(n => n.id === connectingFrom.nodeId)
            if (sourceNode) {
              setShowNodeMenu({
                x: relativeX,
                y: relativeY,
                fromPort: connectingFrom,
              })
              setMenuAnimating(true)
            }
          }
        }
        setConnectingFrom(null)
      }

      // Only select node if it was a click, not a drag
      if (draggingNode && !hasDragged) {
        setSelectedNode(draggingNode)
      }

      setDraggingNode(null)
      setIsPanning(false)
      dragStartPos.current = null
    }

    window.addEventListener('mousemove', handleMouseMove)
    window.addEventListener('mouseup', handleMouseUp)
    return () => {
      window.removeEventListener('mousemove', handleMouseMove)
      window.removeEventListener('mouseup', handleMouseUp)
    }
  }, [draggingNode, dragOffset, isPanning, panStart, pan, zoom, connectingFrom, nodes, hasDragged])

  // Handle zoom
  const handleWheel = useCallback((e: React.WheelEvent) => {
    e.preventDefault()
    const delta = e.deltaY > 0 ? 0.9 : 1.1
    setZoom(prev => Math.min(Math.max(prev * delta, 0.25), 2))
  }, [])

  // Add new node
  const addNode = useCallback((type: NodeType) => {
    // Get default ports based on type
    let ports: Port[]
    let title = `New ${type}`
    let data: Record<string, unknown> | undefined

    if (type === 'input') {
      ports = [{ id: 'out-1', type: 'output', label: 'out' }]
    } else if (type === 'output') {
      ports = [{ id: 'in-1', type: 'input', label: 'in' }]
    } else if (type === 'tool') {
      // Tool nodes get ports based on tool definition
      const defaultTool = TOOL_DEFINITIONS.find(t => t.id === 'read_file')!
      ports = [
        ...defaultTool.inputs.map((inp, i) => ({ id: `in-${i + 1}`, type: 'input' as const, label: inp })),
        ...defaultTool.outputs.map((out, i) => ({ id: `out-${i + 1}`, type: 'output' as const, label: out })),
      ]
      title = defaultTool.name
      data = { toolGroup: 'filesystem', toolId: 'read_file' }
    } else {
      ports = [
        { id: 'in-1', type: 'input', label: 'in' },
        { id: 'out-1', type: 'output', label: 'out' },
      ]
    }

    const newNode: Node = {
      id: `node-${Date.now()}`,
      type,
      title,
      position: { x: 200 - pan.x / zoom, y: 200 - pan.y / zoom },
      ports,
      data,
    }
    setNodes(prev => [...prev, newNode])
    setSelectedNode(newNode.id)
  }, [pan, zoom])

  // Delete selected node
  const deleteSelected = useCallback(() => {
    if (!selectedNode) return
    setNodes(prev => prev.filter(n => n.id !== selectedNode))
    setConnections(prev => prev.filter(c =>
      c.from.nodeId !== selectedNode && c.to.nodeId !== selectedNode
    ))
    setSelectedNode(null)
  }, [selectedNode])

  // Get port position for drawing connections
  const getPortPosition = useCallback((nodeId: string, portId: string): Position | null => {
    const node = nodes.find(n => n.id === nodeId)
    if (!node) return null

    const port = node.ports.find(p => p.id === portId)
    if (!port) return null

    // Find the index of this port in the ports array (all ports rendered in order)
    const portIndex = node.ports.indexOf(port)

    // Node dimensions - content width is 180px, PLUS 2px border on each side
    const nodeContentWidth = 180
    const nodeBorder = 2
    const portCircleSize = 14
    const portOffset = 8 // Port circle positioned at -8px from edge

    // Header height: padding-top (10px) + icon/text height (~18px) + padding-bottom (10px) + border-bottom (1px)
    const headerHeight = 39

    // Port section: starts with padding-top 8px
    const portSectionPaddingTop = 8

    // Each port row: height is padding (4px top + 4px bottom) + content (~14px) = 22px
    const portRowHeight = 22

    // X: Center of the port circle
    // The port circle is absolutely positioned relative to the port row
    // Port row starts at node.position.x + nodeBorder
    // Input: left: -8px from row left edge, center is +7px from circle left
    // Output: right: -8px from row right edge, so circle right is at row right + 8
    const x = port.type === 'input'
      ? node.position.x + nodeBorder - portOffset + (portCircleSize / 2)
      : node.position.x + nodeBorder + nodeContentWidth + portOffset - (portCircleSize / 2)

    // Y position: Port circle is now centered with transform: translateY(-50%) at top: 50%
    // So the center is at the vertical center of the port row
    const y = node.position.y + headerHeight + portSectionPaddingTop + (portIndex * portRowHeight) + (portRowHeight / 2)

    return { x, y }
  }, [nodes])

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: settings.theme.background,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      {/* Toolbar */}
      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          gap: '8px',
          padding: '12px 16px',
          borderBottom: `1px solid ${settings.theme.brightBlack}40`,
          backgroundColor: `${settings.theme.background}ee`,
          flexShrink: 0,
          minHeight: 'fit-content',
          overflow: 'visible',
        }}
      >
        <button
          onClick={() => addNode('input')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.input}20`,
            border: `1px solid ${NODE_COLORS.input}`,
            borderRadius: '6px',
            color: NODE_COLORS.input,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> Input
        </button>
        <button
          onClick={() => addNode('llm')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.llm}20`,
            border: `1px solid ${NODE_COLORS.llm}`,
            borderRadius: '6px',
            color: NODE_COLORS.llm,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> LLM
        </button>
        <button
          onClick={() => addNode('code')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.code}20`,
            border: `1px solid ${NODE_COLORS.code}`,
            borderRadius: '6px',
            color: NODE_COLORS.code,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> Code
        </button>
        <button
          onClick={() => addNode('condition')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.condition}20`,
            border: `1px solid ${NODE_COLORS.condition}`,
            borderRadius: '6px',
            color: NODE_COLORS.condition,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> Condition
        </button>
        <button
          onClick={() => addNode('output')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.output}20`,
            border: `1px solid ${NODE_COLORS.output}`,
            borderRadius: '6px',
            color: NODE_COLORS.output,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> Output
        </button>
        <button
          onClick={() => addNode('tool')}
          style={{
            padding: '6px 12px',
            backgroundColor: `${NODE_COLORS.tool}20`,
            border: `1px solid ${NODE_COLORS.tool}`,
            borderRadius: '6px',
            color: NODE_COLORS.tool,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Plus size={14} /> Tool
        </button>

        <div style={{ flex: 1 }} />

        {/* Adapter Selector */}
        <select
          value={selectedAdapterId}
          onChange={(e) => setSelectedAdapterId(e.target.value)}
          style={{
            padding: '6px 8px',
            backgroundColor: `${settings.theme.background}`,
            border: `1px solid ${settings.theme.brightBlack}60`,
            borderRadius: '6px',
            color: settings.theme.foreground,
            fontSize: '11px',
            outline: 'none',
            cursor: 'pointer',
            marginRight: '8px',
          }}
        >
          {AVAILABLE_ADAPTERS.map(adapter => (
            <option key={adapter.id} value={adapter.id}>
              {adapter.name}
            </option>
          ))}
        </select>

        {selectedNode && (
          <button
            onClick={deleteSelected}
            style={{
              padding: '6px 12px',
              backgroundColor: `${settings.theme.red}20`,
              border: `1px solid ${settings.theme.red}`,
              borderRadius: '6px',
              color: settings.theme.red,
              fontSize: '12px',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              marginRight: '8px',
            }}
          >
            <Trash2 size={14} /> Delete
          </button>
        )}

        <button
          onClick={handleRunWorkflow}
          disabled={isExecuting}
          style={{
            padding: '6px 12px',
            backgroundColor: isExecuting ? `${settings.theme.yellow}20` : `${settings.theme.green}20`,
            border: `1px solid ${isExecuting ? settings.theme.yellow : settings.theme.green}`,
            borderRadius: '6px',
            color: isExecuting ? settings.theme.yellow : settings.theme.green,
            fontSize: '12px',
            cursor: isExecuting ? 'wait' : 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
            opacity: isExecuting ? 0.8 : 1,
          }}
        >
          {isExecuting ? <Zap size={14} className="animate-pulse" /> : <Play size={14} />}
          {isExecuting ? 'Running...' : 'Run'}
        </button>

        <div
          style={{
            padding: '6px 12px',
            backgroundColor: `${settings.theme.brightBlack}20`,
            borderRadius: '6px',
            color: settings.theme.foreground,
            fontSize: '12px',
            marginLeft: '8px',
          }}
        >
          {Math.round(zoom * 100)}%
        </div>
      </div>

      {/* Canvas */}
      <div
        ref={containerRef}
        onMouseDown={handleCanvasMouseDown}
        onWheel={handleWheel}
        style={{
          flex: 1,
          position: 'relative',
          overflow: 'hidden',
          cursor: isPanning ? 'grabbing' : connectingFrom ? 'crosshair' : 'default',
        }}
      >
        {/* Grid background */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundImage: `
              linear-gradient(${settings.theme.brightBlack}20 1px, transparent 1px),
              linear-gradient(90deg, ${settings.theme.brightBlack}20 1px, transparent 1px)
            `,
            backgroundSize: `${20 * zoom}px ${20 * zoom}px`,
            backgroundPosition: `${pan.x}px ${pan.y}px`,
          }}
        />

        {/* SVG for connections */}
        <svg
          style={{
            position: 'absolute',
            inset: 0,
            width: '100%',
            height: '100%',
            pointerEvents: 'none',
            overflow: 'visible',
          }}
        >
          <defs>
            {/* Gradient definitions for connections */}
            {connections.map(conn => {
              const fromNode = nodes.find(n => n.id === conn.from.nodeId)
              const toNode = nodes.find(n => n.id === conn.to.nodeId)
              if (!fromNode || !toNode) return null

              const fromColor = NODE_COLORS[fromNode.type]
              const toColor = NODE_COLORS[toNode.type]

              return (
                <linearGradient
                  key={`gradient-${conn.id}`}
                  id={`gradient-${conn.id}`}
                  gradientUnits="userSpaceOnUse"
                  x1="0%"
                  y1="0%"
                  x2="100%"
                  y2="0%"
                >
                  <stop offset="0%" stopColor={fromColor} />
                  <stop offset="100%" stopColor={toColor} />
                </linearGradient>
              )
            })}

            {/* Gradient for connection being drawn */}
            {connectingFrom && (() => {
              const fromNode = nodes.find(n => n.id === connectingFrom.nodeId)
              if (!fromNode) return null
              const fromColor = NODE_COLORS[fromNode.type]

              return (
                <linearGradient
                  id="gradient-drawing"
                  gradientUnits="userSpaceOnUse"
                  x1="0%"
                  y1="0%"
                  x2="100%"
                  y2="0%"
                >
                  <stop offset="0%" stopColor={fromColor} />
                  <stop offset="100%" stopColor={settings.theme.cyan} />
                </linearGradient>
              )
            })()}
          </defs>

          <g transform={`translate(${pan.x}, ${pan.y}) scale(${zoom})`}>
            {/* Existing connections */}
            {connections.map(conn => {
              const fromPos = getPortPosition(conn.from.nodeId, conn.from.portId)
              const toPos = getPortPosition(conn.to.nodeId, conn.to.portId)
              if (!fromPos || !toPos) return null

              const midX = (fromPos.x + toPos.x) / 2

              return (
                <path
                  key={conn.id}
                  d={`M ${fromPos.x} ${fromPos.y} C ${midX} ${fromPos.y}, ${midX} ${toPos.y}, ${toPos.x} ${toPos.y}`}
                  fill="none"
                  stroke={`url(#gradient-${conn.id})`}
                  strokeWidth={2.5}
                  strokeLinecap="round"
                  opacity={0.85}
                />
              )
            })}

            {/* Connection being drawn */}
            {connectingFrom && (() => {
              const fromPos = getPortPosition(connectingFrom.nodeId, connectingFrom.portId)
              if (!fromPos) return null

              const toX = (mousePos.x - pan.x) / zoom
              const toY = (mousePos.y - pan.y) / zoom
              const midX = (fromPos.x + toX) / 2

              return (
                <path
                  d={`M ${fromPos.x} ${fromPos.y} C ${midX} ${fromPos.y}, ${midX} ${toY}, ${toX} ${toY}`}
                  fill="none"
                  stroke={`url(#gradient-drawing)`}
                  strokeWidth={2.5}
                  strokeLinecap="round"
                  strokeDasharray="8,4"
                  opacity={0.9}
                />
              )
            })()}
          </g>
        </svg>

        {/* Nodes */}
        <div
          style={{
            position: 'absolute',
            transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`,
            transformOrigin: '0 0',
            overflow: 'visible',
          }}
        >
          {nodes.map(node => {
            const Icon = NODE_ICONS[node.type]
            const color = NODE_COLORS[node.type]
            const isSelected = selectedNode === node.id
            const status = executionStatus[node.id]
            
            // Determine display color based on status
            const statusColor = status === 'running' ? settings.theme.yellow :
                               status === 'completed' ? settings.theme.green :
                               status === 'error' ? settings.theme.red :
                               color
            
            // Use status color for border if active/completed, otherwise normal color
            const borderColor = status ? statusColor : (isSelected ? color : settings.theme.brightBlack)
            const glowColor = status ? statusColor : color

            return (
              <div
                key={node.id}
                onMouseDown={(e) => handleNodeMouseDown(e, node.id)}
                style={{
                  position: 'absolute',
                  left: node.position.x,
                  top: node.position.y,
                  width: '180px',
                  backgroundColor: `${settings.theme.background}f0`,
                  border: `2px solid ${borderColor}`,
                  borderRadius: '12px',
                  boxShadow: isSelected || status === 'running'
                    ? `0 0 20px ${glowColor}40`
                    : '0 4px 12px rgba(0,0,0,0.3)',
                  cursor: 'grab',
                  userSelect: 'none',
                  overflow: 'visible',
                  transition: 'border-color 0.3s, box-shadow 0.3s',
                }}
              >
                {/* Header */}
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    padding: '10px 12px',
                    borderBottom: `1px solid ${settings.theme.brightBlack}40`,
                    backgroundColor: `${color}15`,
                    borderRadius: '10px 10px 0 0',
                  }}
                >
                  <Icon size={16} style={{ color }} />
                  <span style={{ color: settings.theme.foreground, fontSize: '13px', fontWeight: 500, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {node.title}
                  </span>
                  
                  {/* Status Indicator */}
                  {status === 'running' && (
                    <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: settings.theme.yellow, boxShadow: `0 0 8px ${settings.theme.yellow}` }} />
                  )}
                  {status === 'completed' && (
                    <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: settings.theme.green }} />
                  )}
                  {status === 'error' && (
                    <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: settings.theme.red }} />
                  )}
                </div>

                {/* Ports */}
                <div style={{ padding: '8px 0' }}>
                  {node.ports.map(port => (
                    <div
                      key={port.id}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: port.type === 'input' ? 'flex-start' : 'flex-end',
                        padding: '4px 12px',
                        position: 'relative',
                      }}
                    >
                      {/* Port circle */}
                      <div
                        data-port="true"
                        onMouseDown={(e) => handlePortMouseDown(e, node.id, port.id, port.type)}
                        onMouseUp={(e) => handlePortMouseUp(e, node.id, port.id, port.type)}
                        style={{
                          position: 'absolute',
                          [port.type === 'input' ? 'left' : 'right']: '-8px',
                          top: '50%',
                          transform: 'translateY(-50%)',
                          width: '14px',
                          height: '14px',
                          borderRadius: '50%',
                          backgroundColor: connectingFrom ? (
                            // Highlight valid drop targets
                            (connectingFrom.portType !== port.type && connectingFrom.nodeId !== node.id)
                              ? `${color}`
                              : settings.theme.background
                          ) : settings.theme.background,
                          border: `2px solid ${color}`,
                          cursor: 'crosshair',
                          transition: 'all 0.15s ease',
                          boxShadow: connectingFrom && connectingFrom.portType !== port.type && connectingFrom.nodeId !== node.id
                            ? `0 0 8px ${color}`
                            : 'none',
                        }}
                        onMouseEnter={(e) => {
                          e.currentTarget.style.transform = 'translateY(-50%) scale(1.4)'
                        }}
                        onMouseLeave={(e) => {
                          e.currentTarget.style.transform = 'translateY(-50%) scale(1)'
                        }}
                      />
                      <span
                        style={{
                          color: settings.theme.brightBlack,
                          fontSize: '11px',
                          marginLeft: port.type === 'input' ? '12px' : 0,
                          marginRight: port.type === 'output' ? '12px' : 0,
                        }}
                      >
                        {port.label}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )
          })}
        </div>

        {/* Help text */}
        {!selectedNode && !showNodeMenu && (
          <div
            style={{
              position: 'absolute',
              bottom: '16px',
              left: '16px',
              padding: '8px 12px',
              backgroundColor: `${settings.theme.background}e0`,
              borderRadius: '6px',
              border: `1px solid ${settings.theme.brightBlack}40`,
              color: settings.theme.brightBlack,
              fontSize: '11px',
            }}
          >
            Drag from ports to connect | Alt+Drag to pan | Scroll to zoom
          </div>
        )}

        {/* Animated Node Menu */}
        {showNodeMenu && (() => {
          const sourceNode = nodes.find(n => n.id === showNodeMenu.fromPort.nodeId)
          if (!sourceNode) return null
          const recommendedNodes = getRecommendedNodes(sourceNode.type, showNodeMenu.fromPort.portType)

          return (
            <div
              style={{
                position: 'absolute',
                left: showNodeMenu.x,
                top: showNodeMenu.y,
                transform: 'translate(-50%, -50%)',
                zIndex: 200,
              }}
              onClick={(e) => e.stopPropagation()}
            >
              {/* Backdrop blur circle */}
              <div
                style={{
                  position: 'absolute',
                  left: '50%',
                  top: '50%',
                  transform: 'translate(-50%, -50%)',
                  width: menuAnimating ? '200px' : '0px',
                  height: menuAnimating ? '200px' : '0px',
                  borderRadius: '50%',
                  backgroundColor: `${settings.theme.background}d0`,
                  backdropFilter: 'blur(8px)',
                  transition: 'all 0.2s cubic-bezier(0.34, 1.56, 0.64, 1)',
                  boxShadow: `0 8px 32px rgba(0,0,0,0.4), inset 0 0 0 1px ${settings.theme.brightBlack}30`,
                  pointerEvents: 'none',
                }}
              />

              {/* Cancel button in center */}
              <button
                onClick={() => {
                  setShowNodeMenu(null)
                  setMenuAnimating(false)
                }}
                style={{
                  position: 'absolute',
                  left: '50%',
                  top: '50%',
                  transform: 'translate(-50%, -50%)',
                  width: '32px',
                  height: '32px',
                  borderRadius: '50%',
                  backgroundColor: `${settings.theme.red}30`,
                  border: `2px solid ${settings.theme.red}`,
                  color: settings.theme.red,
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: '16px',
                  fontWeight: 'bold',
                  opacity: menuAnimating ? 1 : 0,
                  transition: 'all 0.2s ease 0.1s',
                  zIndex: 10,
                }}
              >
                ×
              </button>

              {/* Node options in a circle */}
              {recommendedNodes.map((nodeType, index) => {
                const angle = (index / recommendedNodes.length) * Math.PI * 2 - Math.PI / 2
                const radius = 75
                const x = Math.cos(angle) * radius
                const y = Math.sin(angle) * radius
                const Icon = NODE_ICONS[nodeType]
                const nodeColor = NODE_COLORS[nodeType]

                return (
                  <button
                    key={nodeType}
                    onClick={(e) => {
                      e.preventDefault()
                      e.stopPropagation()
                      addNodeFromMenu(nodeType)
                    }}
                    onMouseDown={(e) => e.stopPropagation()}
                    style={{
                      position: 'absolute',
                      left: '50%',
                      top: '50%',
                      transform: menuAnimating
                        ? `translate(calc(-50% + ${x}px), calc(-50% + ${y}px)) scale(1)`
                        : 'translate(-50%, -50%) scale(0)',
                      width: '44px',
                      height: '44px',
                      borderRadius: '50%',
                      backgroundColor: `${nodeColor}25`,
                      border: `2px solid ${nodeColor}`,
                      color: nodeColor,
                      cursor: 'pointer',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      transition: `all 0.25s cubic-bezier(0.34, 1.56, 0.64, 1) ${0.03 * index}s`,
                      boxShadow: `0 4px 12px ${nodeColor}40`,
                      zIndex: 5,
                    }}
                    onMouseEnter={(e) => {
                      e.currentTarget.style.transform = `translate(calc(-50% + ${x}px), calc(-50% + ${y}px)) scale(1.15)`
                      e.currentTarget.style.boxShadow = `0 6px 20px ${nodeColor}60`
                    }}
                    onMouseLeave={(e) => {
                      e.currentTarget.style.transform = `translate(calc(-50% + ${x}px), calc(-50% + ${y}px)) scale(1)`
                      e.currentTarget.style.boxShadow = `0 4px 12px ${nodeColor}40`
                    }}
                    title={nodeType.charAt(0).toUpperCase() + nodeType.slice(1)}
                  >
                    <Icon size={20} />
                  </button>
                )
              })}
            </div>
          )
        })()}
      </div>

      {/* Properties Panel - Top Right */}
      {selectedNode && nodes.find(n => n.id === selectedNode) && (
        <div
          style={{
            position: 'absolute',
            top: '60px',
            right: '16px',
            bottom: '16px',
            zIndex: 100,
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          <NodePropertiesPanel
            node={nodes.find(n => n.id === selectedNode)!}
            onUpdate={(updates) => {
              setNodes(prev => prev.map(n =>
                n.id === selectedNode ? { ...n, ...updates } : n
              ))
            }}
            onClose={() => setSelectedNode(null)}
          />
        </div>
      )}
    </div>
  )
}

// Attribute Input Component - Renders different input types based on schema
interface AttributeInputProps {
  schema: AttributeSchema
  value: unknown
  onChange: (value: unknown) => void
  theme: TerminalTheme
  nodeColor: string
}

function AttributeInput({ schema, value, onChange, theme, nodeColor }: AttributeInputProps) {
  const inputStyle = {
    width: '100%',
    padding: '8px 10px',
    backgroundColor: theme.background,
    border: `1px solid ${theme.brightBlack}40`,
    borderRadius: '8px',
    color: theme.foreground,
    fontSize: '12px',
    outline: 'none',
  }

  switch (schema.type) {
    case 'text':
      return (
        <input
          type="text"
          value={(value as string) ?? schema.defaultValue ?? ''}
          onChange={(e) => onChange(e.target.value)}
          placeholder={schema.placeholder}
          style={inputStyle}
        />
      )

    case 'textarea':
      return (
        <textarea
          value={(value as string) ?? schema.defaultValue ?? ''}
          onChange={(e) => onChange(e.target.value)}
          placeholder={schema.placeholder}
          rows={schema.rows ?? 3}
          style={{ ...inputStyle, resize: 'vertical', fontFamily: 'inherit' }}
        />
      )

    case 'number':
      return (
        <input
          type="number"
          value={(value as number) ?? schema.defaultValue ?? 0}
          onChange={(e) => onChange(parseFloat(e.target.value) || 0)}
          min={schema.min}
          max={schema.max}
          step={schema.step ?? 1}
          style={inputStyle}
        />
      )

    case 'select':
      return (
        <select
          value={(value as string) ?? (schema.defaultValue as string) ?? ''}
          onChange={(e) => onChange(e.target.value)}
          style={{ ...inputStyle, cursor: 'pointer' }}
        >
          {schema.options?.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      )

    case 'checkbox':
      return (
        <label
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            cursor: 'pointer',
            padding: '4px 0',
          }}
        >
          <input
            type="checkbox"
            checked={(value as boolean) ?? (schema.defaultValue as boolean) ?? false}
            onChange={(e) => onChange(e.target.checked)}
            style={{
              width: '16px',
              height: '16px',
              accentColor: nodeColor,
              cursor: 'pointer',
            }}
          />
          <span style={{ color: theme.foreground, fontSize: '12px' }}>
            {schema.label}
          </span>
        </label>
      )

    case 'radio':
      return (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          {schema.options?.map((opt) => (
            <label
              key={opt.value}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                cursor: 'pointer',
              }}
            >
              <input
                type="radio"
                name={schema.key}
                value={opt.value}
                checked={(value as string) === opt.value}
                onChange={(e) => onChange(e.target.value)}
                style={{ accentColor: nodeColor, cursor: 'pointer' }}
              />
              <span style={{ color: theme.foreground, fontSize: '12px' }}>
                {opt.label}
              </span>
            </label>
          ))}
        </div>
      )

    case 'slider':
      const sliderValue = (value as number) ?? (schema.defaultValue as number) ?? schema.min ?? 0
      return (
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <input
            type="range"
            value={sliderValue}
            onChange={(e) => onChange(parseFloat(e.target.value))}
            min={schema.min ?? 0}
            max={schema.max ?? 100}
            step={schema.step ?? 1}
            style={{
              flex: 1,
              accentColor: nodeColor,
              cursor: 'pointer',
            }}
          />
          <span
            style={{
              minWidth: '40px',
              textAlign: 'right',
              color: theme.foreground,
              fontSize: '11px',
              fontFamily: 'monospace',
            }}
          >
            {sliderValue.toFixed(schema.step && schema.step < 1 ? 1 : 0)}
          </span>
        </div>
      )

    case 'button':
      return (
        <button
          onClick={() => onChange(schema.buttonAction)}
          style={{
            padding: '8px 16px',
            backgroundColor: `${nodeColor}20`,
            border: `1px solid ${nodeColor}`,
            borderRadius: '8px',
            color: nodeColor,
            fontSize: '12px',
            cursor: 'pointer',
            width: '100%',
          }}
        >
          {schema.label}
        </button>
      )

    default:
      return null
  }
}

// Tool Selector Component for cascading dropdowns
interface ToolSelectorProps {
  toolGroup: ToolGroup
  toolId: string
  onGroupChange: (group: ToolGroup) => void
  onToolChange: (toolId: string) => void
  theme: TerminalTheme
  nodeColor: string
}

function ToolSelector({ toolGroup, toolId, onGroupChange, onToolChange, theme, nodeColor }: ToolSelectorProps) {
  // Get tools for current group - this updates when toolGroup changes
  const tools = useMemo(() => getToolsByGroup(toolGroup), [toolGroup])

  // Find selected tool, falling back to first in group if current toolId not in group
  const selectedTool = useMemo(() => {
    const found = tools.find(t => t.id === toolId)
    return found || tools[0]
  }, [tools, toolId])

  const inputStyle = {
    width: '100%',
    padding: '8px 10px',
    backgroundColor: theme.background,
    border: `1px solid ${theme.brightBlack}40`,
    borderRadius: '8px',
    color: theme.foreground,
    fontSize: '12px',
    outline: 'none',
    cursor: 'pointer',
  }

  // Handle group change - auto-select first tool in new group
  const handleGroupChange = useCallback((newGroup: ToolGroup) => {
    onGroupChange(newGroup)
    const newTools = getToolsByGroup(newGroup)
    if (newTools.length > 0) {
      onToolChange(newTools[0].id)
    }
  }, [onGroupChange, onToolChange])

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
      {/* Tool Group */}
      <div>
        <label style={{ display: 'block', fontSize: '11px', color: theme.foreground, marginBottom: '4px', opacity: 0.8 }}>
          Tool Group
        </label>
        <select
          value={toolGroup}
          onChange={(e) => handleGroupChange(e.target.value as ToolGroup)}
          style={inputStyle}
        >
          <option value="filesystem">Filesystem</option>
          <option value="search">Search</option>
          <option value="coding">Coding</option>
          <option value="git">Git</option>
          <option value="web">Web</option>
          <option value="ai">AI</option>
          <option value="system">System</option>
        </select>
      </div>

      {/* Tool */}
      <div>
        <label style={{ display: 'block', fontSize: '11px', color: theme.foreground, marginBottom: '4px', opacity: 0.8 }}>
          Tool
        </label>
        <select
          value={selectedTool?.id || ''}
          onChange={(e) => onToolChange(e.target.value)}
          style={inputStyle}
        >
          {tools.map((tool) => (
            <option key={tool.id} value={tool.id}>
              {tool.name}
            </option>
          ))}
        </select>
      </div>

      {/* Tool Description */}
      {selectedTool && (
        <div
          style={{
            padding: '10px 12px',
            backgroundColor: `${nodeColor}10`,
            borderRadius: '8px',
            border: `1px solid ${nodeColor}30`,
          }}
        >
          <div style={{ color: theme.foreground, fontSize: '12px', fontWeight: 500, marginBottom: '4px' }}>
            {selectedTool.name}
          </div>
          <div style={{ color: theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>
            {selectedTool.description}
          </div>
          <div style={{ display: 'flex', gap: '16px', fontSize: '10px' }}>
            <div>
              <span style={{ color: theme.green }}>Inputs: </span>
              <span style={{ color: theme.foreground }}>{selectedTool.inputs.join(', ') || 'none'}</span>
            </div>
            <div>
              <span style={{ color: theme.blue }}>Outputs: </span>
              <span style={{ color: theme.foreground }}>{selectedTool.outputs.join(', ') || 'none'}</span>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

// Properties Panel Component
interface NodePropertiesPanelProps {
  node: Node
  onUpdate: (updates: Partial<Node>) => void
  onClose: () => void
}

function NodePropertiesPanel({ node, onUpdate, onClose }: NodePropertiesPanelProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const Icon = NODE_ICONS[node.type]
  const color = NODE_COLORS[node.type]

  const [title, setTitle] = useState(node.title)
  const [jsonMode, setJsonMode] = useState(false)
  const [jsonText, setJsonText] = useState('')
  const [jsonError, setJsonError] = useState<string | null>(null)

  // Parse and validate node data with Zod
  const parsedData = parseNodeData(node.type, node.data)
  const [data, setData] = useState<Record<string, unknown>>(parsedData)

  // Get UI schema for this node type
  const uiSchema = NODE_UI_SCHEMAS[node.type] ?? []

  // Group attributes by their group property
  const groupedAttrs = uiSchema.reduce<Record<string, AttributeSchema[]>>((acc, attr) => {
    const group = attr.group ?? 'General'
    if (!acc[group]) acc[group] = []
    acc[group].push(attr)
    return acc
  }, {})

  // Update local state when node changes
  useEffect(() => {
    setTitle(node.title)
    const parsed = parseNodeData(node.type, node.data)
    setData(parsed)
    setJsonText(serializeNodeData(node.type, node.data))
    setJsonError(null)
  }, [node.id, node.title, node.data, node.type])

  const handleTitleChange = (newTitle: string) => {
    setTitle(newTitle)
    onUpdate({ title: newTitle })
  }

  const handleDataChange = (key: string, value: unknown) => {
    const newData = { ...data, [key]: value }
    // Validate with Zod
    const result = validateNodeData(node.type, newData)
    if (result.success) {
      setData(result.data)
      onUpdate({ data: result.data })
    } else {
      // Still update locally but don't persist invalid data
      setData(newData)
    }
  }

  const handleJsonChange = (text: string) => {
    setJsonText(text)
    const result = deserializeNodeData(node.type, text)
    if (result.success) {
      setJsonError(null)
      setData(result.data)
      onUpdate({ data: result.data })
    } else {
      setJsonError(result.error)
    }
  }

  const toggleJsonMode = () => {
    if (!jsonMode) {
      // Entering JSON mode - serialize current data
      setJsonText(serializeNodeData(node.type, data))
      setJsonError(null)
    }
    setJsonMode(!jsonMode)
  }

  const addPort = (type: 'input' | 'output') => {
    const existingPorts = node.ports.filter(p => p.type === type)
    const newPort: Port = {
      id: `${type === 'input' ? 'in' : 'out'}-${existingPorts.length + 1}`,
      type,
      label: `${type === 'input' ? 'in' : 'out'}${existingPorts.length + 1}`,
    }
    onUpdate({ ports: [...node.ports, newPort] })
  }

  const removePort = (portId: string) => {
    onUpdate({ ports: node.ports.filter(p => p.id !== portId) })
  }

  // Handle tool changes - update ports based on selected tool
  const handleToolChange = (toolId: string) => {
    const tool = TOOL_DEFINITIONS.find(t => t.id === toolId)
    if (tool) {
      const newPorts: Port[] = [
        ...tool.inputs.map((inp, i) => ({ id: `in-${i + 1}`, type: 'input' as const, label: inp })),
        ...tool.outputs.map((out, i) => ({ id: `out-${i + 1}`, type: 'output' as const, label: out })),
      ]
      handleDataChange('toolId', toolId)
      onUpdate({ title: tool.name, ports: newPorts })
    }
  }

  return (
    <div
      style={{
        width: '340px',
        flex: 1,
        minHeight: 0,
        maxHeight: '100%',
        borderRadius: '16px',
        border: `2px solid ${color}`,
        backgroundColor: `${theme.background}f8`,
        backdropFilter: 'blur(12px)',
        display: 'flex',
        flexDirection: 'column',
        boxShadow: `0 8px 32px rgba(0,0,0,0.4), 0 0 0 1px ${theme.brightBlack}20`,
        overflow: 'hidden',
      }}
    >
      {/* Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '10px',
          padding: '12px 14px',
          backgroundColor: `${color}20`,
          borderBottom: `1px solid ${theme.brightBlack}30`,
          flexShrink: 0,
        }}
      >
        <Icon size={16} style={{ color }} />
        <input
          type="text"
          value={title}
          onChange={(e) => handleTitleChange(e.target.value)}
          style={{
            flex: 1,
            fontSize: '13px',
            fontWeight: 600,
            color: theme.foreground,
            backgroundColor: 'transparent',
            border: 'none',
            outline: 'none',
          }}
        />
        <button
          onClick={toggleJsonMode}
          title={jsonMode ? 'Switch to Form View' : 'Edit as JSON'}
          style={{
            padding: '4px 6px',
            backgroundColor: jsonMode ? `${color}30` : 'transparent',
            border: `1px solid ${jsonMode ? color : theme.brightBlack}40`,
            borderRadius: '4px',
            color: jsonMode ? color : theme.brightBlack,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
          }}
        >
          <FileJson size={14} />
        </button>
        <button
          onClick={onClose}
          style={{
            padding: '4px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '6px',
            color: theme.brightBlack,
            cursor: 'pointer',
            fontSize: '16px',
            lineHeight: 1,
          }}
        >
          ×
        </button>
      </div>

      {/* Content */}
      <div
        style={{
          flex: 1,
          padding: '12px 14px',
          overflow: 'auto',
          display: 'flex',
          flexDirection: 'column',
          gap: '16px',
        }}
      >
        {/* Ports Section - always visible */}
        <div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
            <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px', fontWeight: 600 }}>
              Ports
            </label>
            <div style={{ display: 'flex', gap: '4px' }}>
              <button
                onClick={() => addPort('input')}
                style={{ padding: '2px 6px', backgroundColor: `${theme.green}20`, border: `1px solid ${theme.green}60`, borderRadius: '4px', color: theme.green, fontSize: '9px', cursor: 'pointer' }}
              >
                + In
              </button>
              <button
                onClick={() => addPort('output')}
                style={{ padding: '2px 6px', backgroundColor: `${theme.blue}20`, border: `1px solid ${theme.blue}60`, borderRadius: '4px', color: theme.blue, fontSize: '9px', cursor: 'pointer' }}
              >
                + Out
              </button>
            </div>
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px' }}>
            {node.ports.map((port) => (
              <div
                key={port.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '4px',
                  padding: '3px 6px',
                  backgroundColor: `${port.type === 'input' ? theme.green : theme.blue}15`,
                  border: `1px solid ${port.type === 'input' ? theme.green : theme.blue}40`,
                  borderRadius: '4px',
                  fontSize: '10px',
                }}
              >
                <span style={{ color: port.type === 'input' ? theme.green : theme.blue }}>
                  {port.type === 'input' ? '→' : '←'}
                </span>
                <span style={{ color: theme.foreground }}>{port.label}</span>
                <button
                  onClick={() => removePort(port.id)}
                  style={{ padding: '0 2px', backgroundColor: 'transparent', border: 'none', color: theme.brightBlack, cursor: 'pointer', fontSize: '11px', lineHeight: 1 }}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        </div>

        {/* JSON Mode */}
        {jsonMode ? (
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px', fontWeight: 600 }}>
              JSON Configuration
            </label>
            <textarea
              value={jsonText}
              onChange={(e) => handleJsonChange(e.target.value)}
              style={{
                flex: 1,
                minHeight: '200px',
                padding: '10px 12px',
                backgroundColor: theme.background,
                border: `1px solid ${jsonError ? theme.red : theme.brightBlack}40`,
                borderRadius: '8px',
                color: theme.foreground,
                fontSize: '12px',
                fontFamily: 'monospace',
                outline: 'none',
                resize: 'vertical',
              }}
            />
            {jsonError && (
              <div
                style={{
                  padding: '8px 10px',
                  backgroundColor: `${theme.red}15`,
                  border: `1px solid ${theme.red}40`,
                  borderRadius: '6px',
                  color: theme.red,
                  fontSize: '11px',
                }}
              >
                {jsonError}
              </div>
            )}
            <div
              style={{
                fontSize: '10px',
                color: theme.brightBlack,
                opacity: 0.7,
              }}
            >
              Edit JSON directly. Changes are validated with Zod schema.
            </div>
          </div>
        ) : (
          /* Form Mode - Schema-based Attributes */
          <>
            {/* Special handling for Tool nodes */}
            {node.type === 'tool' && (
              <div>
                <label
                  style={{
                    display: 'block',
                    fontSize: '10px',
                    color: theme.brightBlack,
                    textTransform: 'uppercase',
                    letterSpacing: '0.5px',
                    fontWeight: 600,
                    marginBottom: '10px',
                    paddingBottom: '4px',
                    borderBottom: `1px solid ${theme.brightBlack}20`,
                  }}
                >
                  Tool Selection
                </label>
                <ToolSelector
                  toolGroup={(data.toolGroup as ToolGroup) || 'filesystem'}
                  toolId={(data.toolId as string) || 'read_file'}
                  onGroupChange={(group) => handleDataChange('toolGroup', group)}
                  onToolChange={handleToolChange}
                  theme={theme}
                  nodeColor={color}
                />
              </div>
            )}

            {/* Standard schema-based attributes */}
            {Object.entries(groupedAttrs)
              .filter(([groupName]) => node.type !== 'tool' || groupName !== 'Tool')
              .map(([groupName, attrs]) => (
              <div key={groupName}>
                <label
                  style={{
                    display: 'block',
                    fontSize: '10px',
                    color: theme.brightBlack,
                    textTransform: 'uppercase',
                    letterSpacing: '0.5px',
                    fontWeight: 600,
                    marginBottom: '10px',
                    paddingBottom: '4px',
                    borderBottom: `1px solid ${theme.brightBlack}20`,
                  }}
                >
                  {groupName}
                </label>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
                  {attrs.map((attr) => (
                    <div key={attr.key}>
                      {attr.type !== 'checkbox' && attr.type !== 'button' && (
                        <label
                          style={{
                            display: 'block',
                            fontSize: '11px',
                            color: theme.foreground,
                            marginBottom: '4px',
                            opacity: 0.8,
                          }}
                        >
                          {attr.label}
                        </label>
                      )}
                      <AttributeInput
                        schema={attr}
                        value={data[attr.key]}
                        onChange={(val) => handleDataChange(attr.key, val)}
                        theme={theme}
                        nodeColor={color}
                      />
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </>
        )}
      </div>
    </div>
  )
}

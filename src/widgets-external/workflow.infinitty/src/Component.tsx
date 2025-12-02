// Workflow Widget - React UI Component
// This component connects to the widget's MCP server for workflow execution

import { useState, useCallback, useRef, useEffect, type MouseEvent, type DragEvent } from 'react'
import type { Node, Connection, Position, NodeType, NodeStatus } from './types.js'

// Icons (using simple SVG representations)
const Icons = {
  Database: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>,
  Cpu: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><rect x="4" y="4" width="16" height="16" rx="2" ry="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/></svg>,
  Zap: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>,
  GitBranch: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg>,
  MessageSquare: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>,
  Code: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>,
  Tool: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="16" height="16"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>,
  Plus: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>,
  Play: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><polygon points="5 3 19 12 5 21 5 3"/></svg>,
  Trash: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>,
  Save: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg>,
  FolderOpen: () => <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>,
}

const NODE_ICONS: Record<NodeType, () => JSX.Element> = {
  input: Icons.Database,
  process: Icons.Cpu,
  output: Icons.Zap,
  condition: Icons.GitBranch,
  llm: Icons.MessageSquare,
  code: Icons.Code,
  tool: Icons.Tool,
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

// Map Mermaid class to node type
const CLASS_TO_TYPE: Record<string, NodeType> = {
  skill: 'llm',
  principle: 'input',
  workflow: 'process',
  reference: 'output',
  routing: 'condition',
}

// Parse Mermaid flowchart to nodes and connections
function parseMermaidToWorkflow(mermaid: string): { nodes: Node[]; connections: Connection[] } {

  const nodes: Node[] = []
  const connections: Connection[] = []
  const nodeMap = new Map<string, Node>()
  const lines = mermaid.split('\n')

  let connectionIndex = 0

  // Auto-layout settings
  const X_START = 100
  const Y_START = 100
  const X_SPACING = 220
  const Y_SPACING = 100

  // Track positions for layout
  let currentGroup = ''
  let groupY = Y_START
  const groupCounts: Record<string, number> = {}

  for (const line of lines) {
    const trimmed = line.trim()

    // Skip empty lines, comments, classDef, direction, flowchart header
    if (!trimmed || trimmed.startsWith('%') || trimmed.startsWith('classDef') ||
        trimmed.startsWith('direction') || trimmed === 'end' || trimmed.startsWith('flowchart')) {
      continue
    }

    // Track subgraph for positioning
    if (trimmed.startsWith('subgraph')) {
      const subgraphMatch = trimmed.match(/^subgraph\s+(\w+)/)
      if (subgraphMatch) {
        currentGroup = subgraphMatch[1]
        groupCounts[currentGroup] = 0
        groupY += Y_SPACING
      }
      continue
    }

    // Parse node definition - try with class first, then without
    // Format: id["label"]:::class or id["label"]
    let nodeMatch: RegExpMatchArray | null = null
    let nodeId = '', nodeLabel = '', nodeClass = ''

    if (!trimmed.includes('-->') && !trimmed.startsWith('subgraph')) {
      // Try with :::class suffix first
      const withClassMatch = trimmed.match(/^(\w+)\[(.+?)\]:::(\w+)$/)
      if (withClassMatch) {
        nodeId = withClassMatch[1]
        nodeLabel = withClassMatch[2].replace(/^["']|["']$/g, '') // Remove quotes
        nodeClass = withClassMatch[3]
        nodeMatch = withClassMatch
      } else {
        // Try without :::class
        const withoutClassMatch = trimmed.match(/^(\w+)\[(.+?)\]$/)
        if (withoutClassMatch) {
          nodeId = withoutClassMatch[1]
          nodeLabel = withoutClassMatch[2].replace(/^["']|["']$/g, '')
          nodeClass = ''
          nodeMatch = withoutClassMatch
        }
      }
    }

    if (nodeMatch && nodeId) {
      if (nodeMap.has(nodeId)) {
        continue
      }

      // Clean label (remove emoji, split on \n)
      const labelParts = nodeLabel.replace(/[\u{1F300}-\u{1F9FF}]/gu, '').split('\\n')
      const title = labelParts[0].trim() || nodeId

      // Get node type from class
      const nodeType: NodeType = CLASS_TO_TYPE[nodeClass] || 'process'

      // Calculate position
      let x: number, y: number
      if (currentGroup) {
        const count = groupCounts[currentGroup] || 0
        x = X_START + (count * X_SPACING)
        y = groupY
        groupCounts[currentGroup] = count + 1
      } else {
        x = X_START + X_SPACING * 2
        y = Y_START
      }

      const node: Node = {
        id: nodeId,
        type: nodeType,
        title,
        position: { x, y },
        ports: [
          { id: `${nodeId}-in`, type: 'input', label: 'in' },
          { id: `${nodeId}-out`, type: 'output', label: 'out' },
        ],
      }

      nodes.push(node)
      nodeMap.set(nodeId, node)
    }

    // Parse connection: source --> target or source -->|"label"| target
    const connMatch = trimmed.match(/^(\w+)\s*-->\s*(?:\|[^|]*\|)?\s*(\w+)$/)
    if (connMatch) {
      const [, fromId, toId] = connMatch

      // Only create connection if both nodes exist
      if (nodeMap.has(fromId) && nodeMap.has(toId)) {
        connections.push({
          id: `conn-${connectionIndex++}`,
          from: { nodeId: fromId, portId: `${fromId}-out` },
          to: { nodeId: toId, portId: `${toId}-in` },
        })
      }
    }
  }

  return { nodes, connections }
}

// Demo nodes
const INITIAL_NODES: Node[] = [
  { id: 'node-1', type: 'input', title: 'User Input', position: { x: 50, y: 100 }, ports: [{ id: 'out-1', type: 'output', label: 'text' }] },
  { id: 'node-2', type: 'llm', title: 'GPT-4 Process', position: { x: 300, y: 80 }, ports: [{ id: 'in-1', type: 'input', label: 'prompt' }, { id: 'out-1', type: 'output', label: 'response' }] },
  { id: 'node-3', type: 'condition', title: 'Check Valid', position: { x: 550, y: 100 }, ports: [{ id: 'in-1', type: 'input', label: 'data' }, { id: 'out-1', type: 'output', label: 'yes' }, { id: 'out-2', type: 'output', label: 'no' }] },
  { id: 'node-4', type: 'output', title: 'Success', position: { x: 800, y: 50 }, ports: [{ id: 'in-1', type: 'input', label: 'result' }] },
  { id: 'node-5', type: 'code', title: 'Error Handler', position: { x: 800, y: 180 }, ports: [{ id: 'in-1', type: 'input', label: 'error' }, { id: 'out-1', type: 'output', label: 'log' }] },
]

const INITIAL_CONNECTIONS: Connection[] = [
  { id: 'conn-1', from: { nodeId: 'node-1', portId: 'out-1' }, to: { nodeId: 'node-2', portId: 'in-1' } },
  { id: 'conn-2', from: { nodeId: 'node-2', portId: 'out-1' }, to: { nodeId: 'node-3', portId: 'in-1' } },
  { id: 'conn-3', from: { nodeId: 'node-3', portId: 'out-1' }, to: { nodeId: 'node-4', portId: 'in-1' } },
  { id: 'conn-4', from: { nodeId: 'node-3', portId: 'out-2' }, to: { nodeId: 'node-5', portId: 'in-1' } },
]

interface WorkflowComponentProps {
  serverUrl?: string
  theme?: {
    background: string
    foreground: string
    brightBlack: string
    red: string
    green: string
    yellow: string
    blue: string
    cyan: string
  }
}

export function WorkflowComponent({ serverUrl = 'http://localhost:3030', theme }: WorkflowComponentProps) {
  const defaultTheme = {
    background: '#1a1b26',
    foreground: '#c0caf5',
    brightBlack: '#565f89',
    red: '#f7768e',
    green: '#9ece6a',
    yellow: '#e0af68',
    blue: '#7aa2f7',
    cyan: '#7dcfff',
  }
  const colors = theme || defaultTheme

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

  // Mermaid/drop state
  const [isDragOver, setIsDragOver] = useState(false)
  const [mermaidSource, setMermaidSource] = useState<string>('')
  const [sourcePath, setSourcePath] = useState<string>('')
  const [dropMessage, setDropMessage] = useState<string>('')
  const [isLoading, setIsLoading] = useState(false)

  // Execution state
  const [executionStatus, setExecutionStatus] = useState<Record<string, NodeStatus>>({})
  const [isExecuting, setIsExecuting] = useState(false)
  const [adapters, setAdapters] = useState<Array<{ id: string; name: string; description: string }>>([])
  const [selectedAdapter, setSelectedAdapter] = useState('local-browser')
  const wsRef = useRef<WebSocket | null>(null)

  // Connect to WebSocket
  useEffect(() => {
    const ws = new WebSocket(`${serverUrl.replace('http', 'ws')}/ws`)

    ws.onopen = () => {
      console.log('[WorkflowComponent] WebSocket connected')
    }

    ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data)
        if (message.method === 'workflow/nodeStatus') {
          const { nodeId, status, result } = message.params
          setExecutionStatus((prev) => ({ ...prev, [nodeId]: status }))
          if (status === 'completed' || status === 'error') {
            console.log(`[Node ${nodeId}] ${status}:`, result)
          }
        }
      } catch (err) {
        console.error('[WorkflowComponent] WebSocket message error:', err)
      }
    }

    ws.onclose = () => {
      console.log('[WorkflowComponent] WebSocket disconnected')
    }

    wsRef.current = ws

    // Fetch adapters
    fetch(`${serverUrl}/mcp`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: { name: 'list_adapters', arguments: {} },
      }),
    })
      .then((r) => r.json())
      .then((result) => {
        if (result.result?.content?.[0]?.json) {
          setAdapters(result.result.content[0].json)
        }
      })
      .catch(console.error)

    return () => {
      ws.close()
    }
  }, [serverUrl])

  // Run workflow
  const handleRunWorkflow = useCallback(async () => {
    if (isExecuting) return
    setIsExecuting(true)
    setExecutionStatus({})

    try {
      const response = await fetch(`${serverUrl}/mcp`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: Date.now(),
          method: 'tools/call',
          params: {
            name: 'run_workflow',
            arguments: {
              adapterId: selectedAdapter,
              context: { nodes, connections },
            },
          },
        }),
      })

      const result = await response.json()
      console.log('[WorkflowComponent] Execution complete:', result)
    } catch (err) {
      console.error('[WorkflowComponent] Execution error:', err)
    } finally {
      setIsExecuting(false)
    }
  }, [serverUrl, nodes, connections, selectedAdapter, isExecuting])

  // Save workflow
  const handleSaveWorkflow = useCallback(async () => {
    const name = prompt('Workflow name:')
    if (!name) return

    try {
      const response = await fetch(`${serverUrl}/mcp`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: Date.now(),
          method: 'tools/call',
          params: {
            name: 'save_workflow',
            arguments: { name, nodes, connections },
          },
        }),
      })

      const result = await response.json()
      console.log('[WorkflowComponent] Saved:', result)
      alert(`Workflow saved: ${result.result?.content?.[0]?.json?.id}`)
    } catch (err) {
      console.error('[WorkflowComponent] Save error:', err)
    }
  }, [serverUrl, nodes, connections])

  // Add node
  const addNode = useCallback((type: NodeType) => {
    const ports = type === 'input'
      ? [{ id: 'out-1', type: 'output' as const, label: 'out' }]
      : type === 'output'
      ? [{ id: 'in-1', type: 'input' as const, label: 'in' }]
      : [{ id: 'in-1', type: 'input' as const, label: 'in' }, { id: 'out-1', type: 'output' as const, label: 'out' }]

    const newNode: Node = {
      id: `node-${Date.now()}`,
      type,
      title: `New ${type}`,
      position: { x: 200 - pan.x / zoom, y: 200 - pan.y / zoom },
      ports,
    }
    setNodes((prev) => [...prev, newNode])
    setSelectedNode(newNode.id)
  }, [pan, zoom])

  // Delete node
  const deleteSelected = useCallback(() => {
    if (!selectedNode) return
    setNodes((prev) => prev.filter((n) => n.id !== selectedNode))
    setConnections((prev) =>
      prev.filter((c) => c.from?.nodeId !== selectedNode && c.to?.nodeId !== selectedNode)
    )
    setSelectedNode(null)
  }, [selectedNode])

  // Node mouse handlers
  const handleNodeMouseDown = useCallback((e: MouseEvent, nodeId: string) => {
    e.stopPropagation()
    const node = nodes.find((n) => n.id === nodeId)
    if (!node || !node.position || !containerRef.current) return

    const rect = containerRef.current.getBoundingClientRect()
    const relativeX = e.clientX - rect.left
    const relativeY = e.clientY - rect.top

    setDraggingNode(nodeId)
    setDragOffset({
      x: (relativeX - pan.x) / zoom - node.position.x,
      y: (relativeY - pan.y) / zoom - node.position.y,
    })
  }, [nodes, pan, zoom])

  const handlePortMouseDown = useCallback((e: MouseEvent, nodeId: string, portId: string, portType: 'input' | 'output') => {
    e.stopPropagation()
    e.preventDefault()
    setConnectingFrom({ nodeId, portId, portType })
  }, [])

  const handlePortMouseUp = useCallback((e: MouseEvent, nodeId: string, portId: string, portType: 'input' | 'output') => {
    e.stopPropagation()
    if (connectingFrom && connectingFrom.nodeId !== nodeId) {
      const isFromOutput = connectingFrom.portType === 'output'
      const isToInput = portType === 'input'

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
        setConnections((prev) => [...prev, newConnection])
      }
    }
    setConnectingFrom(null)
  }, [connectingFrom])

  const handleCanvasMouseDown = useCallback((e: MouseEvent) => {
    const container = containerRef.current
    if (!container) return

    const rect = container.getBoundingClientRect()
    const relativeX = e.clientX - rect.left
    const relativeY = e.clientY - rect.top

    if (e.button === 1 || (e.button === 0 && e.altKey)) {
      setIsPanning(true)
      setPanStart({ x: relativeX - pan.x, y: relativeY - pan.y })
    } else {
      setSelectedNode(null)
      setConnectingFrom(null)
    }
  }, [pan])

  // Mouse move/up effects
  useEffect(() => {
    const handleMouseMove = (e: globalThis.MouseEvent) => {
      const container = containerRef.current
      if (!container) return
      const rect = container.getBoundingClientRect()
      const relativeX = e.clientX - rect.left
      const relativeY = e.clientY - rect.top
      setMousePos({ x: relativeX, y: relativeY })

      if (draggingNode) {
        const newX = (relativeX - pan.x) / zoom - dragOffset.x
        const newY = (relativeY - pan.y) / zoom - dragOffset.y
        setNodes((prev) =>
          prev.map((node) =>
            node.id === draggingNode ? { ...node, position: { x: newX, y: newY } } : node
          )
        )
      }

      if (isPanning) {
        setPan({ x: relativeX - panStart.x, y: relativeY - panStart.y })
      }
    }

    const handleMouseUp = () => {
      setDraggingNode(null)
      setIsPanning(false)
      setConnectingFrom(null)
    }

    window.addEventListener('mousemove', handleMouseMove)
    window.addEventListener('mouseup', handleMouseUp)
    return () => {
      window.removeEventListener('mousemove', handleMouseMove)
      window.removeEventListener('mouseup', handleMouseUp)
    }
  }, [draggingNode, dragOffset, isPanning, panStart, pan, zoom])

  // Wheel zoom
  const handleWheel = useCallback((e: React.WheelEvent) => {
    e.preventDefault()
    const delta = e.deltaY > 0 ? 0.9 : 1.1
    setZoom((prev) => Math.min(Math.max(prev * delta, 0.25), 2))
  }, [])

  // Load skill from path via /parse endpoint
  const loadFromPath = useCallback(async (path: string) => {
    console.log('[WorkflowComponent] loadFromPath:', path)
    setIsLoading(true)
    setDropMessage(`Loading: ${path.split('/').pop() || path}...`)
    try {
      const response = await fetch(`${serverUrl}/parse`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path }),
      })
      const result = await response.json()
      console.log('[WorkflowComponent] Parse result:', result)
      if (result.mermaid) {
        setMermaidSource(result.mermaid)
        setSourcePath(path)

        // Parse Mermaid to workflow nodes and connections
        const { nodes: parsedNodes, connections: parsedConnections } = parseMermaidToWorkflow(result.mermaid)
        if (parsedNodes.length > 0) {
          setNodes(parsedNodes)
          setConnections(parsedConnections)
          setSelectedNode(null)
          setPan({ x: 0, y: 0 })
          setZoom(1)
          setDropMessage(`Loaded ${parsedNodes.length} nodes from: ${path.split('/').pop() || path}`)
          console.log('[WorkflowComponent] Workflow loaded:', parsedNodes.length, 'nodes')
        } else {
          setDropMessage(`Loaded (no nodes): ${path.split('/').pop() || path}`)
          console.log('[WorkflowComponent] Mermaid loaded but no nodes parsed')
        }
      } else if (result.error) {
        console.error('[WorkflowComponent] Parse error:', result.error)
        setDropMessage(`Error: ${result.error}`)
      }
    } catch (err) {
      console.error('[WorkflowComponent] Failed to load:', err)
      setDropMessage(`Failed to load: ${err}`)
    } finally {
      setIsLoading(false)
      // Clear message after 3s
      setTimeout(() => setDropMessage(''), 3000)
    }
  }, [serverUrl])

  // Listen for Tauri drag-drop events
  useEffect(() => {
    const handleTauriFileDrop = (event: CustomEvent<{ paths: string[] }>) => {
      console.log('[WorkflowComponent] Tauri file drop received:', event.detail)
      const paths = event.detail.paths
      if (paths && paths.length > 0) {
        // Load the first dropped path
        loadFromPath(paths[0])
      }
      setIsDragOver(false)
    }

    const handleDragEnter = () => {
      console.log('[WorkflowComponent] Tauri drag enter')
      setIsDragOver(true)
    }

    const handleDragLeave = () => {
      console.log('[WorkflowComponent] Tauri drag leave')
      setIsDragOver(false)
    }

    window.addEventListener('tauri-file-drop', handleTauriFileDrop as EventListener)
    window.addEventListener('tauri-drag-enter', handleDragEnter)
    window.addEventListener('tauri-drag-leave', handleDragLeave)

    return () => {
      window.removeEventListener('tauri-file-drop', handleTauriFileDrop as EventListener)
      window.removeEventListener('tauri-drag-enter', handleDragEnter)
      window.removeEventListener('tauri-drag-leave', handleDragLeave)
    }
  }, [loadFromPath])

  // Handle drop
  const handleDrop = useCallback(async (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    e.stopPropagation()
    setIsDragOver(false)
    console.log('[WorkflowComponent] Drop event, types:', e.dataTransfer.types)

    // Check for file with path (Tauri)
    const items = Array.from(e.dataTransfer.items)
    for (const item of items) {
      if (item.kind === 'file') {
        const file = item.getAsFile()
        if (file && (file as any).path) {
          await loadFromPath((file as any).path)
          return
        }
      }
    }

    // Check for text/uri-list
    const uriList = e.dataTransfer.getData('text/uri-list')
    if (uriList) {
      const paths = uriList.split('\n').filter(p => p && !p.startsWith('#'))
      for (const uri of paths) {
        const path = decodeURIComponent(uri.replace('file://', ''))
        console.log('[WorkflowComponent] URI path:', path)
        await loadFromPath(path)
        return
      }
    }

    // Check for text/plain path
    const text = e.dataTransfer.getData('text/plain')
    if (text && (text.startsWith('/') || text.startsWith('~'))) {
      const path = text.startsWith('~') ? text.replace(/^~/, '/Users/jkneen') : text
      console.log('[WorkflowComponent] Text path:', path)
      await loadFromPath(path)
    }
  }, [loadFromPath])

  const handleDragOver = useCallback((e: DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    setIsDragOver(true)
  }, [])

  const handleDragLeave = useCallback((e: DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    setIsDragOver(false)
  }, [])

  // Get port position for connections
  const getPortPosition = useCallback((nodeId: string, portId: string): Position | null => {
    const node = nodes.find((n) => n.id === nodeId)
    if (!node || !node.ports || !node.position) return null

    const port = node.ports.find((p) => p.id === portId)
    if (!port) return null

    const portIndex = node.ports.indexOf(port)
    const nodeContentWidth = 180
    const nodeBorder = 2
    const portCircleSize = 14
    const portOffset = 8
    const headerHeight = 39
    const portSectionPaddingTop = 8
    const portRowHeight = 22

    const x = port.type === 'input'
      ? node.position.x + nodeBorder - portOffset + portCircleSize / 2
      : node.position.x + nodeBorder + nodeContentWidth + portOffset - portCircleSize / 2

    const y = node.position.y + headerHeight + portSectionPaddingTop + portIndex * portRowHeight + portRowHeight / 2

    return { x, y }
  }, [nodes])

  return (
    <div
      onDrop={handleDrop}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: colors.background,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        border: isDragOver ? `2px dashed ${colors.cyan}` : '2px solid transparent',
      }}
    >
      {/* Toolbar */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px', padding: '12px 16px', borderBottom: `1px solid ${colors.brightBlack}40`, backgroundColor: `${colors.background}ee`, flexShrink: 0 }}>
        {(['input', 'llm', 'code', 'condition', 'output', 'tool'] as NodeType[]).map((type) => (
          <button
            key={type}
            onClick={() => addNode(type)}
            title={`Add ${type} node`}
            style={{
              padding: '6px 12px',
              backgroundColor: `${NODE_COLORS[type]}20`,
              border: `1px solid ${NODE_COLORS[type]}`,
              borderRadius: '6px',
              color: NODE_COLORS[type],
              fontSize: '12px',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
            }}
          >
            <Icons.Plus /> {type.charAt(0).toUpperCase() + type.slice(1)}
          </button>
        ))}

        <div style={{ flex: 1 }} />

        {/* Adapter selector */}
        <select
          value={selectedAdapter}
          onChange={(e) => setSelectedAdapter(e.target.value)}
          style={{
            padding: '6px 8px',
            backgroundColor: colors.background,
            border: `1px solid ${colors.brightBlack}60`,
            borderRadius: '6px',
            color: colors.foreground,
            fontSize: '11px',
            outline: 'none',
            cursor: 'pointer',
          }}
        >
          {adapters.map((a) => (
            <option key={a.id} value={a.id}>{a.name}</option>
          ))}
        </select>

        {selectedNode && (
          <button
            onClick={deleteSelected}
            style={{
              padding: '6px 12px',
              backgroundColor: `${colors.red}20`,
              border: `1px solid ${colors.red}`,
              borderRadius: '6px',
              color: colors.red,
              fontSize: '12px',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
            }}
          >
            <Icons.Trash /> Delete
          </button>
        )}

        <button
          onClick={handleSaveWorkflow}
          style={{
            padding: '6px 12px',
            backgroundColor: `${colors.blue}20`,
            border: `1px solid ${colors.blue}`,
            borderRadius: '6px',
            color: colors.blue,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Icons.Save /> Save
        </button>

        <button
          onClick={handleRunWorkflow}
          disabled={isExecuting}
          style={{
            padding: '6px 12px',
            backgroundColor: isExecuting ? `${colors.yellow}20` : `${colors.green}20`,
            border: `1px solid ${isExecuting ? colors.yellow : colors.green}`,
            borderRadius: '6px',
            color: isExecuting ? colors.yellow : colors.green,
            fontSize: '12px',
            cursor: isExecuting ? 'wait' : 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
          }}
        >
          <Icons.Play /> {isExecuting ? 'Running...' : 'Run'}
        </button>

        <div style={{ padding: '6px 12px', backgroundColor: `${colors.brightBlack}20`, borderRadius: '6px', color: colors.foreground, fontSize: '12px' }}>
          {Math.round(zoom * 100)}%
        </div>
      </div>

      {/* Canvas */}
      <div
        ref={containerRef}
        onMouseDown={handleCanvasMouseDown}
        onWheel={handleWheel}
        style={{ flex: 1, position: 'relative', overflow: 'hidden', cursor: isPanning ? 'grabbing' : connectingFrom ? 'crosshair' : 'default' }}
      >
        {/* Grid */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundImage: `linear-gradient(${colors.brightBlack}20 1px, transparent 1px), linear-gradient(90deg, ${colors.brightBlack}20 1px, transparent 1px)`,
            backgroundSize: `${20 * zoom}px ${20 * zoom}px`,
            backgroundPosition: `${pan.x}px ${pan.y}px`,
          }}
        />

        {/* Connections SVG */}
        <svg style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}>
          <g transform={`translate(${pan.x}, ${pan.y}) scale(${zoom})`}>
            {connections.map((conn) => {
              if (!conn.from || !conn.to) return null
              const fromPos = getPortPosition(conn.from.nodeId, conn.from.portId)
              const toPos = getPortPosition(conn.to.nodeId, conn.to.portId)
              if (!fromPos || !toPos) return null

              const midX = (fromPos.x + toPos.x) / 2
              const fromNode = nodes.find((n) => n.id === conn.from?.nodeId)
              const color = fromNode && fromNode.type in NODE_COLORS
                ? NODE_COLORS[fromNode.type as NodeType]
                : colors.cyan

              return (
                <path
                  key={conn.id}
                  d={`M ${fromPos.x} ${fromPos.y} C ${midX} ${fromPos.y}, ${midX} ${toPos.y}, ${toPos.x} ${toPos.y}`}
                  fill="none"
                  stroke={color}
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
              const fromNode = nodes.find((n) => n.id === connectingFrom.nodeId)
              const color = fromNode && fromNode.type in NODE_COLORS
                ? NODE_COLORS[fromNode.type as NodeType]
                : colors.cyan

              return (
                <path
                  d={`M ${fromPos.x} ${fromPos.y} C ${midX} ${fromPos.y}, ${midX} ${toY}, ${toX} ${toY}`}
                  fill="none"
                  stroke={color}
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
        <div style={{ position: 'absolute', transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`, transformOrigin: '0 0', overflow: 'visible' }}>
          {nodes.map((node) => {
            if (!node.position) return null
            const nodeType = node.type as NodeType
            const Icon = node.type in NODE_ICONS ? NODE_ICONS[nodeType] : Icons.Tool
            const color = node.type in NODE_COLORS ? NODE_COLORS[nodeType] : colors.cyan
            const isSelected = selectedNode === node.id
            const status = executionStatus[node.id]

            const statusColor =
              status === 'running' ? colors.yellow :
              status === 'completed' ? colors.green :
              status === 'error' ? colors.red : color

            const borderColor = status ? statusColor : isSelected ? color : colors.brightBlack

            return (
              <div
                key={node.id}
                onMouseDown={(e) => handleNodeMouseDown(e, node.id)}
                onClick={() => setSelectedNode(node.id)}
                style={{
                  position: 'absolute',
                  left: node.position.x,
                  top: node.position.y,
                  width: '180px',
                  backgroundColor: `${colors.background}f0`,
                  border: `2px solid ${borderColor}`,
                  borderRadius: '12px',
                  boxShadow: isSelected || status === 'running' ? `0 0 20px ${statusColor}40` : '0 4px 12px rgba(0,0,0,0.3)',
                  cursor: 'grab',
                  userSelect: 'none',
                  overflow: 'visible',
                  transition: 'border-color 0.3s, box-shadow 0.3s',
                }}
              >
                {/* Header */}
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px', padding: '10px 12px', borderBottom: `1px solid ${colors.brightBlack}40`, backgroundColor: `${color}15`, borderRadius: '10px 10px 0 0' }}>
                  <Icon />
                  <span style={{ color: colors.foreground, fontSize: '13px', fontWeight: 500, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {node.title}
                  </span>
                  {status === 'running' && <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: colors.yellow, boxShadow: `0 0 8px ${colors.yellow}` }} />}
                  {status === 'completed' && <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: colors.green }} />}
                  {status === 'error' && <div style={{ width: '8px', height: '8px', borderRadius: '50%', backgroundColor: colors.red }} />}
                </div>

                {/* Ports */}
                <div style={{ padding: '8px 0' }}>
                  {(node.ports || []).map((port) => (
                    <div
                      key={port.id}
                      style={{ display: 'flex', alignItems: 'center', justifyContent: port.type === 'input' ? 'flex-start' : 'flex-end', padding: '4px 12px', position: 'relative' }}
                    >
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
                          backgroundColor: connectingFrom && connectingFrom.portType !== port.type && connectingFrom.nodeId !== node.id ? color : colors.background,
                          border: `2px solid ${color}`,
                          cursor: 'crosshair',
                          transition: 'all 0.15s ease',
                          boxShadow: connectingFrom && connectingFrom.portType !== port.type && connectingFrom.nodeId !== node.id ? `0 0 8px ${color}` : 'none',
                        }}
                      />
                      <span style={{ color: colors.brightBlack, fontSize: '11px', marginLeft: port.type === 'input' ? '12px' : 0, marginRight: port.type === 'output' ? '12px' : 0 }}>
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
        <div style={{ position: 'absolute', bottom: '16px', left: '16px', padding: '8px 12px', backgroundColor: `${colors.background}e0`, borderRadius: '6px', border: `1px solid ${colors.brightBlack}40`, color: colors.brightBlack, fontSize: '11px' }}>
          Drag from ports to connect | Alt+Drag to pan | Scroll to zoom | Drop skill folders to import
        </div>

        {/* Drag overlay */}
        {isDragOver && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              backgroundColor: `${colors.cyan}20`,
              border: `3px dashed ${colors.cyan}`,
              borderRadius: '8px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              pointerEvents: 'none',
              zIndex: 100,
            }}
          >
            <div
              style={{
                padding: '24px 48px',
                backgroundColor: `${colors.background}f0`,
                borderRadius: '12px',
                border: `2px solid ${colors.cyan}`,
                textAlign: 'center',
              }}
            >
              <div style={{ color: colors.cyan, fontSize: '18px', fontWeight: 600, marginBottom: '8px' }}>
                Drop to Import
              </div>
              <div style={{ color: colors.foreground, fontSize: '13px' }}>
                Drop a skill folder to convert to workflow
              </div>
            </div>
          </div>
        )}

        {/* Status message */}
        {dropMessage && (
          <div
            style={{
              position: 'absolute',
              bottom: '60px',
              left: '50%',
              transform: 'translateX(-50%)',
              padding: '12px 24px',
              backgroundColor: `${colors.background}f0`,
              borderRadius: '8px',
              border: `1px solid ${isLoading ? colors.yellow : dropMessage.includes('Error') ? colors.red : colors.green}`,
              color: isLoading ? colors.yellow : dropMessage.includes('Error') ? colors.red : colors.green,
              fontSize: '13px',
              fontWeight: 500,
              zIndex: 101,
              boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
            }}
          >
            {isLoading && (
              <span style={{ marginRight: '8px' }}>
                <svg width="14" height="14" viewBox="0 0 24 24" style={{ animation: 'spin 1s linear infinite', display: 'inline-block', verticalAlign: 'middle' }}>
                  <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" fill="none" strokeDasharray="31.4 31.4" />
                </svg>
              </span>
            )}
            {dropMessage}
          </div>
        )}

        {/* Mermaid source display (debug) */}
        {mermaidSource && (
          <div
            style={{
              position: 'absolute',
              top: '60px',
              right: '16px',
              maxWidth: '300px',
              maxHeight: '200px',
              padding: '12px',
              backgroundColor: `${colors.background}f0`,
              borderRadius: '8px',
              border: `1px solid ${colors.brightBlack}60`,
              overflow: 'auto',
              fontSize: '10px',
              fontFamily: 'monospace',
              color: colors.foreground,
              whiteSpace: 'pre-wrap',
              zIndex: 50,
            }}
          >
            <div style={{ color: colors.cyan, marginBottom: '8px', fontWeight: 600 }}>
              Source: {sourcePath.split('/').pop()}
            </div>
            {mermaidSource.substring(0, 500)}
            {mermaidSource.length > 500 && '...'}
          </div>
        )}
      </div>
    </div>
  )
}

export default WorkflowComponent

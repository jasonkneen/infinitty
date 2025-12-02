import { createContext, useContext, useState, useCallback, useRef, useEffect, type ReactNode } from 'react'
import type { MCPServerConfig, MCPServerStatus, MCPTool } from '../types/mcp'
import { DEFAULT_MCP_SERVERS } from '../types/mcp'
import { MCPClientManager } from '../services/mcpClient'
import { getErrorMessage } from '../lib/utils'

interface MCPConnectionContextValue {
  // Connection state
  serverStatuses: Record<string, MCPServerStatus>
  selectedServerId: string | null
  isDiscovering: boolean

  // Connection management
  connectServer: (serverId: string) => Promise<void>
  disconnectServer: (serverId: string) => Promise<void>
  refreshServer: (serverId: string) => Promise<void>
  discoverServers: () => Promise<void>
  selectServer: (serverId: string | null) => void

  // Tool access
  getAllTools: () => MCPTool[]
  getServerTools: (serverId: string) => MCPTool[]
  callTool: (serverId: string, toolName: string, args: Record<string, unknown>) => Promise<unknown>

  // Internal ref for parent context integration
  clientManagerRef: React.MutableRefObject<MCPClientManager | null>
}

const MCPConnectionContext = createContext<MCPConnectionContextValue | null>(null)

export function useMCPConnection() {
  const context = useContext(MCPConnectionContext)
  if (!context) {
    throw new Error('useMCPConnection must be used within MCPConnectionProvider')
  }
  return context
}

interface MCPConnectionProviderProps {
  children: ReactNode
  servers: MCPServerConfig[]
  autoConnectServerIds: string[]
  addServer: (config: Omit<MCPServerConfig, 'id'>) => Promise<MCPServerConfig>
}

export function MCPConnectionProvider({
  children,
  servers,
  autoConnectServerIds,
  addServer,
}: MCPConnectionProviderProps) {
  const [serverStatuses, setServerStatuses] = useState<Record<string, MCPServerStatus>>({})
  const [selectedServerId, setSelectedServerId] = useState<string | null>(null)
  const [isDiscovering, setIsDiscovering] = useState(false)

  // Create MCP client manager with callbacks
  const clientManagerRef = useRef<MCPClientManager | null>(null)

  // Track if component is mounted to prevent state updates after unmount
  const mountedRef = useRef(true)

  // Set mounted state and cleanup
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  // Initialize client manager
  useEffect(() => {
    clientManagerRef.current = new MCPClientManager({
      onStatusChange: (serverId, status, error) => {
        // Only update state if component is still mounted
        if (mountedRef.current) {
          setServerStatuses((prev) => ({
            ...prev,
            [serverId]: {
              ...prev[serverId],
              status,
              error,
              lastConnected: status === 'connected' ? Date.now() : prev[serverId]?.lastConnected,
            },
          }))
        }
      },
      onToolsChange: (serverId, tools) => {
        // Only update state if component is still mounted
        if (mountedRef.current) {
          setServerStatuses((prev) => ({
            ...prev,
            [serverId]: {
              ...prev[serverId],
              tools,
            },
          }))
        }
      },
    })

    // Expose the manager globally so non-React services (AI providers)
    // can access MCP tools.
    ;(globalThis as any).__infinittyMcpManager = clientManagerRef.current

    return () => {
      clientManagerRef.current?.disconnectAll()
      if ((globalThis as any).__infinittyMcpManager === clientManagerRef.current) {
        delete (globalThis as any).__infinittyMcpManager
      }
    }
  }, [])

  // Initialize server statuses when servers change
  useEffect(() => {
    setServerStatuses((prev) => {
      const next = { ...prev }
      // Remove statuses for servers that no longer exist
      for (const serverId of Object.keys(next)) {
        if (!servers.find((s) => s.id === serverId)) {
          delete next[serverId]
        }
      }
      // Add new statuses for new servers
      for (const server of servers) {
        if (!next[server.id]) {
          next[server.id] = {
            id: server.id,
            status: 'disconnected',
            tools: [],
            resources: [],
            prompts: [],
          }
        }
      }
      return next
    })
  }, [servers])

  const connectServer = useCallback(
    async (serverId: string) => {
      const server = servers.find((s) => s.id === serverId)
      if (!server) return

      if (mountedRef.current) {
        setServerStatuses((prev) => ({
          ...prev,
          [serverId]: {
            ...prev[serverId],
            status: 'connecting',
            error: undefined,
          },
        }))
      }

      try {
        // Use the real MCP client manager to spawn and connect
        if (clientManagerRef.current) {
          await clientManagerRef.current.connect(server)
        }
      } catch (err) {
        if (mountedRef.current) {
          setServerStatuses((prev) => ({
            ...prev,
            [serverId]: {
              ...prev[serverId],
              status: 'error',
              error: err instanceof Error ? err.message : 'Connection failed',
            },
          }))
        }
      }
    },
    [servers]
  )

  const disconnectServer = useCallback(async (serverId: string) => {
    // Disconnect using the client manager
    if (clientManagerRef.current) {
      await clientManagerRef.current.disconnect(serverId)
    }

    // Only update state if component is still mounted
    if (mountedRef.current) {
      setServerStatuses((prev) => ({
        ...prev,
        [serverId]: {
          ...prev[serverId],
          status: 'disconnected',
          tools: [],
          resources: [],
          prompts: [],
        },
      }))
    }
  }, [])

  const refreshServer = useCallback(
    async (serverId: string) => {
      await disconnectServer(serverId)
      await connectServer(serverId)
    },
    [connectServer, disconnectServer]
  )

  const discoverServers = useCallback(async () => {
    if (mountedRef.current) {
      setIsDiscovering(true)
    }

    try {
      // Add default MCP servers that aren't already added
      const existingNames = new Set(servers.map((s) => s.name))

      for (const defaultServer of DEFAULT_MCP_SERVERS) {
        // Check if we should continue after each operation
        if (!mountedRef.current) return

        if (!existingNames.has(defaultServer.name)) {
          await addServer(defaultServer)
        }
      }

      // In a real implementation, we would also:
      // - Check for installed MCP packages in node_modules
      // - Look for .mcp.json in common locations
      // - Check Claude Desktop config file

      await new Promise((resolve) => setTimeout(resolve, 500))
    } finally {
      if (mountedRef.current) {
        setIsDiscovering(false)
      }
    }
  }, [servers, addServer])

  const selectServer = useCallback((serverId: string | null) => {
    setSelectedServerId(serverId)
  }, [])

  const getAllTools = useCallback((): MCPTool[] => {
    return Object.values(serverStatuses)
      .filter((status) => status.status === 'connected')
      .flatMap((status) => status.tools)
  }, [serverStatuses])

  const getServerTools = useCallback((serverId: string): MCPTool[] => {
    return serverStatuses[serverId]?.tools ?? []
  }, [serverStatuses])

  const callTool = useCallback(
    async (serverId: string, toolName: string, args: Record<string, unknown>): Promise<unknown> => {
      if (!clientManagerRef.current) {
        throw new Error('MCP client manager not initialized')
      }
      return await clientManagerRef.current.callTool(serverId, toolName, args)
    },
    []
  )

  // Auto-connect on startup
  useEffect(() => {
    if (!servers.length || !clientManagerRef.current) return

    const autoConnectServers = async () => {
      for (const server of servers) {
        if (autoConnectServerIds.includes(server.id)) {
          try {
            await connectServer(server.id)
          } catch (error: unknown) {
            console.error(`[MCP Connection] Auto-connect failed for ${server.name}:`, getErrorMessage(error))
          }
        }
      }
    }

    autoConnectServers()
  }, [servers, autoConnectServerIds, connectServer])

  return (
    <MCPConnectionContext.Provider
      value={{
        serverStatuses,
        selectedServerId,
        isDiscovering,
        connectServer,
        disconnectServer,
        refreshServer,
        discoverServers,
        selectServer,
        getAllTools,
        getServerTools,
        callTool,
        clientManagerRef,
      }}
    >
      {children}
    </MCPConnectionContext.Provider>
  )
}

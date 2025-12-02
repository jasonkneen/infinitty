import { createContext, useContext, useState, useCallback, useRef, useEffect, type ReactNode } from 'react'
import type { MCPServerConfig } from '../types/mcp'
import {
  loadMCPSettings,
  addServerToSettings,
  removeServerFromSettings,
  updateServerInSettings,
  toggleServerHidden,
  toggleServerAutoConnect,
  type MCPSettings,
} from '../services/mcpSettings'
import { getErrorMessage } from '../lib/utils'

interface MCPServersContextValue {
  // Server management
  servers: MCPServerConfig[]
  addServer: (config: Omit<MCPServerConfig, 'id'>) => Promise<MCPServerConfig>
  removeServer: (serverId: string) => Promise<void>
  updateServer: (serverId: string, updates: Partial<MCPServerConfig>) => Promise<void>
  toggleServer: (serverId: string) => void

  // Server visibility
  hiddenServerIds: string[]
  toggleHideServer: (serverId: string) => void
  isServerHidden: (serverId: string) => boolean
  getVisibleServers: () => MCPServerConfig[]

  // Server auto-connect
  autoConnectServerIds: string[]
  toggleAutoConnect: (serverId: string) => void
  isAutoConnect: (serverId: string) => boolean

  // Settings state
  settingsLoaded: boolean
}

const MCPServersContext = createContext<MCPServersContextValue | null>(null)

let serverCounter = 0

function generateServerId(): string {
  return `mcp-server-${++serverCounter}-${Date.now()}`
}

export function useMCPServers() {
  const context = useContext(MCPServersContext)
  if (!context) {
    throw new Error('useMCPServers must be used within MCPServersProvider')
  }
  return context
}

export function MCPServersProvider({ children }: { children: ReactNode }) {
  const [servers, setServers] = useState<MCPServerConfig[]>([])
  const [hiddenServerIds, setHiddenServerIds] = useState<string[]>([])
  const [autoConnectServerIds, setAutoConnectServerIds] = useState<string[]>([])
  const [settingsLoaded, setSettingsLoaded] = useState(false)
  const settingsRef = useRef<MCPSettings | null>(null)

  // Track if component is mounted to prevent state updates after unmount
  const mountedRef = useRef(true)

  // Set mounted state and cleanup
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  // Load settings on mount
  useEffect(() => {
    const abortController = new AbortController()

    const loadSettings = async () => {
      try {
        const settings = await loadMCPSettings()

        // Check if component is still mounted before updating state
        if (!mountedRef.current || abortController.signal.aborted) return

        settingsRef.current = settings
        setServers(settings.servers)
        setHiddenServerIds(settings.hiddenServerIds)
        setAutoConnectServerIds(settings.autoConnectServerIds)
        console.log('[MCP Servers] Settings loaded:', settings.servers.length, 'servers')
        setSettingsLoaded(true)
      } catch (error: unknown) {
        if (mountedRef.current && !abortController.signal.aborted) {
          console.error('[MCP Servers] Failed to load settings:', getErrorMessage(error))
          setSettingsLoaded(true)
        }
      }
    }

    loadSettings()

    return () => {
      abortController.abort()
    }
  }, [])

  const addServer = useCallback(async (config: Omit<MCPServerConfig, 'id'>): Promise<MCPServerConfig> => {
    const newServer: MCPServerConfig = {
      ...config,
      id: generateServerId(),
    }

    // Only update state if component is still mounted
    if (mountedRef.current) {
      setServers((prev) => [...prev, newServer])
    }

    // Persist to settings
    if (settingsRef.current && mountedRef.current) {
      settingsRef.current = await addServerToSettings(settingsRef.current, newServer)
    }

    return newServer
  }, [])

  const removeServer = useCallback(async (serverId: string) => {
    // Only update state if component is still mounted
    if (mountedRef.current) {
      setServers((prev) => prev.filter((s) => s.id !== serverId))
    }

    // Persist to settings
    if (settingsRef.current && mountedRef.current) {
      settingsRef.current = await removeServerFromSettings(settingsRef.current, serverId)
    }
  }, [])

  const updateServer = useCallback(async (serverId: string, updates: Partial<MCPServerConfig>) => {
    // Only update state if component is still mounted
    if (mountedRef.current) {
      setServers((prev) =>
        prev.map((s) => (s.id === serverId ? { ...s, ...updates } : s))
      )
    }

    // Persist to settings
    if (settingsRef.current && mountedRef.current) {
      settingsRef.current = await updateServerInSettings(settingsRef.current, serverId, updates)
    }
  }, [])

  const toggleServer = useCallback((serverId: string) => {
    setServers((prev) =>
      prev.map((s) => (s.id === serverId ? { ...s, enabled: !s.enabled } : s))
    )
  }, [])

  // Hide/show server functions
  const toggleHideServer = useCallback(async (serverId: string) => {
    // Get current hidden state from previous state
    setHiddenServerIds((prev) => {
      const isHidden = prev.includes(serverId)
      return isHidden ? prev.filter((id) => id !== serverId) : [...prev, serverId]
    })

    // Persist to settings (settings are updated after state change)
    if (settingsRef.current && mountedRef.current) {
      settingsRef.current = await toggleServerHidden(settingsRef.current, serverId)
    }
  }, [])

  const isServerHidden = useCallback((serverId: string): boolean => {
    return hiddenServerIds.includes(serverId)
  }, [hiddenServerIds])

  const getVisibleServers = useCallback((): MCPServerConfig[] => {
    return servers.filter((s) => !hiddenServerIds.includes(s.id))
  }, [servers, hiddenServerIds])

  // Auto-connect functions
  const toggleAutoConnect = useCallback(async (serverId: string) => {
    // Get current auto-connect state from previous state
    setAutoConnectServerIds((prev) => {
      const isAutoConnectEnabled = prev.includes(serverId)
      return isAutoConnectEnabled ? prev.filter((id) => id !== serverId) : [...prev, serverId]
    })

    // Persist to settings (settings are updated after state change)
    if (settingsRef.current && mountedRef.current) {
      settingsRef.current = await toggleServerAutoConnect(settingsRef.current, serverId)
    }
  }, [])

  const isAutoConnect = useCallback((serverId: string): boolean => {
    return autoConnectServerIds.includes(serverId)
  }, [autoConnectServerIds])

  return (
    <MCPServersContext.Provider
      value={{
        servers,
        addServer,
        removeServer,
        updateServer,
        toggleServer,
        hiddenServerIds,
        toggleHideServer,
        isServerHidden,
        getVisibleServers,
        autoConnectServerIds,
        toggleAutoConnect,
        isAutoConnect,
        settingsLoaded,
      }}
    >
      {children}
    </MCPServersContext.Provider>
  )
}

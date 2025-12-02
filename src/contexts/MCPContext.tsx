import { type ReactNode } from 'react'
import { MCPServersProvider } from './MCPServersContext'
import { MCPConnectionProvider } from './MCPConnectionContext'
import { MCPPreferencesProvider } from './MCPPreferencesContext'
import { useMCPServers } from './MCPServersContext'
import { useMCPConnection } from './MCPConnectionContext'
import { useMCPPreferences } from './MCPPreferencesContext'

/**
 * Inner wrapper to inject servers context into MCPConnectionProvider
 * This avoids circular dependencies while maintaining proper nesting
 */
function MCPConnectionProviderWrapper({ children }: { children: ReactNode }) {
  const { servers, addServer, autoConnectServerIds } = useMCPServers()
  return (
    <MCPConnectionProvider
      servers={servers}
      autoConnectServerIds={autoConnectServerIds}
      addServer={addServer}
    >
      {children}
    </MCPConnectionProvider>
  )
}

/**
 * Main MCP Provider that composes all three focused context providers
 * in the proper dependency order:
 * 1. MCPServersProvider - manages server config and settings
 * 2. MCPConnectionProvider - manages connections and tools (depends on servers)
 * 3. MCPPreferencesProvider - manages user preferences (depends on servers)
 */
export function MCPProvider({ children }: { children: ReactNode }) {
  return (
    <MCPServersProvider>
      <MCPConnectionProviderWrapper>
        <MCPPreferencesProvider>
          {children}
        </MCPPreferencesProvider>
      </MCPConnectionProviderWrapper>
    </MCPServersProvider>
  )
}

/**
 * Combined hook that provides all MCP functionality for backwards compatibility
 * Use individual hooks (useMCPServers, useMCPConnection, useMCPPreferences) for better performance
 */
export function useMCP() {
  const servers = useMCPServers()
  const connection = useMCPConnection()
  const preferences = useMCPPreferences()

  return {
    // Servers context
    servers: servers.servers,
    addServer: servers.addServer,
    removeServer: servers.removeServer,
    updateServer: servers.updateServer,
    toggleServer: servers.toggleServer,

    // Connection context
    serverStatuses: connection.serverStatuses,
    selectedServerId: connection.selectedServerId,
    isDiscovering: connection.isDiscovering,
    connectServer: connection.connectServer,
    disconnectServer: connection.disconnectServer,
    refreshServer: connection.refreshServer,
    discoverServers: connection.discoverServers,
    selectServer: connection.selectServer,
    getAllTools: connection.getAllTools,
    getServerTools: connection.getServerTools,
    callTool: connection.callTool,

    // Preferences context
    hiddenServerIds: preferences.hiddenServerIds,
    toggleHideServer: preferences.toggleHideServer,
    isServerHidden: preferences.isServerHidden,
    autoConnectServerIds: preferences.autoConnectServerIds,
    toggleAutoConnect: preferences.toggleAutoConnect,
    isAutoConnect: preferences.isAutoConnect,

    // Combined utilities
    getVisibleServers: servers.getVisibleServers,

    // Settings state from servers context
    settingsLoaded: servers.settingsLoaded,
  }
}

// Re-export individual hooks for fine-grained usage
export { useMCPServers } from './MCPServersContext'
export { useMCPConnection } from './MCPConnectionContext'
export { useMCPPreferences } from './MCPPreferencesContext'

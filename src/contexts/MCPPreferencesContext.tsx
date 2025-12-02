import { createContext, useContext, type ReactNode } from 'react'
import { useMCPServers } from './MCPServersContext'

interface MCPPreferencesContextValue {
  // User preferences
  autoConnectServerIds: string[]
  toggleAutoConnect: (serverId: string) => void
  isAutoConnect: (serverId: string) => boolean

  hiddenServerIds: string[]
  toggleHideServer: (serverId: string) => void
  isServerHidden: (serverId: string) => boolean
}

const MCPPreferencesContext = createContext<MCPPreferencesContextValue | null>(null)

export function useMCPPreferences() {
  const context = useContext(MCPPreferencesContext)
  if (!context) {
    throw new Error('useMCPPreferences must be used within MCPPreferencesProvider')
  }
  return context
}

export function MCPPreferencesProvider({ children }: { children: ReactNode }) {
  const { autoConnectServerIds, toggleAutoConnect, isAutoConnect, hiddenServerIds, toggleHideServer, isServerHidden } =
    useMCPServers()

  return (
    <MCPPreferencesContext.Provider
      value={{
        autoConnectServerIds,
        toggleAutoConnect,
        isAutoConnect,
        hiddenServerIds,
        toggleHideServer,
        isServerHidden,
      }}
    >
      {children}
    </MCPPreferencesContext.Provider>
  )
}

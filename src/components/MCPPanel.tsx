import { useState, useCallback } from 'react'
import {
  Plus,
  Power,
  PowerOff,
  ChevronDown,
  ChevronRight,
  Wrench,
  Trash2,
  Search,
  AlertCircle,
  Loader2,
  Puzzle,
  Server,
  Settings,
  X,
  Save,
  Eye,
  EyeOff,
  Zap,
  Globe,
} from 'lucide-react'
import { useMCP } from '../contexts/MCPContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { useWidgetTools } from '../contexts/WidgetToolsContext'
import type { MCPServerConfig, MCPTool } from '../types/mcp'

interface MCPPanelProps {
  onToolSelect?: (tool: MCPTool, serverId: string) => void
}

export function MCPPanel({ onToolSelect }: MCPPanelProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const {
    servers,
    serverStatuses,
    isDiscovering,
    discoverServers,
    connectServer,
    disconnectServer,
    removeServer,
    toggleHideServer,
    isServerHidden,
    getVisibleServers,
    toggleAutoConnect,
    isAutoConnect,
  } = useMCP()
  const { tools: widgetTools } = useWidgetTools()

  const [expandedServers, setExpandedServers] = useState<Set<string>>(new Set())
  const [showAddServer, setShowAddServer] = useState(false)
  const [showWidgetTools, setShowWidgetTools] = useState(true)
  const [editingServerId, setEditingServerId] = useState<string | null>(null)
  const [showHiddenServers, setShowHiddenServers] = useState(false)

  // Get servers to display based on visibility toggle
  const displayServers = showHiddenServers ? servers : getVisibleServers()
  const hiddenCount = servers.length - getVisibleServers().length

  const toggleExpanded = useCallback((serverId: string) => {
    setExpandedServers((prev) => {
      const next = new Set(prev)
      if (next.has(serverId)) {
        next.delete(serverId)
      } else {
        next.add(serverId)
      }
      return next
    })
  }, [])

  const handleConnect = useCallback(async (server: MCPServerConfig) => {
    const status = serverStatuses[server.id]
    if (status?.status === 'connected') {
      await disconnectServer(server.id)
    } else {
      await connectServer(server.id)
    }
  }, [serverStatuses, connectServer, disconnectServer])

  const getStatusIcon = (serverId: string) => {
    const status = serverStatuses[serverId]?.status ?? 'disconnected'
    switch (status) {
      case 'connected':
        return null // No icon needed - "Connected" text is clear enough
      case 'connecting':
        return <Loader2 size={12} className="animate-spin" style={{ color: theme.yellow }} />
      case 'error':
        return <AlertCircle size={12} style={{ color: theme.red }} />
      default:
        return <PowerOff size={12} style={{ color: theme.brightBlack }} />
    }
  }

  const getStatusText = (serverId: string, toolCount: number) => {
    const status = serverStatuses[serverId]?.status ?? 'disconnected'
    switch (status) {
      case 'connected':
        return toolCount > 0 ? `${toolCount} tools` : ''
      case 'connecting':
        return '' // Spinner already indicates connecting
      case 'error':
        return serverStatuses[serverId]?.error || 'Error'
      default:
        return 'Disconnected'
    }
  }

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        color: theme.foreground,
      }}
    >
      {/* Header row - active count + action buttons */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 12px',
          gap: '8px',
        }}
      >
        {/* Active servers count */}
        {(() => {
          const activeCount = servers.filter(s => serverStatuses[s.id]?.status === 'connected').length
          return activeCount > 0 ? (
            <span
              style={{
                padding: '4px 10px',
                backgroundColor: `${theme.green}20`,
                border: `1px solid ${theme.green}50`,
                borderRadius: '6px',
                color: theme.green,
                fontSize: '11px',
                fontWeight: 500,
              }}
            >
              {activeCount} active
            </span>
          ) : <div />
        })()}

        {/* Action buttons */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
        {hiddenCount > 0 && (
          <button
            onClick={() => setShowHiddenServers(!showHiddenServers)}
            style={{
              padding: '4px 8px',
              backgroundColor: showHiddenServers ? `${theme.yellow}30` : 'transparent',
              border: `1px solid ${showHiddenServers ? theme.yellow : theme.white}30`,
              borderRadius: '4px',
              color: showHiddenServers ? theme.yellow : theme.white,
              opacity: showHiddenServers ? 1 : 0.7,
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '4px',
              fontSize: '11px',
            }}
            title={showHiddenServers ? 'Hide hidden servers' : 'Show hidden servers'}
          >
            {showHiddenServers ? <EyeOff size={12} /> : <Eye size={12} />}
            <span>{hiddenCount} hidden</span>
          </button>
        )}
        <button
          onClick={() => discoverServers()}
          disabled={isDiscovering}
          style={{
            padding: '4px 8px',
            backgroundColor: servers.length === 0 ? theme.cyan : 'transparent',
            border: `1px solid ${servers.length === 0 ? theme.cyan : theme.white}30`,
            borderRadius: '4px',
            color: servers.length === 0 ? '#000' : theme.white,
            opacity: servers.length === 0 ? 1 : 0.7,
            cursor: isDiscovering ? 'wait' : 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            fontSize: '11px',
            fontWeight: servers.length === 0 ? 500 : 400,
          }}
          title="Discover servers"
        >
          {isDiscovering ? (
            <Loader2 size={12} className="animate-spin" />
          ) : (
            <Search size={12} />
          )}
          <span>Discover</span>
        </button>
        <button
          onClick={() => setShowAddServer(!showAddServer)}
          style={{
            padding: '4px 8px',
            backgroundColor: showAddServer ? `${theme.cyan}30` : 'transparent',
            border: `1px solid ${showAddServer ? theme.cyan : theme.white}30`,
            borderRadius: '4px',
            color: showAddServer ? theme.cyan : theme.white,
            opacity: showAddServer ? 1 : 0.7,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            fontSize: '11px',
          }}
          title="Add server"
        >
          <Plus size={12} />
          <span>Add</span>
        </button>
        </div>
      </div>

      {/* Add Server Form */}
      {showAddServer && (
        <AddServerForm
          onClose={() => setShowAddServer(false)}
        />
      )}

      {/* Server List */}
      <div
        style={{
          flex: 1,
          overflow: 'auto',
          padding: '8px',
        }}
      >
        {displayServers.length === 0 ? (
          <div
            style={{
              padding: '20px',
              textAlign: 'center',
              color: theme.brightBlack,
              fontSize: '13px',
            }}
          >
            <Server size={32} style={{ marginBottom: '8px', opacity: 0.5 }} />
            <div>{hiddenCount > 0 ? 'All servers are hidden' : 'No MCP servers configured'}</div>
          </div>
        ) : (
          displayServers.map((server) => {
            const isExpanded = expandedServers.has(server.id)
            const status = serverStatuses[server.id]
            const tools = status?.tools ?? []
            const isConnected = status?.status === 'connected'
            const isHidden = isServerHidden(server.id)
            const hasAutoConnect = isAutoConnect(server.id)
            const isHttpServer = server.transport === 'http' || !!server.url || !!server.port

            return (
              <div
                key={server.id}
                style={{
                  marginBottom: '8px',
                  backgroundColor: isHidden ? `${theme.yellow}10` : `${theme.brightBlack}20`,
                  borderRadius: '8px',
                  overflow: 'hidden',
                  border: isHidden ? `1px dashed ${theme.yellow}40` : 'none',
                }}
              >
                {/* Server Header - Compact Layout */}
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    padding: '8px 10px',
                    cursor: 'pointer',
                    gap: '6px',
                  }}
                  onClick={() => toggleExpanded(server.id)}
                >
                  <button
                    style={{
                      padding: '2px',
                      backgroundColor: 'transparent',
                      border: 'none',
                      color: theme.brightBlack,
                      cursor: 'pointer',
                      display: 'flex',
                      alignItems: 'center',
                      flexShrink: 0,
                    }}
                  >
                    {isExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                  </button>

                  {/* Server name and status */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px', minWidth: 0, flex: 1 }}>
                    {getStatusIcon(server.id)}
                    <span style={{
                      fontSize: '13px',
                      fontWeight: 500,
                      opacity: isHidden ? 0.6 : 1,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                    }}>
                      {server.name}
                    </span>
                    {isHttpServer && (
                      <span
                        style={{
                          fontSize: '9px',
                          backgroundColor: `${theme.magenta}30`,
                          color: theme.magenta,
                          padding: '1px 4px',
                          borderRadius: '3px',
                          display: 'flex',
                          alignItems: 'center',
                          gap: '2px',
                          flexShrink: 0,
                        }}
                      >
                        <Globe size={8} />
                      </span>
                    )}
                    {getStatusText(server.id, tools.length) && (
                      <span
                        style={{
                          fontSize: '11px',
                          color: theme.brightBlack,
                          whiteSpace: 'nowrap',
                        }}
                      >
                        {getStatusText(server.id, tools.length)}
                      </span>
                    )}
                  </div>

                  {/* Action buttons - inline */}
                  <div
                    style={{ display: 'flex', alignItems: 'center', gap: '2px', flexShrink: 0 }}
                    onClick={(e) => e.stopPropagation()}
                  >
                    <button
                      onClick={() => toggleAutoConnect(server.id)}
                      style={{
                        padding: '3px',
                        backgroundColor: hasAutoConnect ? `${theme.green}20` : 'transparent',
                        border: 'none',
                        borderRadius: '3px',
                        color: hasAutoConnect ? theme.green : theme.brightBlack,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                      }}
                      title={hasAutoConnect ? 'Disable auto-connect' : 'Enable auto-connect'}
                    >
                      <Zap size={12} />
                    </button>
                    <button
                      onClick={() => toggleHideServer(server.id)}
                      style={{
                        padding: '3px',
                        backgroundColor: isHidden ? `${theme.yellow}20` : 'transparent',
                        border: 'none',
                        borderRadius: '3px',
                        color: isHidden ? theme.yellow : theme.brightBlack,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                      }}
                      title={isHidden ? 'Show server' : 'Hide server'}
                    >
                      {isHidden ? <Eye size={12} /> : <EyeOff size={12} />}
                    </button>
                    <button
                      onClick={() => setEditingServerId(editingServerId === server.id ? null : server.id)}
                      style={{
                        padding: '3px',
                        backgroundColor: editingServerId === server.id ? `${theme.cyan}20` : 'transparent',
                        border: 'none',
                        borderRadius: '3px',
                        color: editingServerId === server.id ? theme.cyan : theme.brightBlack,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                      }}
                      title="Edit settings"
                    >
                      <Settings size={12} />
                    </button>
                    <button
                      onClick={() => handleConnect(server)}
                      style={{
                        padding: '3px',
                        backgroundColor: isConnected ? `${theme.green}20` : 'transparent',
                        border: 'none',
                        borderRadius: '3px',
                        color: isConnected ? theme.green : theme.brightBlack,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                      }}
                      title={isConnected ? 'Disconnect' : 'Connect'}
                    >
                      {isConnected ? <Power size={12} /> : <PowerOff size={12} />}
                    </button>
                    <button
                      onClick={() => removeServer(server.id)}
                      style={{
                        padding: '3px',
                        backgroundColor: 'transparent',
                        border: 'none',
                        borderRadius: '3px',
                        color: theme.brightBlack,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                      }}
                      title="Remove server"
                    >
                      <Trash2 size={12} />
                    </button>
                  </div>
                </div>

                {/* Edit Server Settings */}
                {editingServerId === server.id && (
                  <EditServerForm
                    server={server}
                    onClose={() => setEditingServerId(null)}
                  />
                )}

                {/* Expanded Tools */}
                {isExpanded && tools.length > 0 && (
                  <div
                    style={{
                      padding: '8px 12px 12px 12px',
                      borderTop: `1px solid ${theme.brightBlack}30`,
                    }}
                  >
                    <div
                      style={{
                        fontSize: '11px',
                        color: theme.brightBlack,
                        marginBottom: '8px',
                        textTransform: 'uppercase',
                        letterSpacing: '0.5px',
                      }}
                    >
                      Available Tools
                    </div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
                      {tools.map((tool) => (
                        <ToolChip
                          key={tool.name}
                          tool={tool}
                          onClick={() => onToolSelect?.(tool, server.id)}
                        />
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )
          })
        )}

        {/* Widget Tools Section */}
        {widgetTools.length > 0 && (
          <div
            style={{
              marginTop: '16px',
              backgroundColor: `${theme.magenta}10`,
              borderRadius: '8px',
              overflow: 'hidden',
              border: `1px solid ${theme.magenta}30`,
            }}
          >
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                padding: '10px 12px',
                cursor: 'pointer',
              }}
              onClick={() => setShowWidgetTools(!showWidgetTools)}
            >
              <button
                style={{
                  padding: '2px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  color: theme.magenta,
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                }}
              >
                {showWidgetTools ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              </button>
              <div style={{ flex: 1, marginLeft: '8px' }}>
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    fontSize: '13px',
                    fontWeight: 500,
                  }}
                >
                  <Puzzle size={14} style={{ color: theme.magenta }} />
                  <span style={{ color: theme.foreground }}>Widget Tools</span>
                  <span
                    style={{
                      fontSize: '10px',
                      backgroundColor: `${theme.magenta}30`,
                      color: theme.magenta,
                      padding: '2px 6px',
                      borderRadius: '10px',
                    }}
                  >
                    {widgetTools.length} tools
                  </span>
                </div>
                <div
                  style={{
                    fontSize: '11px',
                    color: theme.brightBlack,
                    marginTop: '2px',
                  }}
                >
                  Tools from active widgets
                </div>
              </div>
            </div>

            {showWidgetTools && (
              <div
                style={{
                  padding: '8px 12px 12px 12px',
                  borderTop: `1px solid ${theme.magenta}30`,
                }}
              >
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
                  {widgetTools.map((tool) => (
                    <WidgetToolChip
                      key={`${tool.widgetId}-${tool.name}`}
                      tool={tool}
                      onClick={() => onToolSelect?.({ name: tool.name, description: tool.description }, tool.widgetId)}
                    />
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

type ToolToggleState = 'off' | 'ask' | 'always'

interface ToolChipProps {
  tool: MCPTool
  onClick?: () => void
}

function ToolChip({ tool, onClick }: ToolChipProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [isHovered, setIsHovered] = useState(false)
  const [toggleState, setToggleState] = useState<ToolToggleState>('ask') // Default to ask permission

  const handleClick = (e: React.MouseEvent) => {
    e.stopPropagation()
    // Cycle through states: ask -> always -> off -> ask
    setToggleState(prev => {
      if (prev === 'ask') return 'always'
      if (prev === 'always') return 'off'
      return 'ask'
    })
    onClick?.()
  }

  // Colors based on toggle state
  const getStateColors = () => {
    switch (toggleState) {
      case 'always':
        return {
          bg: `${theme.green}20`,
          border: `${theme.green}50`,
          color: theme.green,
        }
      case 'ask':
        return {
          bg: `${theme.cyan}15`,
          border: `${theme.cyan}40`,
          color: theme.cyan,
        }
      case 'off':
        return {
          bg: `${theme.brightBlack}20`,
          border: `${theme.brightBlack}40`,
          color: theme.brightBlack,
        }
    }
  }

  const stateColors = getStateColors()

  return (
    <button
      onClick={handleClick}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '4px',
        padding: '4px 8px',
        backgroundColor: isHovered ? `${stateColors.color}25` : stateColors.bg,
        border: `1px solid ${stateColors.border}`,
        borderRadius: '4px',
        color: stateColors.color,
        fontSize: '11px',
        cursor: 'pointer',
        transition: 'all 0.15s ease',
        opacity: toggleState === 'off' ? 0.6 : 1,
      }}
      title={`${tool.description} (${toggleState === 'always' ? 'Auto-approve' : toggleState === 'ask' ? 'Ask permission' : 'Disabled'})`}
    >
      <Wrench size={10} />
      <span>{tool.name}</span>
    </button>
  )
}

interface WidgetToolChipProps {
  tool: { name: string; description: string; widgetType: string }
  onClick?: () => void
}

function WidgetToolChip({ tool, onClick }: WidgetToolChipProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [isHovered, setIsHovered] = useState(false)

  return (
    <button
      onClick={onClick}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '4px',
        padding: '4px 8px',
        backgroundColor: isHovered ? `${theme.magenta}25` : `${theme.magenta}15`,
        border: `1px solid ${theme.magenta}40`,
        borderRadius: '4px',
        color: theme.magenta,
        fontSize: '11px',
        cursor: 'pointer',
        transition: 'all 0.15s ease',
      }}
      title={tool.description}
    >
      <Puzzle size={10} />
      <span>{tool.name}</span>
    </button>
  )
}

function AddServerForm({ onClose }: { onClose: () => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const { addServer } = useMCP()

  const [name, setName] = useState('')
  const [command, setCommand] = useState('')
  const [args, setArgs] = useState('')

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!name || !command) return

    addServer({
      name,
      command,
      args: args.split(' ').filter(Boolean),
      enabled: false,
    })

    onClose()
  }

  return (
    <form
      onSubmit={handleSubmit}
      style={{
        padding: '12px',
        borderBottom: `1px solid ${theme.brightBlack}40`,
        backgroundColor: `${theme.brightBlack}10`,
      }}
    >
      <div style={{ marginBottom: '8px' }}>
        <input
          type="text"
          placeholder="Server name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>
      <div style={{ marginBottom: '8px' }}>
        <input
          type="text"
          placeholder="Command (e.g., npx)"
          value={command}
          onChange={(e) => setCommand(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>
      <div style={{ marginBottom: '12px' }}>
        <input
          type="text"
          placeholder="Arguments (space-separated)"
          value={args}
          onChange={(e) => setArgs(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>
      <div style={{ display: 'flex', gap: '8px', justifyContent: 'flex-end' }}>
        <button
          type="button"
          onClick={onClose}
          style={{
            padding: '6px 12px',
            backgroundColor: 'transparent',
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '12px',
            cursor: 'pointer',
          }}
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={!name || !command}
          style={{
            padding: '6px 12px',
            backgroundColor: theme.cyan,
            border: 'none',
            borderRadius: '6px',
            color: '#000',
            fontSize: '12px',
            fontWeight: 500,
            cursor: name && command ? 'pointer' : 'not-allowed',
            opacity: name && command ? 1 : 0.5,
          }}
        >
          Add Server
        </button>
      </div>
    </form>
  )
}

function EditServerForm({ server, onClose }: { server: MCPServerConfig; onClose: () => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const { updateServer } = useMCP()

  const [name, setName] = useState(server.name)
  const [command, setCommand] = useState(server.command)
  const [args, setArgs] = useState(server.args?.join(' ') ?? '')
  const [env, setEnv] = useState(
    server.env ? Object.entries(server.env).map(([k, v]) => `${k}=${v}`).join('\n') : ''
  )

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!name || !command) return

    // Parse env vars from text
    const envObj: Record<string, string> = {}
    env.split('\n').forEach(line => {
      const [key, ...valueParts] = line.split('=')
      if (key && valueParts.length > 0) {
        envObj[key.trim()] = valueParts.join('=').trim()
      }
    })

    updateServer(server.id, {
      name,
      command,
      args: args.split(' ').filter(Boolean),
      env: Object.keys(envObj).length > 0 ? envObj : undefined,
    })

    onClose()
  }

  return (
    <form
      onSubmit={handleSubmit}
      style={{
        padding: '12px',
        borderTop: `1px solid ${theme.brightBlack}30`,
        backgroundColor: `${theme.cyan}08`,
      }}
      onClick={(e) => e.stopPropagation()}
    >
      <div style={{ marginBottom: '8px' }}>
        <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px' }}>
          Name
        </label>
        <input
          type="text"
          placeholder="Server name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            marginTop: '4px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>
      <div style={{ marginBottom: '8px' }}>
        <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px' }}>
          Command
        </label>
        <input
          type="text"
          placeholder="Command (e.g., npx, node, python)"
          value={command}
          onChange={(e) => setCommand(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            marginTop: '4px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
            fontFamily: 'monospace',
          }}
        />
      </div>
      <div style={{ marginBottom: '8px' }}>
        <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px' }}>
          Arguments
        </label>
        <input
          type="text"
          placeholder="Arguments (space-separated)"
          value={args}
          onChange={(e) => setArgs(e.target.value)}
          style={{
            width: '100%',
            padding: '8px 12px',
            marginTop: '4px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
            fontFamily: 'monospace',
          }}
        />
      </div>
      <div style={{ marginBottom: '12px' }}>
        <label style={{ fontSize: '10px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.5px' }}>
          Environment Variables (one per line: KEY=value)
        </label>
        <textarea
          placeholder="API_KEY=xxx&#10;DEBUG=true"
          value={env}
          onChange={(e) => setEnv(e.target.value)}
          rows={3}
          style={{
            width: '100%',
            padding: '8px 12px',
            marginTop: '4px',
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '12px',
            outline: 'none',
            fontFamily: 'monospace',
            resize: 'vertical',
          }}
        />
      </div>
      <div style={{ display: 'flex', gap: '8px', justifyContent: 'flex-end' }}>
        <button
          type="button"
          onClick={onClose}
          style={{
            padding: '6px 12px',
            backgroundColor: 'transparent',
            border: `1px solid ${theme.brightBlack}`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '12px',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
          }}
        >
          <X size={12} />
          Cancel
        </button>
        <button
          type="submit"
          disabled={!name || !command}
          style={{
            padding: '6px 12px',
            backgroundColor: theme.cyan,
            border: 'none',
            borderRadius: '6px',
            color: '#000',
            fontSize: '12px',
            fontWeight: 500,
            cursor: name && command ? 'pointer' : 'not-allowed',
            opacity: name && command ? 1 : 0.5,
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
          }}
        >
          <Save size={12} />
          Save
        </button>
      </div>
    </form>
  )
}

// Tool chips bar that can be shown in the terminal input area
export function MCPToolBar({ onToolSelect }: { onToolSelect?: (tool: MCPTool, serverId: string) => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const { servers, serverStatuses } = useMCP()

  const connectedServers = servers.filter(
    (s) => serverStatuses[s.id]?.status === 'connected'
  )

  if (connectedServers.length === 0) return null

  const allTools = connectedServers.flatMap((server) =>
    (serverStatuses[server.id]?.tools ?? []).map((tool) => ({
      tool,
      serverId: server.id,
      serverName: server.name,
    }))
  )

  if (allTools.length === 0) return null

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '8px',
        padding: '8px 12px',
        borderBottom: `1px solid ${theme.brightBlack}30`,
        overflow: 'auto',
      }}
    >
      <Wrench size={12} style={{ color: theme.brightBlack, flexShrink: 0 }} />
      <div style={{ display: 'flex', gap: '6px', flexWrap: 'nowrap' }}>
        {allTools.slice(0, 8).map(({ tool, serverId }) => (
          <ToolChip
            key={`${serverId}-${tool.name}`}
            tool={tool}
            onClick={() => onToolSelect?.(tool, serverId)}
          />
        ))}
        {allTools.length > 8 && (
          <span
            style={{
              fontSize: '11px',
              color: theme.brightBlack,
              padding: '4px 8px',
            }}
          >
            +{allTools.length - 8} more
          </span>
        )}
      </div>
    </div>
  )
}

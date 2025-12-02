// MCP (Model Context Protocol) Types

export interface MCPTool {
  name: string
  description: string
  inputSchema?: Record<string, unknown>
}

export interface MCPResource {
  uri: string
  name: string
  description?: string
  mimeType?: string
}

export interface MCPPrompt {
  name: string
  description?: string
  arguments?: Array<{
    name: string
    description?: string
    required?: boolean
  }>
}

export type MCPTransportType = 'stdio' | 'http'

export interface MCPServerConfig {
  id: string
  name: string
  // Transport type - stdio (spawn process) or http (connect to running server)
  transport?: MCPTransportType
  // For stdio transport
  command: string
  args?: string[]
  env?: Record<string, string>
  // For http transport (widget servers)
  url?: string
  port?: number
  // Common fields
  enabled: boolean
  autoStart?: boolean
  // Source of the server config
  source?: 'user' | 'discovered' | 'widget'
}

export interface MCPServerStatus {
  id: string
  status: 'disconnected' | 'connecting' | 'connected' | 'error'
  error?: string
  tools: MCPTool[]
  resources: MCPResource[]
  prompts: MCPPrompt[]
  lastConnected?: number
}

export interface MCPState {
  servers: MCPServerConfig[]
  serverStatuses: Record<string, MCPServerStatus>
  selectedServerId: string | null
  isDiscovering: boolean
}

// Default MCP servers that can be discovered
export const DEFAULT_MCP_SERVERS: Omit<MCPServerConfig, 'id'>[] = [
  {
    name: 'File System',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', '/'],
    enabled: false,
  },
  {
    name: 'Git',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-git'],
    enabled: false,
  },
  {
    name: 'GitHub',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-github'],
    env: { GITHUB_PERSONAL_ACCESS_TOKEN: '' },
    enabled: false,
  },
  {
    name: 'Brave Search',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-brave-search'],
    env: { BRAVE_API_KEY: '' },
    enabled: false,
  },
  {
    name: 'SQLite',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-sqlite', '--db-path', ''],
    enabled: false,
  },
  {
    name: 'PostgreSQL',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-postgres'],
    env: { POSTGRES_CONNECTION_STRING: '' },
    enabled: false,
  },
  {
    name: 'Fetch',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-fetch'],
    enabled: false,
  },
  {
    name: 'Memory',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-memory'],
    enabled: false,
  },
]

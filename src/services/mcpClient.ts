// MCP Client - Spawns and manages MCP servers using JSON-RPC over stdio
import { Command, type Child, type TerminatedPayload } from '@tauri-apps/plugin-shell'
import type { MCPTool, MCPResource, MCPPrompt, MCPServerConfig } from '../types/mcp'
import { getErrorMessage } from '../lib/utils'
import { getEnvWithPath } from '../lib/shellEnv'

interface JSONRPCRequest {
  jsonrpc: '2.0'
  id: number
  method: string
  params?: Record<string, unknown>
}

interface JSONRPCResponse {
  jsonrpc: '2.0'
  id: number
  result?: unknown
  error?: {
    code: number
    message: string
    data?: unknown
  }
}

interface MCPCapabilities {
  tools?: boolean
  resources?: boolean
  prompts?: boolean
  sampling?: boolean
}

interface MCPServerInfo {
  name: string
  version: string
  capabilities?: MCPCapabilities
}

interface PendingRequest {
  resolve: (result: unknown) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

export class MCPClient {
  private process: Child | null = null
  private requestId = 0
  private pendingRequests = new Map<number, PendingRequest>()
  private buffer = ''
  private serverInfo: MCPServerInfo | null = null
  private tools: MCPTool[] = []
  private resources: MCPResource[] = []
  private prompts: MCPPrompt[] = []
  private isConnected = false
  private onStatusChange?: (status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) => void
  private onToolsChange?: (tools: MCPTool[]) => void

  constructor(
    private config: MCPServerConfig,
    callbacks?: {
      onStatusChange?: (status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) => void
      onToolsChange?: (tools: MCPTool[]) => void
    }
  ) {
    this.onStatusChange = callbacks?.onStatusChange
    this.onToolsChange = callbacks?.onToolsChange
  }

  async connect(): Promise<void> {
    if (this.isConnected || this.process) {
      return
    }

    this.onStatusChange?.('connecting')

    try {
      // Get shell environment with proper PATH, then merge with config env
      const shellEnv = await getEnvWithPath(this.config.env)

      // Create command with the server's command and args
      const command = Command.create(this.config.command, this.config.args ?? [], {
        env: shellEnv,
      })

      // Set up stdout handler for JSON-RPC responses
      command.stdout.on('data', (data) => {
        this.handleStdout(data as string)
      })

      // Set up stderr handler for debugging
      command.stderr.on('data', (data) => {
        console.error(`[MCP ${this.config.name}] stderr:`, data)
      })

      // Handle process close
      command.on('close', (data: TerminatedPayload) => {
        console.log(`[MCP ${this.config.name}] closed with code:`, data.code)
        this.isConnected = false
        this.process = null
        this.onStatusChange?.('disconnected')
      })

      command.on('error', (error: string) => {
        console.error(`[MCP ${this.config.name}] error:`, error)
        this.isConnected = false
        this.onStatusChange?.('error', error)
      })

      // Spawn the process
      this.process = await command.spawn()
      console.log(`[MCP ${this.config.name}] spawned, pid:`, this.process.pid)

      // Initialize the MCP connection
      await this.initialize()

      // Fetch available tools
      await this.refreshCapabilities()

      this.isConnected = true
      this.onStatusChange?.('connected')
    } catch (error: unknown) {
      const errorMsg = getErrorMessage(error)
      console.error(`[MCP ${this.config.name}] failed to connect:`, errorMsg)
      this.onStatusChange?.('error', errorMsg)
      throw error
    }
  }

  async disconnect(): Promise<void> {
    if (!this.process) return

    try {
      // Send shutdown notification
      await this.sendNotification('shutdown', {})
    } catch (error: unknown) {
      // Ignore shutdown errors but log them
      console.debug(`[MCP ${this.config.name}] shutdown notification error:`, getErrorMessage(error))
    }

    // Kill the process
    await this.process.kill()
    this.process = null
    this.isConnected = false
    this.tools = []
    this.resources = []
    this.prompts = []
    this.onStatusChange?.('disconnected')
    this.onToolsChange?.([])
  }

  private async initialize(): Promise<void> {
    const result = await this.sendRequest<{
      serverInfo: MCPServerInfo
      capabilities?: MCPCapabilities
    }>('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {
        roots: {},
      },
      clientInfo: {
        name: 'infinitty',
        version: '0.1.0',
      },
    })

    this.serverInfo = result.serverInfo
    console.log(`[MCP ${this.config.name}] initialized:`, this.serverInfo)

    // Send initialized notification
    await this.sendNotification('notifications/initialized', {})
  }

  private async refreshCapabilities(): Promise<void> {
    // Fetch tools
    try {
      const toolsResult = await this.sendRequest<{ tools: MCPTool[] }>('tools/list', {})
      this.tools = toolsResult.tools ?? []
      console.log(`[MCP ${this.config.name}] found ${this.tools.length} tools`)
      this.onToolsChange?.(this.tools)
    } catch (error: unknown) {
      console.debug(`[MCP ${this.config.name}] no tools available:`, getErrorMessage(error))
      this.tools = []
    }

    // Fetch resources
    try {
      const resourcesResult = await this.sendRequest<{ resources: MCPResource[] }>('resources/list', {})
      this.resources = resourcesResult.resources ?? []
      console.log(`[MCP ${this.config.name}] found ${this.resources.length} resources`)
    } catch (error: unknown) {
      console.debug(`[MCP ${this.config.name}] no resources available:`, getErrorMessage(error))
      this.resources = []
    }

    // Fetch prompts
    try {
      const promptsResult = await this.sendRequest<{ prompts: MCPPrompt[] }>('prompts/list', {})
      this.prompts = promptsResult.prompts ?? []
      console.log(`[MCP ${this.config.name}] found ${this.prompts.length} prompts`)
    } catch (error: unknown) {
      console.debug(`[MCP ${this.config.name}] no prompts available:`, getErrorMessage(error))
      this.prompts = []
    }
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    const result = await this.sendRequest<{ content: unknown[] }>('tools/call', {
      name,
      arguments: args,
    })
    return result.content
  }

  async readResource(uri: string): Promise<{ contents: string; mimeType?: string }> {
    const result = await this.sendRequest<{ contents: Array<{ uri: string; text?: string; blob?: string; mimeType?: string }> }>('resources/read', {
      uri,
    })
    const content = result.contents[0]
    return {
      contents: content.text ?? content.blob ?? '',
      mimeType: content.mimeType,
    }
  }

  async getPrompt(name: string, args?: Record<string, string>): Promise<{ messages: Array<{ role: string; content: string }> }> {
    return await this.sendRequest('prompts/get', {
      name,
      arguments: args,
    })
  }

  getTools(): MCPTool[] {
    return this.tools
  }

  getResources(): MCPResource[] {
    return this.resources
  }

  getPrompts(): MCPPrompt[] {
    return this.prompts
  }

  getServerInfo(): MCPServerInfo | null {
    return this.serverInfo
  }

  isServerConnected(): boolean {
    return this.isConnected
  }

  private handleStdout(data: string): void {
    // Buffer incoming data as we may receive partial JSON
    this.buffer += data

    // Try to parse complete JSON-RPC messages (newline-delimited)
    const lines = this.buffer.split('\n')
    this.buffer = lines.pop() ?? '' // Keep incomplete line in buffer

    for (const line of lines) {
      if (!line.trim()) continue

      try {
        const message = JSON.parse(line) as JSONRPCResponse
        this.handleResponse(message)
      } catch (error: unknown) {
        console.error(`[MCP ${this.config.name}] failed to parse:`, line, getErrorMessage(error))
      }
    }
  }

  private handleResponse(response: JSONRPCResponse): void {
    const pending = this.pendingRequests.get(response.id)
    if (!pending) {
      console.warn(`[MCP ${this.config.name}] received response for unknown request:`, response.id)
      return
    }

    clearTimeout(pending.timeout)
    this.pendingRequests.delete(response.id)

    if (response.error) {
      pending.reject(new Error(`${response.error.message} (code: ${response.error.code})`))
    } else {
      pending.resolve(response.result)
    }
  }

  private async sendRequest<T>(method: string, params: Record<string, unknown>): Promise<T> {
    if (!this.process) {
      throw new Error('Not connected')
    }

    const id = ++this.requestId
    const request: JSONRPCRequest = {
      jsonrpc: '2.0',
      id,
      method,
      params,
    }

    return new Promise<T>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id)
        reject(new Error(`Request timed out: ${method}`))
      }, 30000)

      this.pendingRequests.set(id, {
        resolve: resolve as (result: unknown) => void,
        reject,
        timeout,
      })

      // Send the request as newline-delimited JSON
      const message = JSON.stringify(request) + '\n'
      this.process!.write(message)
    })
  }

  private async sendNotification(method: string, params: Record<string, unknown>): Promise<void> {
    if (!this.process) return

    const notification = {
      jsonrpc: '2.0',
      method,
      params,
    }

    const message = JSON.stringify(notification) + '\n'
    await this.process.write(message)
  }
}

// MCP Client Manager - manages multiple MCP server connections
import { MCPHttpClient } from './mcpHttpClient'

interface MCPClientInterface {
  connect(): Promise<void>
  disconnect(): Promise<void>
  callTool(name: string, args: Record<string, unknown>): Promise<unknown>
  getTools(): MCPTool[]
  isServerConnected(): boolean
}

export class MCPClientManager {
  private clients = new Map<string, MCPClientInterface>()
  private connectingPromises = new Map<string, Promise<void>>()
  private onStatusChange?: (serverId: string, status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) => void
  private onToolsChange?: (serverId: string, tools: MCPTool[]) => void

  constructor(callbacks?: {
    onStatusChange?: (serverId: string, status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) => void
    onToolsChange?: (serverId: string, tools: MCPTool[]) => void
  }) {
    this.onStatusChange = callbacks?.onStatusChange
    this.onToolsChange = callbacks?.onToolsChange
  }

  async connect(config: MCPServerConfig): Promise<void> {
    // Guard against double-spawn: if already connecting, return existing promise
    const existingPromise = this.connectingPromises.get(config.id)
    if (existingPromise) {
      return existingPromise
    }

    // Create the connection promise and track it atomically
    const connectPromise = this._doConnect(config).finally(() => {
      this.connectingPromises.delete(config.id)
    })

    this.connectingPromises.set(config.id, connectPromise)
    return connectPromise
  }

  private async _doConnect(config: MCPServerConfig): Promise<void> {
    if (this.clients.has(config.id)) {
      await this.disconnect(config.id)
    }

    const callbacks = {
      onStatusChange: (status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) =>
        this.onStatusChange?.(config.id, status, error),
      onToolsChange: (tools: MCPTool[]) => this.onToolsChange?.(config.id, tools),
    }

    // Choose client type based on transport
    let client: MCPClientInterface
    if (config.transport === 'http' || config.url || config.port) {
      // Use HTTP client for http transport or if url/port is specified
      client = new MCPHttpClient(config, callbacks)
    } else {
      // Use stdio client for spawning processes
      client = new MCPClient(config, callbacks)
    }

    this.clients.set(config.id, client)
    await client.connect()
  }

  async disconnect(serverId: string): Promise<void> {
    const client = this.clients.get(serverId)
    if (client) {
      await client.disconnect()
      this.clients.delete(serverId)
    }
  }

  async disconnectAll(): Promise<void> {
    const disconnectPromises = Array.from(this.clients.keys()).map((id) => this.disconnect(id))
    await Promise.all(disconnectPromises)
  }

  getClient(serverId: string): MCPClientInterface | undefined {
    return this.clients.get(serverId)
  }

  async callTool(serverId: string, toolName: string, args: Record<string, unknown>): Promise<unknown> {
    const client = this.clients.get(serverId)
    if (!client) {
      throw new Error(`Server not connected: ${serverId}`)
    }
    return await client.callTool(toolName, args)
  }

  getAllTools(): Array<{ tool: MCPTool; serverId: string }> {
    const allTools: Array<{ tool: MCPTool; serverId: string }> = []
    for (const [serverId, client] of this.clients) {
      for (const tool of client.getTools()) {
        allTools.push({ tool, serverId })
      }
    }
    return allTools
  }
}

// MCP HTTP Client - Connects to HTTP-based MCP servers (like widget servers)
import type { MCPTool, MCPResource, MCPPrompt, MCPServerConfig } from '../types/mcp'
import { getErrorMessage } from '../lib/utils'

interface JSONRPCRequest {
  jsonrpc: '2.0'
  id: number
  method: string
  params?: Record<string, unknown>
}

interface JSONRPCResponse {
  jsonrpc: '2.0'
  id?: number
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

export class MCPHttpClient {
  private requestId = 0
  private sessionId: string | null = null
  private serverInfo: MCPServerInfo | null = null
  private tools: MCPTool[] = []
  private resources: MCPResource[] = []
  private prompts: MCPPrompt[] = []
  private isConnected = false
  private baseUrl: string
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

    // Determine base URL from config
    if (config.url) {
      this.baseUrl = config.url
    } else if (config.port) {
      this.baseUrl = `http://localhost:${config.port}`
    } else {
      this.baseUrl = 'http://localhost:3030'
    }
  }

  async connect(): Promise<void> {
    if (this.isConnected) {
      return
    }

    this.onStatusChange?.('connecting')

    try {
      // Check if server is reachable
      const healthCheck = await fetch(this.baseUrl, {
        method: 'GET',
        headers: { 'Accept': 'application/json' },
      })

      if (!healthCheck.ok) {
        throw new Error(`Server not reachable: ${healthCheck.status}`)
      }

      // Initialize the MCP session
      await this.initialize()

      // Fetch available tools
      await this.refreshCapabilities()

      this.isConnected = true
      this.onStatusChange?.('connected')
      console.log(`[MCP HTTP ${this.config.name}] connected to ${this.baseUrl}`)
    } catch (error: unknown) {
      const errorMsg = getErrorMessage(error)
      console.error(`[MCP HTTP ${this.config.name}] failed to connect:`, errorMsg)
      this.onStatusChange?.('error', errorMsg)
      throw error
    }
  }

  async disconnect(): Promise<void> {
    if (!this.isConnected) return

    try {
      // Close MCP session if we have one
      if (this.sessionId) {
        await fetch(`${this.baseUrl}/mcp`, {
          method: 'DELETE',
          headers: {
            'Mcp-Session-Id': this.sessionId,
          },
        })
      }
    } catch (error: unknown) {
      // Ignore disconnect errors but log them
      console.debug(`[MCP HTTP ${this.config.name}] disconnect error:`, getErrorMessage(error))
    }

    this.sessionId = null
    this.isConnected = false
    this.tools = []
    this.resources = []
    this.prompts = []
    this.onStatusChange?.('disconnected')
    this.onToolsChange?.([])
  }

  private async initialize(): Promise<void> {
    const response = await this.sendRequest<{
      protocolVersion: string
      serverInfo: MCPServerInfo
      capabilities?: MCPCapabilities
    }>('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: {
        name: 'infinitty',
        version: '1.0.0',
      },
    })

    this.serverInfo = response.serverInfo
    console.log(`[MCP HTTP ${this.config.name}] initialized:`, this.serverInfo)

    // Send initialized notification
    await this.sendNotification('notifications/initialized', {})
  }

  private async refreshCapabilities(): Promise<void> {
    // Fetch tools
    try {
      const toolsResult = await this.sendRequest<{ tools: MCPTool[] }>('tools/list', {})
      this.tools = toolsResult.tools ?? []
      console.log(`[MCP HTTP ${this.config.name}] found ${this.tools.length} tools`)
      this.onToolsChange?.(this.tools)
    } catch (error: unknown) {
      console.debug(`[MCP HTTP ${this.config.name}] no tools available:`, getErrorMessage(error))
      this.tools = []
    }

    // Fetch resources
    try {
      const resourcesResult = await this.sendRequest<{ resources: MCPResource[] }>('resources/list', {})
      this.resources = resourcesResult.resources ?? []
      console.log(`[MCP HTTP ${this.config.name}] found ${this.resources.length} resources`)
    } catch (error: unknown) {
      console.debug(`[MCP HTTP ${this.config.name}] no resources available:`, getErrorMessage(error))
      this.resources = []
    }

    // Fetch prompts
    try {
      const promptsResult = await this.sendRequest<{ prompts: MCPPrompt[] }>('prompts/list', {})
      this.prompts = promptsResult.prompts ?? []
      console.log(`[MCP HTTP ${this.config.name}] found ${this.prompts.length} prompts`)
    } catch (error: unknown) {
      console.debug(`[MCP HTTP ${this.config.name}] no prompts available:`, getErrorMessage(error))
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

  private async sendRequest<T>(method: string, params: Record<string, unknown>): Promise<T> {
    const id = ++this.requestId
    const request: JSONRPCRequest = {
      jsonrpc: '2.0',
      id,
      method,
      params,
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    }

    if (this.sessionId) {
      headers['Mcp-Session-Id'] = this.sessionId
    }

    const response = await fetch(`${this.baseUrl}/mcp`, {
      method: 'POST',
      headers,
      body: JSON.stringify(request),
    })

    // Extract session ID from response headers
    const newSessionId = response.headers.get('Mcp-Session-Id')
    if (newSessionId) {
      this.sessionId = newSessionId
    }

    if (!response.ok) {
      const text = await response.text()
      throw new Error(`HTTP ${response.status}: ${text}`)
    }

    const contentType = response.headers.get('Content-Type') ?? ''

    // Handle SSE streaming response
    if (contentType.includes('text/event-stream')) {
      return await this.handleSSEResponse<T>(response)
    }

    // Handle regular JSON response
    const json = await response.json() as JSONRPCResponse

    if (json.error) {
      throw new Error(`${json.error.message} (code: ${json.error.code})`)
    }

    return json.result as T
  }

  private async handleSSEResponse<T>(response: Response): Promise<T> {
    const reader = response.body?.getReader()
    if (!reader) {
      throw new Error('No response body')
    }

    const decoder = new TextDecoder()
    let buffer = ''
    let result: T | null = null

    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })

      // Parse SSE events
      const lines = buffer.split('\n')
      buffer = lines.pop() ?? ''

      for (const line of lines) {
        if (line.startsWith('data: ')) {
          const data = line.slice(6)
          try {
            const json = JSON.parse(data) as JSONRPCResponse
            if (json.error) {
              throw new Error(`${json.error.message} (code: ${json.error.code})`)
            }
            if (json.result !== undefined) {
              result = json.result as T
            }
          } catch (error: unknown) {
            // Ignore parse errors for SSE data but log them
            console.debug('[MCP HTTP] SSE parse error:', getErrorMessage(error))
          }
        }
      }
    }

    if (result === null) {
      throw new Error('No result received from SSE stream')
    }

    return result
  }

  private async sendNotification(method: string, params: Record<string, unknown>): Promise<void> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    }

    if (this.sessionId) {
      headers['Mcp-Session-Id'] = this.sessionId
    }

    const notification = {
      jsonrpc: '2.0',
      method,
      params,
    }

    await fetch(`${this.baseUrl}/mcp`, {
      method: 'POST',
      headers,
      body: JSON.stringify(notification),
    })
  }
}

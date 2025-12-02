// OpenCode SDK Integration Service
// Uses @opencode-ai/sdk for direct API access
// Spawns opencode serve with dynamic port via Tauri shell

import { createOpencodeClient, type OpencodeClient, type Session, type GlobalEvent } from '@opencode-ai/sdk/client'
import { Command, type Child } from '@tauri-apps/plugin-shell'
import { getEnvWithPath } from '../lib/shellEnv'

// OpenCode server management
let serverProcess: Child | null = null
let serverPort: number | null = null
let serverReady = false
let serverStartPromise: Promise<void> | null = null

// Initialize SDK client (lazy, uses dynamic port)
let client: OpencodeClient | null = null

function getServerUrl(): string {
  return `http://127.0.0.1:${serverPort || 4096}`
}

function getClient(): OpencodeClient {
  if (!client || !serverPort) {
    client = createOpencodeClient({
      baseUrl: getServerUrl(),
    })
  }
  return client
}

// Start the OpenCode server if not already running
async function ensureServerRunning(): Promise<void> {
  // If already starting, wait for that
  if (serverStartPromise) {
    await serverStartPromise
    return
  }

  // If already running and ready, we're good
  if (serverProcess && serverReady && serverPort) {
    return
  }

  // Start the server
  serverStartPromise = startServer()
  try {
    await serverStartPromise
  } finally {
    serverStartPromise = null
  }
}

async function startServer(): Promise<void> {
  console.log('[OpenCode] Starting server...')

  const env = await getEnvWithPath()

  // Use port 0 for dynamic assignment
  const args = ['serve', '--port', '0', '--print-logs']

  const command = Command.create('opencode', args, { env })

  return new Promise<void>((resolve, reject) => {
    let portFound = false
    const timeout = setTimeout(() => {
      if (!portFound) {
        reject(new Error('Timeout waiting for OpenCode server to start'))
      }
    }, 30000)

    // Listen for server ready message with port
    command.stdout.on('data', (data: string) => {
      console.log('[OpenCode] STDOUT:', data)

      // Look for port in output - opencode prints something like "Listening on http://127.0.0.1:XXXXX"
      const portMatch = data.match(/(?:listening|started|serving|running).*?(?:port\s*[=:]\s*|:)(\d{4,5})/i) ||
                       data.match(/127\.0\.0\.1:(\d{4,5})/) ||
                       data.match(/:(\d{4,5})/)

      if (portMatch && !portFound) {
        serverPort = parseInt(portMatch[1], 10)
        portFound = true
        serverReady = true
        // Recreate client with new port
        client = createOpencodeClient({
          baseUrl: getServerUrl(),
        })
        console.log('[OpenCode] Server ready on port:', serverPort)
        clearTimeout(timeout)
        resolve()
      }
    })

    command.stderr.on('data', (data: string) => {
      console.error('[OpenCode] STDERR:', data)
      // Also check stderr for port info
      const portMatch = data.match(/(?:listening|started|serving|running).*?(?:port\s*[=:]\s*|:)(\d{4,5})/i) ||
                       data.match(/127\.0\.0\.1:(\d{4,5})/) ||
                       data.match(/:(\d{4,5})/)

      if (portMatch && !portFound) {
        serverPort = parseInt(portMatch[1], 10)
        portFound = true
        serverReady = true
        client = createOpencodeClient({
          baseUrl: getServerUrl(),
        })
        console.log('[OpenCode] Server ready on port:', serverPort)
        clearTimeout(timeout)
        resolve()
      }
    })

    command.on('close', (data: { code: number | null }) => {
      console.log('[OpenCode] Server closed with code:', data.code)
      serverProcess = null
      serverReady = false
      serverPort = null
      client = null
      if (!portFound) {
        clearTimeout(timeout)
        reject(new Error(`OpenCode server exited with code ${data.code}`))
      }
    })

    command.on('error', (error: string) => {
      console.error('[OpenCode] Server error:', error)
      clearTimeout(timeout)
      reject(new Error(error))
    })

    // Spawn the server process
    command.spawn().then((proc) => {
      serverProcess = proc
      console.log('[OpenCode] Server process spawned, pid:', proc.pid)
    }).catch((err) => {
      clearTimeout(timeout)
      reject(err)
    })
  })
}

// Stop the server
export async function stopServer(): Promise<void> {
  if (serverProcess) {
    console.log('[OpenCode] Stopping server...')
    await serverProcess.kill()
    serverProcess = null
    serverReady = false
    serverPort = null
    client = null
  }
}

export interface OpenCodeSession {
  id: string
  createdAt: Date
}

export interface OpenCodeMessage {
  role: 'user' | 'assistant'
  content: string
  timestamp: Date
}

export interface StreamingResponse {
  type: 'text' | 'tool-call' | 'tool-result' | 'error' | 'done' | 'stats'
  content?: string
  toolName?: string
  toolInput?: Record<string, unknown>
  toolResult?: string
  error?: string
  stats?: {
    provider?: string
    model?: string
    tokens?: {
      input?: number
      output?: number
      reasoning?: number
      cache?: { read?: number; write?: number }
    }
    cost?: number
    duration?: number
  }
}

// Create a new OpenCode session
export async function createSession(): Promise<OpenCodeSession> {
  console.log('[OpenCode SDK] Creating session...')
  try {
    // Ensure server is running first
    await ensureServerRunning()

    const response = await getClient().session.create()
    console.log('[OpenCode SDK] Session create response:', JSON.stringify(response).slice(0, 500))

    // Handle various response shapes
    const data = response.data || response
    const session = data as Session | undefined

    if (!session?.id) {
      console.error('[OpenCode SDK] Invalid session response:', response)
      throw new Error('Failed to create session: no session ID returned')
    }

    console.log('[OpenCode SDK] Session created:', session.id)
    return {
      id: session.id,
      createdAt: session.time ? new Date(session.time.created * 1000) : new Date(),
    }
  } catch (error) {
    console.error('[OpenCode SDK] Session creation error:', error)
    throw error
  }
}

// Send a prompt to OpenCode with SSE streaming
export async function* streamPrompt(
  sessionId: string,
  prompt: string,
  model?: string
): AsyncGenerator<StreamingResponse> {
  console.log('[OpenCode SDK] Sending prompt to session:', sessionId)

  // Ensure server is running
  await ensureServerRunning()

  // Determine provider and model
  const getModelConfig = (modelId?: string) => {
    if (!modelId || modelId === 'auto') {
      return { providerID: 'anthropic', modelID: 'claude-sonnet-4-20250514' }
    }

    // Check if model ID includes provider prefix (provider/modelid format)
    if (modelId.includes('/')) {
      const [providerID, ...modelParts] = modelId.split('/')
      const actualModelID = modelParts.join('/')  // Rejoin in case model ID had slashes
      
      // For 'opencode' provider, the full model ID IS the model (e.g., opencode/big-pickle)
      // The provider for API calls is still 'opencode'
      if (providerID === 'opencode') {
        return { providerID: 'opencode', modelID: modelId }
      }
      
      return { providerID, modelID: actualModelID }
    }

    // Fallback: Claude models use anthropic provider
    const isClaudeModel = modelId.startsWith('claude-') || modelId.includes('anthropic')
    return {
      providerID: isClaudeModel ? 'anthropic' : 'openrouter',
      modelID: modelId,
    }
  }
  const modelConfig = getModelConfig(model)

  // Create event queue for streaming
  const eventQueue: StreamingResponse[] = []
  type ResolveFunc = (value: StreamingResponse | null) => void
  let resolveNext: ResolveFunc | null = null
  let isDone = false
  let messageId: string | null = null

  // Start listening to events BEFORE sending the message
  const eventResult = await getClient().global.event()
  const eventStream = eventResult.stream

  // Process events in background
  const eventProcessor = (async () => {
    try {
      for await (const globalEvent of eventStream) {
        const event = (globalEvent as GlobalEvent).payload as Record<string, unknown>
        const eventType = event.type as string
        // Filter events for our session
        const props = event.properties as Record<string, unknown> | undefined
        if (!props || props.sessionID !== sessionId) continue

        // Track message ID from first relevant event
        if (props.messageID && !messageId) {
          messageId = props.messageID as string
        }

        // Only process events for our message
        if (messageId && props.messageID !== messageId) continue

        console.log('[OpenCode SDK] Event:', eventType, JSON.stringify(props).slice(0, 200))

        const pushResponse = (response: StreamingResponse) => {
          const resolver = resolveNext
          if (resolver) {
            resolver(response)
            resolveNext = null
          } else {
            eventQueue.push(response)
          }
        }

        // Handle part updates
        if (eventType === 'part.updated' || eventType === 'message.part.updated') {
          const part = props.part as Record<string, unknown> | undefined
          if (part?.type === 'text' && part?.text) {
            pushResponse({ type: 'text', content: part.text as string })
          } else if (part?.type === 'tool') {
            const toolState = (part.state || {}) as Record<string, unknown>
            const status = toolState.status as string

            if (status === 'pending' || status === 'running') {
              pushResponse({
                type: 'tool-call',
                toolName: part.tool as string,
                toolInput: toolState.input as Record<string, unknown>,
              })
            } else if (status === 'completed') {
              pushResponse({
                type: 'tool-result',
                toolName: part.tool as string,
                toolResult: (toolState.output || toolState.title) as string,
              })
            } else if (status === 'error') {
              pushResponse({
                type: 'tool-result',
                toolName: part.tool as string,
                toolResult: `Error: ${toolState.error}`,
              })
            }
          }
        }
        // Handle message completion
        else if (eventType === 'message.completed' || eventType === 'message.updated') {
          const info = props.info as Record<string, unknown> | undefined
          if (info?.finish === 'stop' || props.finish === 'stop') {
            isDone = true
            pushResponse({ type: 'done' })
            break
          }
        }
        // Handle session status - idle means done
        else if (eventType === 'session.status') {
          const status = props.status as Record<string, unknown> | undefined
          if (status?.type === 'idle') {
            isDone = true
            pushResponse({ type: 'done' })
            break
          }
        }
      }
    } catch (error) {
      console.error('[OpenCode SDK] Event stream error:', error)
      isDone = true
      const response: StreamingResponse = { type: 'error', error: 'Event stream error' }
      const resolver = resolveNext as ResolveFunc | null
      if (resolver) {
        resolver(response)
        resolveNext = null
      } else {
        eventQueue.push(response)
      }
    }
  })()

  // Send the message
  try {
    const response = await getClient().session.prompt({
      path: { id: sessionId },
      body: {
        model: modelConfig,
        parts: [{ type: 'text', text: prompt }],
      },
    })

    console.log('[OpenCode SDK] Prompt response received')

    // Process response parts
    const data = response.data as Record<string, unknown>
    const parts = data.parts as Array<Record<string, unknown>> | undefined
    if (parts && Array.isArray(parts)) {
      for (const part of parts) {
        if (part.type === 'text' && part.text) {
          yield { type: 'text', content: part.text as string }
        } else if (part.type === 'tool') {
          const toolState = (part.state || {}) as Record<string, unknown>
          yield {
            type: 'tool-call',
            toolName: part.tool as string,
            toolInput: toolState.input as Record<string, unknown>,
          }
          if (toolState.status === 'completed') {
            yield {
              type: 'tool-result',
              toolName: part.tool as string,
              toolResult: (toolState.output || toolState.title) as string,
            }
          }
        }
      }
    }

    // Extract stats from response
    const info = data.info as Record<string, unknown> | undefined
    const usage = (info?.usage || data.usage || {}) as Record<string, unknown>

    yield {
      type: 'stats',
      stats: {
        provider: modelConfig.providerID,
        model: ((info?.model as Record<string, unknown>)?.id as string) || modelConfig.modelID,
        tokens: {
          input: usage.promptTokens as number | undefined,
          output: usage.completionTokens as number | undefined,
          reasoning: usage.reasoningTokens as number | undefined,
          cache: {
            read: usage.cacheReadInputTokens as number | undefined,
            write: usage.cacheCreationInputTokens as number | undefined,
          },
        },
        cost: (info?.cost || data.cost) as number | undefined,
      },
    }
  } catch (error) {
    console.error('[OpenCode SDK] Prompt error:', error)
    yield { type: 'error', error: error instanceof Error ? error.message : 'Unknown error' }
    return
  }

  // Yield any queued events from stream
  while (eventQueue.length > 0) {
    const event = eventQueue.shift()!
    yield event
    if (event.type === 'done' || event.type === 'error') return
  }

  // Wait for remaining events
  while (!isDone) {
    const event = await new Promise<StreamingResponse | null>((resolve) => {
      if (eventQueue.length > 0) {
        resolve(eventQueue.shift()!)
      } else if (isDone) {
        resolve(null)
      } else {
        resolveNext = resolve
        setTimeout(() => {
          if (resolveNext === resolve) {
            resolveNext = null
            resolve({ type: 'done' })
          }
        }, 60000)
      }
    })

    if (!event) break
    yield event
    if (event.type === 'done' || event.type === 'error') break
  }

  // Clean up
  await eventProcessor.catch(() => {})
  yield { type: 'done' }
}

// Simple non-streaming prompt
export async function sendPrompt(
  sessionId: string,
  prompt: string,
  model?: string
): Promise<string> {
  let fullResponse = ''

  for await (const chunk of streamPrompt(sessionId, prompt, model)) {
    if (chunk.type === 'text' && chunk.content) {
      fullResponse += chunk.content
    } else if (chunk.type === 'error') {
      throw new Error(chunk.error)
    }
  }

  return fullResponse
}

// Check if OpenCode CLI is available
let cachedAvailability: boolean | null = null
let availabilityPromise: Promise<boolean> | null = null

export async function isOpenCodeAvailable(): Promise<boolean> {
  if (cachedAvailability !== null) return cachedAvailability
  if (availabilityPromise) return availabilityPromise

  availabilityPromise = (async () => {
    try {
      const env = await getEnvWithPath()
      const cmd = Command.create('opencode', ['--version'], { env })
      const output = await cmd.execute()
      console.log('[OpenCode] Version check result:', output.code, output.stdout)
      cachedAvailability = output.code === 0
      return cachedAvailability
    } catch (e) {
      console.error('[OpenCode] CLI availability check failed:', e)
      cachedAvailability = false
      return false
    } finally {
      availabilityPromise = null
    }
  })()

  return availabilityPromise
}

// Provider info
export interface OpenCodeProvider {
  id: string
  name: string
  models: OpenCodeModel[]
}

export interface OpenCodeModel {
  id: string
  name: string
  providerId: string
  providerName: string
}

// Get list of available providers and models
export async function getProvidersAndModels(): Promise<{ providers: OpenCodeProvider[]; models: OpenCodeModel[] }> {
  try {
    // Ensure server is running first
    await ensureServerRunning()

    const response = await getClient().config.providers()
    console.log('[OpenCode SDK] Providers response:', JSON.stringify(response).slice(0, 500))

    const data = (response.data || response) as Record<string, unknown>
    const providers: OpenCodeProvider[] = []
    const models: OpenCodeModel[] = []

    // Parse providers from response - handle both array and object formats
    let providerList: Array<Record<string, unknown>> = []
    if (Array.isArray(data.providers)) {
      providerList = data.providers
    } else if (Array.isArray(data)) {
      providerList = data as Array<Record<string, unknown>>
    } else if (data.providers && typeof data.providers === 'object') {
      providerList = Object.values(data.providers) as Array<Record<string, unknown>>
    }

    for (const provider of providerList) {
      const providerId = provider.id as string
      const providerName = (provider.name || providerId) as string

      const providerModels: OpenCodeModel[] = []

      // Handle models in various formats
      let modelEntries: Array<[string, unknown]> = []
      if (provider.models) {
        if (Array.isArray(provider.models)) {
          // Models is an array
          for (const m of provider.models as Array<Record<string, unknown>>) {
            const modelId = (m.id || m.name) as string
            modelEntries.push([modelId, m])
          }
        } else if (typeof provider.models === 'object') {
          // Models is an object
          modelEntries = Object.entries(provider.models as Record<string, unknown>)
        }
      }

      for (const [modelId, modelConfig] of modelEntries) {
        const config = (modelConfig || {}) as { name?: string; id?: string }
        const model: OpenCodeModel = {
          id: config.id || modelId,
          name: config.name || modelId,
          providerId,
          providerName,
        }
        providerModels.push(model)
        models.push(model)
      }

      if (providerModels.length > 0) {
        providers.push({
          id: providerId,
          name: providerName,
          models: providerModels,
        })
      }
    }

    console.log('[OpenCode SDK] Parsed providers:', providers.length, 'models:', models.length)
    return { providers, models }
  } catch (error) {
    console.error('[OpenCode SDK] Failed to fetch providers:', error)
    return { providers: [], models: [] }
  }
}

// Get list of available models (legacy function)
export async function getModels(): Promise<{ id: string; name: string; provider: string }[]> {
  const { models } = await getProvidersAndModels()
  return models.map(m => ({ id: m.id, name: m.name, provider: m.providerId }))
}

// Session info returned from listing
export interface OpenCodeSessionInfo {
  id: string
  title: string
  directory: string
  createdAt: Date
  updatedAt: Date
}

// Message from a session
export interface OpenCodeMessageInfo {
  id: string
  role: 'user' | 'assistant'
  content: string
  createdAt: Date
  model?: string
  provider?: string
  tokens?: {
    input?: number
    output?: number
    reasoning?: number
  }
  toolCalls?: {
    id: string
    name: string
    input?: Record<string, unknown>
    output?: string
    status: 'completed' | 'error'
  }[]
}

// List all OpenCode sessions
export async function listSessions(): Promise<OpenCodeSessionInfo[]> {
  console.log('[OpenCode SDK] Listing sessions...')
  try {
    // Ensure server is running first
    await ensureServerRunning()

    const response = await getClient().session.list()
    console.log('[OpenCode SDK] Sessions list response:', JSON.stringify(response).slice(0, 500))

    // Handle various response shapes
    const data = (response.data || response) as Record<string, unknown>
    const sessions: OpenCodeSessionInfo[] = []

    // Parse sessions - could be array directly or in a sessions field
    let sessionList: Array<Record<string, unknown>> = []
    if (Array.isArray(data)) {
      sessionList = data
    } else if (Array.isArray(data.sessions)) {
      sessionList = data.sessions
    } else if (data && typeof data === 'object') {
      // Could be an object with session IDs as keys
      sessionList = Object.values(data) as Array<Record<string, unknown>>
    }

    for (const session of sessionList) {
      if (!session || typeof session !== 'object') continue
      const time = session.time as { created?: number; updated?: number } | undefined
      sessions.push({
        id: session.id as string,
        title: (session.title as string) || 'Untitled',
        directory: (session.directory as string) || '',
        createdAt: time?.created ? new Date(time.created * 1000) : new Date(),
        updatedAt: time?.updated ? new Date(time.updated * 1000) : new Date(),
      })
    }

    // Sort by updated date descending (most recent first)
    sessions.sort((a, b) => b.updatedAt.getTime() - a.updatedAt.getTime())

    console.log('[OpenCode SDK] Parsed sessions:', sessions.length)
    return sessions
  } catch (error) {
    console.error('[OpenCode SDK] Failed to list sessions:', error)
    return []
  }
}

// Pagination options for message fetching
export interface GetSessionMessagesOptions {
  limit?: number        // Max messages to return (default: all)
  offset?: number       // Skip this many messages from the end (for backfill)
  fromEnd?: boolean     // If true, count from end (most recent) - default: true
}

// Result includes pagination info
export interface GetSessionMessagesResult {
  messages: OpenCodeMessageInfo[]
  total: number         // Total messages in session
  hasMore: boolean      // More messages available before these
}

// Get messages for a session with optional pagination
export async function getSessionMessages(
  sessionId: string,
  options: GetSessionMessagesOptions = {}
): Promise<GetSessionMessagesResult> {
  const { limit, offset = 0, fromEnd = true } = options
  console.log('[OpenCode SDK] Getting messages for session:', sessionId, 'options:', options)
  
  try {
    // Ensure server is running first
    await ensureServerRunning()

    const response = await getClient().session.messages({ path: { id: sessionId } })
    console.log('[OpenCode SDK] Messages response:', JSON.stringify(response).slice(0, 1000))

    // Handle response - it should be an array of {info, parts}
    const data = (response.data || response) as Array<{ info: Record<string, unknown>; parts: Array<Record<string, unknown>> }> | Record<string, unknown>
    const allMessages: OpenCodeMessageInfo[] = []

    let messageList: Array<{ info: Record<string, unknown>; parts: Array<Record<string, unknown>> }> = []
    if (Array.isArray(data)) {
      messageList = data
    } else if (Array.isArray((data as Record<string, unknown>).messages)) {
      messageList = (data as Record<string, unknown>).messages as typeof messageList
    }

    for (const msg of messageList) {
      const info = msg.info || {}
      const parts = msg.parts || []
      const role = info.role as 'user' | 'assistant'
      
      // Debug: log role extraction
      if (!role) {
        console.warn('[OpenCode SDK] Message missing role, info:', JSON.stringify(info).slice(0, 200))
      }
      
      // Extract text content from parts
      let content = ''
      const toolCalls: OpenCodeMessageInfo['toolCalls'] = []
      
      for (const part of parts) {
        if (part.type === 'text' && part.text) {
          content += part.text as string
        } else if (part.type === 'tool') {
          const state = (part.state || {}) as Record<string, unknown>
          toolCalls.push({
            id: part.id as string,
            name: part.tool as string,
            input: state.input as Record<string, unknown>,
            output: state.output as string,
            status: state.status === 'error' ? 'error' : 'completed',
          })
        }
      }

      // Get tokens from assistant messages
      const tokens = info.tokens as { input?: number; output?: number; reasoning?: number } | undefined
      const time = info.time as { created?: number } | undefined
      
      // Timestamp is already in milliseconds (13 digits like 1765708218339)
      const createdAt = time?.created ? new Date(time.created) : new Date()

      allMessages.push({
        id: info.id as string,
        role,
        content,
        createdAt,
        model: role === 'assistant' ? info.modelID as string : undefined,
        provider: role === 'assistant' ? info.providerID as string : undefined,
        tokens: tokens ? {
          input: tokens.input,
          output: tokens.output,
          reasoning: tokens.reasoning,
        } : undefined,
        toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
      })
    }

    // Sort by creation time ascending
    allMessages.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime())
    
    // Debug: log roles distribution
    const userCount = allMessages.filter(m => m.role === 'user').length
    const assistantCount = allMessages.filter(m => m.role === 'assistant').length
    console.log('[OpenCode SDK] Message roles - users:', userCount, 'assistants:', assistantCount)
    
    const total = allMessages.length
    
    // Apply pagination
    let messages: OpenCodeMessageInfo[]
    let hasMore: boolean
    
    if (fromEnd) {
      // Get messages from the end (most recent first for initial load)
      // offset=0, limit=20 means get last 20 messages
      // offset=20, limit=20 means get messages 20-40 from end (older)
      const endIndex = total - offset
      const startIndex = limit ? Math.max(0, endIndex - limit) : 0
      messages = allMessages.slice(startIndex, endIndex)
      hasMore = startIndex > 0
    } else {
      // Traditional pagination from start
      const startIndex = offset
      const endIndex = limit ? Math.min(total, offset + limit) : total
      messages = allMessages.slice(startIndex, endIndex)
      hasMore = endIndex < total
    }

    console.log('[OpenCode SDK] Parsed messages:', messages.length, 'of', total, 'hasMore:', hasMore)
    return { messages, total, hasMore }
  } catch (error) {
    console.error('[OpenCode SDK] Failed to get session messages:', error)
    return { messages: [], total: 0, hasMore: false }
  }
}

// Get current server port (for debugging)
export function getServerPort(): number | null {
  return serverPort
}

// Check if server is running
export function isServerRunning(): boolean {
  return serverReady && serverProcess !== null
}

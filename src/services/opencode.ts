// OpenCode SDK Integration Service

// Note: This is a client-side integration that will connect to a locally running
// OpenCode instance or remote API. The actual SDK usage may need to be wrapped
// in Tauri commands for full functionality.

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

// OpenCode API endpoint (local instance)
// Use fixed port 4096 - start OpenCode with: opencode serve --port 4096
const OPENCODE_API_URL = import.meta.env.VITE_OPENCODE_URL || 'http://127.0.0.1:4096'

// Create a new OpenCode session
export async function createSession(): Promise<OpenCodeSession> {
  console.log('[OpenCode] Creating session at:', `${OPENCODE_API_URL}/session`)
  try {
    const response = await fetch(`${OPENCODE_API_URL}/session`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    })

    console.log('[OpenCode] Session creation response:', response.status)

    if (!response.ok) {
      const text = await response.text()
      console.error('[OpenCode] Session creation failed:', response.status, text)
      throw new Error(`Failed to create session: ${response.status}`)
    }

    const data = await response.json()
    console.log('[OpenCode] Session created:', data.id)
    return {
      id: data.id,
      createdAt: new Date(data.time?.created || Date.now()),
    }
  } catch (error) {
    console.error('[OpenCode] Session creation error:', error)
    throw error
  }
}

// Send a prompt to OpenCode with SSE streaming
export async function* streamPrompt(
  sessionId: string,
  prompt: string,
  model?: string
): AsyncGenerator<StreamingResponse> {
  console.log('[OpenCode] Sending prompt to session:', sessionId)

  // Determine provider based on model
  // Claude models should use 'anthropic' provider to get fine-grained tool streaming beta headers
  // Other models go through OpenRouter
  const getModelConfig = (modelId?: string) => {
    if (!modelId || modelId === 'auto') {
      return { providerID: 'anthropic', modelID: 'claude-opus-4-5-20251101' }
    }
    // Claude models use anthropic provider for tool streaming beta headers
    const isClaudeModel = modelId.startsWith('claude-') || modelId.includes('anthropic')
    return {
      providerID: isClaudeModel ? 'anthropic' : 'openrouter',
      modelID: modelId,
    }
  }
  const modelConfig = getModelConfig(model)

  // Create a queue for SSE events
  const eventQueue: StreamingResponse[] = []
  let resolveNext: ((value: StreamingResponse | null) => void) | null = null
  let isDone = false
  let messageId: string | null = null

  // Connect to SSE event stream
  const eventSource = new EventSource(`${OPENCODE_API_URL}/event`)

  eventSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data)

      // Filter events for our session
      if (data.properties?.sessionID !== sessionId) return

      // Track the message ID from the first relevant event
      if (data.properties?.messageID && !messageId) {
        messageId = data.properties.messageID
      }

      // Only process events for our message
      if (messageId && data.properties?.messageID !== messageId) return

      // Log ALL events for debugging
      console.log('[OpenCode] SSE event:', data.type, JSON.stringify(data.properties || {}).slice(0, 200))

      // Helper to push response
      const pushResponse = (response: StreamingResponse) => {
        if (resolveNext) {
          resolveNext(response)
          resolveNext = null
        } else {
          eventQueue.push(response)
        }
      }

      // Handle part updates (text, tool invocations, tool results)
      if (data.type === 'part.updated' || data.type === 'message.part.updated') {
        const part = data.properties?.part || data.properties
        if (part?.type === 'text' && part?.text) {
          pushResponse({ type: 'text', content: part.text })
        } else if (part?.type === 'tool') {
          // OpenCode SDK ToolPart: { type: "tool", tool: string, state: { status, input, output, ... } }
          console.log('[OpenCode] 🔧 TOOL PART:', part.tool, part.state?.status, JSON.stringify(part).slice(0, 300))
          const toolState = part.state || {}
          const status = toolState.status

          if (status === 'pending' || status === 'running') {
            pushResponse({
              type: 'tool-call',
              toolName: part.tool,
              toolInput: toolState.input,
            })
          } else if (status === 'completed') {
            pushResponse({
              type: 'tool-result',
              toolName: part.tool,
              toolResult: toolState.output || toolState.title,
            })
          } else if (status === 'error') {
            pushResponse({
              type: 'tool-result',
              toolName: part.tool,
              toolResult: `Error: ${toolState.error}`,
            })
          }
        } else if (part?.type === 'tool-invocation' || part?.type === 'tool_invocation' || part?.type === 'toolInvocation') {
          // Legacy format fallback
          pushResponse({
            type: 'tool-call',
            toolName: part.toolName || part.name || part.tool_name,
            toolInput: part.input || part.args || part.arguments,
          })
        } else if (part?.type === 'tool-result' || part?.type === 'tool_result' || part?.type === 'toolResult') {
          pushResponse({
            type: 'tool-result',
            toolResult: part.result || part.output || part.text || part.content,
          })
        }
      }
      // Handle direct tool events
      else if (data.type === 'tool.invocation' || data.type === 'tool.call' || data.type === 'tool_call') {
        const props = data.properties || data
        pushResponse({
          type: 'tool-call',
          toolName: props.toolName || props.name || props.tool_name || props.tool,
          toolInput: props.input || props.args || props.arguments,
        })
      }
      else if (data.type === 'tool.result' || data.type === 'tool_result') {
        const props = data.properties || data
        pushResponse({
          type: 'tool-result',
          toolResult: props.result || props.output || props.text || props.content,
        })
      }
      // Handle message completion
      else if (data.type === 'message.completed' || data.type === 'message.updated') {
        if (data.properties?.info?.finish === 'stop' || data.properties?.finish === 'stop') {
          isDone = true
          const response: StreamingResponse = { type: 'done' }
          if (resolveNext) {
            resolveNext(response)
            resolveNext = null
          } else {
            eventQueue.push(response)
          }
          eventSource.close()
        }
      }
    } catch (e) {
      console.error('[OpenCode] SSE parse error:', e)
    }
  }

  eventSource.onerror = (error) => {
    console.error('[OpenCode] SSE error:', error)
    isDone = true
    const response: StreamingResponse = { type: 'error', error: 'SSE connection error' }
    if (resolveNext) {
      resolveNext(response)
      resolveNext = null
    } else {
      eventQueue.push(response)
    }
    eventSource.close()
  }

  // Send the message (don't await the full response)
  try {
    const response = await fetch(`${OPENCODE_API_URL}/session/${sessionId}/message`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        parts: [{ type: 'text', text: prompt }],
        model: modelConfig,
      }),
    })

    if (!response.ok) {
      const errorText = await response.text()
      console.error('[OpenCode] Error:', response.status, errorText)
      eventSource.close()
      yield { type: 'error', error: `API error: ${response.status}` }
      return
    }

    // Get the message ID from the response
    const data = await response.json()
    console.log('[OpenCode] Full response data:', JSON.stringify(data).slice(0, 500))

    if (data.info?.id) {
      messageId = data.info.id
      console.log('[OpenCode] Message ID:', messageId)
    }

    // Check for tools/tool_calls in various locations
    const toolsUsed = data.tools || data.tool_calls || data.toolCalls || data.info?.tools || []
    if (toolsUsed.length > 0) {
      console.log('[OpenCode] 🔧 Found tools in response:', toolsUsed)
      for (const tool of toolsUsed) {
        yield {
          type: 'tool-call',
          toolName: tool.name || tool.toolName || tool.tool_name || tool.function?.name,
          toolInput: tool.input || tool.args || tool.arguments || tool.function?.arguments,
        }
        if (tool.result || tool.output) {
          yield {
            type: 'tool-result',
            toolResult: tool.result || tool.output,
          }
        }
      }
    }

    // Also yield the final response parts (in case SSE missed them)
    if (data.parts && Array.isArray(data.parts)) {
      console.log('[OpenCode] Processing parts:', data.parts.length, 'parts')
      for (const part of data.parts) {
        console.log('[OpenCode] Part type:', part.type)
        if (part.type === 'text' && part.text) {
          yield { type: 'text', content: part.text }
        } else if (part.type === 'tool') {
          // OpenCode SDK ToolPart format: { type: "tool", tool: string, state: { status, input, output } }
          console.log('[OpenCode] 🔧 Tool part from response:', part.tool, part.state?.status)
          const toolState = part.state || {}
          if (toolState.status === 'pending' || toolState.status === 'running') {
            yield {
              type: 'tool-call',
              toolName: part.tool,
              toolInput: toolState.input,
            }
          } else if (toolState.status === 'completed') {
            yield {
              type: 'tool-call',
              toolName: part.tool,
              toolInput: toolState.input,
            }
            yield {
              type: 'tool-result',
              toolName: part.tool,
              toolResult: toolState.output || toolState.title,
            }
          } else if (toolState.status === 'error') {
            yield {
              type: 'tool-call',
              toolName: part.tool,
              toolInput: toolState.input,
            }
            yield {
              type: 'tool-result',
              toolName: part.tool,
              toolResult: `Error: ${toolState.error}`,
            }
          }
        } else if (part.type === 'tool-invocation' || part.type === 'tool_invocation' || part.type === 'tool_use') {
          // Legacy format fallback
          console.log('[OpenCode] 🔧 Tool invocation part:', part)
          yield {
            type: 'tool-call',
            toolName: part.toolName || part.name || part.tool_name,
            toolInput: part.input || part.args,
          }
        } else if (part.type === 'tool-result' || part.type === 'tool_result') {
          yield {
            type: 'tool-result',
            toolResult: part.result || part.output || part.text || part.content,
          }
        }
      }
    }

    // Extract and yield stats from the response
    const info = data.info || {}
    const usage = info.usage || data.usage || {}
    const metadata = info.metadata || data.metadata || {}

    // Calculate duration if we have timestamps
    let duration: number | undefined
    if (info.time?.created && info.time?.completed) {
      duration = new Date(info.time.completed).getTime() - new Date(info.time.created).getTime()
    }

    // Yield stats
    yield {
      type: 'stats',
      stats: {
        provider: modelConfig.providerID,
        model: info.model?.id || modelConfig.modelID,
        tokens: {
          input: usage.promptTokens || usage.input_tokens || usage.prompt_tokens,
          output: usage.completionTokens || usage.output_tokens || usage.completion_tokens,
          reasoning: usage.reasoningTokens || usage.reasoning_tokens,
          cache: {
            read: usage.cacheReadInputTokens || usage.cache_read_input_tokens,
            write: usage.cacheCreationInputTokens || usage.cache_creation_input_tokens,
          },
        },
        cost: metadata.cost || info.cost,
        duration,
      },
    }
  } catch (error) {
    console.error('[OpenCode] Error:', error)
    eventSource.close()
    yield { type: 'error', error: error instanceof Error ? error.message : 'Unknown error' }
    return
  }

  // Yield any queued events
  while (eventQueue.length > 0) {
    const event = eventQueue.shift()!
    yield event
    if (event.type === 'done' || event.type === 'error') return
  }

  // Wait for more events if not done
  while (!isDone) {
    const event = await new Promise<StreamingResponse | null>((resolve) => {
      if (eventQueue.length > 0) {
        resolve(eventQueue.shift()!)
      } else if (isDone) {
        resolve(null)
      } else {
        resolveNext = resolve
        // Timeout after 60 seconds
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

  eventSource.close()
  yield { type: 'done' }
}

// Simple non-streaming prompt for quick queries
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

// Check if OpenCode is running locally
export async function isOpenCodeAvailable(): Promise<boolean> {
  try {
    // Use /config/providers endpoint which returns JSON
    const response = await fetch(`${OPENCODE_API_URL}/config/providers`, {
      method: 'GET',
      signal: AbortSignal.timeout(2000),
    })
    console.log('[OpenCode] Health check response:', response.status)
    return response.ok
  } catch (error) {
    console.error('[OpenCode] Health check failed:', error)
    return false
  }
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

// Get list of available providers and models from OpenCode
export async function getProvidersAndModels(): Promise<{ providers: OpenCodeProvider[]; models: OpenCodeModel[] }> {
  try {
    const response = await fetch(`${OPENCODE_API_URL}/config/providers`)
    if (!response.ok) return { providers: [], models: [] }

    const data = await response.json()
    const providers: OpenCodeProvider[] = []
    const models: OpenCodeModel[] = []

    // Parse providers array
    const providerList = data.providers || []
    for (const provider of providerList) {
      const providerId = provider.id
      const providerName = provider.name || providerId

      const providerModels: OpenCodeModel[] = []

      // Models can be an object or array
      const modelEntries = provider.models
        ? (typeof provider.models === 'object' && !Array.isArray(provider.models)
          ? Object.entries(provider.models)
          : [])
        : []

      for (const [modelId, modelConfig] of modelEntries) {
        const config = modelConfig as { name?: string; id?: string }
        const model: OpenCodeModel = {
          id: config.id || modelId,
          name: config.name || modelId,
          providerId,
          providerName,
        }
        providerModels.push(model)
        models.push(model)
      }

      providers.push({
        id: providerId,
        name: providerName,
        models: providerModels,
      })
    }

    return { providers, models }
  } catch (error) {
    console.error('[OpenCode] Failed to fetch providers:', error)
    return { providers: [], models: [] }
  }
}

// Get list of available models (legacy function)
export async function getModels(): Promise<{ id: string; name: string; provider: string }[]> {
  const { models } = await getProvidersAndModels()
  return models.map(m => ({ id: m.id, name: m.name, provider: m.providerId }))
}

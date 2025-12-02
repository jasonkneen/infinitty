// Claude Code Integration Service
// Uses persistent bidirectional streaming with Claude CLI

import { Command, type Child } from '@tauri-apps/plugin-shell'
import { getEnvWithPath } from '../lib/shellEnv'

// Thinking levels for extended thinking feature
export type ThinkingLevel = 'none' | 'low' | 'medium' | 'high'

export const THINKING_BUDGETS: Record<ThinkingLevel, number> = {
  none: 0,
  low: 5000,      // ~5k tokens
  medium: 20000,  // ~20k tokens
  high: 50000,    // ~50k tokens (max supported)
}

export interface ClaudeCodeSession {
  id: string
  createdAt: Date
}

export interface StreamingResponse {
  type: 'text' | 'tool-call' | 'tool-result' | 'thinking' | 'error' | 'done' | 'stats'
  content?: string
  toolName?: string
  toolId?: string
  toolInput?: Record<string, unknown>
  toolResult?: string
  isError?: boolean
  error?: string
  stats?: {
    provider?: string
    model?: string
    tokens?: {
      input?: number
      output?: number
      cacheRead?: number
      cacheCreation?: number
    }
    cost?: number
    duration?: number
  }
}

// Get the Claude CLI command name for Tauri shell allowlist
function getClaudeCommand(): string {
  return 'claude'
}

// Check if Claude CLI is available
export async function isClaudeCodeAvailable(): Promise<boolean> {
  try {
    const claudeCmd = getClaudeCommand()
    const env = await getEnvWithPath()
    const cmd = Command.create(claudeCmd, ['--version'], { env })
    const output = await cmd.execute()
    console.log('[ClaudeCode] Version check result:', output.code, output.stdout)
    return output.code === 0
  } catch (e) {
    console.error('[ClaudeCode] CLI availability check failed:', e)
    return false
  }
}

// Persistent Claude Code Session Manager
// Maintains a single long-running process with bidirectional JSON streaming
class ClaudeCodeSessionManager {
  private process: Child | null = null
  private command: ReturnType<typeof Command.create> | null = null
  private sessionId: string | null = null
  private model: string = 'sonnet'
  private thinkingLevel: ThinkingLevel = 'none'
  private cwd: string | undefined = undefined
  private buffer: string = ''
  private messageQueue: StreamingResponse[] = []
  private waitingResolvers: ((response: StreamingResponse | null) => void)[] = []
  private isConnected: boolean = false
  private currentMessageId: number = 0

  async connect(model: string = 'sonnet', cwd?: string, thinkingLevel: ThinkingLevel = 'none'): Promise<string> {
    // Check if settings changed - need to reconnect
    const settingsChanged = this.isConnected && this.process && (
      this.model !== model ||
      this.thinkingLevel !== thinkingLevel ||
      this.cwd !== cwd
    )

    if (settingsChanged) {
      console.log('[ClaudeCode] Settings changed, reconnecting...')
      await this.disconnect()
    }

    if (this.isConnected && this.process) {
      console.log('[ClaudeCode] Already connected, session:', this.sessionId)
      return this.sessionId!
    }

    this.model = model
    this.thinkingLevel = thinkingLevel
    this.cwd = cwd
    this.sessionId = crypto.randomUUID()

    const claudeCmd = getClaudeCommand()
    const env = await getEnvWithPath()

    // Bidirectional streaming mode - keeps process alive for multiple messages
    const args = [
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose', // Required for stream-json output
      '--model', model,
      '--permission-mode', 'acceptEdits',
      '--session-id', this.sessionId,
      '--replay-user-messages', // Echo back user messages for acknowledgment
    ]

    // Add thinking budget if enabled
    const thinkingBudget = THINKING_BUDGETS[thinkingLevel]
    if (thinkingBudget > 0) {
      args.push('--thinking-budget', thinkingBudget.toString())
      console.log('[ClaudeCode] Extended thinking enabled, budget:', thinkingBudget)
    }

    console.log('[ClaudeCode] Starting persistent session:', this.sessionId)
    console.log('[ClaudeCode] Args:', args)

    this.command = Command.create(claudeCmd, args, {
      cwd: cwd || undefined,
      env,
    })

    // Set up stdout handler for streaming responses
    this.command.stdout.on('data', (data: string) => {
      this.handleStdout(data)
    })

    this.command.stderr.on('data', (data: string) => {
      console.error('[ClaudeCode] STDERR:', data)
    })

    this.command.on('close', (data: { code: number | null }) => {
      console.log('[ClaudeCode] Process closed with code:', data.code)
      this.isConnected = false
      this.process = null
      // Resolve any waiting promises with done
      this.resolveAll({ type: 'done' })
    })

    this.command.on('error', (error: string) => {
      console.error('[ClaudeCode] Process error:', error)
      this.isConnected = false
      this.resolveAll({ type: 'error', error })
    })

    // Spawn the persistent process
    this.process = await this.command.spawn()
    this.isConnected = true
    console.log('[ClaudeCode] Persistent process started, pid:', this.process.pid)

    return this.sessionId
  }

  private handleStdout(data: string) {
    this.buffer += data
    const lines = this.buffer.split('\n')
    this.buffer = lines.pop() || ''

    for (const line of lines) {
      this.processLine(line)
    }
  }

  private processLine(line: string) {
    const trimmed = line.trim()
    if (!trimmed || !trimmed.startsWith('{')) return

    try {
      const data = JSON.parse(trimmed)
      console.log('[ClaudeCode] Event:', data.type, data.subtype || '')

      // Handle different event types
      if (data.type === 'assistant' && data.message?.content) {
        for (const block of data.message.content) {
          if (block.type === 'text' && block.text) {
            this.pushResponse({ type: 'text', content: block.text })
          } else if (block.type === 'thinking' && block.thinking) {
            this.pushResponse({ type: 'thinking', content: block.thinking })
          } else if (block.type === 'tool_use') {
            this.pushResponse({
              type: 'tool-call',
              toolId: block.id,
              toolName: block.name,
              toolInput: block.input,
            })
          }
        }
      } else if (data.type === 'tool_result') {
        this.pushResponse({
          type: 'tool-result',
          toolId: data.tool_use_id,
          toolResult: typeof data.content === 'string' ? data.content : JSON.stringify(data.content),
          isError: data.is_error || false,
        })
      } else if (data.type === 'result') {
        // End of response for this message
        this.pushResponse({
          type: 'stats',
          stats: {
            provider: 'anthropic',
            model: data.modelUsage ? Object.keys(data.modelUsage)[0] : this.model,
            tokens: {
              input: data.usage?.input_tokens,
              output: data.usage?.output_tokens,
              cacheRead: data.usage?.cache_read_input_tokens,
              cacheCreation: data.usage?.cache_creation_input_tokens,
            },
            cost: data.total_cost_usd,
            duration: data.duration_ms,
          },
        })
        this.pushResponse({ type: 'done' })
      } else if (data.type === 'error') {
        this.pushResponse({ type: 'error', error: data.error?.message || 'Unknown error' })
      }
    } catch (e) {
      console.error('[ClaudeCode] JSON parse error:', e, 'Line:', line.slice(0, 100))
    }
  }

  private pushResponse(response: StreamingResponse) {
    if (this.waitingResolvers.length > 0) {
      const resolve = this.waitingResolvers.shift()!
      resolve(response)
    } else {
      this.messageQueue.push(response)
    }
  }

  private resolveAll(response: StreamingResponse) {
    while (this.waitingResolvers.length > 0) {
      const resolve = this.waitingResolvers.shift()!
      resolve(response)
    }
  }

  async *sendMessage(prompt: string): AsyncGenerator<StreamingResponse> {
    if (!this.isConnected || !this.process) {
      yield { type: 'error', error: 'Not connected. Call connect() first.' }
      yield { type: 'done' }
      return
    }

    this.currentMessageId++
    const messageId = this.currentMessageId

    // Send message as JSON to stdin
    const message = {
      type: 'user',
      message: {
        role: 'user',
        content: prompt,
      },
    }

    console.log('[ClaudeCode] Sending message:', messageId, prompt.slice(0, 50))
    await this.process.write(JSON.stringify(message) + '\n')

    // Yield responses until we get 'done' for this message
    let gotDone = false
    while (!gotDone) {
      const response = await this.waitForResponse()
      if (!response) {
        yield { type: 'done' }
        return
      }

      yield response

      if (response.type === 'done' || response.type === 'error') {
        gotDone = true
      }
    }
  }

  private waitForResponse(): Promise<StreamingResponse | null> {
    return new Promise((resolve) => {
      if (this.messageQueue.length > 0) {
        resolve(this.messageQueue.shift()!)
      } else if (!this.isConnected) {
        resolve(null)
      } else {
        this.waitingResolvers.push(resolve)
        // Timeout after 120 seconds
        setTimeout(() => {
          const idx = this.waitingResolvers.indexOf(resolve)
          if (idx !== -1) {
            this.waitingResolvers.splice(idx, 1)
            resolve({ type: 'done' })
          }
        }, 120000)
      }
    })
  }

  async disconnect(): Promise<void> {
    if (this.process) {
      console.log('[ClaudeCode] Disconnecting session:', this.sessionId)
      await this.process.kill()
      this.process = null
      this.isConnected = false
      this.sessionId = null
    }
  }

  isSessionConnected(): boolean {
    return this.isConnected
  }

  getSessionId(): string | null {
    return this.sessionId
  }
}

// Singleton session manager
let sessionManager: ClaudeCodeSessionManager | null = null

function getSessionManager(): ClaudeCodeSessionManager {
  if (!sessionManager) {
    sessionManager = new ClaudeCodeSessionManager()
  }
  return sessionManager
}

// Public API - maintains persistent connection

export async function createSession(
  model: string = 'sonnet',
  cwd?: string,
  thinkingLevel: ThinkingLevel = 'none'
): Promise<ClaudeCodeSession> {
  const manager = getSessionManager()
  const id = await manager.connect(model, cwd, thinkingLevel)
  return {
    id,
    createdAt: new Date(),
  }
}

export async function* streamPrompt(
  prompt: string,
  model: string = 'sonnet',
  cwd?: string,
  thinkingLevel: ThinkingLevel = 'none'
): AsyncGenerator<StreamingResponse> {
  const manager = getSessionManager()

  // Ensure connected (will reconnect if thinking level changed)
  if (!manager.isSessionConnected()) {
    await manager.connect(model, cwd, thinkingLevel)
  }

  // Stream response from persistent process
  yield* manager.sendMessage(prompt)
}

// Get current thinking level
export function getThinkingLevelLabel(level: ThinkingLevel): string {
  switch (level) {
    case 'none': return 'Off'
    case 'low': return 'Low (~5k tokens)'
    case 'medium': return 'Medium (~20k tokens)'
    case 'high': return 'High (~50k tokens)'
  }
}

export async function disconnectSession(): Promise<void> {
  const manager = getSessionManager()
  await manager.disconnect()
}

// Simple non-streaming prompt
export async function sendPrompt(prompt: string, model?: string): Promise<string> {
  let fullResponse = ''

  for await (const chunk of streamPrompt(prompt, model)) {
    if (chunk.type === 'text' && chunk.content) {
      fullResponse += chunk.content
    } else if (chunk.type === 'error') {
      throw new Error(chunk.error)
    }
  }

  return fullResponse
}

// Codex CLI Integration Service
// Uses Tauri shell to spawn codex CLI with JSONL streaming output

import { Command, type Child } from '@tauri-apps/plugin-shell'
import { getEnvWithPath } from '../lib/shellEnv'

export interface CodexSession {
  id: string
  createdAt: Date
}

export interface StreamingResponse {
  type: 'text' | 'tool-call' | 'tool-result' | 'reasoning' | 'error' | 'done' | 'stats' | 'file-change'
  content?: string
  toolName?: string
  toolId?: string
  toolInput?: Record<string, unknown>
  toolResult?: string
  isError?: boolean
  error?: string
  changes?: Array<{ kind: string; path: string }>
  stats?: {
    provider?: string
    model?: string
    tokens?: {
      input?: number
      output?: number
      cached?: number
    }
    cost?: number
    duration?: number
  }
}

// Check if Codex CLI is available
let cachedAvailability: boolean | null = null
let availabilityPromise: Promise<boolean> | null = null

export async function isCodexAvailable(): Promise<boolean> {
  if (cachedAvailability !== null) return cachedAvailability
  if (availabilityPromise) return availabilityPromise

  availabilityPromise = (async () => {
    try {
      const env = await getEnvWithPath()
      const cmd = Command.create('codex', ['--version'], { env })
      const output = await cmd.execute()
      console.log('[Codex] Version check result:', output.code, output.stdout)
      cachedAvailability = output.code === 0
      return cachedAvailability
    } catch (e) {
      console.error('[Codex] CLI availability check failed:', e)
      cachedAvailability = false
      return false
    } finally {
      availabilityPromise = null
    }
  })()

  return availabilityPromise
}

// Codex Session Manager - spawns codex exec with --json for JSONL streaming
class CodexSessionManager {
  private process: Child | null = null
  private command: ReturnType<typeof Command.create> | null = null
  private sessionId: string | null = null
  private model: string = 'o4-mini'
  private buffer: string = ''
  private messageQueue: StreamingResponse[] = []
  private waitingResolvers: ((response: StreamingResponse | null) => void)[] = []
  private isRunning: boolean = false
  private startTime: number = 0

  async run(prompt: string, model: string = 'o4-mini', cwd?: string): Promise<string> {
    if (this.isRunning) {
      // Kill existing process
      await this.stop()
    }

    this.model = model
    this.sessionId = crypto.randomUUID()
    this.buffer = ''
    this.messageQueue = []
    this.waitingResolvers = []
    this.startTime = Date.now()

    const env = await getEnvWithPath()

    // Build args for codex exec with JSONL output
    const args = [
      'exec',
      '--json',                    // JSONL output
      '--sandbox', 'workspace-write',
      '--skip-git-repo-check',
      '-a', 'never',               // Never ask for approval (auto-approve)
    ]

    // Add model if specified
    if (model && model !== 'codex-default') {
      args.push('-m', model)
    }

    // Add working directory
    if (cwd) {
      args.push('-C', cwd)
    }

    // Add prompt
    args.push(prompt)

    console.log('[Codex] Starting exec with args:', args)

    this.command = Command.create('codex', args, {
      cwd: cwd || undefined,
      env,
    })

    // Set up stdout handler for JSONL streaming
    this.command.stdout.on('data', (data: string) => {
      this.handleStdout(data)
    })

    this.command.stderr.on('data', (data: string) => {
      console.error('[Codex] STDERR:', data)
    })

    this.command.on('close', (data: { code: number | null }) => {
      console.log('[Codex] Process closed with code:', data.code)
      this.isRunning = false
      this.process = null

      // Send stats and done
      const duration = Date.now() - this.startTime
      this.pushResponse({
        type: 'stats',
        stats: {
          provider: 'openai',
          model: this.model,
          duration,
        },
      })
      this.pushResponse({ type: 'done' })
    })

    this.command.on('error', (error: string) => {
      console.error('[Codex] Process error:', error)
      this.isRunning = false
      this.pushResponse({ type: 'error', error })
    })

    // Spawn the process
    this.process = await this.command.spawn()
    this.isRunning = true
    console.log('[Codex] Process started, pid:', this.process.pid)

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
      const event = JSON.parse(trimmed)
      console.log('[Codex] Event:', event.type || event.event_type)

      // Handle different Codex JSONL event types
      // Based on codex CLI output format
      if (event.type === 'message' || event.event_type === 'message') {
        // Text output from the model
        const content = event.content || event.message || event.text
        if (content) {
          this.pushResponse({ type: 'text', content })
        }
      } else if (event.type === 'reasoning' || event.event_type === 'reasoning') {
        // Chain of thought / reasoning
        const content = event.content || event.reasoning || event.text
        if (content) {
          this.pushResponse({ type: 'reasoning', content })
        }
      } else if (event.type === 'tool_call' || event.event_type === 'tool_call' || event.type === 'function_call') {
        // Tool/function call
        this.pushResponse({
          type: 'tool-call',
          toolId: event.id || event.call_id,
          toolName: event.name || event.function?.name || event.tool_name,
          toolInput: event.arguments || event.input || event.function?.arguments,
        })
      } else if (event.type === 'tool_result' || event.event_type === 'tool_result' || event.type === 'function_result') {
        // Tool result
        this.pushResponse({
          type: 'tool-result',
          toolId: event.id || event.call_id,
          toolResult: typeof event.result === 'string' ? event.result : JSON.stringify(event.result),
          isError: event.is_error || event.error,
        })
      } else if (event.type === 'patch' || event.event_type === 'patch' || event.type === 'file_change') {
        // File changes
        const changes = event.changes || event.patches || [{ kind: event.action || 'modify', path: event.path }]
        this.pushResponse({
          type: 'file-change',
          changes,
        })
      } else if (event.type === 'error' || event.event_type === 'error') {
        this.pushResponse({
          type: 'error',
          error: event.message || event.error || 'Unknown error',
        })
      } else if (event.type === 'done' || event.event_type === 'done' || event.type === 'completed') {
        // Completion event with possible stats
        if (event.usage || event.tokens) {
          this.pushResponse({
            type: 'stats',
            stats: {
              provider: 'openai',
              model: event.model || this.model,
              tokens: {
                input: event.usage?.input_tokens || event.tokens?.input,
                output: event.usage?.output_tokens || event.tokens?.output,
                cached: event.usage?.cached_tokens,
              },
              cost: event.cost,
              duration: event.duration_ms || (Date.now() - this.startTime),
            },
          })
        }
      } else if (event.content || event.text || event.message) {
        // Fallback: treat any event with content as text
        const content = event.content || event.text || event.message
        if (typeof content === 'string') {
          this.pushResponse({ type: 'text', content })
        }
      }
    } catch (e) {
      console.error('[Codex] JSON parse error:', e, 'Line:', line.slice(0, 100))
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

  async *getResponses(): AsyncGenerator<StreamingResponse> {
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
      } else if (!this.isRunning && this.messageQueue.length === 0) {
        resolve(null)
      } else {
        this.waitingResolvers.push(resolve)
        // Timeout after 300 seconds (codex can be slow)
        setTimeout(() => {
          const idx = this.waitingResolvers.indexOf(resolve)
          if (idx !== -1) {
            this.waitingResolvers.splice(idx, 1)
            resolve({ type: 'done' })
          }
        }, 300000)
      }
    })
  }

  async stop(): Promise<void> {
    if (this.process) {
      console.log('[Codex] Stopping session:', this.sessionId)
      await this.process.kill()
      this.process = null
      this.isRunning = false
      this.sessionId = null
    }
  }

  isSessionRunning(): boolean {
    return this.isRunning
  }

  getSessionId(): string | null {
    return this.sessionId
  }
}

// Singleton session manager
let sessionManager: CodexSessionManager | null = null

function getSessionManager(): CodexSessionManager {
  if (!sessionManager) {
    sessionManager = new CodexSessionManager()
  }
  return sessionManager
}

// Public API

export async function createSession(): Promise<CodexSession> {
  return {
    id: crypto.randomUUID(),
    createdAt: new Date(),
  }
}

export async function* streamPrompt(
  _sessionId: string,
  prompt: string,
  model: string = 'o4-mini',
  cwd?: string
): AsyncGenerator<StreamingResponse> {
  const manager = getSessionManager()

  // Start the codex exec process
  await manager.run(prompt, model, cwd)

  // Stream responses
  yield* manager.getResponses()
}

export async function stopSession(): Promise<void> {
  const manager = getSessionManager()
  await manager.stop()
}

// Simple non-streaming prompt
export async function sendPrompt(prompt: string, model?: string, cwd?: string): Promise<string> {
  let fullResponse = ''

  for await (const chunk of streamPrompt('', prompt, model, cwd)) {
    if (chunk.type === 'text' && chunk.content) {
      fullResponse += chunk.content
    } else if (chunk.type === 'error') {
      throw new Error(chunk.error)
    }
  }

  return fullResponse
}

// Get available Codex models
export function getCodexModels(): Array<{ id: string; name: string; description?: string }> {
  return [
    { id: 'o4-mini', name: 'o4-mini', description: 'Fast and efficient' },
    { id: 'o3', name: 'o3', description: 'Most capable reasoning' },
    { id: 'gpt-4.1', name: 'GPT-4.1', description: 'Latest GPT-4 variant' },
  ]
}

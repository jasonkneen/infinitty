import { useCallback, useRef, useState, useEffect } from 'react'
import { spawn, type IPty } from 'tauri-pty'
import { homeDir } from '@tauri-apps/api/path'
import type { Block } from '../types/blocks'
import { createCommandBlock, createAIResponseBlock, createInteractiveBlock, isInteractiveCommand } from '../types/blocks'
import { cleanTerminalOutput } from '../lib/ansi'
import type { ProviderType } from '../types/providers'
import { createSession, streamPrompt, getSessionMessages } from '../services/opencode'
import { streamChat, THINKING_BUDGETS, type ThinkingLevel } from '../services/ai'
import { CHANGE_TERMINAL_CWD_EVENT, emitPwdChanged } from './useFileExplorer'
import { getEnvWithPath } from '../lib/shellEnv'
import type { ModelMessage } from 'ai'

// Maximum blocks to keep in memory - evict oldest when exceeded
const MAX_BLOCKS = 500

// Helper to get block creation time (handles different field names)
function getBlockTime(block: Block): Date {
  if (block.type === 'error' || block.type === 'system' || block.type === 'tool-output') {
    return block.timestamp
  }
  return block.startTime
}

// Helper to check if block is still running/active
function isBlockActive(block: Block): boolean {
  return (
    (block.type === 'command' && block.isRunning) ||
    (block.type === 'interactive' && block.isRunning) ||
    (block.type === 'ai-response' && block.isStreaming)
  )
}

// Track evicted block IDs for cleanup (populated by addBlockWithEviction)
let lastEvictedIds: string[] = []

// Helper to add block with eviction policy
function addBlockWithEviction(blocks: Block[], newBlock: Block): Block[] {
  const updated = [...blocks, newBlock]
  lastEvictedIds = [] // Reset evicted IDs tracking
  if (updated.length > MAX_BLOCKS) {
    // Remove oldest blocks that aren't running
    const running = updated.filter(isBlockActive)
    const completed = updated.filter(b => !isBlockActive(b))
    // Keep newest completed blocks up to limit
    const toKeep = completed.slice(-(MAX_BLOCKS - running.length))
    // Track which blocks were evicted for completedBlocksRef cleanup
    const toKeepIds = new Set([...toKeep, ...running].map(b => b.id))
    lastEvictedIds = updated.filter(b => !toKeepIds.has(b.id)).map(b => b.id)
    return [...toKeep, ...running].sort((a, b) =>
      getBlockTime(a).getTime() - getBlockTime(b).getTime()
    )
  }
  return updated
}

// Get and clear evicted block IDs (called after setBlocks to clean up refs)
function getAndClearEvictedIds(): string[] {
  const ids = lastEvictedIds
  lastEvictedIds = []
  return ids
}

// Helper to convert blocks to history
function blocksToHistory(blocks: Block[]): ModelMessage[] {
  const messages: ModelMessage[] = [];
  for (const block of blocks) {
    if (block.type === 'ai-response') {
      if (block.prompt) {
        messages.push({ role: 'user', content: block.prompt });
      }
      
      const content: any[] = [];
      if (block.response) {
        content.push({ type: 'text', text: block.response });
      }
      
       if (block.toolCalls) {
         for (const tc of block.toolCalls) {
           content.push({ 
             type: 'tool-call', 
             toolCallId: tc.id, 
             toolName: tc.name, 
             input: tc.input || {} 
           });
         }
       }
      
      if (content.length > 0) {
        messages.push({ role: 'assistant', content });
      }
      
       if (block.toolCalls) {
         const toolResults: any[] = [];
         for (const tc of block.toolCalls) {
           if (tc.status === 'completed' || tc.status === 'error') {
              toolResults.push({
                type: 'tool-result',
                toolCallId: tc.id,
                toolName: tc.name,
                output: tc.output || (tc.status === 'error' ? 'Error' : 'Done')
              });
           }
         }
         if (toolResults.length > 0) {
             messages.push({ role: 'tool', content: toolResults });
        }
      }
    }
  }
  return messages;
}

// Global registry to persist blocks across React remounts (tab switches)
interface BlocksInstance {
  blocks: Block[]
  cwd: string
}
const blocksRegistry = new Map<string, BlocksInstance>()

// Clean up a persisted blocks instance (call when pane is permanently closed)
export function destroyPersistedBlocks(persistKey: string): void {
  blocksRegistry.delete(persistKey)
}

interface UseBlockTerminalOptions {
  persistKey?: string
  initialCwd?: string
}

export function useBlockTerminal(options: UseBlockTerminalOptions = {}) {
  const { persistKey, initialCwd } = options

  // Initialize from registry if persisted, otherwise empty
  const getInitialBlocks = (): Block[] => {
    if (persistKey && blocksRegistry.has(persistKey)) {
      return blocksRegistry.get(persistKey)!.blocks
    }
    return []
  }

  const getInitialCwd = (): string => {
    if (persistKey && blocksRegistry.has(persistKey)) {
      return blocksRegistry.get(persistKey)!.cwd
    }
    return initialCwd || ''
  }

  const [blocks, setBlocks] = useState<Block[]>(getInitialBlocks)
  const [cwd, setCwd] = useState<string>(getInitialCwd)
  const homePathRef = useRef<string>('~')

  // Sync blocks to registry when they change
  useEffect(() => {
    if (persistKey) {
      blocksRegistry.set(persistKey, { blocks, cwd })
    }
  }, [persistKey, blocks, cwd])

  // Get real home directory on mount (only if cwd not already set)
  useEffect(() => {
    if (cwd) return // Already have cwd from registry or prop
    homeDir()
      .then((dir) => {
        homePathRef.current = dir
        setCwd(dir)
      })
      .catch(() => setCwd('~'))
  }, [cwd])

  // Listen for CWD change requests from file explorer
  useEffect(() => {
    const handleCwdChange = (event: CustomEvent<{ path: string }>) => {
      const path = event.detail.path
      if (path) {
        console.log('[BlockTerminal] Changing CWD to:', path)
        setCwd(path)
        emitPwdChanged(path)
      }
    }

    window.addEventListener(CHANGE_TERMINAL_CWD_EVENT, handleCwdChange as EventListener)
    return () => {
      window.removeEventListener(CHANGE_TERMINAL_CWD_EVENT, handleCwdChange as EventListener)
    }
  }, [])

  // Track ALL spawned PTYs by block ID for proper cleanup
  const ptyMapRef = useRef<Map<string, IPty>>(new Map())
  // Track which processes have completed to prevent race conditions
  const completedBlocksRef = useRef<Set<string>>(new Set())

  // Clean up completedBlocksRef when blocks are evicted to prevent memory leak
  useEffect(() => {
    const evictedIds = getAndClearEvictedIds()
    if (evictedIds.length > 0) {
      evictedIds.forEach(id => completedBlocksRef.current.delete(id))
    }
  }, [blocks])

  const resolvePath = useCallback((target: string, base: string): string => {
    if (target === '~') {
      return homePathRef.current
    }
    if (target.startsWith('~/')) {
      return `${homePathRef.current}/${target.slice(2)}`
    }
    if (!target.startsWith('/')) {
      return `${base}/${target}`
    }
    return target
  }, [])

  const getDefaultShell = useCallback(() => {
    if (navigator.platform.includes('Mac')) return '/bin/zsh'
    if (navigator.platform.includes('Win')) return 'powershell.exe'
    return '/bin/bash'
  }, [])

  // No-op for backwards compatibility
  const initPty = useCallback(() => {}, [])

  const executeCommand = useCallback(async (command: string) => {
    // Check if this is an interactive command
    if (isInteractiveCommand(command)) {
      const block = createInteractiveBlock(command, cwd)
      setBlocks((prev) => addBlockWithEviction(prev, block))
      return block.id
    }

    // Create new command block
    const block = createCommandBlock(command, cwd)
    setBlocks((prev) => addBlockWithEviction(prev, block))

    // Spawn a new PTY for this command specifically
    const shell = getDefaultShell()
    let outputBuffer = ''
    let cleanedOutput = ''
    let updateTimeout: ReturnType<typeof setTimeout> | null = null

    try {
      const cdMatch = command.match(/^\\s*cd\\s+([^;&|]+)\\s*$/)
      const nextCwdTarget = cdMatch?.[1]?.trim()

      let env: Record<string, string> | undefined
      try {
        env = await getEnvWithPath()
      } catch (error) {
        console.warn('[BlockTerminal] Failed to capture shell env, using default:', error)
      }

      const pty = spawn(shell, ['-l', '-c', command], {
        cols: 120,
        rows: 30,
        cwd,
        env,
      })

      ptyMapRef.current.set(block.id, pty)

      pty.onData((data: string) => {
        if (completedBlocksRef.current.has(block.id)) return

        outputBuffer += data
        cleanedOutput += cleanTerminalOutput(data, command)

        if (!updateTimeout) {
          updateTimeout = setTimeout(() => {
            updateTimeout = null
            if (completedBlocksRef.current.has(block.id)) return
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id ? { ...b, output: cleanedOutput } : b
              )
            )
          }, 100)
        }
      })

      pty.onExit((e: { exitCode: number }) => {
        completedBlocksRef.current.add(block.id)

        if (updateTimeout) {
          clearTimeout(updateTimeout)
          updateTimeout = null
        }

        cleanedOutput = cleanTerminalOutput(outputBuffer, command)
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  isRunning: false,
                  exitCode: e.exitCode,
                  endTime: new Date(),
                  output: cleanedOutput,
                }
              : b
          )
        )

        if (nextCwdTarget && e.exitCode === 0) {
          const nextPath = resolvePath(nextCwdTarget, cwd)
          setCwd(nextPath)
          emitPwdChanged(nextPath)
        }

        ptyMapRef.current.delete(block.id)
      })
    } catch (error) {
      console.error('Failed to spawn command:', error)
      completedBlocksRef.current.add(block.id)
      setBlocks((prev) =>
        prev.map((b) =>
          b.id === block.id
            ? {
                ...b,
                isRunning: false,
                exitCode: 1,
                endTime: new Date(),
                output: 'Error: Failed to execute command',
              }
            : b
        )
      )
    }

    return block.id
  }, [cwd, getDefaultShell, resolvePath])

  const completeInteractiveBlock = useCallback((blockId: string, exitCode: number) => {
    setBlocks((prev) =>
      prev.map((b) =>
        b.id === blockId
          ? {
              ...b,
              isRunning: false,
              exitCode,
              endTime: new Date(),
            }
          : b
      )
    )
  }, [])

  // OpenCode session reference
  const openCodeSessionRef = useRef<string | null>(null)

  // Set/switch the OpenCode session
  const setOpenCodeSession = useCallback((sessionId: string | null) => {
    console.log('[BlockTerminal] Setting OpenCode session to:', sessionId)
    openCodeSessionRef.current = sessionId
  }, [])

  // Get current OpenCode session ID
  const getOpenCodeSessionId = useCallback(() => {
    return openCodeSessionRef.current
  }, [])

  // Track pagination state for session loading
  const sessionPaginationRef = useRef<{
    sessionId: string
    loadedCount: number
    total: number
    hasMore: boolean
  } | null>(null)

  // Convert messages to blocks (helper function)
  const messagesToBlocks = useCallback((messages: Awaited<ReturnType<typeof getSessionMessages>>['messages']): Block[] => {
    const rawBlocks: Block[] = []
    const usedUserMsgIds = new Set<string>()
    
    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i]
      
      if (msg.role === 'assistant') {
        let userMsg = null
        for (let j = i - 1; j >= 0; j--) {
          const candidate = messages[j]
          if (candidate.role === 'user' && !usedUserMsgIds.has(candidate.id)) {
            userMsg = candidate
            usedUserMsgIds.add(candidate.id)
            break
          }
        }
        
        const hasContent = msg.content && msg.content.trim().length > 0
        const hasToolCalls = msg.toolCalls && msg.toolCalls.length > 0
        
        if (!userMsg && !hasContent && !hasToolCalls) {
          continue
        }
        
        const prompt = userMsg?.content || ''
        
        const block: Block = {
          id: msg.id,
          type: 'ai-response',
          prompt,
          response: msg.content,
          model: msg.model || 'unknown',
          startTime: userMsg?.createdAt || msg.createdAt,
          endTime: msg.createdAt,
          isStreaming: false,
          provider: msg.provider,
          tokens: msg.tokens,
          toolCalls: msg.toolCalls?.map((tc: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'completed' | 'error' }) => ({
            id: tc.id,
            name: tc.name,
            input: tc.input,
            output: tc.output,
            status: tc.status,
          })),
        }
        rawBlocks.push(block)
      }
    }
    
    const mergedBlocks: Block[] = []
    for (const block of rawBlocks) {
      if (block.type !== 'ai-response') {
        mergedBlocks.push(block)
        continue
      }
      
      const hasPrompt = block.prompt && block.prompt.trim().length > 0
      const hasResponse = block.response && block.response.trim().length > 0
      const isToolOnly = !hasPrompt && !hasResponse && block.toolCalls && block.toolCalls.length > 0
      
      const prevBlock = mergedBlocks[mergedBlocks.length - 1]
      if (isToolOnly && prevBlock && prevBlock.type === 'ai-response') {
        const sameModel = prevBlock.model === block.model && prevBlock.provider === block.provider
        
        if (sameModel) {
          prevBlock.toolCalls = [...(prevBlock.toolCalls || []), ...(block.toolCalls || [])]
          if (block.tokens) {
            prevBlock.tokens = {
              input: (prevBlock.tokens?.input || 0) + (block.tokens.input || 0),
              output: (prevBlock.tokens?.output || 0) + (block.tokens.output || 0),
            }
          }
          prevBlock.endTime = block.endTime
          continue
        }
      }
      
      mergedBlocks.push(block)
    }
    
    return mergedBlocks
  }, [])

  const loadOpenCodeSession = useCallback(async (sessionId: string, limit = 20) => {
    openCodeSessionRef.current = sessionId
    const result = await getSessionMessages(sessionId, { limit, fromEnd: true })
    sessionPaginationRef.current = {
      sessionId,
      loadedCount: result.messages.length,
      total: result.total,
      hasMore: result.hasMore,
    }
    const newBlocks = messagesToBlocks(result.messages)
    setBlocks(newBlocks)
    return { loaded: newBlocks.length, total: result.total, hasMore: result.hasMore }
  }, [messagesToBlocks])

  const loadMoreMessages = useCallback(async (count = 20) => {
    const pagination = sessionPaginationRef.current
    if (!pagination || !pagination.hasMore) {
      return { loaded: 0, hasMore: false }
    }
    
    const result = await getSessionMessages(pagination.sessionId, {
      limit: count,
      offset: pagination.loadedCount,
      fromEnd: true,
    })
    
    sessionPaginationRef.current = {
      ...pagination,
      loadedCount: pagination.loadedCount + result.messages.length,
      hasMore: result.hasMore,
    }
    
    const olderBlocks = messagesToBlocks(result.messages)
    if (olderBlocks.length > 0) {
      setBlocks(prev => [...olderBlocks, ...prev])
    }
    
    return { loaded: olderBlocks.length, hasMore: result.hasMore }
  }, [messagesToBlocks])

  const canLoadMoreMessages = useCallback(() => {
    return sessionPaginationRef.current?.hasMore ?? false
  }, [])

  const executeAIQuery = useCallback((prompt: string, model: string, provider?: ProviderType, thinkingLevel?: ThinkingLevel) => {
    const debug = import.meta.env.DEV
    if (debug) {
      console.log('[BlockTerminal] executeAIQuery called with provider:', provider, 'model:', model, 'thinkingLevel:', thinkingLevel)
    }

    const formatErrorMessage = (error: unknown): string => {
      if (error instanceof Error) return error.message || 'Unknown error'
      return 'Unknown error'
    }

    const block = createAIResponseBlock(prompt, model)
    setBlocks((prev) => addBlockWithEviction(prev, block))

    let started = false
    let resolveStarted!: () => void
    let rejectStarted!: (err: unknown) => void
    const startedPromise = new Promise<void>((resolve, reject) => {
      resolveStarted = () => {
        if (started) return
        started = true
        resolve()
      }
      rejectStarted = (err) => {
        if (started) return
        started = true
        reject(err)
      }
    })

    const failBlock = (prefix: string, error: unknown) => {
      const message = formatErrorMessage(error)
      if (debug) {
        console.error(`[BlockTerminal] ${prefix}:`, error)
      }
      setBlocks((prev) =>
        prev.map((b) =>
          b.id === block.id
            ? {
                ...b,
                response: `❌ ${prefix}: ${message}`,
                isStreaming: false,
                endTime: new Date(),
              }
            : b
        )
      )
    }

    // Run the long-lived stream in the background; resolve/reject only based on whether the stream starts.
    void (async () => {
      // Handle OpenCode provider
      if (provider === 'opencode') {
        if (debug) console.log('[BlockTerminal] Using OpenCode SDK')
        try {
          if (!openCodeSessionRef.current) {
            const session = await createSession()
            openCodeSessionRef.current = session.id
          }

          let fullResponse = ''
          let stats: any
          const toolCalls: any[] = []
          let currentToolId: string | null = null

          const handleChunk = async (chunk: any) => {
            if (chunk.type === 'text' && chunk.content) {
              fullResponse += chunk.content
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id
                    ? { ...b, response: fullResponse }
                    : b
                )
              )
            } else if (chunk.type === 'tool-call' && chunk.toolName) {
              const toolId = crypto.randomUUID()
              currentToolId = toolId
              toolCalls.push({
                id: toolId,
                name: chunk.toolName,
                input: chunk.toolInput,
                status: 'running',
                startTime: new Date(),
              })
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id && b.type === 'ai-response'
                    ? { ...b, toolCalls: [...toolCalls.map(t => ({ ...t }))] }
                    : b
                )
              )
            } else if (chunk.type === 'tool-result') {
              if (currentToolId) {
                const toolIndex = toolCalls.findIndex(t => t.id === currentToolId)
                if (toolIndex !== -1) {
                  toolCalls[toolIndex] = {
                    ...toolCalls[toolIndex],
                    status: 'completed',
                    output: chunk.toolResult,
                    endTime: new Date(),
                  }
                }
                currentToolId = null
              }
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id && b.type === 'ai-response'
                    ? { ...b, toolCalls: [...toolCalls.map(t => ({ ...t }))] }
                    : b
                )
              )
            } else if (chunk.type === 'stats' && chunk.stats) {
              stats = chunk.stats
            } else if (chunk.type === 'error') {
              fullResponse += `\n❌ Error: ${chunk.error}\n`
            }
          }

          const stream = streamPrompt(openCodeSessionRef.current, prompt, model)
          const iterator = (stream as AsyncIterable<any>)[Symbol.asyncIterator]()

          const first = await iterator.next()
          resolveStarted()

          if (!first.done) {
            await handleChunk(first.value)
          }

          while (true) {
            const next = await iterator.next()
            if (next.done) break
            await handleChunk(next.value)
          }

          const endTime = new Date()
          const duration = stats?.duration || (endTime.getTime() - block.startTime.getTime())
          setBlocks((prev) =>
            prev.map((b) =>
              b.id === block.id && b.type === 'ai-response'
                ? {
                    ...b,
                    isStreaming: false,
                    endTime,
                    provider: stats?.provider,
                    model: stats?.model || b.model,
                    tokens: stats?.tokens,
                    cost: stats?.cost,
                    duration,
                    toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
                  }
                : b
            )
          )
        } catch (error) {
          if (!started) rejectStarted(error)
          failBlock('OpenCode error', error)
        }
        return
      }

      if (provider === 'claude-code' || provider === 'codex') {
        // Handle Claude Code / Codex via Vercel AI SDK
        if (debug) console.log(`[BlockTerminal] Using ${provider} via AI SDK`)

        try {
          const history = blocksToHistory(blocks)
          history.push({ role: 'user', content: prompt })

           // Provider switch logic:
           // - `claude-code` -> local-auth via `claude-agent-sdk` (no API key)
           // - `codex` -> OpenAI HTTP via AI SDK (requires OPENAI_API_KEY)
           const aiProvider = provider === 'claude-code' ? 'claude-code' : 'openai'
          const thinking = thinkingLevel && thinkingLevel !== 'none' ? {
            type: 'enabled' as const,
            budget: THINKING_BUDGETS[thinkingLevel],
          } : undefined

          const result = await streamChat({
            modelId: model,
                     provider: aiProvider,
            messages: history,
            thinking,
            cwd,
          })

          let fullResponse = ''
          let thinkingContent = ''
          const toolCalls: any[] = []

          // Smooth streaming
          let pendingText = ''
          let flushScheduled = false
          const flushText = () => {
            if (!pendingText) {
              flushScheduled = false
              return
            }
            fullResponse += pendingText
            pendingText = ''
            flushScheduled = false
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id
                  ? { ...b, response: fullResponse }
                  : b
              )
            )
          }
          const scheduleFlush = () => {
            if (flushScheduled) return
            flushScheduled = true
            setTimeout(flushText, 50)
          }

          const handlePart = (part: any) => {
            if (part.type === 'text-delta') {
              pendingText += part.text
              scheduleFlush()
            } else if (part.type === 'reasoning-start') {
              thinkingContent = ''
            } else if (part.type === 'reasoning-delta') {
              thinkingContent += part.text
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id && b.type === 'ai-response'
                    ? { ...b, thinking: thinkingContent }
                    : b
                )
              )
            } else if (part.type === 'tool-call') {
              toolCalls.push({
                id: part.toolCallId,
                name: part.toolName,
                input: part.input,
                status: 'running',
                startTime: new Date(),
              })
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id && b.type === 'ai-response'
                    ? { ...b, toolCalls: [...toolCalls.map(t => ({ ...t }))] }
                    : b
                )
              )
            } else if (part.type === 'tool-result') {
              const toolIndex = toolCalls.findIndex(t => t.id === part.toolCallId)
              if (toolIndex !== -1) {
                toolCalls[toolIndex] = {
                  ...toolCalls[toolIndex],
                  status: 'completed',
                  output: typeof part.output === 'string' ? part.output : JSON.stringify(part.output),
                  endTime: new Date(),
                }
              }
              setBlocks((prev) =>
                prev.map((b) =>
                  b.id === block.id && b.type === 'ai-response'
                    ? { ...b, toolCalls: [...toolCalls.map(t => ({ ...t }))] }
                    : b
                )
              )
            } else if (part.type === 'error') {
              flushText()
              fullResponse += `\n❌ Error: ${part.error}\n`
            }
          }

          const iterator = (result.fullStream as AsyncIterable<any>)[Symbol.asyncIterator]()
          const first = await iterator.next()
          resolveStarted()
          if (!first.done) handlePart(first.value)

          while (true) {
            const next = await iterator.next()
            if (next.done) break
            handlePart(next.value)
          }

          flushText()

          // Mark complete
          const endTime = new Date()
          const duration = endTime.getTime() - block.startTime.getTime()

          setBlocks((prev) =>
            prev.map((b) =>
              b.id === block.id && b.type === 'ai-response'
                ? {
                    ...b,
                    isStreaming: false,
                    endTime,
                    provider: aiProvider,
                    model: model,
                    duration,
                    toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
                  }
                : b
            )
          )
        } catch (error) {
          if (!started) rejectStarted(error)
          failBlock('AI SDK error', error)
        }

        return
      }

      if (provider === 'lmstudio') {
      // Handle LM Studio provider (OpenAI-compatible API)
      if (debug) console.log('[BlockTerminal] Using LM Studio')

      // System prompt for local models to enable coding assistance
      const localModelSystemPrompt = `You are an expert coding assistant running locally. You help with:
- Writing, reviewing, and debugging code
- Explaining programming concepts
- Suggesting best practices and improvements
- Answering technical questions

When providing code:
- Use markdown code blocks with language tags (e.g., \`\`\`typescript)
- Keep explanations concise but helpful
- If asked to modify code, show the complete modified version
- Suggest improvements when you see potential issues

You have access to the user's terminal and can help them run commands. When suggesting shell commands, format them in code blocks with \`\`\`bash or \`\`\`sh.

Be direct and helpful. The user is a developer who values efficiency.`

      let reader: ReadableStreamDefaultReader<Uint8Array> | undefined
      try {
        const response = await fetch('http://localhost:1234/v1/chat/completions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model: model,
            messages: [
              { role: 'system', content: localModelSystemPrompt },
              { role: 'user', content: prompt }
            ],
            stream: true,
          }),
        })

        if (!response.ok) {
          throw new Error(`LM Studio API error: ${response.status} ${response.statusText}`)
        }

        reader = response.body?.getReader()
        if (!reader) throw new Error('No response body')

        resolveStarted()

        const decoder = new TextDecoder()
        let fullResponse = ''
        const startTime = block.startTime.getTime()

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          const chunk = decoder.decode(value, { stream: true })
          const lines = chunk.split('\n').filter(line => line.trim().startsWith('data:'))

          for (const line of lines) {
            const data = line.replace('data: ', '').trim()
            if (data === '[DONE]') continue
            try {
              const parsed = JSON.parse(data)
              const content = parsed.choices?.[0]?.delta?.content || ''
              if (content) {
                fullResponse += content
                setBlocks((prev) =>
                  prev.map((b) =>
                    b.id === block.id ? { ...b, response: fullResponse } : b
                  )
                )
              }
            } catch {
              // Skip malformed JSON
            }
          }
        }

        const endTime = new Date()
        const duration = endTime.getTime() - startTime
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  isStreaming: false,
                  endTime,
                  provider: 'lmstudio',
                  model: model,
                  duration,
                }
              : b
          )
        )
      } catch (error) {
        if (!started) rejectStarted(error)
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                ...b,
                response: `❌ LM Studio error: ${error instanceof Error ? error.message : 'Unknown error'}\n\nMake sure LM Studio is running on localhost:1234`,
                isStreaming: false,
                endTime: new Date(),
              }
              : b
          )
        )
        if (debug) console.error('[BlockTerminal] LM Studio error:', error)
      } finally {
        // Always cancel reader to prevent memory leaks
        reader?.cancel().catch(() => {})
      }
      return
    }

    if (provider === 'ollama') {
      // Handle Ollama provider
      if (debug) console.log('[BlockTerminal] Using Ollama')

      // System prompt for local models to enable coding assistance
      const ollamaSystemPrompt = `You are an expert coding assistant running locally. You help with:
- Writing, reviewing, and debugging code
- Explaining programming concepts
- Suggesting best practices and improvements
- Answering technical questions

When providing code:
- Use markdown code blocks with language tags (e.g., \`\`\`typescript)
- Keep explanations concise but helpful
- If asked to modify code, show the complete modified version
- Suggest improvements when you see potential issues

You have access to the user's terminal and can help them run commands. When suggesting shell commands, format them in code blocks with \`\`\`bash or \`\`\`sh.

Be direct and helpful. The user is a developer who values efficiency.`

      let reader: ReadableStreamDefaultReader<Uint8Array> | undefined
      try {
        const response = await fetch('http://localhost:11434/api/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model: model,
            messages: [
              { role: 'system', content: ollamaSystemPrompt },
              { role: 'user', content: prompt }
            ],
            stream: true,
          }),
        })

        if (!response.ok) {
          throw new Error(`Ollama API error: ${response.status} ${response.statusText}`)
        }

        reader = response.body?.getReader()
        if (!reader) throw new Error('No response body')

        resolveStarted()

        const decoder = new TextDecoder()
        let fullResponse = ''
        const startTime = block.startTime.getTime()

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          const chunk = decoder.decode(value, { stream: true })
          const lines = chunk.split('\n').filter(line => line.trim())

          for (const line of lines) {
            try {
              const parsed = JSON.parse(line)
              const content = parsed.message?.content || ''
              if (content) {
                fullResponse += content
                setBlocks((prev) =>
                  prev.map((b) =>
                    b.id === block.id ? { ...b, response: fullResponse } : b
                  )
                )
              }
            } catch {
              // Skip malformed JSON
            }
          }
        }

        const endTime = new Date()
        const duration = endTime.getTime() - startTime
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  isStreaming: false,
                  endTime,
                  provider: 'ollama',
                  model: model,
                  duration,
                }
              : b
          )
        )
      } catch (error) {
        if (!started) rejectStarted(error)
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                ...b,
                response: `❌ Ollama error: ${error instanceof Error ? error.message : 'Unknown error'}\n\nMake sure Ollama is running on localhost:11434`,
                isStreaming: false,
                endTime: new Date(),
              }
              : b
          )
        )
        if (debug) console.error('[BlockTerminal] Ollama error:', error)
      } finally {
        // Always cancel reader to prevent memory leaks
        reader?.cancel().catch(() => {})
      }
      return
    }

      // Placeholder for other providers
      resolveStarted()
      setTimeout(() => {
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  response: `This is a placeholder response for: "${prompt}"\n\nProvider: ${provider || 'default'}\nModel: ${model}\n\nDirect API integration for ${provider} coming soon!`,
                  isStreaming: false,
                  endTime: new Date(),
                }
              : b
          )
        )
      }, 1000)
    })()

    return startedPromise
  }, [blocks, cwd])

  const clearBlocks = useCallback(() => {
    setBlocks([])
  }, [])

  // Dismiss an interactive block (shows minimal status line)
  const dismissBlock = useCallback((blockId: string) => {
    // Kill the PTY if running
    const pty = ptyMapRef.current.get(blockId)
    if (pty) {
      pty.kill()
      ptyMapRef.current.delete(blockId)
      completedBlocksRef.current.add(blockId)
    }

    // Mark as dismissed
    setBlocks((prev) =>
      prev.map((b) => {
        if (b.id !== blockId) return b
        // Only interactive and command blocks have exitCode
        if (b.type === 'interactive' || b.type === 'command') {
          return { ...b, isRunning: false, dismissed: true, endTime: new Date(), exitCode: b.exitCode ?? 130 }
        }
        return b
      })
    )
  }, [])

  // Kill a specific PTY by block ID, or all PTYs if no ID provided
  const killPty = useCallback((blockId?: string) => {
    if (blockId) {
      const pty = ptyMapRef.current.get(blockId)
      if (pty) {
        pty.kill()
        ptyMapRef.current.delete(blockId)
        completedBlocksRef.current.add(blockId)
      }
    } else {
      // Kill ALL PTYs (for cleanup on unmount)
      ptyMapRef.current.forEach((pty, id) => {
        try {
          pty.kill()
        } catch (e) {
          console.error(`Failed to kill PTY ${id}:`, e)
        }
        completedBlocksRef.current.add(id)
      })
      ptyMapRef.current.clear()
    }
  }, [])

  // Change working directory
  const changeDirectory = useCallback((newCwd: string) => {
    setCwd(newCwd)
    emitPwdChanged(newCwd)
  }, [])

  return {
    blocks,
    cwd,
    executeCommand,
    executeAIQuery,
    clearBlocks,
    initPty,
    killPty,
    completeInteractiveBlock,
    dismissBlock,
    changeDirectory,
    setOpenCodeSession,
    getOpenCodeSessionId,
    loadOpenCodeSession,
    loadMoreMessages,
    canLoadMoreMessages,
  }
}

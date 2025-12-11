import { useCallback, useRef, useState, useEffect } from 'react'
import { spawn, type IPty } from 'tauri-pty'
import { homeDir } from '@tauri-apps/api/path'
import type { Block } from '../types/blocks'
import { createCommandBlock, createAIResponseBlock, createInteractiveBlock, isInteractiveCommand } from '../types/blocks'
import { cleanTerminalOutput } from '../lib/ansi'
import type { ProviderType } from '../types/providers'
import { createSession, streamPrompt, getSessionMessages } from '../services/opencode'
import { streamPrompt as streamClaudeCode, createSession as createClaudeCodeSession, isClaudeCodeAvailable, type ThinkingLevel } from '../services/claudecode'
import { streamPrompt as streamCodex } from '../services/codex'
import { CHANGE_TERMINAL_CWD_EVENT, emitPwdChanged } from './useFileExplorer'
import { getEnvWithPath } from '../lib/shellEnv'

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

// Helper to add block with eviction policy
function addBlockWithEviction(blocks: Block[], newBlock: Block): Block[] {
  const updated = [...blocks, newBlock]
  if (updated.length > MAX_BLOCKS) {
    // Remove oldest blocks that aren't running
    const running = updated.filter(isBlockActive)
    const completed = updated.filter(b => !isBlockActive(b))
    // Keep newest completed blocks up to limit
    const toKeep = completed.slice(-(MAX_BLOCKS - running.length))
    return [...toKeep, ...running].sort((a, b) =>
      getBlockTime(a).getTime() - getBlockTime(b).getTime()
    )
  }
  return updated
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

  // Pre-warm Claude Code session once we have a cwd.
  useEffect(() => {
    if (!cwd) return
    let cancelled = false
    // Fire and forget; warm-up cost happens off the first user prompt.
    void (async () => {
      try {
        const available = await isClaudeCodeAvailable()
        if (!available || cancelled) return
        await createClaudeCodeSession('haiku', cwd, 'none')
      } catch (e) {
        // Ignore warm-up errors; actual prompt will surface failures.
        if (!cancelled) console.debug('[BlockTerminal] Claude Code prewarm skipped:', e)
      }
    })()
    return () => {
      cancelled = true
    }
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
      // Use login shell (-l) to source user's shell config (.zshrc, .zprofile)
      // which sets up PATH for tools like claude, opencode, etc.
      // Heuristic: detect simple `cd <path>` commands so we can persist cwd for the next block
      const cdMatch = command.match(/^\\s*cd\\s+([^;&|]+)\\s*$/)
      const nextCwdTarget = cdMatch?.[1]?.trim()

      // Get shell environment with proper PATH (fixes GUI app not inheriting shell env)
      // If this fails (e.g. in tests or restricted environments), fall back to default env.
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

      // Track PTY by block ID for proper cleanup
      ptyMapRef.current.set(block.id, pty)

      // Capture output with batched updates (every 100ms max)
      pty.onData((data: string) => {
        // Skip if process already completed (race condition prevention)
        if (completedBlocksRef.current.has(block.id)) return

        outputBuffer += data
        cleanedOutput += cleanTerminalOutput(data, command)

        // Batch updates to reduce re-renders
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

      // Handle exit
      pty.onExit((e: { exitCode: number }) => {
        // Mark as completed to prevent race conditions
        completedBlocksRef.current.add(block.id)

        // Clear any pending update
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

        // Persist cwd after a successful `cd` command in OpenWarp mode
        if (nextCwdTarget && e.exitCode === 0) {
          const nextPath = resolvePath(nextCwdTarget, cwd)
          setCwd(nextPath)
          emitPwdChanged(nextPath)
        }

        // Clean up PTY reference
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
                // Sanitized error - no stack traces
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
    
    // Messages are sorted by time, so iterate and pair user -> assistant
    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i]
      
      if (msg.role === 'assistant') {
        // Find the most recent unpaired user message before this assistant message
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
        
        // Skip if no user prompt AND no content AND no tool calls
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
    
    // Merge tool-only blocks into previous block (same model)
    const mergedBlocks: Block[] = []
    for (const block of rawBlocks) {
      if (block.type !== 'ai-response') {
        mergedBlocks.push(block)
        continue
      }
      
      const hasPrompt = block.prompt && block.prompt.trim().length > 0
      const hasResponse = block.response && block.response.trim().length > 0
      const isToolOnly = !hasPrompt && !hasResponse && block.toolCalls && block.toolCalls.length > 0
      
      // Check if we can merge tool-only block into previous block
      const prevBlock = mergedBlocks[mergedBlocks.length - 1]
      if (isToolOnly && prevBlock && prevBlock.type === 'ai-response') {
        const sameModel = prevBlock.model === block.model && prevBlock.provider === block.provider
        
        // Merge tool calls into previous block if same model
        if (sameModel) {
          prevBlock.toolCalls = [...(prevBlock.toolCalls || []), ...(block.toolCalls || [])]
          // Accumulate tokens
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
    
    console.log('[BlockTerminal] Created', mergedBlocks.length, 'blocks from', messages.length, 'messages (merged from', rawBlocks.length, ')')
    return mergedBlocks
  }, [])

  // Load a session's messages as blocks (initial load - last 20 messages)
  const loadOpenCodeSession = useCallback(async (sessionId: string, limit = 20) => {
    console.log('[BlockTerminal] Loading OpenCode session:', sessionId, 'limit:', limit)
    
    // Set the session ID
    openCodeSessionRef.current = sessionId
    
    // Fetch last N messages from the session
    const result = await getSessionMessages(sessionId, { limit, fromEnd: true })
    console.log('[BlockTerminal] Loaded', result.messages.length, 'of', result.total, 'messages, hasMore:', result.hasMore)
    
    // Track pagination state
    sessionPaginationRef.current = {
      sessionId,
      loadedCount: result.messages.length,
      total: result.total,
      hasMore: result.hasMore,
    }
    
    // Convert to blocks
    console.log('[BlockTerminal] Converting', result.messages.length, 'messages to blocks')
    const newBlocks = messagesToBlocks(result.messages)
    console.log('[BlockTerminal] Converted to', newBlocks.length, 'blocks')
    
    // Replace current blocks with loaded ones
    setBlocks(newBlocks)
    
    return { loaded: newBlocks.length, total: result.total, hasMore: result.hasMore }
  }, [messagesToBlocks])

  // Load older messages (backfill when scrolling up)
  const loadMoreMessages = useCallback(async (count = 20) => {
    const pagination = sessionPaginationRef.current
    if (!pagination || !pagination.hasMore) {
      console.log('[BlockTerminal] No more messages to load')
      return { loaded: 0, hasMore: false }
    }
    
    console.log('[BlockTerminal] Loading more messages, offset:', pagination.loadedCount)
    
    // Fetch older messages
    const result = await getSessionMessages(pagination.sessionId, {
      limit: count,
      offset: pagination.loadedCount,
      fromEnd: true,
    })
    
    console.log('[BlockTerminal] Loaded', result.messages.length, 'more messages, hasMore:', result.hasMore)
    
    // Update pagination state
    sessionPaginationRef.current = {
      ...pagination,
      loadedCount: pagination.loadedCount + result.messages.length,
      hasMore: result.hasMore,
    }
    
    // Convert to blocks
    const olderBlocks = messagesToBlocks(result.messages)
    
    // Prepend older blocks to existing ones
    if (olderBlocks.length > 0) {
      setBlocks(prev => [...olderBlocks, ...prev])
    }
    
    return { loaded: olderBlocks.length, hasMore: result.hasMore }
  }, [messagesToBlocks])

  // Check if more messages can be loaded
  const canLoadMoreMessages = useCallback(() => {
    return sessionPaginationRef.current?.hasMore ?? false
  }, [])

  // Note: Claude Code session is managed internally by the service (persistent connection)

  const executeAIQuery = useCallback(async (prompt: string, model: string, provider?: ProviderType, thinkingLevel?: ThinkingLevel) => {
    const debug = import.meta.env.DEV
    if (debug) {
      console.log('[BlockTerminal] executeAIQuery called with provider:', provider, 'model:', model, 'thinkingLevel:', thinkingLevel)
    }
    const block = createAIResponseBlock(prompt, model)
    setBlocks((prev) => addBlockWithEviction(prev, block))

    // Handle OpenCode provider
    if (provider === 'opencode') {
      if (debug) console.log('[BlockTerminal] Using OpenCode SDK')
      try {
        // Create session if needed
        if (!openCodeSessionRef.current) {
          if (debug) console.log('[BlockTerminal] Creating new OpenCode session...')
          const session = await createSession()
          openCodeSessionRef.current = session.id
          if (debug) console.log('[BlockTerminal] Session created:', session.id)
        } else {
          if (debug) console.log('[BlockTerminal] Reusing existing session:', openCodeSessionRef.current)
        }

        // Stream the response
        if (debug) console.log('[BlockTerminal] Starting to stream response...')
        let fullResponse = ''
        let chunkCount = 0
        let stats: { provider?: string; model?: string; tokens?: { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } }; cost?: number; duration?: number } | undefined
        const toolCalls: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'pending' | 'running' | 'completed' | 'error'; startTime?: Date; endTime?: Date }[] = []
        let currentToolId: string | null = null

        for await (const chunk of streamPrompt(openCodeSessionRef.current, prompt, model)) {
          chunkCount++
          if (debug) console.log('[BlockTerminal] Received chunk', chunkCount, ':', chunk.type)
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
            // Track tool call
            if (debug) console.log('[BlockTerminal] TOOL CALL:', chunk.toolName, chunk.toolInput)
            const toolId = crypto.randomUUID()
            currentToolId = toolId
            toolCalls.push({
              id: toolId,
              name: chunk.toolName,
              input: chunk.toolInput,
              status: 'running',
              startTime: new Date(),
            })
            if (debug) console.log('[BlockTerminal] Tool calls array now:', toolCalls.length, 'items')
            // Update block with tool calls
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'tool-result') {
            // Mark tool as completed
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
            // Update block with tool calls
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'stats' && chunk.stats) {
            stats = chunk.stats
            if (debug) console.log('[BlockTerminal] Received stats:', stats)
          } else if (chunk.type === 'error') {
            fullResponse += `\n❌ Error: ${chunk.error}\n`
            break
          }
        }

        // Mark complete with stats
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
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  response: `❌ OpenCode error: ${error instanceof Error ? error.message : 'Unknown error'}`,
                  isStreaming: false,
                  endTime: new Date(),
                }
              : b
          )
        )
      }
    } else if (provider === 'claude-code') {
      // Handle Claude Code provider
      if (debug) console.log('[BlockTerminal] Using Claude Code provider')
      try {
        // Stream the response (session is managed by the service - persistent connection)
        let fullResponse = ''
        let thinkingContent = ''
        let stats: { provider?: string; model?: string; tokens?: { input?: number; output?: number; cacheRead?: number; cacheCreation?: number }; cost?: number; duration?: number } | undefined
        const toolCalls: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'pending' | 'running' | 'completed' | 'error'; startTime?: Date; endTime?: Date }[] = []

        // Smooth streaming: batch text updates to avoid React render per token.
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

        for await (const chunk of streamClaudeCode(prompt, model, cwd, thinkingLevel)) {
          if (debug) console.log('[BlockTerminal] Claude Code chunk received:', chunk.type)
          if (chunk.type === 'text' && chunk.content) {
            pendingText += chunk.content
            scheduleFlush()
          } else if (chunk.type === 'thinking' && chunk.content) {
            // Extended thinking content
            thinkingContent += chunk.content
            if (debug) console.log('[BlockTerminal] Thinking chunk')
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, thinking: thinkingContent }
                  : b
              )
            )
          } else if (chunk.type === 'tool-call' && chunk.toolName) {
            if (debug) console.log('[BlockTerminal] Claude Code tool call:', chunk.toolName)
            const toolId = chunk.toolId || crypto.randomUUID()
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
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'tool-result') {
            const toolIndex = toolCalls.findIndex(t => t.id === chunk.toolId || t.status === 'running')
            if (toolIndex !== -1) {
              // Create new object to trigger React re-render
              toolCalls[toolIndex] = {
                ...toolCalls[toolIndex],
                status: chunk.isError ? 'error' : 'completed',
                output: chunk.toolResult,
                endTime: new Date(),
              }
            }
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'stats' && chunk.stats) {
            stats = chunk.stats
            if (debug) console.log('[BlockTerminal] Claude Code stats')
          } else if (chunk.type === 'error') {
            // Ensure any pending text is flushed before final error.
            flushText()
            fullResponse += `\n❌ Error: ${chunk.error}\n`
            break
          }
        }

        // Flush remaining pending text.
        flushText()

        // Mark all remaining running tools as completed (fallback if tool-result wasn't received)
        for (const tool of toolCalls) {
          if (tool.status === 'running' || tool.status === 'pending') {
            tool.status = 'completed'
            tool.endTime = new Date()
          }
        }

        // Mark complete with stats
        const endTime = new Date()
        const duration = stats?.duration || (endTime.getTime() - block.startTime.getTime())
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id && b.type === 'ai-response'
              ? {
                  ...b,
                  isStreaming: false,
                  endTime,
                  provider: stats?.provider || 'anthropic',
                  model: stats?.model || b.model,
                  tokens: stats?.tokens ? {
                    input: stats.tokens.input,
                    output: stats.tokens.output,
                    cache: {
                      read: stats.tokens.cacheRead,
                      write: stats.tokens.cacheCreation,
                    },
                  } : undefined,
                  cost: stats?.cost,
                  duration,
                  toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
                }
              : b
          )
        )
      } catch (error) {
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  response: `❌ Claude Code error: ${error instanceof Error ? error.message : 'Unknown error'}`,
                  isStreaming: false,
                  endTime: new Date(),
                }
              : b
          )
        )
      }
    } else if (provider === 'codex') {
      // Handle Codex provider via CLI
      if (debug) console.log('[BlockTerminal] Using Codex CLI')
      try {
        let fullResponse = ''
        let reasoningContent = ''
        let stats: { provider?: string; model?: string; tokens?: { input?: number; output?: number; cached?: number }; cost?: number; duration?: number } | undefined
        const toolCalls: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'pending' | 'running' | 'completed' | 'error'; startTime?: Date; endTime?: Date }[] = []
        let currentToolId: string | null = null

        for await (const chunk of streamCodex('', prompt, model, cwd)) {
          if (debug) console.log('[BlockTerminal] Codex chunk:', chunk.type)
          if (chunk.type === 'text' && chunk.content) {
            fullResponse += chunk.content
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id
                  ? { ...b, response: fullResponse }
                  : b
              )
            )
          } else if (chunk.type === 'reasoning' && chunk.content) {
            reasoningContent += chunk.content
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, thinking: reasoningContent }
                  : b
              )
            )
          } else if (chunk.type === 'tool-call' && chunk.toolName) {
            const toolId = chunk.toolId || crypto.randomUUID()
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
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'tool-result') {
            const toolIndex = toolCalls.findIndex(t => t.id === currentToolId || t.status === 'running')
            if (toolIndex !== -1) {
              toolCalls[toolIndex] = {
                ...toolCalls[toolIndex],
                status: chunk.isError ? 'error' : 'completed',
                output: chunk.toolResult,
                endTime: new Date(),
              }
            }
            currentToolId = null
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'file-change' && chunk.changes) {
            const fileToolId = crypto.randomUUID()
            toolCalls.push({
              id: fileToolId,
              name: 'file_change',
              input: { changes: chunk.changes },
              status: 'completed',
              output: chunk.changes.map(c => `${c.kind}: ${c.path}`).join('\n'),
              startTime: new Date(),
              endTime: new Date(),
            })
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, toolCalls: [...toolCalls.map(t => ({...t}))] }
                  : b
              )
            )
          } else if (chunk.type === 'stats' && chunk.stats) {
            stats = chunk.stats
          } else if (chunk.type === 'error') {
            fullResponse += `\n❌ Error: ${chunk.error}\n`
            break
          }
        }

        // Mark complete with stats
        const endTime = new Date()
        const duration = stats?.duration || (endTime.getTime() - block.startTime.getTime())
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id && b.type === 'ai-response'
              ? {
                  ...b,
                  isStreaming: false,
                  endTime,
                  provider: stats?.provider || 'openai',
                  model: stats?.model || b.model,
                  tokens: stats?.tokens ? {
                    input: stats.tokens.input,
                    output: stats.tokens.output,
                    cache: { read: stats.tokens.cached },
                  } : undefined,
                  cost: stats?.cost,
                  duration,
                  toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
                }
              : b
          )
        )
      } catch (error) {
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  response: `❌ Codex error: ${error instanceof Error ? error.message : 'Unknown error'}`,
                  isStreaming: false,
                  endTime: new Date(),
                }
              : b
          )
        )
      }
    } else {
      // Placeholder for other providers
      setTimeout(() => {
        setBlocks((prev) =>
          prev.map((b) =>
            b.id === block.id
              ? {
                  ...b,
                  response: `This is a placeholder response for: "${prompt}"\n\nProvider: ${provider || 'default'}\nModel: ${model}\n\nFull AI backend integration coming soon!`,
                  isStreaming: false,
                  endTime: new Date(),
                }
              : b
          )
        )
      }, 1000)
    }

    return block.id
  }, [])

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

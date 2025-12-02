import { useCallback, useRef, useState, useEffect } from 'react'
import { spawn, type IPty } from 'tauri-pty'
import { homeDir } from '@tauri-apps/api/path'
import type { Block } from '../types/blocks'
import { createCommandBlock, createAIResponseBlock, createInteractiveBlock, isInteractiveCommand } from '../types/blocks'
import { cleanTerminalOutput } from '../lib/ansi'
import type { ProviderType } from '../types/providers'
import { createSession, streamPrompt, isOpenCodeAvailable } from '../services/opencode'
import { streamPrompt as streamClaudeCode, isClaudeCodeAvailable, type ThinkingLevel } from '../services/claudecode'
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
    let updateTimeout: ReturnType<typeof setTimeout> | null = null

    try {
      // Use login shell (-l) to source user's shell config (.zshrc, .zprofile)
      // which sets up PATH for tools like claude, opencode, etc.
      // Heuristic: detect simple `cd <path>` commands so we can persist cwd for the next block
      const cdMatch = command.match(/^\\s*cd\\s+([^;&|]+)\\s*$/)
      const nextCwdTarget = cdMatch?.[1]?.trim()
      if (nextCwdTarget) {
        const nextPath = resolvePath(nextCwdTarget, cwd)
        setCwd(nextPath)
        emitPwdChanged(nextPath)
      }

      // Get shell environment with proper PATH (fixes GUI app not inheriting shell env)
      const env = await getEnvWithPath()

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

        // Batch updates to reduce re-renders
        if (!updateTimeout) {
          updateTimeout = setTimeout(() => {
            updateTimeout = null
            if (completedBlocksRef.current.has(block.id)) return
            const cleanedOutput = cleanTerminalOutput(outputBuffer, command)
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

        const cleanedOutput = cleanTerminalOutput(outputBuffer, command)
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

  // Note: Claude Code session is managed internally by the service (persistent connection)

  const executeAIQuery = useCallback(async (prompt: string, model: string, provider?: ProviderType, thinkingLevel?: ThinkingLevel) => {
    console.log('[BlockTerminal] executeAIQuery called with provider:', provider, 'model:', model, 'thinkingLevel:', thinkingLevel)
    const block = createAIResponseBlock(prompt, model)
    setBlocks((prev) => addBlockWithEviction(prev, block))

    // Handle OpenCode provider
    if (provider === 'opencode') {
      console.log('[BlockTerminal] Using OpenCode provider')
      try {
        // Check if OpenCode is available
        console.log('[BlockTerminal] Checking OpenCode availability...')
        const available = await isOpenCodeAvailable()
        console.log('[BlockTerminal] OpenCode available:', available)
        if (!available) {
          setBlocks((prev) =>
            prev.map((b) =>
              b.id === block.id
                ? {
                    ...b,
                    response: '⚠️ OpenCode is not running.\n\nStart OpenCode with `opencode` in your terminal, then try again.',
                    isStreaming: false,
                    endTime: new Date(),
                  }
                : b
            )
          )
          return block.id
        }

        // Create session if needed
        if (!openCodeSessionRef.current) {
          console.log('[BlockTerminal] Creating new OpenCode session...')
          const session = await createSession()
          openCodeSessionRef.current = session.id
          console.log('[BlockTerminal] Session created:', session.id)
        } else {
          console.log('[BlockTerminal] Reusing existing session:', openCodeSessionRef.current)
        }

        // Stream the response
        console.log('[BlockTerminal] Starting to stream response...')
        let fullResponse = ''
        let chunkCount = 0
        let stats: { provider?: string; model?: string; tokens?: { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } }; cost?: number; duration?: number } | undefined
        const toolCalls: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'pending' | 'running' | 'completed' | 'error'; startTime?: Date; endTime?: Date }[] = []
        let currentToolId: string | null = null

        for await (const chunk of streamPrompt(openCodeSessionRef.current, prompt, model)) {
          chunkCount++
          console.log('[BlockTerminal] Received chunk', chunkCount, ':', chunk.type)
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
            console.log('[BlockTerminal] 🔧 TOOL CALL:', chunk.toolName, chunk.toolInput)
            const toolId = crypto.randomUUID()
            currentToolId = toolId
            toolCalls.push({
              id: toolId,
              name: chunk.toolName,
              input: chunk.toolInput,
              status: 'running',
              startTime: new Date(),
            })
            console.log('[BlockTerminal] Tool calls array now:', toolCalls.length, 'items')
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
            console.log('[BlockTerminal] Received stats:', stats)
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
      console.log('[BlockTerminal] Using Claude Code provider')
      try {
        // Check if Claude CLI is available
        const available = await isClaudeCodeAvailable()
        console.log('[BlockTerminal] Claude Code available:', available)
        if (!available) {
          setBlocks((prev) =>
            prev.map((b) =>
              b.id === block.id
                ? {
                    ...b,
                    response: '⚠️ Claude Code CLI is not available.\n\nInstall with `npm install -g @anthropic-ai/claude-code` or check your PATH.',
                    isStreaming: false,
                    endTime: new Date(),
                  }
                : b
            )
          )
          return block.id
        }

        // Stream the response (session is managed by the service - persistent connection)
        let fullResponse = ''
        let thinkingContent = ''
        let stats: { provider?: string; model?: string; tokens?: { input?: number; output?: number; cacheRead?: number; cacheCreation?: number }; cost?: number; duration?: number } | undefined
        const toolCalls: { id: string; name: string; input?: Record<string, unknown>; output?: string; status: 'pending' | 'running' | 'completed' | 'error'; startTime?: Date; endTime?: Date }[] = []

        for await (const chunk of streamClaudeCode(prompt, model, cwd, thinkingLevel)) {
          console.log('[BlockTerminal] 📥 Claude Code chunk received:', chunk.type, chunk.content?.slice(0, 50) || '')
          if (chunk.type === 'text' && chunk.content) {
            fullResponse += chunk.content
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id
                  ? { ...b, response: fullResponse }
                  : b
              )
            )
          } else if (chunk.type === 'thinking' && chunk.content) {
            // Extended thinking content
            thinkingContent += chunk.content
            console.log('[BlockTerminal] 🧠 Thinking:', chunk.content.slice(0, 100))
            setBlocks((prev) =>
              prev.map((b) =>
                b.id === block.id && b.type === 'ai-response'
                  ? { ...b, thinking: thinkingContent }
                  : b
              )
            )
          } else if (chunk.type === 'tool-call' && chunk.toolName) {
            console.log('[BlockTerminal] 🔧 Claude Code tool call:', chunk.toolName)
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
            console.log('[BlockTerminal] Claude Code stats:', stats)
          } else if (chunk.type === 'error') {
            fullResponse += `\n❌ Error: ${chunk.error}\n`
            break
          }
        }

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
  }
}

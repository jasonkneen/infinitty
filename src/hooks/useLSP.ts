/**
 * useLSP Hook
 * Provides access to LSP (Language Server Protocol) functionality
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { lspService, type LSPEvent, type Hover, type CompletionItem, type Location, type Diagnostic, type ServerStatus } from '../services/lsp'

/**
 * LSP Hook for editor-like functionality
 */
export function useLSP() {
  const [isInitialized, setIsInitialized] = useState(false)
  const [serverStatus, setServerStatus] = useState<ServerStatus[]>([])

  // Cache debounce timers to prevent memory leaks
  const debounceTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())

  /**
   * Debounce a function call to avoid excessive LSP requests
   * Default delay is 200ms (standard for editor hover)
   */
  const debounce = useCallback(
    <T extends (...args: unknown[]) => Promise<unknown>>(
      key: string,
      fn: T,
      delayMs: number = 200
    ) => {
      return (...args: Parameters<T>) => {
        const timers = debounceTimersRef.current

        // Clear existing timer
        if (timers.has(key)) {
          clearTimeout(timers.get(key)!)
        }

        // Set new timer
        const timer = setTimeout(() => {
          fn(...args)
          timers.delete(key)
        }, delayMs)

        timers.set(key, timer)
      }
    },
    []
  )

  /**
   * Initialize LSP for a project
   */
  const init = useCallback(async (projectPath: string) => {
    const result = await lspService.init(projectPath)
    if (result.success) {
      setIsInitialized(true)
      // Refresh status
      const statusResult = await lspService.getStatus()
      if (statusResult.success && statusResult.data) {
        setServerStatus(statusResult.data)
      }
    }
    return result.success
  }, [])

  /**
   * Shutdown LSP
   */
  const shutdown = useCallback(async () => {
    const result = await lspService.shutdown()
    if (result.success) {
      setIsInitialized(false)
    }
    return result.success
  }, [])

  /**
   * Get hover information at a specific position
   */
  const hover = useCallback(
    async (filePath: string, line: number, character: number): Promise<Hover | null> => {
      const result = await lspService.hover(filePath, line, character)
      return result.success ? result.data ?? null : null
    },
    []
  )

  /**
   * Get completion items at a specific position
   */
  const completion = useCallback(
    async (filePath: string, line: number, character: number): Promise<CompletionItem[]> => {
      const result = await lspService.completion(filePath, line, character)
      return result.success ? result.data ?? [] : []
    },
    []
  )

  /**
   * Go to definition for a symbol
   */
  const definition = useCallback(
    async (filePath: string, line: number, character: number): Promise<Location | Location[] | null> => {
      const result = await lspService.definition(filePath, line, character)
      return result.success ? result.data ?? null : null
    },
    []
  )

  /**
   * Find all references to a symbol
   */
  const references = useCallback(
    async (filePath: string, line: number, character: number): Promise<Location[]> => {
      const result = await lspService.references(filePath, line, character)
      return result.success ? result.data ?? [] : []
    },
    []
  )

  /**
   * Get diagnostics for a file
   */
  const getDiagnostics = useCallback(
    async (filePath: string): Promise<Diagnostic[]> => {
      const result = await lspService.getDiagnosticsForFile(filePath)
      return result.success ? result.data ?? [] : []
    },
    []
  )

  /**
   * Notify LSP that a file has been saved
   */
  const fileSaved = useCallback(async (filePath: string) => {
    const result = await lspService.fileSaved(filePath)
    return result.success
  }, [])

  /**
   * Notify LSP that file content has changed
   */
  const fileChanged = useCallback(async (filePath: string, content?: string) => {
    const result = await lspService.fileChanged(filePath, content)
    return result.success
  }, [])

  /**
   * Enable or disable a server
   */
  const setServerEnabled = useCallback(async (serverId: string, enabled: boolean) => {
    const result = await lspService.setServerEnabled(serverId, enabled)
    if (result.success) {
      // Refresh status
      const statusResult = await lspService.getStatus()
      if (statusResult.success && statusResult.data) {
        setServerStatus(statusResult.data)
      }
    }
    return result.success
  }, [])

  /**
   * Install a server
   */
  const installServer = useCallback(async (serverId: string) => {
    const result = await lspService.installServer(serverId)
    if (result.success) {
      // Refresh status
      const statusResult = await lspService.getStatus()
      if (statusResult.success && statusResult.data) {
        setServerStatus(statusResult.data)
      }
    }
    return result.success
  }, [])

  /**
   * Refresh server status
   */
  const refreshStatus = useCallback(async () => {
    const result = await lspService.getStatus()
    if (result.success && result.data) {
      setServerStatus(result.data)
    }
    return result.success
  }, [])

  /**
   * Subscribe to LSP events
   */
  const onEvent = useCallback((callback: (event: LSPEvent) => void) => {
    return lspService.onEvent(callback)
  }, [])

  /**
   * Check if LSP is available for a file
   */
  const isAvailableForFile = useCallback((filePath: string) => {
    return lspService.isAvailableForFile(filePath)
  }, [])

  /**
   * Get language ID for a file
   */
  const getLanguageId = useCallback((filePath: string) => {
    return lspService.getLanguageId(filePath)
  }, [])

  // Clean up debounce timers on unmount
  useEffect(() => {
    return () => {
      debounceTimersRef.current.forEach((timer) => clearTimeout(timer))
      debounceTimersRef.current.clear()
    }
  }, [])

  return {
    isInitialized,
    serverStatus,
    init,
    shutdown,
    hover,
    completion,
    definition,
    references,
    getDiagnostics,
    fileSaved,
    fileChanged,
    setServerEnabled,
    installServer,
    refreshStatus,
    onEvent,
    debounce,
    isAvailableForFile,
    getLanguageId,
  }
}

/**
 * Hook for LSP UI state management (hover tooltips, autocomplete popups)
 */
export function useLSPUI() {
  const lsp = useLSP()
  const [hoverData, setHoverData] = useState<Hover | null>(null)
  const [hoverPosition, setHoverPosition] = useState<{ x: number; y: number } | null>(null)
  const [isHoverVisible, setIsHoverVisible] = useState(false)

  const [completionItems, setCompletionItems] = useState<CompletionItem[]>([])
  const [completionPosition, setCompletionPosition] = useState<{ x: number; y: number } | null>(null)
  const [isCompletionVisible, setIsCompletionVisible] = useState(false)
  const [filterText, setFilterText] = useState('')

  // Cache for hover results to avoid repeated requests
  const hoverCacheRef = useRef<Map<string, { data: Hover | null; timestamp: number }>>(new Map())
  const CACHE_TTL = 5000 // 5 seconds

  /**
   * Request hover info with debouncing and caching
   */
  const requestHover = useCallback(
    async (filePath: string, line: number, character: number, screenX: number, screenY: number) => {
      const cacheKey = `${filePath}:${line}:${character}`
      const cached = hoverCacheRef.current.get(cacheKey)

      // Check cache
      if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
        if (cached.data) {
          setHoverData(cached.data)
          setHoverPosition({ x: screenX, y: screenY })
          setIsHoverVisible(true)
        }
        return
      }

      // Debounced request
      lsp.debounce(
        'hover',
        async () => {
          const data = await lsp.hover(filePath, line, character)
          hoverCacheRef.current.set(cacheKey, { data, timestamp: Date.now() })

          if (data) {
            setHoverData(data)
            setHoverPosition({ x: screenX, y: screenY })
            setIsHoverVisible(true)
          }
        },
        200
      )()
    },
    [lsp]
  )

  /**
   * Dismiss hover tooltip
   */
  const dismissHover = useCallback(() => {
    setIsHoverVisible(false)
    setHoverData(null)
    setHoverPosition(null)
  }, [])

  /**
   * Request completion items
   */
  const requestCompletion = useCallback(
    async (filePath: string, line: number, character: number, screenX: number, screenY: number) => {
      const items = await lsp.completion(filePath, line, character)

      if (items.length > 0) {
        setCompletionItems(items)
        setCompletionPosition({ x: screenX, y: screenY })
        setIsCompletionVisible(true)
        setFilterText('')
      }
    },
    [lsp]
  )

  /**
   * Filter completion items
   */
  const filterCompletion = useCallback((text: string) => {
    setFilterText(text)
  }, [])

  /**
   * Dismiss completion popup
   */
  const dismissCompletion = useCallback(() => {
    setIsCompletionVisible(false)
    setCompletionItems([])
    setCompletionPosition(null)
    setFilterText('')
  }, [])

  /**
   * Go to definition helper
   */
  const goToDefinition = useCallback(
    async (filePath: string, line: number, character: number) => {
      const result = await lsp.definition(filePath, line, character)

      if (result) {
        const locations = Array.isArray(result) ? result : [result]
        if (locations.length > 0) {
          // Return first location - caller can handle navigation
          return locations[0]
        }
      }

      return null
    },
    [lsp]
  )

  /**
   * Find references helper
   */
  const findReferences = useCallback(
    async (filePath: string, line: number, character: number) => {
      return await lsp.references(filePath, line, character)
    },
    [lsp]
  )

  return {
    ...lsp,
    // Hover state
    hoverData,
    hoverPosition,
    isHoverVisible,
    requestHover,
    dismissHover,
    // Completion state
    completionItems,
    completionPosition,
    isCompletionVisible,
    filterText,
    requestCompletion,
    filterCompletion,
    dismissCompletion,
    // Helpers
    goToDefinition,
    findReferences,
  }
}

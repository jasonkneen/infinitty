// Widget SDK React Hooks
import { useState, useEffect, useCallback, useRef, useContext, createContext } from 'react'
import type {
  WidgetContext,
  WidgetHostAPI,
  WidgetEvents,
  ThemeColors,
  ToolDefinition,
  Disposable,
} from './types'

// ============================================
// SDK Context
// ============================================

interface WidgetSDKContextValue {
  context: WidgetContext
  api: WidgetHostAPI
  events: WidgetEvents
}

export const WidgetSDKContext = createContext<WidgetSDKContextValue | null>(null)

export function useWidgetSDK(): WidgetSDKContextValue {
  const sdk = useContext(WidgetSDKContext)
  if (!sdk) {
    throw new Error('useWidgetSDK must be used within a WidgetSDKProvider')
  }
  return sdk
}

// ============================================
// Theme Hook
// ============================================

export function useTheme(): ThemeColors {
  const { context, events } = useWidgetSDK()
  const [theme, setTheme] = useState<ThemeColors>(context.theme)

  useEffect(() => {
    const disposable = events.onDidChangeVisibility(() => {
      // Refresh theme when visibility changes
      setTheme(context.theme)
    })

    const themeDisposable = context.onThemeChange((newTheme) => {
      setTheme(newTheme)
    })

    return () => {
      disposable.dispose()
      themeDisposable.dispose()
    }
  }, [context, events])

  return theme
}

// ============================================
// Config Hook
// ============================================

export function useConfig<T = Record<string, unknown>>(): T {
  const { context, events } = useWidgetSDK()
  const [config, setConfig] = useState<T>(context.config as T)

  useEffect(() => {
    const disposable = events.onDidChangeConfig((newConfig) => {
      setConfig(newConfig as T)
    })
    return () => disposable.dispose()
  }, [events])

  return config
}

export function useConfigValue<T>(key: string, defaultValue?: T): T | undefined {
  const { context, events } = useWidgetSDK()
  const [value, setValue] = useState<T | undefined>(context.getConfig(key, defaultValue) ?? defaultValue)

  useEffect(() => {
    const disposable = events.onDidChangeConfig((newConfig) => {
      const newValue = (newConfig[key] as T | undefined) ?? defaultValue
      setValue(newValue)
    })
    return () => disposable.dispose()
  }, [events, key, defaultValue])

  return value
}

// ============================================
// Storage Hooks
// ============================================

export function useStorage<T>(key: string, defaultValue?: T): [T | undefined, (value: T) => Promise<void>] {
  const { context } = useWidgetSDK()
  const [value, setLocalValue] = useState<T | undefined>(
    context.storage.get(key, defaultValue)
  )

  const setValue = useCallback(async (newValue: T) => {
    await context.storage.set(key, newValue)
    setLocalValue(newValue)
  }, [context.storage, key])

  return [value, setValue]
}

export function useGlobalState<T>(key: string, defaultValue?: T): [T | undefined, (value: T) => Promise<void>] {
  const { context } = useWidgetSDK()
  const [value, setLocalValue] = useState<T | undefined>(
    context.globalState.get(key, defaultValue)
  )

  const setValue = useCallback(async (newValue: T) => {
    await context.globalState.set(key, newValue)
    setLocalValue(newValue)
  }, [context.globalState, key])

  return [value, setValue]
}

// ============================================
// Tool Registration Hook
// ============================================

export function useTool(tool: Omit<ToolDefinition, 'handler'>, handler: ToolDefinition['handler']): void {
  const { api } = useWidgetSDK()
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    const disposable = api.registerTool({
      ...tool,
      handler: (args) => handlerRef.current(args),
    })
    return () => disposable.dispose()
  }, [api, tool.name, tool.description])
}

export function useTools(tools: ToolDefinition[]): void {
  const { api } = useWidgetSDK()
  const toolsRef = useRef(tools)
  toolsRef.current = tools

  useEffect(() => {
    const disposables: Disposable[] = tools.map((tool) =>
      api.registerTool({
        ...tool,
        handler: (args) => {
          const currentTool = toolsRef.current.find((t) => t.name === tool.name)
          return currentTool?.handler(args) ?? Promise.resolve(null)
        },
      })
    )
    return () => disposables.forEach((d) => d.dispose())
  }, [api, tools.map((t) => t.name).join(',')])
}

// ============================================
// Command Hook
// ============================================

export function useCommand(id: string, handler: (...args: unknown[]) => unknown): void {
  const { api } = useWidgetSDK()
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    const disposable = api.registerCommand(id, (...args) => handlerRef.current(...args))
    return () => disposable.dispose()
  }, [api, id])
}

// ============================================
// Messaging Hooks
// ============================================

export function useMessage<T = unknown>(handler: (message: T) => void): void {
  const { events } = useWidgetSDK()
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    const disposable = events.onDidReceiveMessage((message) => {
      handlerRef.current(message as T)
    })
    return () => disposable.dispose()
  }, [events])
}

export function useBroadcast<T = unknown>(channel: string, handler: (message: T) => void): void {
  const { api } = useWidgetSDK()
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    const disposable = api.subscribe(channel, (message) => {
      handlerRef.current(message as T)
    })
    return () => disposable.dispose()
  }, [api, channel])
}

export function useSendMessage(): (targetWidgetId: string, message: unknown) => void {
  const { api } = useWidgetSDK()
  return useCallback(
    (targetWidgetId: string, message: unknown) => {
      api.postMessage(targetWidgetId, message)
    },
    [api]
  )
}

export function useBroadcastSend(): (channel: string, message: unknown) => void {
  const { api } = useWidgetSDK()
  return useCallback(
    (channel: string, message: unknown) => {
      api.broadcast(channel, message)
    },
    [api]
  )
}

// ============================================
// Lifecycle Hooks
// ============================================

export function useWidgetSize(): { width: number; height: number } {
  const { events } = useWidgetSDK()
  const [size, setSize] = useState({ width: 0, height: 0 })

  useEffect(() => {
    const disposable = events.onDidResize((newSize) => {
      setSize(newSize)
    })
    return () => disposable.dispose()
  }, [events])

  return size
}

export function useWidgetVisibility(): boolean {
  const { events } = useWidgetSDK()
  const [visible, setVisible] = useState(true)

  useEffect(() => {
    const disposable = events.onDidChangeVisibility((isVisible) => {
      setVisible(isVisible)
    })
    return () => disposable.dispose()
  }, [events])

  return visible
}

export function useWidgetFocus(): boolean {
  const { events } = useWidgetSDK()
  const [focused, setFocused] = useState(false)

  useEffect(() => {
    const focusDisposable = events.onDidFocus(() => setFocused(true))
    const blurDisposable = events.onDidBlur(() => setFocused(false))
    return () => {
      focusDisposable.dispose()
      blurDisposable.dispose()
    }
  }, [events])

  return focused
}

// ============================================
// Logger Hook
// ============================================

export function useLogger() {
  const { context } = useWidgetSDK()
  return context.log
}

// ============================================
// Disposables Management
// ============================================

export function useDisposables(): {
  add: (disposable: Disposable) => void
  clear: () => void
} {
  const disposablesRef = useRef<Disposable[]>([])

  const add = useCallback((disposable: Disposable) => {
    disposablesRef.current.push(disposable)
  }, [])

  const clear = useCallback(() => {
    disposablesRef.current.forEach((d) => d.dispose())
    disposablesRef.current = []
  }, [])

  useEffect(() => {
    return () => {
      disposablesRef.current.forEach((d) => d.dispose())
    }
  }, [])

  return { add, clear }
}

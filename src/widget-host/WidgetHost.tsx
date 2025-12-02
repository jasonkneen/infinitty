// Widget Host - Loads and manages external widget packages
import { useEffect, useCallback, useRef, useMemo, createContext, useContext, useState } from 'react'
import { createPortal } from "react-dom"
import { open, save } from '@tauri-apps/plugin-dialog'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { useWidgetTools } from '../contexts/WidgetToolsContext'
import { useTabs } from '../contexts/TabsContext'
import { writeToTerminalByKey } from '../hooks/useTerminal'
import { WidgetSDKContext } from '../widget-sdk/hooks'
import { createEventEmitter, DisposableStore } from '../widget-sdk/core'
import { getWidgetProcessManager, type WidgetProcess, type WidgetProcessEvent } from './WidgetProcessManager'
import { getWidgetDiscovery, type DiscoveredWidget } from './WidgetDiscovery'
import type {
  WidgetManifest,
  WidgetModule,
  WidgetContext,
  WidgetHostAPI,
  WidgetEvents,
  ThemeColors,
  WidgetStorage,
  SecretsStorage,
  WidgetLogger,
  ToolDefinition,
  TerminalInstance,
} from '../widget-sdk/types'

// ============================================
// Modal Dialog Types
// ============================================

interface QuickPickItem {
  label: string
  description?: string
  value: unknown
}

interface QuickPickState {
  items: QuickPickItem[]
  placeholder?: string
  resolve: (value: unknown | undefined) => void
}

interface InputBoxState {
  placeholder?: string
  value?: string
  resolve: (value: string | undefined) => void
}

// ============================================
// Widget Registry
// ============================================

interface LoadedWidget {
  manifest: WidgetManifest
  module: WidgetModule
  instances: Map<string, WidgetInstance>
}

interface WidgetInstance {
  id: string
  context: WidgetContext
  api: WidgetHostAPI
  events: WidgetEvents
  disposables: DisposableStore
}

interface RegisteredCommand {
  id: string
  handler: (...args: unknown[]) => unknown | Promise<unknown>
  widgetId: string
}

// In-memory widget registry
const widgetRegistry = new Map<string, LoadedWidget>()

// ============================================
// Widget Host Context
// ============================================

interface WidgetHostContextValue {
  // Inline widget management (traditional)
  loadWidget: (manifestPath: string) => Promise<void>
  unloadWidget: (widgetId: string) => void
  getLoadedWidgets: () => WidgetManifest[]
  createWidgetInstance: (widgetType: string, config?: Record<string, unknown>) => Promise<string>
  destroyWidgetInstance: (instanceId: string) => void

  // Process-based widget management (new)
  discoveredWidgets: DiscoveredWidget[]
  runningProcesses: WidgetProcess[]
  startWidgetProcess: (widgetId: string) => Promise<WidgetProcess>
  stopWidgetProcess: (widgetId: string) => Promise<void>
  refreshWidgets: () => Promise<void>
  callWidgetTool: (toolName: string, args: Record<string, unknown>) => Promise<unknown>

  // Command management
  getRegisteredCommands: () => string[]
}

const WidgetHostContext = createContext<WidgetHostContextValue | null>(null)

export function useWidgetHost() {
  const context = useContext(WidgetHostContext)
  if (!context) {
    throw new Error('useWidgetHost must be used within a WidgetHostProvider')
  }
  return context
}

// ============================================
// Modal Dialog Components
// ============================================

interface QuickPickModalProps {
  state: QuickPickState | null
  onClose: () => void
}

function QuickPickModal({ state, onClose }: QuickPickModalProps) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [filtered, _setFiltered] = useState<QuickPickItem[]>(state?.items || [])

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        state?.resolve(undefined)
        onClose()
      }
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [state, onClose])

  if (!state) return null

  const handleSelect = (item: QuickPickItem) => {
    state.resolve(item.value)
    onClose()
  }

  const handleCancel = () => {
    state.resolve(undefined)
    onClose()
  }

  return createPortal(
    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.5)',
        zIndex: 999999,
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'center',
        paddingTop: 100,
      }}
    >
      <div
        style={{
          backgroundColor: '#1e1e1e',
          borderRadius: 8,
          width: 400,
          maxHeight: 400,
          overflow: 'hidden',
          boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
          border: '1px solid #333',
        }}
      >
        {state.placeholder && (
          <div
            style={{
              padding: '12px 16px',
              borderBottom: '1px solid #333',
              color: '#888',
              fontSize: 13,
            }}
          >
            {state.placeholder}
          </div>
        )}
        <div style={{ maxHeight: 300, overflow: 'auto' }}>
          {filtered.map((item, i) => (
            <div
              key={i}
              onClick={() => handleSelect(item)}
              style={{
                padding: '10px 16px',
                cursor: 'pointer',
                borderBottom: '1px solid #333',
                transition: 'background-color 0.15s',
              }}
              onMouseEnter={(e) => {
                e.currentTarget.style.backgroundColor = '#2a2a2a'
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.backgroundColor = 'transparent'
              }}
            >
              <div style={{ color: '#fff', fontSize: 13 }}>{item.label}</div>
              {item.description && (
                <div style={{ color: '#888', fontSize: 12, marginTop: 2 }}>
                  {item.description}
                </div>
              )}
            </div>
          ))}
        </div>
        <div
          style={{
            padding: '8px 12px',
            borderTop: '1px solid #333',
            textAlign: 'right',
            backgroundColor: '#1a1a1a',
          }}
        >
          <button
            onClick={handleCancel}
            style={{
              padding: '6px 12px',
              background: '#333',
              border: 'none',
              borderRadius: 4,
              color: '#fff',
              cursor: 'pointer',
              fontSize: 13,
              transition: 'background-color 0.15s',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.backgroundColor = '#444'
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.backgroundColor = '#333'
            }}
          >
            Cancel
          </button>
        </div>
      </div>
    </div>,
    document.body
  )
}

interface InputBoxModalProps {
  state: InputBoxState | null
  onClose: () => void
}

function InputBoxModal({ state, onClose }: InputBoxModalProps) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [value, setValue] = useState(state?.value || '')

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        state?.resolve(undefined)
        onClose()
      } else if (e.key === 'Enter') {
        e.preventDefault()
        state?.resolve(value)
        onClose()
      }
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [state, value, onClose])

  if (!state) return null

  const handleSubmit = () => {
    state.resolve(value)
    onClose()
  }

  const handleCancel = () => {
    state.resolve(undefined)
    onClose()
  }

  return createPortal(
    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.5)',
        zIndex: 999999,
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'center',
        paddingTop: 100,
      }}
    >
      <div
        style={{
          backgroundColor: '#1e1e1e',
          borderRadius: 8,
          width: 400,
          boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
          border: '1px solid #333',
          overflow: 'hidden',
        }}
      >
        {state.placeholder && (
          <div
            style={{
              padding: '12px 16px',
              borderBottom: '1px solid #333',
              color: '#888',
              fontSize: 13,
            }}
          >
            {state.placeholder}
          </div>
        )}
        <div style={{ padding: '16px' }}>
          <input
            ref={inputRef}
            type="text"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            style={{
              width: '100%',
              padding: '8px 12px',
              backgroundColor: '#2a2a2a',
              border: '1px solid #444',
              borderRadius: 4,
              color: '#fff',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
            placeholder={state.placeholder}
          />
        </div>
        <div
          style={{
            padding: '12px 16px',
            borderTop: '1px solid #333',
            display: 'flex',
            gap: 8,
            justifyContent: 'flex-end',
            backgroundColor: '#1a1a1a',
          }}
        >
          <button
            onClick={handleCancel}
            style={{
              padding: '6px 12px',
              background: '#333',
              border: 'none',
              borderRadius: 4,
              color: '#fff',
              cursor: 'pointer',
              fontSize: 13,
              transition: 'background-color 0.15s',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.backgroundColor = '#444'
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.backgroundColor = '#333'
            }}
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            style={{
              padding: '6px 12px',
              background: '#0e639c',
              border: 'none',
              borderRadius: 4,
              color: '#fff',
              cursor: 'pointer',
              fontSize: 13,
              transition: 'background-color 0.15s',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.backgroundColor = '#1177bb'
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.backgroundColor = '#0e639c'
            }}
          >
            OK
          </button>
        </div>
      </div>
    </div>,
    document.body
  )
}

// ============================================
// Widget Host Provider
// ============================================

interface WidgetHostProviderProps {
  children: React.ReactNode
  widgetPaths?: string[]  // Paths to widget directories
}

// Toast notification type
interface Toast {
  id: string
  message: string
  type: 'info' | 'warning' | 'error'
}
  const commandsRef = useRef<Map<string, RegisteredCommand>>(new Map())

export function WidgetHostProvider({ children, widgetPaths = [] }: WidgetHostProviderProps) {
  const { settings } = useTerminalSettings()

  // Execute a registered command by ID
  const executeCommand = useCallback(async (commandId: string, ...args: unknown[]): Promise<unknown> => {
    // Try exact match first
    let command = commandsRef.current.get(commandId)

    // If not found, try to find by short name (without widget prefix)
    if (!command) {
      for (const [id, cmd] of commandsRef.current) {
        if (id.endsWith(`:${commandId}`)) {
          command = cmd
          break
        }
      }
    }

    if (!command) {
      console.warn(`[WidgetHost] Command not found: ${commandId}`)
      return undefined
    }

    try {
      const result = command.handler(...args)
      // Handle both sync and async handlers
      return await Promise.resolve(result)
    } catch (error) {
      console.error(`[WidgetHost] Error executing command ${commandId}:`, error)
      throw error
    }
  }, [])

  // Get list of registered commands
  const getRegisteredCommands = useCallback(() => {
    return Array.from(commandsRef.current.keys())
  }, [])

  const { registerTool, unregisterTool, callTool: callWidgetTool } = useWidgetTools()
  const { createNewTab, createWebViewTab, activePaneId } = useTabs()
  const instancesRef = useRef<Map<string, WidgetInstance>>(new Map())
  // Toast notification state
  const [toasts, setToasts] = useState<Toast[]>([])

  // Create showToast function
  const showToast = useCallback((message: string, type: 'info' | 'warning' | 'error' = 'info') => {
    const id = `toast-${Date.now()}-${Math.random()}`
    setToasts(prev => [...prev, { id, message, type }])
    // Auto-dismiss after 4 seconds
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id))
    }, 4000)
  }, [])


  // Modal dialog state
  const [quickPickState, setQuickPickState] = useState<QuickPickState | null>(null)
  const [inputBoxState, setInputBoxState] = useState<InputBoxState | null>(null)

  // Process-based widget state
  const [discoveredWidgets, setDiscoveredWidgets] = useState<DiscoveredWidget[]>([])
  const [runningProcesses, setRunningProcesses] = useState<WidgetProcess[]>([])
  const processManagerRef = useRef(getWidgetProcessManager())
  const discoveryRef = useRef(getWidgetDiscovery())

  // Convert theme settings to ThemeColors
  const theme: ThemeColors = useMemo(() => ({
    ...settings.theme,
    selection: settings.theme.selectionBackground,
  }), [settings.theme])

  // Load a widget from a manifest file
  const loadWidget = useCallback(async (manifestPath: string) => {
    try {
      // In a real implementation, this would:
      // 1. Read the manifest.json
      // 2. Load the compiled widget bundle
      // 3. Validate and register the widget

      // For now, we'll use dynamic imports for local widgets
      const response = await fetch(manifestPath)
      const manifest: WidgetManifest = await response.json()

      // Load the widget module
      const moduleUrl = new URL(manifest.main, manifestPath).href
      const module = await import(/* @vite-ignore */ moduleUrl) as WidgetModule

      widgetRegistry.set(manifest.id, {
        manifest,
        module,
        instances: new Map(),
      })

      console.log(`[WidgetHost] Loaded widget: ${manifest.name} (${manifest.id})`)
    } catch (error) {
      console.error(`[WidgetHost] Failed to load widget from ${manifestPath}:`, error)
      throw error
    }
  }, [])

  // Unload a widget
  const unloadWidget = useCallback((widgetId: string) => {
    const widget = widgetRegistry.get(widgetId)
    if (!widget) return

    const errors: Error[] = []

    // Destroy all instances, collecting errors but continuing to cleanup
    for (const [instanceId, instance] of widget.instances) {
      // Try to dispose instance resources
      try {
        instance.disposables.dispose()
      } catch (e) {
        errors.push(new Error(`Failed to dispose instance ${instanceId}: ${String(e)}`))
      }

      // Try to deactivate the widget module
      try {
        if (widget.module.deactivate) {
          widget.module.deactivate()
        }
      } catch (e) {
        errors.push(new Error(`Failed to deactivate widget ${widgetId}: ${String(e)}`))
      }
    }

    // Clear instances even if some cleanup operations failed
    widget.instances.clear()

    // ALWAYS remove from registry, even if errors occurred
    widgetRegistry.delete(widgetId)

    // Log all collected errors for debugging
    if (errors.length > 0) {
      console.error(`[WidgetHost] Errors unloading widget ${widgetId}:`, errors)
    }

    console.log(`[WidgetHost] Unloaded widget: ${widgetId}`)
  }, [])

  // Get list of loaded widgets
  const getLoadedWidgets = useCallback(() => {
    return Array.from(widgetRegistry.values()).map((w) => w.manifest)
  }, [])

  // Create a widget instance
  const createWidgetInstance = useCallback(async (
    widgetType: string,
    config: Record<string, unknown> = {}
  ): Promise<string> => {
    const widget = widgetRegistry.get(widgetType)
    if (!widget) {
      throw new Error(`Widget not found: ${widgetType}`)
    }

    const instanceId = `${widgetType}-${Date.now()}`
    const disposables = new DisposableStore()

    // Create storage implementations
    const createStorage = (prefix: string): WidgetStorage => {
      const storageKey = `widget:${widgetType}:${prefix}`
      const cache = new Map<string, unknown>()

      // Load from localStorage
      try {
        const stored = localStorage.getItem(storageKey)
        if (stored) {
          const data = JSON.parse(stored)
          Object.entries(data).forEach(([k, v]) => cache.set(k, v))
        }
      } catch {}

      return {
        get: <T,>(key: string, defaultValue?: T) =>
          (cache.get(key) as T | undefined) ?? defaultValue,
        set: async (key: string, value: unknown) => {
          cache.set(key, value)
          localStorage.setItem(storageKey, JSON.stringify(Object.fromEntries(cache)))
        },
        delete: async (key: string) => {
          cache.delete(key)
          localStorage.setItem(storageKey, JSON.stringify(Object.fromEntries(cache)))
        },
        keys: () => Array.from(cache.keys()),
      }
    }

    const storage = createStorage(`instance:${instanceId}`)
    const globalState = createStorage('global')

    // Create secrets storage (in production, use secure storage)
    const secrets: SecretsStorage = {
      get: async (key) => {
        const stored = localStorage.getItem(`widget:${widgetType}:secrets:${key}`)
        return stored ?? undefined
      },
      store: async (key, value) => {
        localStorage.setItem(`widget:${widgetType}:secrets:${key}`, value)
      },
      delete: async (key) => {
        localStorage.removeItem(`widget:${widgetType}:secrets:${key}`)
      },
    }

    // Create logger
    const log: WidgetLogger = {
      trace: (msg, ...args) => console.trace(`[${widget.manifest.name}]`, msg, ...args),
      debug: (msg, ...args) => console.debug(`[${widget.manifest.name}]`, msg, ...args),
      info: (msg, ...args) => console.info(`[${widget.manifest.name}]`, msg, ...args),
      warn: (msg, ...args) => console.warn(`[${widget.manifest.name}]`, msg, ...args),
      error: (msg, ...args) => console.error(`[${widget.manifest.name}]`, msg, ...args),
    }

    // Create event emitters
    const activateEmitter = createEventEmitter<void>()
    const deactivateEmitter = createEventEmitter<void>()
    const resizeEmitter = createEventEmitter<{ width: number; height: number }>()
    const visibilityEmitter = createEventEmitter<boolean>()
    const focusEmitter = createEventEmitter<void>()
    const blurEmitter = createEventEmitter<void>()
    const messageEmitter = createEventEmitter<unknown>()
    const configEmitter = createEventEmitter<Record<string, unknown>>()
    const themeChangeEmitter = createEventEmitter<ThemeColors>()

    // Create widget context
    const context: WidgetContext = {
      widgetId: widgetType,
      widgetType,
      instanceId,
      config,
      getConfig: <T,>(key: string, defaultValue?: T) =>
        (config[key] as T | undefined) ?? defaultValue,
      theme,
      onThemeChange: (callback) => themeChangeEmitter.event(callback),
      storage,
      globalState,
      secrets,
      log,
      extensionPath: '',
      extensionUri: '',
    }

    // Create events object
    const events: WidgetEvents = {
      onDidActivate: activateEmitter.event,
      onWillDeactivate: deactivateEmitter.event,
      onDidResize: resizeEmitter.event,
      onDidChangeVisibility: visibilityEmitter.event,
      onDidFocus: focusEmitter.event,
      onDidBlur: blurEmitter.event,
      onDidReceiveMessage: messageEmitter.event,
      onDidChangeConfig: configEmitter.event,
    }

    // Create host API
    const api: WidgetHostAPI = {
      showMessage: (message, type = 'info') => {
        showToast(message, type as 'info' | 'warning' | 'error')
      },
      showQuickPick: async <T extends { label: string }>(items: (string | T)[], options?: { placeholder?: string }) => {
        return new Promise<T | undefined>((resolve) => {
          const quickPickItems = items.map((item): QuickPickItem => {
            if (typeof item === 'string') {
              return { label: item, value: item }
            }
            // Convert SDK QuickPickItem to local QuickPickItem with value
            return { label: item.label, description: (item as { description?: string }).description, value: item }
          })
          setQuickPickState({
            items: quickPickItems,
            placeholder: options?.placeholder,
            resolve: resolve as (value: unknown) => void,
          })
        })
      },
      showInputBox: async (options) => {
        return new Promise((resolve) => {
          setInputBoxState({
            placeholder: options?.placeholder,
            value: options?.value,
            resolve,
          })
        })
      },
      showProgress: async (task) => task({ report: () => {} }),
      executeCommand: async (commandId: string, ...args: unknown[]) => {
        return executeCommand(commandId, ...args)
      },
      registerCommand: (id: string, handler: (...args: unknown[]) => unknown | Promise<unknown>) => {
        const commandId = `${instanceId}:${id}`

        commandsRef.current.set(commandId, {
          id: commandId,
          handler,
          widgetId: instanceId,
        })

        console.log(`[WidgetHost] Registered command: ${commandId}`)

        return {
          dispose: () => {
            commandsRef.current.delete(commandId)
            console.log(`[WidgetHost] Unregistered command: ${commandId}`)
          },
        }
      },
      registerTool: (tool: ToolDefinition) => {
        registerTool({
          name: tool.name,
          description: tool.description,
          widgetId: instanceId,
          widgetType,
          inputSchema: tool.inputSchema as Record<string, unknown>,
          handler: tool.handler,
        })
        return {
          dispose: () => unregisterTool(tool.name, instanceId),
        }
      },
      callTool: async () => null, // TODO: Implement
      readClipboard: async () => navigator.clipboard.readText(),
      writeClipboard: async (text) => navigator.clipboard.writeText(text),
      readFile: async () => new Uint8Array(), // TODO: Implement with Tauri
      writeFile: async () => {}, // TODO: Implement with Tauri
      showOpenDialog: async (options?: {
        filters?: Array<{ name: string; extensions: string[] }>
        multiple?: boolean
        directory?: boolean
        defaultPath?: string
        title?: string
      }): Promise<string[] | undefined> => {
        try {
          const result = await open({
            filters: options?.filters,
            multiple: options?.multiple,
            directory: options?.directory,
            defaultPath: options?.defaultPath,
            title: options?.title,
          })
          // open() returns null if cancelled, string if single file, string[] if multiple
          // Normalize to always return an array
          if (result === null) return undefined
          return Array.isArray(result) ? result : [result]
        } catch (error) {
          console.error('[WidgetHost] Failed to show open dialog:', error)
          return undefined
        }
      },
      showSaveDialog: async (options?: {
        filters?: Array<{ name: string; extensions: string[] }>
        defaultPath?: string
        title?: string
      }): Promise<string | undefined> => {
        try {
          const result = await save({
            filters: options?.filters,
            defaultPath: options?.defaultPath,
            title: options?.title,
          })
          return result ?? undefined
        } catch (error) {
          console.error('[WidgetHost] Failed to show save dialog:', error)
          return undefined
        }
      },
      createTerminal: (options?: { name?: string; cwd?: string }): TerminalInstance => {
        // Create a new terminal tab with the given options
        const newTab = createNewTab(options?.name || 'Widget Terminal', options?.cwd)
        const terminalPaneId = newTab.root.id

        return {
          id: terminalPaneId,
          name: options?.name || 'Widget Terminal',
          sendText: (text: string) => {
            writeToTerminalByKey(terminalPaneId, text)
          },
          show: () => {
            console.log(`[WidgetHost] Terminal ${terminalPaneId} is now visible`)
          },
          hide: () => {
            console.log(`[WidgetHost] Terminal ${terminalPaneId} hidden`)
          },
          dispose: () => {
            console.log(`[WidgetHost] Terminal ${terminalPaneId} disposed`)
          },
        }
      },
      sendToActiveTerminal: (text: string) => {
        // Send text to the active terminal pane
        if (activePaneId) {
          writeToTerminalByKey(activePaneId, text)
        } else {
          console.warn('[WidgetHost] No active terminal pane found')
        }
      },
      openWidget: async (widgetType: string, _config?: Record<string, unknown>): Promise<string> => {
        try {
          // Check if widget exists in discovered widgets
          const discoveredWidget = discoveredWidgets.find(w => w.manifest.id === widgetType)
          if (!discoveredWidget) {
            // Also check registered widgets in the registry
            const registeredWidget = widgetRegistry.get(widgetType)
            if (!registeredWidget) {
              throw new Error(`Widget not found: ${widgetType}`)
            }
          }

          // Create a new widget tab with the specified widget type
          const tab = createNewTab(
            discoveredWidget?.manifest.name || widgetType,
            undefined
          )

          console.log(`[WidgetHost] Opened widget: ${widgetType}`)
          return tab.id
        } catch (error) {
          console.error(`[WidgetHost] Failed to open widget ${widgetType}:`, error)
          throw error
        }
      },
      openWebView: async (url: string, title?: string): Promise<string> => {
        try {
          // Validate URL (reuse existing validation from TabsContext)
          const urlObj = new URL(url)
          if (!['http:', 'https:'].includes(urlObj.protocol)) {
            throw new Error(`Invalid URL protocol: ${urlObj.protocol}. Only http and https are allowed.`)
          }

          // Create a new webview tab
          const tab = createWebViewTab(url, title || urlObj.hostname)

          console.log(`[WidgetHost] Opened webview: ${url}`)
          return tab.id
        } catch (error) {
          console.error(`[WidgetHost] Failed to open webview:`, error)
          throw error
        }
      },
      closePane: () => {},
      postMessage: (targetId, _message) => {
        const target = instancesRef.current.get(targetId)
        if (target) {
          // Fire message event on target
          // TODO: Need access to target's messageEmitter
        }
      },
      broadcast: (_channel, _message) => {
        // Broadcast to all widget instances
        // TODO: Fire on matching channel subscriptions
      },
      subscribe: (_channel, _handler) => {
        // TODO: Implement pub/sub system
        return { dispose: () => {} }
      },
    }

    // Store instance
    const instance: WidgetInstance = {
      id: instanceId,
      context,
      api,
      events,
      disposables,
    }
    widget.instances.set(instanceId, instance)
    instancesRef.current.set(instanceId, instance)

    // Activate the widget
    if (widget.module.activate) {
      await widget.module.activate(context, api, events)
    }
    activateEmitter.fire()

    console.log(`[WidgetHost] Created instance: ${instanceId}`)
    return instanceId
  }, [theme, registerTool, unregisterTool, showToast])

  // Destroy a widget instance
  const destroyWidgetInstance = useCallback((instanceId: string) => {
    const instance = instancesRef.current.get(instanceId)
    if (!instance) return

    const errors: Error[] = []

    // Try to dispose instance resources
    try {
      instance.disposables.dispose()
    } catch (e) {
      errors.push(new Error(`Failed to dispose instance ${instanceId}: ${String(e)}`))
    }

    // Always remove from local instances registry, even if dispose failed
    instancesRef.current.delete(instanceId)

    // Remove all commands registered by this instance
    for (const [commandId, cmd] of commandsRef.current) {
      if (cmd.widgetId === instanceId) {
        commandsRef.current.delete(commandId)
        console.log(`[WidgetHost] Cleaned up command: ${commandId}`)
      }
    }

    // Find and update widget registry, collecting errors but continuing cleanup
    widgetRegistry.forEach((widget) => {
      if (widget.instances.has(instanceId)) {
        widget.instances.delete(instanceId)

        // Try to deactivate the widget module
        try {
          if (widget.module.deactivate) {
            widget.module.deactivate()
          }
        } catch (e) {
          errors.push(new Error(`Failed to deactivate widget module: ${String(e)}`))
        }
      }
    })

    // Log all collected errors for debugging
    if (errors.length > 0) {
      console.error(`[WidgetHost] Errors destroying instance ${instanceId}:`, errors)
    }

    console.log(`[WidgetHost] Destroyed instance: ${instanceId}`)
  }, [])

  // Load widgets from configured paths on mount
  useEffect(() => {
    widgetPaths.forEach((path) => {
      loadWidget(path).catch(console.error)
    })
  }, [widgetPaths, loadWidget])

  // Discover and auto-start process-based widgets
  useEffect(() => {
    const discovery = discoveryRef.current
    const processManager = processManagerRef.current

    // Initial discovery
    discovery.discoverWidgets().then((widgets) => {
      setDiscoveredWidgets(widgets)
      console.log(`[WidgetHost] Discovered ${widgets.length} widgets`)
    }).catch(console.error)

    // Subscribe to process events
    const unsubscribe = processManager.on((event: WidgetProcessEvent) => {
      if (event.type === 'started' || event.type === 'stopped' || event.type === 'error') {
        setRunningProcesses(processManager.getAllProcesses())
      }

      if (event.type === 'started') {
        console.log(`[WidgetHost] Widget process started: ${event.widgetId} on port ${event.port}`)
      } else if (event.type === 'error') {
        console.error(`[WidgetHost] Widget process error: ${event.widgetId}`, event.error)
      }
    })

    return () => {
      // Unsubscribe from events
      try {
        unsubscribe()
      } catch (e) {
        console.error('[WidgetHost] Failed to unsubscribe from process events:', e)
      }

      // Stop all widget processes on unmount, collecting errors
      processManager.stopAll().catch((error) => {
        console.error('[WidgetHost] Failed to stop all widget processes on unmount:', error)
      })
    }
  }, [])

  // Process management methods
  const refreshWidgets = useCallback(async () => {
    const widgets = await discoveryRef.current.discoverWidgets(true)
    setDiscoveredWidgets(widgets)
  }, [])

  const startWidgetProcess = useCallback(async (widgetId: string) => {
    const widget = discoveredWidgets.find((w) => w.manifest.id === widgetId)
    if (!widget) {
      throw new Error(`Widget not found: ${widgetId}`)
    }
    if (!widget.isValid) {
      throw new Error(`Widget has validation errors: ${widget.validationErrors.join(', ')}`)
    }

    const process = await processManagerRef.current.startWidget(widget.manifest)
    setRunningProcesses(processManagerRef.current.getAllProcesses())

    // Register tools from the widget
    try {
      const tools = await processManagerRef.current.listTools(widgetId)
      tools.forEach((tool) => {
        registerTool({
          name: `${widgetId}:${tool.name}`,
          description: tool.description,
          widgetId,
          widgetType: 'process',
          inputSchema: {},
          handler: async (args) => {
            return processManagerRef.current.callTool(widgetId, tool.name, args)
          },
        })
      })
      console.log(`[WidgetHost] Registered ${tools.length} tools from ${widgetId}`)
    } catch (err) {
      console.warn(`[WidgetHost] Failed to register tools from ${widgetId}:`, err)
    }

    return process
  }, [discoveredWidgets, registerTool])

  const stopWidgetProcess = useCallback(async (widgetId: string) => {
    await processManagerRef.current.stopWidget(widgetId)
    setRunningProcesses(processManagerRef.current.getAllProcesses())

    // Unregister tools from the widget
    const tools = await processManagerRef.current.listTools(widgetId).catch(() => [])
    tools.forEach((tool) => {
      unregisterTool(`${widgetId}:${tool.name}`, widgetId)
    })
  }, [unregisterTool])

  const value: WidgetHostContextValue = {
    // Traditional inline widgets
    loadWidget,
    unloadWidget,
    getLoadedWidgets,
    createWidgetInstance,
    destroyWidgetInstance,

    // Process-based widgets
    discoveredWidgets,
    runningProcesses,
    startWidgetProcess,
    stopWidgetProcess,
    refreshWidgets,
    callWidgetTool,

    // Command management
    getRegisteredCommands,
  }

  return (
    <>
      <WidgetHostContext.Provider value={value}>
        {children}
      </WidgetHostContext.Provider>
      <QuickPickModal state={quickPickState} onClose={() => setQuickPickState(null)} />
      <InputBoxModal state={inputBoxState} onClose={() => setInputBoxState(null)} />
      {/* Toast notifications container */}
      <div style={{ position: 'fixed', top: 20, right: 20, zIndex: 9999, display: 'flex', flexDirection: 'column', gap: 8 }}>
        {toasts.map(toast => (
          <div
            key={toast.id}
            style={{
              padding: '12px 16px',
              borderRadius: 6,
              backgroundColor: toast.type === 'error' ? '#dc2626' : toast.type === 'warning' ? '#d97706' : '#2563eb',
              color: 'white',
              fontSize: 14,
              boxShadow: '0 4px 12px rgba(0,0,0,0.15)',
              animation: 'fadeIn 0.2s ease-out',
            }}
          >
            {toast.message}
          </div>
        ))}
      </div>
    </>
  )
}

// ============================================
// Widget Renderer Component
// ============================================

interface WidgetRendererProps {
  widgetType: string
  instanceId: string
  config?: Record<string, unknown>
}

export function WidgetRenderer({ widgetType, instanceId }: WidgetRendererProps) {
  const widget = widgetRegistry.get(widgetType)
  const instance = widget?.instances.get(instanceId)

  if (!widget || !instance) {
    return (
      <div style={{ padding: 20, textAlign: 'center', color: '#888' }}>
        Widget not found: {widgetType}
      </div>
    )
  }

  const { Component } = widget.module

  if (!Component) {
    return (
      <div style={{ padding: 20, textAlign: 'center', color: '#888' }}>
        Widget has no UI component
      </div>
    )
  }

  return (
    <WidgetSDKContext.Provider
      value={{
        context: instance.context,
        api: instance.api,
        events: instance.events,
      }}
    >
      <Component
        context={instance.context}
        api={instance.api}
        events={instance.events}
      />
    </WidgetSDKContext.Provider>
  )
}

/**
 * Infinitty Widget Dev Simulator
 *
 * Run widgets standalone for development and testing.
 * Provides mock implementations of all Infinitty host APIs.
 *
 * Usage:
 *   import { createDevSimulator } from '@infinitty/widget-sdk/dev-simulator'
 *   import MyWidget from './index'
 *
 *   createDevSimulator(MyWidget, {
 *     theme: 'dark',
 *     config: { myOption: 'value' },
 *   })
 */

import { useState, useEffect, useCallback, useMemo } from 'react'
import { createRoot } from 'react-dom/client'
import { WidgetSDKContext } from '../hooks'
import type {
  WidgetModule,
  WidgetContext,
  WidgetHostAPI,
  WidgetEvents,
  ThemeColors,
  ToolDefinition,
} from '../types'
import { createEventEmitter } from '../core'

// ============================================
// Theme Presets
// ============================================

const DARK_THEME: ThemeColors = {
  background: '#1a1a2e',
  foreground: '#eaeaea',
  black: '#1a1a2e',
  red: '#ff6b6b',
  green: '#4ecdc4',
  yellow: '#ffe66d',
  blue: '#4dabf7',
  magenta: '#da77f2',
  cyan: '#66d9ef',
  white: '#f8f8f2',
  brightBlack: '#6272a4',
  brightRed: '#ff7979',
  brightGreen: '#7bed9f',
  brightYellow: '#fff59d',
  brightBlue: '#70a1ff',
  brightMagenta: '#ff9ff3',
  brightCyan: '#81ecec',
  brightWhite: '#ffffff',
  cursor: '#f8f8f2',
  cursorAccent: '#1a1a2e',
  selection: '#44475a80',
  selectionBackground: '#44475a80',
}

const LIGHT_THEME: ThemeColors = {
  background: '#ffffff',
  foreground: '#24292e',
  black: '#24292e',
  red: '#d73a49',
  green: '#22863a',
  yellow: '#b08800',
  blue: '#0366d6',
  magenta: '#6f42c1',
  cyan: '#1b7c83',
  white: '#fafbfc',
  brightBlack: '#6a737d',
  brightRed: '#cb2431',
  brightGreen: '#28a745',
  brightYellow: '#dbab09',
  brightBlue: '#2188ff',
  brightMagenta: '#8a63d2',
  brightCyan: '#3192aa',
  brightWhite: '#ffffff',
  cursor: '#24292e',
  cursorAccent: '#ffffff',
  selection: '#0366d633',
  selectionBackground: '#0366d633',
}

// ============================================
// Dev Simulator Options
// ============================================

export interface DevSimulatorOptions {
  /** Widget ID override */
  widgetId?: string
  /** Initial theme */
  theme?: 'dark' | 'light' | ThemeColors
  /** Initial config */
  config?: Record<string, unknown>
  /** Initial size */
  size?: { width: number; height: number }
  /** Container element ID */
  containerId?: string
  /** Enable dev tools panel */
  devTools?: boolean
  /** Mock tool handlers */
  mockTools?: Record<string, (args: Record<string, unknown>) => Promise<unknown>>
}

// ============================================
// Dev Simulator State
// ============================================

interface SimulatorState {
  theme: ThemeColors
  config: Record<string, unknown>
  messages: Array<{ type: string; content: string; timestamp: Date }>
  toolCalls: Array<{ name: string; args: unknown; result?: unknown; timestamp: Date }>
  registeredTools: ToolDefinition[]
  registeredCommands: Array<{ id: string; handler: (...args: unknown[]) => unknown }>
}

// ============================================
// Main Simulator Component
// ============================================

function DevSimulatorShell({
  widget,
  options,
}: {
  widget: WidgetModule
  options: DevSimulatorOptions
}) {
  const [state, setState] = useState<SimulatorState>({
    theme: typeof options.theme === 'object'
      ? options.theme
      : options.theme === 'light'
        ? LIGHT_THEME
        : DARK_THEME,
    config: options.config || {},
    messages: [],
    toolCalls: [],
    registeredTools: [],
    registeredCommands: [],
  })

  const [showDevTools, setShowDevTools] = useState(options.devTools ?? true)
  const [activeTab, setActiveTab] = useState<'messages' | 'tools' | 'config'>('messages')

  // Create event emitters
  const emitters = useMemo(() => ({
    activate: createEventEmitter<void>(),
    deactivate: createEventEmitter<void>(),
    resize: createEventEmitter<{ width: number; height: number }>(),
    visibility: createEventEmitter<boolean>(),
    focus: createEventEmitter<void>(),
    blur: createEventEmitter<void>(),
    message: createEventEmitter<unknown>(),
    configChange: createEventEmitter<Record<string, unknown>>(),
    themeChange: createEventEmitter<ThemeColors>(),
  }), [])

  // Create mock context
  const context = useMemo<WidgetContext>(() => {
    const widgetId = options.widgetId || 'dev-widget'
    const storageKey = `widget-dev:${widgetId}`

    const createStorage = (prefix: string) => {
      const cache = new Map<string, unknown>()
      try {
        const stored = localStorage.getItem(`${storageKey}:${prefix}`)
        if (stored) {
          Object.entries(JSON.parse(stored)).forEach(([k, v]) => cache.set(k, v))
        }
      } catch {}

      return {
        get: <T,>(key: string, defaultValue?: T) =>
          (cache.get(key) as T | undefined) ?? defaultValue,
        set: async (key: string, value: unknown) => {
          cache.set(key, value)
          localStorage.setItem(`${storageKey}:${prefix}`, JSON.stringify(Object.fromEntries(cache)))
        },
        delete: async (key: string) => {
          cache.delete(key)
          localStorage.setItem(`${storageKey}:${prefix}`, JSON.stringify(Object.fromEntries(cache)))
        },
        keys: () => Array.from(cache.keys()),
      }
    }

    return {
      widgetId,
      widgetType: widgetId,
      instanceId: `${widgetId}-dev-instance`,
      config: state.config,
      getConfig: <T,>(key: string, defaultValue?: T) =>
        (state.config[key] as T | undefined) ?? defaultValue,
      theme: state.theme,
      onThemeChange: (callback) => emitters.themeChange.event(callback),
      storage: createStorage('storage'),
      globalState: createStorage('global'),
      secrets: {
        get: async (key) => localStorage.getItem(`${storageKey}:secrets:${key}`) ?? undefined,
        store: async (key, value) => localStorage.setItem(`${storageKey}:secrets:${key}`, value),
        delete: async (key) => localStorage.removeItem(`${storageKey}:secrets:${key}`),
      },
      log: {
        trace: (...args) => console.trace(`[${widgetId}]`, ...args),
        debug: (...args) => console.debug(`[${widgetId}]`, ...args),
        info: (...args) => console.info(`[${widgetId}]`, ...args),
        warn: (...args) => console.warn(`[${widgetId}]`, ...args),
        error: (...args) => console.error(`[${widgetId}]`, ...args),
      },
      extensionPath: '/dev',
      extensionUri: 'file:///dev',
    }
  }, [options.widgetId, state.config, state.theme, emitters])

  // Create mock API
  const api = useMemo<WidgetHostAPI>(() => ({
    showMessage: (message, type = 'info') => {
      setState(s => ({
        ...s,
        messages: [...s.messages, { type, content: message, timestamp: new Date() }],
      }))
      console.log(`[${type.toUpperCase()}]`, message)
    },

    showQuickPick: async (items, options) => {
      const labels = items.map(i => i.label).join('\n')
      const selected = window.prompt(`${options?.title || 'Select'}:\n${labels}`)
      return items.find(i => i.label === selected)
    },

    showInputBox: async (options) => {
      return window.prompt(options?.title || 'Input', options?.value) ?? undefined
    },

    showProgress: async (task, _options) => {
      return task({ report: (v) => console.log('[Progress]', v.message) })
    },

    executeCommand: async (commandId, ...args) => {
      const cmd = state.registeredCommands.find(c => c.id === commandId)
      if (cmd) return cmd.handler(...args)
      console.warn(`Command not found: ${commandId}`)
      return undefined
    },

    registerCommand: (id, handler) => {
      setState(s => ({
        ...s,
        registeredCommands: [...s.registeredCommands, { id, handler }],
      }))
      return { dispose: () => {
        setState(s => ({
          ...s,
          registeredCommands: s.registeredCommands.filter(c => c.id !== id),
        }))
      }}
    },

    registerTool: (tool) => {
      setState(s => ({
        ...s,
        registeredTools: [...s.registeredTools, tool],
      }))
      return { dispose: () => {
        setState(s => ({
          ...s,
          registeredTools: s.registeredTools.filter(t => t.name !== tool.name),
        }))
      }}
    },

    callTool: async (name, args) => {
      const mockHandler = options.mockTools?.[name]
      const toolCall = { name, args, timestamp: new Date() }

      if (mockHandler) {
        const result = await mockHandler(args)
        setState(s => ({
          ...s,
          toolCalls: [...s.toolCalls, { ...toolCall, result }],
        }))
        return result
      }

      const tool = state.registeredTools.find(t => t.name === name)
      if (tool) {
        const result = await tool.handler(args)
        setState(s => ({
          ...s,
          toolCalls: [...s.toolCalls, { ...toolCall, result }],
        }))
        return result
      }

      setState(s => ({
        ...s,
        toolCalls: [...s.toolCalls, { ...toolCall, result: { error: 'Tool not found' } }],
      }))
      throw new Error(`Tool not found: ${name}`)
    },

    readClipboard: () => navigator.clipboard.readText(),
    writeClipboard: (text) => navigator.clipboard.writeText(text),

    readFile: async () => new Uint8Array(),
    writeFile: async () => {},
    showOpenDialog: async () => undefined,
    showSaveDialog: async () => undefined,

    createTerminal: () => ({
      id: 'dev-terminal',
      name: 'Dev Terminal',
      sendText: (text) => console.log('[Terminal]', text),
      show: () => {},
      hide: () => {},
      dispose: () => {},
    }),

    sendToActiveTerminal: (text) => console.log('[Terminal]', text),

    openWidget: async (widgetType) => {
      console.log('[OpenWidget]', widgetType)
      return `widget-${Date.now()}`
    },

    openWebView: async (url) => {
      window.open(url, '_blank')
      return `webview-${Date.now()}`
    },

    closePane: () => {},

    postMessage: (targetId, message) => {
      console.log(`[PostMessage -> ${targetId}]`, message)
    },

    broadcast: (channel, message) => {
      console.log(`[Broadcast:${channel}]`, message)
    },

    subscribe: (channel, _handler) => {
      console.log(`[Subscribe:${channel}]`)
      return { dispose: () => {} }
    },
  }), [options.mockTools, state.registeredCommands, state.registeredTools])

  // Create events
  const events = useMemo<WidgetEvents>(() => ({
    onDidActivate: emitters.activate.event,
    onWillDeactivate: emitters.deactivate.event,
    onDidResize: emitters.resize.event,
    onDidChangeVisibility: emitters.visibility.event,
    onDidFocus: emitters.focus.event,
    onDidBlur: emitters.blur.event,
    onDidReceiveMessage: emitters.message.event,
    onDidChangeConfig: emitters.configChange.event,
  }), [emitters])

  // Activate widget on mount
  useEffect(() => {
    widget.activate?.(context, api, events)
    emitters.activate.fire()

    return () => {
      emitters.deactivate.fire()
      widget.deactivate?.()
    }
  }, [])

  // SDK context value
  const sdkContext = useMemo(() => ({ context, api, events }), [context, api, events])

  // Theme toggle
  const toggleTheme = useCallback(() => {
    const newTheme = state.theme.background === DARK_THEME.background ? LIGHT_THEME : DARK_THEME
    setState(s => ({ ...s, theme: newTheme }))
    emitters.themeChange.fire(newTheme)
  }, [state.theme, emitters])

  // Update config
  const updateConfig = useCallback((key: string, value: unknown) => {
    setState(s => {
      const newConfig = { ...s.config, [key]: value }
      emitters.configChange.fire(newConfig)
      return { ...s, config: newConfig }
    })
  }, [emitters])

  // Send test message
  const sendTestMessage = useCallback((message: unknown) => {
    emitters.message.fire(message)
  }, [emitters])

  const WidgetComponent = widget.Component

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        height: '100vh',
        backgroundColor: state.theme.background,
        color: state.theme.foreground,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
      }}
    >
      {/* Toolbar */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          padding: '8px 16px',
          borderBottom: `1px solid ${state.theme.brightBlack}40`,
          fontSize: '13px',
        }}
      >
        <span style={{ fontWeight: 600 }}>🧪 Infinitty Dev Simulator</span>
        <span style={{ color: state.theme.brightBlack }}>|</span>
        <span>{options.widgetId || 'dev-widget'}</span>
        <div style={{ flex: 1 }} />
        <button
          onClick={toggleTheme}
          style={{
            padding: '4px 12px',
            backgroundColor: `${state.theme.brightBlack}30`,
            border: 'none',
            borderRadius: '4px',
            color: state.theme.foreground,
            cursor: 'pointer',
            fontSize: '12px',
          }}
        >
          {state.theme.background === DARK_THEME.background ? '☀️ Light' : '🌙 Dark'}
        </button>
        <button
          onClick={() => setShowDevTools(!showDevTools)}
          style={{
            padding: '4px 12px',
            backgroundColor: showDevTools ? state.theme.cyan : `${state.theme.brightBlack}30`,
            border: 'none',
            borderRadius: '4px',
            color: showDevTools ? state.theme.background : state.theme.foreground,
            cursor: 'pointer',
            fontSize: '12px',
          }}
        >
          🔧 DevTools
        </button>
      </div>

      {/* Main content */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        {/* Widget area */}
        <div style={{ flex: 1, overflow: 'auto' }}>
          <WidgetSDKContext.Provider value={sdkContext}>
            {WidgetComponent ? (
              <WidgetComponent api={api} context={context} events={events} />
            ) : (
              <div style={{ padding: '20px', color: state.theme.brightBlack }}>
                No Component exported from widget
              </div>
            )}
          </WidgetSDKContext.Provider>
        </div>

        {/* Dev tools panel */}
        {showDevTools && (
          <div
            style={{
              width: '320px',
              borderLeft: `1px solid ${state.theme.brightBlack}40`,
              display: 'flex',
              flexDirection: 'column',
              backgroundColor: `${state.theme.background}`,
            }}
          >
            {/* Tabs */}
            <div
              style={{
                display: 'flex',
                borderBottom: `1px solid ${state.theme.brightBlack}40`,
              }}
            >
              {(['messages', 'tools', 'config'] as const).map((tab) => (
                <button
                  key={tab}
                  onClick={() => setActiveTab(tab)}
                  style={{
                    flex: 1,
                    padding: '8px',
                    backgroundColor: activeTab === tab ? `${state.theme.cyan}20` : 'transparent',
                    border: 'none',
                    borderBottom: activeTab === tab ? `2px solid ${state.theme.cyan}` : '2px solid transparent',
                    color: activeTab === tab ? state.theme.cyan : state.theme.brightBlack,
                    cursor: 'pointer',
                    fontSize: '12px',
                    textTransform: 'capitalize',
                  }}
                >
                  {tab}
                </button>
              ))}
            </div>

            {/* Tab content */}
            <div style={{ flex: 1, overflow: 'auto', padding: '12px' }}>
              {activeTab === 'messages' && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                  {state.messages.length === 0 ? (
                    <div style={{ color: state.theme.brightBlack, fontSize: '12px' }}>
                      No messages yet
                    </div>
                  ) : (
                    state.messages.map((msg, i) => (
                      <div
                        key={i}
                        style={{
                          padding: '8px',
                          backgroundColor: `${state.theme.brightBlack}20`,
                          borderRadius: '4px',
                          fontSize: '12px',
                          borderLeft: `3px solid ${
                            msg.type === 'error' ? state.theme.red :
                            msg.type === 'warning' ? state.theme.yellow :
                            state.theme.blue
                          }`,
                        }}
                      >
                        <div style={{ fontWeight: 500 }}>{msg.type.toUpperCase()}</div>
                        <div>{msg.content}</div>
                        <div style={{ color: state.theme.brightBlack, fontSize: '10px', marginTop: '4px' }}>
                          {msg.timestamp.toLocaleTimeString()}
                        </div>
                      </div>
                    ))
                  )}
                </div>
              )}

              {activeTab === 'tools' && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
                  <div>
                    <div style={{ fontSize: '11px', fontWeight: 600, marginBottom: '8px', color: state.theme.brightBlack }}>
                      REGISTERED TOOLS ({state.registeredTools.length})
                    </div>
                    {state.registeredTools.map((tool, i) => (
                      <div
                        key={i}
                        style={{
                          padding: '8px',
                          backgroundColor: `${state.theme.brightBlack}20`,
                          borderRadius: '4px',
                          marginBottom: '4px',
                          fontSize: '12px',
                        }}
                      >
                        <div style={{ fontWeight: 500, color: state.theme.green }}>{tool.name}</div>
                        <div style={{ color: state.theme.brightBlack }}>{tool.description}</div>
                      </div>
                    ))}
                  </div>

                  <div>
                    <div style={{ fontSize: '11px', fontWeight: 600, marginBottom: '8px', color: state.theme.brightBlack }}>
                      TOOL CALLS ({state.toolCalls.length})
                    </div>
                    {state.toolCalls.map((call, i) => (
                      <div
                        key={i}
                        style={{
                          padding: '8px',
                          backgroundColor: `${state.theme.brightBlack}20`,
                          borderRadius: '4px',
                          marginBottom: '4px',
                          fontSize: '11px',
                          fontFamily: 'monospace',
                        }}
                      >
                        <div style={{ color: state.theme.magenta }}>{call.name}</div>
                        <div style={{ color: state.theme.brightBlack }}>
                          Args: {JSON.stringify(call.args)}
                        </div>
                        {call.result !== undefined && (
                          <div style={{ color: state.theme.green }}>
                            Result: {JSON.stringify(call.result)}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {activeTab === 'config' && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
                  <div style={{ fontSize: '11px', fontWeight: 600, color: state.theme.brightBlack }}>
                    CONFIGURATION
                  </div>
                  {Object.entries(state.config).map(([key, value]) => (
                    <div key={key}>
                      <label style={{ fontSize: '12px', display: 'block', marginBottom: '4px' }}>
                        {key}
                      </label>
                      <input
                        type="text"
                        value={String(value)}
                        onChange={(e) => updateConfig(key, e.target.value)}
                        style={{
                          width: '100%',
                          padding: '6px 8px',
                          backgroundColor: `${state.theme.brightBlack}20`,
                          border: `1px solid ${state.theme.brightBlack}40`,
                          borderRadius: '4px',
                          color: state.theme.foreground,
                          fontSize: '12px',
                        }}
                      />
                    </div>
                  ))}

                  <div style={{ marginTop: '16px' }}>
                    <div style={{ fontSize: '11px', fontWeight: 600, color: state.theme.brightBlack, marginBottom: '8px' }}>
                      SEND TEST MESSAGE
                    </div>
                    <textarea
                      placeholder='{"action": "test", "data": {}}'
                      style={{
                        width: '100%',
                        height: '60px',
                        padding: '8px',
                        backgroundColor: `${state.theme.brightBlack}20`,
                        border: `1px solid ${state.theme.brightBlack}40`,
                        borderRadius: '4px',
                        color: state.theme.foreground,
                        fontSize: '11px',
                        fontFamily: 'monospace',
                        resize: 'none',
                      }}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' && e.metaKey) {
                          try {
                            sendTestMessage(JSON.parse(e.currentTarget.value))
                            e.currentTarget.value = ''
                          } catch {}
                        }
                      }}
                    />
                    <div style={{ fontSize: '10px', color: state.theme.brightBlack, marginTop: '4px' }}>
                      Cmd+Enter to send
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ============================================
// Public API
// ============================================

/**
 * Create and mount the dev simulator
 */
export function createDevSimulator(
  widget: WidgetModule,
  options: DevSimulatorOptions = {}
): void {
  const containerId = options.containerId || 'root'
  let container = document.getElementById(containerId)

  if (!container) {
    container = document.createElement('div')
    container.id = containerId
    document.body.appendChild(container)
  }

  // Reset body styles for full-screen
  document.body.style.margin = '0'
  document.body.style.padding = '0'
  document.body.style.overflow = 'hidden'

  const root = createRoot(container)
  root.render(<DevSimulatorShell widget={widget} options={options} />)
}

/**
 * Check if running in dev simulator vs real Infinitty
 */
export function isDevMode(): boolean {
  return typeof window !== 'undefined' && !!(window as unknown as { __INFINITTY_DEV__?: boolean }).__INFINITTY_DEV__
}

// Set dev mode flag
if (typeof window !== 'undefined') {
  (window as unknown as { __INFINITTY_DEV__?: boolean }).__INFINITTY_DEV__ = true
}

export { DARK_THEME, LIGHT_THEME }

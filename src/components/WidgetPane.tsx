import { useCallback, useMemo } from 'react'
import { X } from 'lucide-react'
import { useTabs } from '../contexts/TabsContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import type { WidgetPane as WidgetPaneType } from '../types/tabs'
import { WidgetSDKContext } from '../widget-sdk/hooks'
import type { WidgetContext, WidgetHostAPI, WidgetEvents, ThemeColors } from '../widget-sdk/types'
import { createEventEmitter } from '../widget-sdk/core'

// Import widgets
import { NodesWidget } from './widgets/NodesWidget'
import ChartWidgetModule from '../widgets-external/chart.infinitty/index'
import { WorkflowComponent } from '../widgets-external/workflow.infinitty/src/Component'

// Extract the Component from the widget modules
const ChartWidgetComponent = ChartWidgetModule.Component

// Widgets that need SDK context wrapper
const SDK_WIDGETS = new Set(['chart', 'workflow'])

// Widget registry - add new widgets here
const WIDGET_REGISTRY: Record<string, React.ComponentType<{ config?: Record<string, unknown> }>> = {
  nodes: NodesWidget,
  chart: ChartWidgetComponent as React.ComponentType<{ config?: Record<string, unknown> }>,
  workflow: WorkflowComponent as React.ComponentType<{ config?: Record<string, unknown> }>,
}

interface WidgetPaneProps {
  pane: WidgetPaneType
}

export function WidgetPane({ pane }: WidgetPaneProps) {
  const { activePaneId, setActivePane, closePane } = useTabs()
  const { settings } = useTerminalSettings()

  const isActive = pane.id === activePaneId

  const handleFocus = useCallback(() => {
    setActivePane(pane.id)
  }, [pane.id, setActivePane])

  // Get the widget component from registry
  const WidgetComponent = WIDGET_REGISTRY[pane.widgetType]

  if (!WidgetComponent) {
    return (
      <div
        onClick={handleFocus}
        style={{
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: settings.theme.background,
          color: settings.theme.foreground,
          opacity: isActive ? 1 : 0.6,
          transition: 'opacity 0.15s ease',
        }}
      >
        <div style={{ fontSize: '16px', fontWeight: 600, marginBottom: '8px' }}>
          Unknown Widget
        </div>
        <div style={{ fontSize: '13px', color: settings.theme.brightBlack }}>
          Widget type "{pane.widgetType}" is not registered
        </div>
      </div>
    )
  }

  return (
    <div
      onClick={handleFocus}
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        backgroundColor: settings.theme.background,
        opacity: isActive ? 1 : 0.6,
        transition: 'opacity 0.15s ease',
        position: 'relative',
      }}
    >
      {/* Widget Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '6px 12px',
          backgroundColor: `${settings.theme.brightBlack}15`,
          borderBottom: `1px solid ${settings.theme.brightBlack}40`,
        }}
      >
        <span
          style={{
            color: settings.theme.foreground,
            fontSize: '12px',
            fontWeight: 500,
          }}
        >
          {pane.title}
        </span>
        <button
          onClick={(e) => {
            e.stopPropagation()
            closePane(pane.id)
          }}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: settings.theme.brightBlack,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.color = settings.theme.red
            e.currentTarget.style.backgroundColor = `${settings.theme.red}20`
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.color = settings.theme.brightBlack
            e.currentTarget.style.backgroundColor = 'transparent'
          }}
        >
          <X size={14} />
        </button>
      </div>

      {/* Widget Content */}
      <div style={{ flex: 1, overflow: 'hidden' }}>
        {SDK_WIDGETS.has(pane.widgetType) ? (
          <SDKWidgetWrapper
            widgetType={pane.widgetType}
            config={pane.config}
            theme={{ ...settings.theme, selection: settings.theme.selectionBackground }}
          >
            <WidgetComponent config={pane.config} />
          </SDKWidgetWrapper>
        ) : (
          <WidgetComponent config={pane.config} />
        )}
      </div>
    </div>
  )
}

// Wrapper component that provides SDK context for widgets that need it
function SDKWidgetWrapper({
  widgetType,
  config,
  theme,
  children,
}: {
  widgetType: string
  config?: Record<string, unknown>
  theme: ThemeColors
  children: React.ReactNode
}) {
  // Create mock SDK context values
  const sdkContext = useMemo(() => {
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

    // Create storage implementations
    const createStorage = (prefix: string) => {
      const storageKey = `widget:${widgetType}:${prefix}`
      const cache = new Map<string, unknown>()

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

    const context: WidgetContext = {
      widgetId: widgetType,
      widgetType,
      instanceId: `${widgetType}-inline`,
      config: config || {},
      getConfig: <T,>(key: string, defaultValue?: T) =>
        ((config || {})[key] as T | undefined) ?? defaultValue,
      theme,
      onThemeChange: (callback) => themeChangeEmitter.event(callback),
      storage: createStorage('storage'),
      globalState: createStorage('global'),
      secrets: {
        get: async () => undefined,
        store: async () => {},
        delete: async () => {},
      },
      log: {
        trace: (...args) => console.trace(`[${widgetType}]`, ...args),
        debug: (...args) => console.debug(`[${widgetType}]`, ...args),
        info: (...args) => console.info(`[${widgetType}]`, ...args),
        warn: (...args) => console.warn(`[${widgetType}]`, ...args),
        error: (...args) => console.error(`[${widgetType}]`, ...args),
      },
      extensionPath: '',
      extensionUri: '',
    }

    const api: WidgetHostAPI = {
      showMessage: (message, type = 'info') => {
        console.log(`[${widgetType}] ${type}: ${message}`)
      },
      showQuickPick: async () => undefined,
      showInputBox: async () => undefined,
      showProgress: async (task) => task({ report: () => {} }),
      executeCommand: async () => undefined,
      registerCommand: () => ({ dispose: () => {} }),
      registerTool: () => ({ dispose: () => {} }),
      callTool: async () => null,
      readClipboard: async () => navigator.clipboard.readText(),
      writeClipboard: async (text) => navigator.clipboard.writeText(text),
      readFile: async () => new Uint8Array(),
      writeFile: async () => {},
      showOpenDialog: async () => undefined,
      showSaveDialog: async () => undefined,
      createTerminal: () => ({
        id: '',
        name: 'Terminal',
        sendText: () => {},
        show: () => {},
        hide: () => {},
        dispose: () => {},
      }),
      sendToActiveTerminal: () => {},
      openWidget: async () => '',
      openWebView: async () => '',
      closePane: () => {},
      postMessage: () => {},
      broadcast: () => {},
      subscribe: () => ({ dispose: () => {} }),
    }

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

    return { context, api, events }
  }, [widgetType, config, theme])

  return (
    <WidgetSDKContext.Provider value={sdkContext}>
      {children}
    </WidgetSDKContext.Provider>
  )
}

# Detailed Refactoring Examples

## Example 1: MCPContext Toggle Duplication → Extraction

### Current Code (36 lines of duplication)

**File:** `/src/contexts/MCPContext.tsx`, lines 305-341

```typescript
// HIDE/SHOW SERVERS PATTERN (18 lines)
const toggleHideServer = useCallback(async (serverId: string) => {
  const isHidden = hiddenServerIds.includes(serverId)
  setHiddenServerIds((prev) =>
    isHidden ? prev.filter((id) => id !== serverId) : [...prev, serverId]
  )

  // Persist to settings
  if (settingsRef.current) {
    settingsRef.current = await toggleServerHidden(settingsRef.current, serverId)
  }
}, [hiddenServerIds])

const isServerHidden = useCallback((serverId: string): boolean => {
  return hiddenServerIds.includes(serverId)
}, [hiddenServerIds])

const getVisibleServers = useCallback((): MCPServerConfig[] => {
  return servers.filter((s) => !hiddenServerIds.includes(s.id))
}, [servers, hiddenServerIds])

// AUTO-CONNECT PATTERN (18 lines) - IDENTICAL STRUCTURE
const toggleAutoConnect = useCallback(async (serverId: string) => {
  const isAutoConnectEnabled = autoConnectServerIds.includes(serverId)
  setAutoConnectServerIds((prev) =>
    isAutoConnectEnabled ? prev.filter((id) => id !== serverId) : [...prev, serverId]
  )

  // Persist to settings
  if (settingsRef.current) {
    settingsRef.current = await toggleServerAutoConnect(settingsRef.current, serverId)
  }
}, [autoConnectServerIds])

const isAutoConnect = useCallback((serverId: string): boolean => {
  return autoConnectServerIds.includes(serverId)
}, [autoConnectServerIds])
```

### Problems
1. **Duplication**: Pattern repeats identically for two different sets
2. **Hard to change**: If you fix a bug in one, must remember to fix the other
3. **Boilerplate**: 18 lines per toggle set, only 2 lines are unique
4. **Testing**: Need to test same logic twice

### Refactored Solution

**Step 1: Create reusable hook**

Create `/src/hooks/useToggleSet.ts`:
```typescript
import { useState, useCallback } from 'react'

/**
 * Manages a set of IDs with toggle, has, and clear operations.
 * Optionally persists changes via callback.
 */
export function useToggleSet(
  initialIds: string[] = [],
  onChangeAsync?: (newSet: string[]) => Promise<void>
) {
  const [ids, setIds] = useState(initialIds)

  const toggle = useCallback(async (id: string) => {
    setIds((prev) => {
      const newSet = prev.includes(id)
        ? prev.filter(x => x !== id)
        : [...prev, id]

      // Persist if callback provided
      onChangeAsync?.(newSet).catch((err) => {
        console.error('Failed to persist toggle set:', err)
      })

      return newSet
    })
  }, [onChangeAsync])

  const has = useCallback((id: string) => ids.includes(id), [ids])
  const clear = useCallback(() => setIds([]), [])

  return { ids, toggle, has, clear }
}
```

**Step 2: Update MCPContext to use the hook**

```typescript
// BEFORE (inside MCPProvider):
const [hiddenServerIds, setHiddenServerIds] = useState<string[]>([])
const [autoConnectServerIds, setAutoConnectServerIds] = useState<string[]>([])

// ... 36 lines of callbacks ...

// AFTER:
const hidden = useToggleSet(
  settings.hiddenServerIds,
  (newSet) => toggleServerHidden(settingsRef.current, newSet)
)

const autoConnect = useToggleSet(
  settings.autoConnectServerIds,
  (newSet) => toggleServerAutoConnect(settingsRef.current, newSet)
)
```

**Step 3: Update context value**

```typescript
// OLD interface (40+ callbacks)
interface MCPContextValue extends MCPState {
  hiddenServerIds: string[]
  toggleHideServer: (serverId: string) => void
  isServerHidden: (serverId: string) => boolean
  getVisibleServers: () => MCPServerConfig[]
  autoConnectServerIds: string[]
  toggleAutoConnect: (serverId: string) => void
  isAutoConnect: (serverId: string) => boolean
  // ... 30+ more ...
}

// NEW interface (simplified)
interface MCPContextValue extends MCPState {
  hidden: ReturnType<typeof useToggleSet>
  autoConnect: ReturnType<typeof useToggleSet>
  // ... other essential methods ...
}
```

**Step 4: Update consumers**

```typescript
// OLD usage in components:
const { hiddenServerIds, toggleHideServer, isServerHidden } = useMCP()

if (isServerHidden(serverId)) {
  // hide it
}

// NEW usage:
const { hidden } = useMCP()

if (hidden.has(serverId)) {
  // hide it
}

// Or with destructuring:
const { toggle, has } = hidden
if (has(serverId)) toggle(serverId)
```

### Result
- **Lines removed**: 36 lines of duplication
- **Lines added**: 25-line reusable hook
- **Net savings**: 11 lines
- **Benefit**: Reusable pattern for ANY toggle set
- **Testing**: Test hook once, use everywhere

---

## Example 2: Delete Inline Widget System (250 lines)

### Current Code Structure

```
WidgetHost.tsx (530 lines total)
├── Lines 40-41: Global widgetRegistry
├── Lines 49-52: Inline widget interface methods
├── Lines 101-127: loadWidget() function
├── Lines 130-144: unloadWidget() function
├── Lines 147-149: getLoadedWidgets() function
├── Lines 152-342: createWidgetInstance() function (190 lines!)
├── Lines 345-363: destroyWidgetInstance() function
├── Lines 366-370: Load widgets on mount useEffect
├── Lines 487-530: WidgetRenderer component
└── Lines 372-457: Process-based widgets (WORKING)
```

### Problem: Which System Is Actually Used?

**Search for callers:**
```bash
grep -r "loadWidget\|createWidgetInstance\|WidgetRenderer" src/
```

**Result:** No hits. These are never called.

**Search for process-based usage:**
```bash
grep -r "startWidgetProcess\|stopWidgetProcess\|discoveredWidgets" src/
```

**Result:** Multiple hits. This system is used.

### Refactored (Delete Everything But Process-Based)

**BEFORE:**
```typescript
// ============================================
// Widget Registry (UNUSED SYSTEM)
// ============================================
interface LoadedWidget {
  manifest: WidgetManifest
  module: WidgetModule
  instances: Map<string, WidgetInstance>
}

interface WidgetInstance { /* 50 lines */ }

const widgetRegistry = new Map<string, LoadedWidget>()

// ============================================
// Widget Host Provider
// ============================================
export function WidgetHostProvider({ children, widgetPaths = [] }: WidgetHostProviderProps) {
  // Inline widget state
  const [discoveredWidgets, setDiscoveredWidgets] = useState<DiscoveredWidget[]>([])
  const [runningProcesses, setRunningProcesses] = useState<WidgetProcess[]>([])

  // Load a widget from a manifest file (UNUSED)
  const loadWidget = useCallback(async (manifestPath: string) => {
    try {
      const response = await fetch(manifestPath)
      const manifest: WidgetManifest = await response.json()
      const moduleUrl = new URL(manifest.main, manifestPath).href
      const module = await import(/* @vite-ignore */ moduleUrl) as WidgetModule

      widgetRegistry.set(manifest.id, {
        manifest,
        module,
        instances: new Map(),
      })

      console.log(`[WidgetHost] Loaded widget: ${manifest.name}`)
    } catch (error) {
      console.error(`[WidgetHost] Failed to load widget from ${manifestPath}:`, error)
      throw error
    }
  }, [])

  // Unload a widget (UNUSED)
  const unloadWidget = useCallback((widgetId: string) => {
    const widget = widgetRegistry.get(widgetId)
    if (!widget) return

    widget.instances.forEach((instance) => {
      instance.disposables.dispose()
      if (widget.module.deactivate) {
        widget.module.deactivate()
      }
    })

    widgetRegistry.delete(widgetId)
    console.log(`[WidgetHost] Unloaded widget: ${widgetId}`)
  }, [])

  // ... 200+ more lines of UNUSED inline widget code ...

  // Load widgets from configured paths on mount (POINTLESS - never called)
  useEffect(() => {
    widgetPaths.forEach((path) => {
      loadWidget(path).catch(console.error)
    })
  }, [widgetPaths, loadWidget])

  return (
    <WidgetHostContext.Provider
      value={{
        // Inline widgets (UNUSED)
        loadWidget,
        unloadWidget,
        getLoadedWidgets,
        createWidgetInstance,
        destroyWidgetInstance,

        // Process widgets (USED)
        discoveredWidgets,
        runningProcesses,
        startWidgetProcess,
        stopWidgetProcess,
        refreshWidgets,
        callWidgetTool,
      }}
    >
      {children}
    </WidgetHostContext.Provider>
  )
}
```

**AFTER - Delete all inline widget code:**

```typescript
// ============================================
// Widget Host - Process-Based Only
// ============================================

interface WidgetHostContextValue {
  // Process-based widget management (only what's actually used)
  discoveredWidgets: DiscoveredWidget[]
  runningProcesses: WidgetProcess[]
  startWidgetProcess: (widgetId: string) => Promise<void>
  stopWidgetProcess: (widgetId: string) => Promise<void>
  refreshWidgets: () => Promise<void>
  callWidgetTool: (widgetId: string, toolName: string, args: Record<string, unknown>) => Promise<unknown>
}

export function WidgetHostProvider({ children }: { children: React.ReactNode }) {
  const { registerTool, unregisterTool } = useWidgetTools()
  const [discoveredWidgets, setDiscoveredWidgets] = useState<DiscoveredWidget[]>([])
  const [runningProcesses, setRunningProcesses] = useState<WidgetProcess[]>([])
  const processManagerRef = useRef(getWidgetProcessManager())
  const discoveryRef = useRef(getWidgetDiscovery())

  // Discover and auto-start process-based widgets
  useEffect(() => {
    const discovery = discoveryRef.current
    const processManager = processManagerRef.current

    discovery.discoverWidgets().then((widgets) => {
      setDiscoveredWidgets(widgets)
      console.log(`[WidgetHost] Discovered ${widgets.length} widgets`)
    }).catch(console.error)

    const unsubscribe = processManager.on((event: WidgetProcessEvent) => {
      if (event.type === 'started' || event.type === 'stopped' || event.type === 'error') {
        setRunningProcesses(processManager.getAllProcesses())
      }
    })

    return () => {
      unsubscribe()
      processManager.stopAll().catch(console.error)
    }
  }, [])

  // Process management methods
  const refreshWidgets = useCallback(async () => {
    const widgets = await discoveryRef.current.discoverWidgets(true)
    setDiscoveredWidgets(widgets)
  }, [])

  const startWidgetProcess = useCallback(async (widgetId: string) => {
    const widget = discoveredWidgets.find((w) => w.manifest.id === widgetId)
    if (!widget || !widget.isValid) {
      throw new Error(`Widget not found or invalid: ${widgetId}`)
    }

    const process = await processManagerRef.current.startWidget(widget.manifest)
    setRunningProcesses(processManagerRef.current.getAllProcesses())

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
    } catch (err) {
      console.warn(`[WidgetHost] Failed to register tools from ${widgetId}:`, err)
    }

    return process
  }, [discoveredWidgets, registerTool])

  const stopWidgetProcess = useCallback(async (widgetId: string) => {
    await processManagerRef.current.stopWidget(widgetId)
    setRunningProcesses(processManagerRef.current.getAllProcesses())

    const tools = await processManagerRef.current.listTools(widgetId).catch(() => [])
    tools.forEach((tool) => {
      unregisterTool(`${widgetId}:${tool.name}`, widgetId)
    })
  }, [unregisterTool])

  const callWidgetTool = useCallback(async (widgetId: string, toolName: string, args: Record<string, unknown>) => {
    return processManagerRef.current.callTool(widgetId, toolName, args)
  }, [])

  return (
    <WidgetHostContext.Provider
      value={{
        discoveredWidgets,
        runningProcesses,
        startWidgetProcess,
        stopWidgetProcess,
        refreshWidgets,
        callWidgetTool,
      }}
    >
      {children}
    </WidgetHostContext.Provider>
  )
}
```

### What Was Deleted
- Lines 26-38: `LoadedWidget`, `WidgetInstance` interfaces
- Lines 40-41: `widgetRegistry` global
- Lines 49-52: `loadWidget`, `unloadWidget`, `getLoadedWidgets`, `createWidgetInstance`, `destroyWidgetInstance` from interface
- Lines 101-127: `loadWidget()` implementation
- Lines 130-144: `unloadWidget()` implementation
- Lines 147-149: `getLoadedWidgets()` implementation
- Lines 152-342: `createWidgetInstance()` implementation (190 lines)
- Lines 345-363: `destroyWidgetInstance()` implementation
- Lines 366-370: Load widgets on mount useEffect
- Lines 487-530: `WidgetRenderer` component

### Result
- **Lines removed**: 250+
- **Functions removed**: 5 (none used)
- **Interfaces removed**: 2 (LoadedWidget, WidgetInstance)
- **Globals removed**: 1 (widgetRegistry)
- **Components removed**: 1 (WidgetRenderer)
- **Risk level**: ZERO (code path never executed)
- **Testing**: Just verify process widgets still work

---

## Example 3: Remove Stub API Functions

### Current Code

File: `/src/widget-host/WidgetHost.tsx`, lines 262-321 in `createWidgetInstance()`

```typescript
// Create host API
const api: WidgetHostAPI = {
  showMessage: (message, type = 'info') => {
    console.log(`[Widget Message] ${type}: ${message}`)
    // TODO: Show toast notification
  },
  showQuickPick: async () => undefined, // TODO: Implement
  showInputBox: async () => undefined, // TODO: Implement
  showProgress: async (task) => task({ report: () => {} }),
  executeCommand: async () => undefined, // TODO: Implement
  registerCommand: (_id, _handler) => {
    // TODO: Register with command palette
    return { dispose: () => {} }
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
  showOpenDialog: async () => undefined, // TODO: Implement
  showSaveDialog: async () => undefined, // TODO: Implement
  createTerminal: () => ({
    id: '',
    name: 'Terminal',
    sendText: () => {},
    show: () => {},
    hide: () => {},
    dispose: () => {},
  }),
  sendToActiveTerminal: () => {},
  openWidget: async () => '', // TODO: Implement
  openWebView: async () => '', // TODO: Implement
  closePane: () => {},
  postMessage: (targetId, _message) => {
    const target = instancesRef.current.get(targetId)
    if (target) {
      // TODO: Need access to target's messageEmitter
    }
  },
  broadcast: (_channel, _message) => {
    // TODO: Fire on matching channel subscriptions
  },
  subscribe: (_channel, _handler) => {
    // TODO: Implement pub/sub system
    return { dispose: () => {} }
  },
}
```

### Problem
- **17 unimplemented functions**
- **False contract**: Widget code may call these thinking they work
- **Silent failures**: Returns undefined instead of error
- **Unclear intent**: Is this a todo list or working API?

### Refactored Solution

```typescript
// Only include functions that actually work
const workingApi = {
  // These actually work
  readClipboard: async () => navigator.clipboard.readText(),
  writeClipboard: async (text) => navigator.clipboard.writeText(text),
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
}

// For unimplemented functions, fail explicitly
const notImplementedApi = {
  showMessage: () => {
    throw new Error('showMessage() not implemented')
  },
  showQuickPick: async () => {
    throw new Error('showQuickPick() not implemented')
  },
  showInputBox: async () => {
    throw new Error('showInputBox() not implemented')
  },
  executeCommand: async () => {
    throw new Error('executeCommand() not implemented')
  },
  // ... etc for each unimplemented function
}

const api: WidgetHostAPI = {
  ...workingApi,
  ...notImplementedApi,
}
```

### Result
- **Lines removed**: 40 lines of silent stubs
- **Behavior improved**: Explicit errors instead of undefined
- **Contract clearer**: Documentation of what's implemented
- **Debugging easier**: Stack traces point to unimplemented features
- **Migration path**: Clear todo list for future work

---

## Summary of Refactoring Patterns

| Pattern | Problem | Solution | LOC Saved |
|---------|---------|----------|-----------|
| Duplication | Same code 2-3x | Extract to reusable hook/function | 20-50 |
| Dead code | Never called | Delete completely | 50-250 |
| Stubs | Silent failure | Throw explicit errors | 20-40 |
| Incomplete feature | Masked intent | Delete or complete | 10-50 |
| Over-engineering | Complexity | Simplify design | 30-100 |

All refactorings above follow YAGNI principle:
- **Y**ou **A**ren't **G**onna **N**eed **I**t
- Remove code not currently used
- Implement features when actually needed
- Keep API honest about capabilities

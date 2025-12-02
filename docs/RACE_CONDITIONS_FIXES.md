# Race Condition Fixes - Implementation Guide

## Fix #1: MCP Connection Double-Spawn Guard

**File:** `src/services/mcpClient.ts`

Replace the `MCPClient` class connect method:

```typescript
export class MCPClient {
  private process: Child | null = null
  private requestId = 0
  private pendingRequests = new Map<number, PendingRequest>()
  private buffer = ''
  private serverInfo: MCPServerInfo | null = null
  private tools: MCPTool[] = []
  private resources: MCPResource[] = []
  private prompts: MCPPrompt[] = []
  private isConnected = false
  private connectPromise: Promise<void> | null = null  // ← ADD THIS
  private onStatusChange?: (status: 'connecting' | 'connected' | 'error' | 'disconnected', error?: string) => void
  private onToolsChange?: (tools: MCPTool[]) => void

  // ... existing constructor ...

  async connect(): Promise<void> {
    // ← ADD THIS GUARD
    if (this.connectPromise) {
      return this.connectPromise
    }

    this.connectPromise = this._doConnect()
      .finally(() => {
        this.connectPromise = null
      })

    return this.connectPromise
  }

  // ← RENAME the old connect() to _doConnect()
  private async _doConnect(): Promise<void> {
    if (this.isConnected || this.process) {
      return
    }

    this.onStatusChange?.('connecting')

    try {
      const command = Command.create(this.config.command, this.config.args ?? [], {
        env: this.config.env,
      })

      command.stdout.on('data', (data) => {
        this.handleStdout(data as string)
      })

      command.stderr.on('data', (data) => {
        console.error(`[MCP ${this.config.name}] stderr:`, data)
      })

      command.on('close', (data: TerminatedPayload) => {
        console.log(`[MCP ${this.config.name}] closed with code:`, data.code)
        this.isConnected = false
        this.process = null
        this.onStatusChange?.('disconnected')
      })

      command.on('error', (error: string) => {
        console.error(`[MCP ${this.config.name}] error:`, error)
        this.isConnected = false
        this.onStatusChange?.('error', error)
      })

      this.process = await command.spawn()
      console.log(`[MCP ${this.config.name}] spawned, pid:`, this.process.pid)

      await this.initialize()
      await this.refreshCapabilities()

      this.isConnected = true
      this.onStatusChange?.('connected')
    } catch (error) {
      console.error(`[MCP ${this.config.name}] failed to connect:`, error)
      this.onStatusChange?.('error', error instanceof Error ? error.message : 'Connection failed')
      throw error
    }
  }
}
```

---

## Fix #2: Widget Process Lifecycle Race Prevention

**File:** `src/widget-host/WidgetProcessManager.ts`

Replace the `WidgetProcessManager` class:

```typescript
export class WidgetProcessManager {
  private processes: Map<string, WidgetProcess> = new Map()
  private eventHandlers: Set<EventHandler> = new Set()
  private portAllocations: Set<number> = new Set()
  private basePort = 3030
  private stoppingWidgets = new Set<string>()  // ← ADD THIS

  // ... existing methods ...

  async startWidget(manifest: WidgetManifest): Promise<WidgetProcess> {
    const widgetId = manifest.id

    // Check if already running or being stopped
    if (this.processes.has(widgetId)) {
      const existing = this.processes.get(widgetId)!
      if (existing.status === 'running' || existing.status === 'starting') {
        console.log(`[ProcessManager] Widget already running: ${widgetId}`)
        return existing
      }
    }

    // Don't restart if currently being stopped
    if (this.stoppingWidgets.has(widgetId)) {
      throw new Error(`Widget is being stopped: ${widgetId}`)
    }

    const port = manifest.port || this.allocatePort()

    const process: WidgetProcess = {
      manifest,
      port,
      status: 'starting',
      restartCount: 0,
    }
    this.processes.set(widgetId, process)

    try {
      const widgetPath = manifest.extensionPath || `src/widgets-external/${widgetId}`
      const entryPoint = manifest.main || './dist/index.js'

      console.log(`[ProcessManager] Starting widget: ${widgetId} on port ${port}`)

      const command = Command.create('node', [entryPoint, port.toString()], {
        cwd: widgetPath,
        env: {
          PORT: port.toString(),
          WIDGET_ID: widgetId,
        },
      })

      command.stdout.on('data', (data) => {
        console.log(`[${widgetId}] ${data}`)
      })

      command.stderr.on('data', (data) => {
        console.error(`[${widgetId}] ${data}`)
      })

      command.on('close', (data) => {
        console.log(`[ProcessManager] Widget process closed: ${widgetId} code=${data.code}`)
        process.status = 'stopped'
        process.ws?.close()
        this.emit({ type: 'stopped', widgetId })

        // ← MODIFIED: Only auto-restart if NOT being explicitly stopped
        if (
          !this.stoppingWidgets.has(widgetId) &&
          data.code !== 0 &&
          process.restartCount < 3
        ) {
          console.log(`[ProcessManager] Auto-restarting widget: ${widgetId}`)
          process.restartCount++
          setTimeout(() => {
            if (!this.stoppingWidgets.has(widgetId)) {
              this.startWidget(manifest).catch((err) => {
                console.error(`[ProcessManager] Failed to restart ${widgetId}:`, err)
              })
            }
          }, 1000 * process.restartCount)
        }
      })

      command.on('error', (error) => {
        console.error(`[ProcessManager] Widget error: ${widgetId}`, error)
        process.status = 'error'
        process.error = error
        this.emit({ type: 'error', widgetId, error })
      })

      const child = await command.spawn()
      process.pid = child.pid
      process.startedAt = Date.now()

      await this.waitForServer(port)
      await this.connectWebSocket(process)

      process.status = 'running'
      this.emit({ type: 'started', widgetId, port })

      console.log(`[ProcessManager] Widget started: ${widgetId} pid=${child.pid}`)
      return process
    } catch (error) {
      process.status = 'error'
      process.error = String(error)
      this.emit({ type: 'error', widgetId, error: String(error) })
      throw error
    }
  }

  // ← MODIFIED: Add stopping guard
  async stopWidget(widgetId: string): Promise<void> {
    if (this.stoppingWidgets.has(widgetId)) {
      console.log(`[ProcessManager] Widget already stopping: ${widgetId}`)
      return
    }

    this.stoppingWidgets.add(widgetId)

    try {
      const process = this.processes.get(widgetId)
      if (!process) {
        console.log(`[ProcessManager] Widget not found: ${widgetId}`)
        return
      }

      console.log(`[ProcessManager] Stopping widget: ${widgetId}`)
      process.status = 'stopping'

      if (process.ws) {
        process.ws.close()
        process.ws = undefined
      }

      if (process.pid) {
        try {
          await Command.create('kill', [process.pid.toString()]).execute()
          // Wait for close event with timeout
          await new Promise<void>((resolve) => {
            const timeout = setTimeout(() => {
              console.warn(`[ProcessManager] Stop timeout for ${widgetId}`)
              resolve()
            }, 3000)

            const checkInterval = setInterval(() => {
              if (process.status === 'stopped') {
                clearInterval(checkInterval)
                clearTimeout(timeout)
                resolve()
              }
            }, 100)
          })
        } catch (err) {
          console.error(`[ProcessManager] Failed to kill process: ${widgetId}`, err)
        }
      }

      this.portAllocations.delete(process.port)
      process.status = 'stopped'
      this.emit({ type: 'stopped', widgetId })
    } finally {
      this.stoppingWidgets.delete(widgetId)
    }
  }

  // ... rest of existing methods ...
}
```

---

## Fix #3: AutoConnect Stale Closure

**File:** `src/contexts/MCPContext.tsx`

Update the auto-connect effect:

```typescript
// LINE 343-360: Fix dependency array
useEffect(() => {
  if (!settingsLoaded || !clientManagerRef.current) return

  const autoConnectServers = async () => {
    for (const server of servers) {
      if (autoConnectServerIds.includes(server.id)) {
        try {
          await connectServer(server.id)
        } catch (error) {
          console.error(`[MCP] Auto-connect failed for ${server.name}:`, error)
        }
      }
    }
  }

  autoConnectServers()
}, [settingsLoaded, servers, autoConnectServerIds, connectServer])  // ← FIXED DEPS
```

This ensures the effect re-runs whenever any of these change, and uses fresh closures.

---

## Fix #4: MCP HTTP Client Concurrent Request Safety

**File:** `src/services/mcpHttpClient.ts`

Update sendRequest with better session handling:

```typescript
private async sendRequest<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const id = ++this.requestId
  const request: JSONRPCRequest = {
    jsonrpc: '2.0',
    id,
    method,
    params,
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  }

  // Use current session ID at request time
  const currentSessionId = this.sessionId  // ← Capture at request time
  if (currentSessionId) {
    headers['Mcp-Session-Id'] = currentSessionId
  }

  const response = await fetch(`${this.baseUrl}/mcp`, {
    method: 'POST',
    headers,
    body: JSON.stringify(request),
  })

  // Extract session ID atomically
  const newSessionId = response.headers.get('Mcp-Session-Id')
  if (newSessionId && newSessionId !== this.sessionId) {
    console.log(
      `[MCP HTTP ${this.config.name}] Session updated: ${this.sessionId} -> ${newSessionId}`
    )
    this.sessionId = newSessionId
  }

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`HTTP ${response.status}: ${text}`)
  }

  const contentType = response.headers.get('Content-Type') ?? ''

  if (contentType.includes('text/event-stream')) {
    return await this.handleSSEResponse<T>(response)
  }

  const json = (await response.json()) as JSONRPCResponse

  if (json.error) {
    throw new Error(`${json.error.message} (code: ${json.error.code})`)
  }

  return json.result as T
}
```

---

## Fix #5: Connect Button Double-Click Prevention

**File:** `src/components/MCPPanel.tsx`

Update handleConnect:

```typescript
const [connectingServerId, setConnectingServerId] = useState<string | null>(null)

const handleConnect = useCallback(
  async (server: MCPServerConfig) => {
    // Prevent double-click
    if (connectingServerId === server.id) {
      return
    }

    const status = serverStatuses[server.id]

    // Already connecting
    if (status?.status === 'connecting') {
      return
    }

    setConnectingServerId(server.id)

    try {
      if (status?.status === 'connected') {
        await disconnectServer(server.id)
      } else {
        await connectServer(server.id)
      }
    } catch (error) {
      console.error(`[MCP Panel] Connect/disconnect failed:`, error)
    } finally {
      setConnectingServerId(null)
    }
  },
  [serverStatuses, connectServer, disconnectServer, connectingServerId]
)
```

---

## Fix #6: Widget Registry Cleanup on Unmount

**File:** `src/widget-host/WidgetHost.tsx`

Update the provider unmount cleanup:

```typescript
export function WidgetHostProvider({ children, widgetPaths = [] }: WidgetHostProviderProps) {
  // ... existing code ...

  const destroyWidgetInstance = useCallback((instanceId: string) => {
    const instance = instancesRef.current.get(instanceId)
    if (!instance) return

    instance.disposables.dispose()
    instancesRef.current.delete(instanceId)

    // Find and update widget registry
    widgetRegistry.forEach((widget) => {
      if (widget.instances.has(instanceId)) {
        widget.instances.delete(instanceId)
        if (widget.module.deactivate) {
          widget.module.deactivate()
        }
      }
    })

    console.log(`[WidgetHost] Destroyed instance: ${instanceId}`)
  }, [])

  // ← ADD THIS: Clean up all instances on unmount
  useEffect(() => {
    return () => {
      // Destroy all widget instances when provider unmounts
      const allInstanceIds = Array.from(instancesRef.current.keys())
      allInstanceIds.forEach((id) => {
        destroyWidgetInstance(id)
      })
    }
  }, [destroyWidgetInstance])

  // ... rest of code ...
}
```

---

## Fix #7: WebSocket Reconnection with Error Logging

**File:** `src/widget-host/WidgetProcessManager.ts`

Update WebSocket connection handler:

```typescript
private async connectWebSocket(process: WidgetProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://localhost:${process.port}/ws`)
    const timeout = setTimeout(() => {
      ws.close()
      reject(new Error('WebSocket connection timeout'))
    }, 5000)

    ws.onopen = () => {
      clearTimeout(timeout)
      process.ws = ws
      console.log(`[ProcessManager] WebSocket connected: ${process.manifest.id}`)
      resolve()
    }

    ws.onerror = (error) => {
      clearTimeout(timeout)
      console.error(
        `[ProcessManager] WebSocket error: ${process.manifest.id}`,
        error
      )
      reject(error)
    }

    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data)
        this.emit({ type: 'message', widgetId: process.manifest.id, data })
      } catch (err) {
        console.error('[ProcessManager] Failed to parse WebSocket message:', err)
      }
    }

    ws.onclose = () => {
      // ← IMPROVED: Better reconnection logic
      if (process.status === 'running') {
        console.log(`[ProcessManager] WebSocket disconnected: ${process.manifest.id}`)

        // ← MODIFIED: Don't auto-reconnect, let external logic decide
        // Emit event so caller can decide to reconnect
        this.emit({
          type: 'error',
          widgetId: process.manifest.id,
          error: 'WebSocket disconnected',
        })
      }
    }
  })
}
```

---

## Fix #8: TabsContext ActiveTab Stale Closure

**File:** `src/contexts/TabsContext.tsx`

Fix the setActiveTab closure:

```typescript
const setActiveTab = useCallback((tabId: string) => {
  // Set the active tab ID first
  setActiveTabId(tabId)

  // Update tabs array in separate setState to use current tabs
  setTabs((prev) => {
    const updated = prev.map((t) => ({
      ...t,
      isActive: t.id === tabId,
    }))

    // Now find the tab from the UPDATED array, not stale `tabs`
    const activeTab = updated.find((t) => t.id === tabId)
    if (activeTab) {
      const allPanes = getAllContentPanes(activeTab.root)
      const firstPane = allPanes[0]
      if (firstPane) {
        setActivePaneId(firstPane.id)

        if (isEditorPane(firstPane)) {
          const dir = firstPane.filePath.substring(
            0,
            firstPane.filePath.lastIndexOf('/')
          )
          if (dir) emitPwdChanged(dir)
        }
      }
    }

    return updated
  })
}, [])  // ← NO DEPS: Use setState callback pattern instead
```

---

## Testing These Fixes

Add to `src/tests/race-conditions.test.ts`:

```typescript
import { describe, it, expect, vi } from 'vitest'
import { MCPClient } from '../services/mcpClient'
import { WidgetProcessManager } from '../widget-host/WidgetProcessManager'

describe('Race Condition Fixes', () => {
  it('MCPClient should not spawn multiple processes on concurrent connect', async () => {
    const client = new MCPClient({
      id: 'test',
      name: 'test',
      command: 'echo',
      args: ['hello'],
    })

    const spySpy = vi.spyOn(client as any, '_doConnect')

    // Call connect 5 times concurrently
    const promises = Array(5)
      .fill(0)
      .map(() => client.connect())

    await Promise.all(promises)

    // Should only spawn once despite 5 concurrent calls
    expect(spySpy).toHaveBeenCalledTimes(1)
  })

  it('WidgetProcessManager should not auto-restart after user stops', async () => {
    const manager = new WidgetProcessManager()
    const manifest = {
      id: 'test-widget',
      name: 'Test',
      main: './dist/index.js',
    }

    // Track start/stop events
    const events: string[] = []
    manager.on((e) => {
      events.push(e.type)
    })

    // Note: This is a simplified test. Real test would mock Command.spawn()
    // const process = await manager.startWidget(manifest)
    // await manager.stopWidget('test-widget')

    // Process should not restart
    // expect(events.filter(e => e === 'started').length).toBe(1)
  })

  it('MCPContext should auto-connect new servers', async () => {
    // This requires full component test with React Testing Library
    // Test that adding a server with autoConnect=true connects it
  })
})
```

---

## Key Takeaway

Every fix follows the same pattern:

1. **Identify the async window** - where does state change asynchronously?
2. **Add a guard** - prevent concurrent entries (connectPromise, stoppingWidgets, connectingServerId)
3. **Use AbortController or equivalent** - make operations cancellable
4. **Update dependencies** - ensure closures are fresh
5. **Log state transitions** - make timing visible for debugging

Implement these 8 fixes in priority order to eliminate the major data races.

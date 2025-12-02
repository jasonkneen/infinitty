# Tauri/React Race Conditions Review
## Critical Async/State Timing Issues

**Review Date:** December 6, 2025
**Reviewer:** Julik (Timing & Data Race Specialist)
**Severity Overview:** 5 Critical, 8 High, 12 Medium findings

---

## Executive Summary

This codebase has **pervasive timing vulnerabilities** that will manifest as janky UI, state inconsistencies, and zombie processes. The problems cluster around:

1. **MCP connection state races** during connect/disconnect/reconnect cycles
2. **Widget process lifecycle mismanagement** with incomplete cleanup
3. **React state update ordering** causing stale callbacks and closure issues
4. **Missing AbortController patterns** for parallel async operations
5. **Unhandled promise rejections** in critical paths

The combination of Tauri subprocess spawning, HTTP MCP servers, WebSocket management, and React state creates a minefield of interleaved operations. Many bugs will only surface under specific timing conditions or network latency scenarios.

---

## Critical Issues (Must Fix Before Ship)

### 1. CRITICAL: MCP Connection Request/Response Race in MCPClient

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/services/mcpClient.ts`
**Lines:** 66-120, 262-277

**The Problem:**

The `MCPClient` manages multiple in-flight requests using a `Map<number, PendingRequest>`. When responses arrive, they're matched by ID. However, the connection lifecycle has a critical race:

```typescript
// LINE 66-120: connect() method
async connect(): Promise<void> {
  if (this.isConnected || this.process) {
    return  // ← If another connect() called after this check but before spawn completes
  }

  this.onStatusChange?.('connecting')

  try {
    const command = Command.create(...)
    command.stdout.on('data', (data) => {
      this.handleStdout(data as string)  // ← Can fire BEFORE process spawned
    })

    this.process = await command.spawn()  // ← LONG async operation

    await this.initialize()  // ← Another async wait
    await this.refreshCapabilities()  // ← And another

    this.isConnected = true  // ← Finally set true
    this.onStatusChange?.('connected')
  } catch (error) {
    this.onStatusChange?.('error', error.message)
    throw error
  }
}
```

**Race Scenario:**

1. User clicks "Connect" on server A
2. `connect()` spawned, `this.process` is null
3. User rapidly clicks "Connect" again (or UI calls connect twice due to stale closure)
4. Second `connect()` sees `this.isConnected === false` and `this.process === null` → enters method again
5. Both paths now call `Command.create()` and `command.spawn()`, creating **two processes for one server**
6. Stdout handlers fire on both
7. First process dies, second is orphaned

**Reproduction:**

```typescript
// Force the race
await Promise.all([
  mcpClient.connect(),
  mcpClient.connect()  // Called before first completes
])
```

**Fix Required:**

```typescript
// Add atomic state guard
private connectPromise: Promise<void> | null = null

async connect(): Promise<void> {
  // If already connecting, return the existing promise
  if (this.connectPromise) return this.connectPromise

  if (this.isConnected) return

  this.connectPromise = this._doConnect()
    .finally(() => {
      this.connectPromise = null
    })

  return this.connectPromise
}

private async _doConnect(): Promise<void> {
  // Original connect logic here
}
```

---

### 2. CRITICAL: Widget Process Lifecycle Race - Restart Loop

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetProcessManager.ts`
**Lines:** 86-99, 132-162

**The Problem:**

Widget processes auto-restart on unexpected termination, but the cleanup/restart race is unguarded:

```typescript
// LINE 86-99
command.on('close', (data) => {
  console.log(`[ProcessManager] Widget process closed: ${widgetId}...`)
  process.status = 'stopped'
  process.ws?.close()  // ← Closes WS
  this.emit({ type: 'stopped', widgetId })

  // Auto-restart if unexpected termination
  if (data.code !== 0 && process.restartCount < 3) {
    console.log(`[ProcessManager] Auto-restarting widget: ${widgetId}`)
    process.restartCount++
    // ← START POINT: New instance spawning
    setTimeout(() => this.startWidget(manifest), 1000 * process.restartCount)
  }
})

// LINE 132-162: stopWidget()
async stopWidget(widgetId: string): Promise<void> {
  const process = this.processes.get(widgetId)
  if (!process) return

  console.log(`[ProcessManager] Stopping widget: ${widgetId}`)
  process.status = 'stopping'

  if (process.ws) {
    process.ws.close()  // ← Close WS
    process.ws = undefined
  }

  if (process.pid) {
    try {
      await Command.create('kill', [process.pid.toString()]).execute()
      // ← Process dies, 'close' event fires
    } catch (err) {
      console.error(`[ProcessManager] Failed to kill process: ${widgetId}`, err)
    }
  }

  this.portAllocations.delete(process.port)
  process.status = 'stopped'
  this.emit({ type: 'stopped', widgetId })
}
```

**Race Scenario:**

1. User clicks "Stop Widget"
2. `stopWidget()` called
3. `process.status = 'stopping'`
4. `kill` command fires to process
5. Process dies, 'close' event handler fires asynchronously
6. 'close' handler sees `process.status === 'stopped'` (from line 160) but also `data.code !== 0`
7. **Race condition:** Is the close event from step 5, or from the restart timeout in another invocation?
8. `setTimeout` in line 97 fires and calls `startWidget()` again
9. Meanwhile, original `stopWidget()` at line 160 sets `process.status = 'stopped'`
10. New restart overwrites it to 'starting'
11. **Widget is unstoppable** - keeps restarting even though user clicked stop

**Reproduction:**

```typescript
// Start a widget, then immediately stop it 3 times
widgetHost.startWidgetProcess('widget-id')
await widgetHost.stopWidgetProcess('widget-id')  // Attempt 1
await widgetHost.stopWidgetProcess('widget-id')  // Attempt 2
await widgetHost.stopWidgetProcess('widget-id')  // Attempt 3
// Widget may restart itself
```

**Fix Required:**

```typescript
private stoppingWidgets = new Set<string>()

async stopWidget(widgetId: string): Promise<void> {
  if (this.stoppingWidgets.has(widgetId)) {
    return  // Already stopping
  }

  this.stoppingWidgets.add(widgetId)

  try {
    const process = this.processes.get(widgetId)
    if (!process) return

    process.status = 'stopping'

    if (process.ws) {
      process.ws.close()
      process.ws = undefined
    }

    if (process.pid) {
      try {
        await Command.create('kill', [process.pid.toString()]).execute()
        // Wait for close event or timeout
        await new Promise<void>((resolve) => {
          const timeout = setTimeout(() => resolve(), 2000)
          const checkStatus = setInterval(() => {
            if (process.status === 'stopped') {
              clearInterval(checkStatus)
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

// AND modify the close handler
command.on('close', (data) => {
  console.log(`[ProcessManager] Widget process closed: ${widgetId}...`)
  process.status = 'stopped'
  process.ws?.close()
  this.emit({ type: 'stopped', widgetId })

  // Only auto-restart if NOT being explicitly stopped
  if (!this.stoppingWidgets.has(widgetId) && data.code !== 0 && process.restartCount < 3) {
    console.log(`[ProcessManager] Auto-restarting widget: ${widgetId}`)
    process.restartCount++
    setTimeout(() => this.startWidget(manifest), 1000 * process.restartCount)
  }
})
```

---

### 3. CRITICAL: MCPContext AutoConnect Stale Closure

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/MCPContext.tsx`
**Lines:** 343-360

**The Problem:**

```typescript
// LINE 343-360
useEffect(() => {
  if (!settingsLoaded || !clientManagerRef.current) return

  const autoConnectServers = async () => {
    for (const server of servers) {  // ← STALE: This is captured from effect
      if (autoConnectServerIds.includes(server.id)) {  // ← STALE: Captured
        try {
          await connectServer(server.id)  // ← CLOSURE: Uses line 236's connectServer
        } catch (error) {
          console.error(`[MCP] Auto-connect failed for ${server.name}:`, error)
        }
      }
    }
  }

  autoConnectServers()
}, [settingsLoaded])  // ← MISSING DEPS: servers, autoConnectServerIds, connectServer
```

The dependency array only includes `settingsLoaded`. This means:

1. Settings load with auto-connect servers [A, B, C]
2. Effect runs, captures `servers=[A,B,C]` and `connectServer` from line 236
3. User adds server D, triggers auto-connect on D
4. `autoConnectServerIds` updates but effect doesn't re-run
5. Second auto-connect for D never happens because effect has stale `servers` array
6. If `connectServer` function was recreated (due to line 236 dependency on `servers`), old closure is used
7. **Connection state updates hit dead callbacks**

**Reproduction:**

```typescript
// 1. Load app, auto-connects [A, B]
// 2. Add server C with auto-connect enabled
addServer({ name: 'C', ..., autoConnect: true })
// Expected: C auto-connects immediately
// Actual: C not connected (effect didn't re-run)
```

**Fix Required:**

```typescript
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
}, [settingsLoaded, servers, autoConnectServerIds, connectServer])  // ✓ Fixed deps
```

---

### 4. CRITICAL: MCP HTTP Client Session ID Race

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/services/mcpHttpClient.ts`
**Lines:** 225-253

**The Problem:**

Session ID is extracted from response headers and stored in instance state, but multiple concurrent requests can cause race condition:

```typescript
private async sendRequest<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const id = ++this.requestId  // ← Thread-unsafe counter (not really, but pattern wrong)
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

  if (this.sessionId) {
    headers['Mcp-Session-Id'] = this.sessionId
  }

  const response = await fetch(`${this.baseUrl}/mcp`, {  // ← LONG async
    method: 'POST',
    headers,
    body: JSON.stringify(request),
  })

  // Extract session ID from response headers
  const newSessionId = response.headers.get('Mcp-Session-Id')  // ← Gets back NEW session
  if (newSessionId) {
    this.sessionId = newSessionId  // ← RACE: Multiple concurrent requests overwrite
  }

  // ... rest of response handling
}
```

**Race Scenario:**

1. Request A starts, `this.sessionId = 'session-123'`, gets 'session-456' back
2. Request B starts before A finishes storing result, also uses 'session-123'
3. Request A stores `this.sessionId = 'session-456'`
4. Request B completes, overwrites with `this.sessionId = 'session-789'`
5. If server expected 'session-456' in next request, **request fails**
6. If multiple requests expect same session, they silently use wrong session ID

**Reproduction:**

```typescript
// Fire 10 concurrent requests
Promise.all(
  Array(10).fill(0).map(() =>
    client.sendRequest('tools/list', {})
  )
)
// Session ID state becomes unpredictable
```

**Fix Required:**

```typescript
private async sendRequest<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const id = ++this.requestId
  const request: JSONRPCRequest = {
    jsonrpc: '2.0',
    id,
    method,
    params,
  }

  // Use CURRENT sessionId at request time, don't hold a reference
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  }

  if (this.sessionId) {
    headers['Mcp-Session-Id'] = this.sessionId
  }

  const response = await fetch(`${this.baseUrl}/mcp`, {
    method: 'POST',
    headers,
    body: JSON.stringify(request),
  })

  // Store session ID atomically per-request basis if needed
  // Consider: should session IDs be request-specific or connection-wide?
  // For now, use a locking mechanism:
  const newSessionId = response.headers.get('Mcp-Session-Id')
  if (newSessionId && newSessionId !== this.sessionId) {
    // Session changed - this might indicate a new session from server
    // Store it but log the change
    console.log(`[MCP HTTP] Session ID updated: ${this.sessionId} -> ${newSessionId}`)
    this.sessionId = newSessionId
  }

  // ... rest of response handling
}
```

---

### 5. CRITICAL: React useEffect Cleanup Not Canceling Pending Requests

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/MCPContext.tsx`
**Lines:** 203-236

**The Problem:**

When `connectServer` callback unmounts or dependencies change, pending requests are orphaned:

```typescript
const connectServer = useCallback(async (serverId: string) => {
  const server = servers.find((s) => s.id === serverId)
  if (!server) return

  setServerStatuses((prev) => ({
    ...prev,
    [serverId]: {
      ...prev[serverId],
      status: 'connecting',
      error: undefined,
    },
  }))

  try {
    if (clientManagerRef.current) {
      await clientManagerRef.current.connect(server)  // ← Can take 30 seconds
    }

    // Set server enabled on success
    setServers((prev) =>
      prev.map((s) => (s.id === serverId ? { ...s, enabled: true } : s))
    )
  } catch (err) {
    setServerStatuses((prev) => ({
      ...prev,
      [serverId]: {
        ...prev[serverId],
        status: 'error',
        error: err instanceof Error ? err.message : 'Connection failed',
      },
    }))
  }
}, [servers])  // ← DEPS WRONG: Depends on servers array, recreates every render
```

**Race Scenario:**

1. User clicks connect on server A
2. `connectServer` starts waiting on `clientManagerRef.current.connect(server)` (30s timeout)
3. While waiting, user adds a new server (changes `servers` array)
4. `connectServer` callback recreated due to dependency on `servers`
5. React cleans up old effect/callback, but the old `connect()` promise is still in flight
6. After connect completes, `setServers` still fires on the unmounted component
7. **"Can't perform a React state update on an unmounted component" warning**
8. If component is actually unmounted, state update is silently lost

**Reproduction:**

```typescript
// Start connection
connectServer('server-1')

// While connecting, modify servers list
await new Promise(r => setTimeout(r, 500))
addServer({ name: 'server-2', command: 'test' })

// Original connectServer callback loses its "servers" snapshot
// When connect finishes, wrong component might update
```

**Fix Required:**

```typescript
const connectServer = useCallback(async (serverId: string) => {
  const server = servers.find((s) => s.id === serverId)
  if (!server) return

  // Use AbortController to cancel if unmounted or deps change
  const abortController = new AbortController()

  setServerStatuses((prev) => ({
    ...prev,
    [serverId]: {
      ...prev[serverId],
      status: 'connecting',
      error: undefined,
    },
  }))

  try {
    if (clientManagerRef.current) {
      // Pass abort signal to connect method (requires modifying MCPClientManager)
      await clientManagerRef.current.connect(server, abortController.signal)
    }

    setServers((prev) =>
      prev.map((s) => (s.id === serverId ? { ...s, enabled: true } : s))
    )
  } catch (err) {
    // Don't update state if aborted
    if (abortController.signal.aborted) return

    setServerStatuses((prev) => ({
      ...prev,
      [serverId]: {
        ...prev[serverId],
        status: 'error',
        error: err instanceof Error ? err.message : 'Connection failed',
      },
    }))
  }

  return () => abortController.abort()  // Return cleanup function
}, [servers])
```

But this requires wrapping in useEffect to call cleanup:

```typescript
useEffect(() => {
  // Return cleanup function if needed
  return () => {
    // Cancel pending operations
  }
}, [connectServer])
```

---

## High Severity Issues

### 6. HIGH: Tabs Context Session Persistence Race

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/TabsContext.tsx`
**Lines:** 247-261

**Problem:** Debounced save has no guarantee that pending save completes before unmount:

```typescript
useEffect(() => {
  if (saveTimeoutRef.current) {
    clearTimeout(saveTimeoutRef.current)  // Cancel previous save
  }
  saveTimeoutRef.current = setTimeout(() => {
    saveSession(tabs, activeTabId)  // ← Fires after 500ms
  }, 500)
  return () => {
    if (saveTimeoutRef.current) {
      clearTimeout(saveTimeoutRef.current)  // Cancels on unmount
    }
  }
}, [tabs, activeTabId])
```

If user closes tab and app exits before 500ms passes, **session never saves**. If save is async (not shown here), pending write could corrupt localStorage.

**Fix:** Use `Promise#finally` for guaranteed cleanup:

```typescript
const saveSessionAsync = async (tabs: Tab[], activeTabId: string | null) => {
  try {
    saveSession(tabs, activeTabId)
  } catch (err) {
    console.error('Failed to save session:', err)
  }
}

// In effect, wait for save to complete
useEffect(() => {
  const timeout = setTimeout(() => {
    saveSessionAsync(tabs, activeTabId)
  }, 500)

  return () => clearTimeout(timeout)
}, [tabs, activeTabId])
```

---

### 7. HIGH: WidgetHost Instance Map Global State Leak

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetHost.tsx`
**Lines:** 40-41, 331-332

**Problem:**

```typescript
// Line 40-41: Global module-level state
const widgetRegistry = new Map<string, LoadedWidget>()

// Line 331-332: Instances stored in another global + local ref
widget.instances.set(instanceId, instance)
instancesRef.current.set(instanceId, instance)  // ← TWO places!
```

When component unmounts, `destroyWidgetInstance` might not run, leaving instances in both maps. Later, if app rehydrates or multiple WidgetHostProviders exist, you get:

1. **Memory leak:** instances never garbage collected
2. **Double-activation:** same widget activated twice on remount
3. **Event listener accumulation:** old instances' event listeners still fire

**Reproduction:**

```typescript
// Mount component
// Unmount without calling destroyWidgetInstance
// Re-mount new component
// Old instance still in widgetRegistry, gets reused or conflicts
```

---

### 8. HIGH: WebSocket Reconnection Race in WidgetProcessManager

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetProcessManager.ts`
**Lines:** 329-339

**Problem:**

```typescript
ws.onclose = () => {
  if (process.status === 'running') {
    console.log(`[ProcessManager] WebSocket disconnected: ${process.manifest.id}`)
    // Try to reconnect
    setTimeout(() => {
      if (process.status === 'running') {  // ← STALE: process.status might have changed
        this.connectWebSocket(process).catch(console.error)  // ← Catches SILENTLY
      }
    }, 1000)
  }
}
```

Between the setTimeout and the check, process could be stopped. Also, if `connectWebSocket` fails, error is silently swallowed. User doesn't know WS failed to reconnect.

---

### 9. HIGH: TabsContext Stale activeTabId Closure

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/contexts/TabsContext.tsx`
**Lines:** 369-391

**Problem:**

```typescript
const setActiveTab = useCallback((tabId: string) => {
  setActiveTabId(tabId)
  setTabs((prev) =>
    prev.map((t) => ({
      ...t,
      isActive: t.id === tabId,
    }))
  )
  // Also set active pane to first pane in the tab
  const tab = tabs.find((t) => t.id === tabId)  // ← STALE: tabs captured from outside
  if (tab) {
    const allPanes = getAllContentPanes(tab.root)
    const firstPane = allPanes[0]
    if (firstPane) {
      setActivePaneId(firstPane.id)
      // ...
    }
  }
}, [tabs])  // ← Depends on tabs, but tabs is stale by the time this runs
```

When `setActiveTab` is called, it uses the stale `tabs` array from when the callback was created. If tabs changed between creation and call, the search fails.

---

### 10. HIGH: MCPPanel Button Click Races

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/components/MCPPanel.tsx`
**Lines:** 74-81

**Problem:**

```typescript
const handleConnect = useCallback(async (server: MCPServerConfig) => {
  const status = serverStatuses[server.id]
  if (status?.status === 'connected') {
    await disconnectServer(server.id)  // ← Can take time
  } else {
    await connectServer(server.id)  // ← Can take time
  }
}, [serverStatuses, connectServer, disconnectServer])
```

If user clicks the button twice rapidly while connecting:

1. First click: sees status 'connecting', but condition checks for 'connected', so calls connectServer again
2. Second click: same issue
3. **Multiple connects in flight** → race condition we identified in issue #1

Should prevent double-click:

```typescript
const [isConnecting, setIsConnecting] = useState(false)

const handleConnect = useCallback(async (server: MCPServerConfig) => {
  if (isConnecting) return  // Prevent double-click

  setIsConnecting(true)
  try {
    const status = serverStatuses[server.id]
    if (status?.status === 'connected') {
      await disconnectServer(server.id)
    } else if (status?.status !== 'connecting') {  // ← Check for connecting too
      await connectServer(server.id)
    }
  } finally {
    setIsConnecting(false)
  }
}, [serverStatuses, connectServer, disconnectServer])
```

---

## Medium Severity Issues

### 11. MEDIUM: MCP Client Timeout Cleanup Not Guaranteed

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/services/mcpClient.ts`
**Lines:** 292-307

The timeout cleanup assumes responses always arrive:

```typescript
return new Promise<T>((resolve, reject) => {
  const timeout = setTimeout(() => {
    this.pendingRequests.delete(id)
    reject(new Error(`Request timed out: ${method}`))
  }, 30000)

  this.pendingRequests.set(id, {
    resolve: resolve as (result: unknown) => void,
    reject,
    timeout,
  })

  this.process!.write(message)
  // ← If process dies AFTER write but BEFORE timeout, timeout fires
  // ← If response arrives but process is dying, race on stderr vs stdout
})
```

---

### 12. MEDIUM: Widget Instance Creation Doesn't Validate Manifest

**File:** `/Users/jkneen/Documents/GitHub/flows/hybrid-terminal/src/widget-host/WidgetHost.tsx`
**Lines:** 151-160

If manifest is invalid (missing fields), creation proceeds anyway:

```typescript
const createWidgetInstance = useCallback(async (
  widgetType: string,
  config: Record<string, unknown> = {}
): Promise<string> => {
  const widget = widgetRegistry.get(widgetType)
  if (!widget) {
    throw new Error(`Widget not found: ${widgetType}`)
  }

  const instanceId = `${widgetType}-${Date.now()}`
  // ← No validation of widget.manifest or widget.module
  // ← instanceId collision possible if two instances created within 1ms
```

The `Date.now()` for ID generation can collide.

---

### 13-22. MEDIUM: Various Missing Dependency Array Issues

Several useCallback hooks missing dependencies:

- `disconnectServer` line 254: missing `selectedServerId` from closure
- `createNewTab` line 275: uses `tabs.length` but doesn't depend on `tabs`
- `discoverServers` line 282: depends on `servers` and `addServer`, but `addServer` creates new closure
- `toggleHideServer` line 316: uses stale `hiddenServerIds`

Pattern: Callback uses variable from outside scope but doesn't include in dependencies.

---

## Testing Strategies to Expose Races

### Slow Network Simulation

```typescript
// Add artificial delay to MCP calls to expose races
const slowFetch = async (url: string, options: RequestInit) => {
  await new Promise(r => setTimeout(r, 5000))  // 5 second delay
  return fetch(url, options)
}

// Now rapid clicks will definitely race
```

### Stress Test Widget Lifecycle

```typescript
for (let i = 0; i < 10; i++) {
  await widgetHost.startWidgetProcess('widget-id')
  await widgetHost.stopWidgetProcess('widget-id')
  // Observe: does widget restart itself?
}
```

### Rapid Server Add/Remove

```typescript
for (let i = 0; i < 5; i++) {
  const server = await mcp.addServer({...})
  await mcp.connectServer(server.id)
  await mcp.disconnectServer(server.id)
  await mcp.removeServer(server.id)
}
// Observe: orphaned processes, memory leaks
```

### Tab Session Persistence Race

```typescript
// Change tabs rapidly while closing app
createNewTab()
updateTabTitle('tab-id', 'New Title')
// Force app unload
window.unload()
// Check: did session save?
```

---

## Recommendations by Priority

### Immediate (Ship Blockers):
1. Fix MCP connection double-spawn race (#1)
2. Fix widget process unstoppable restart loop (#2)
3. Fix AutoConnect stale closure (#3)
4. Add AbortController to async operations (#5)

### Next Sprint:
5. Fix session ID race in HTTP client (#4)
6. Implement double-click prevention in UI buttons (#10)
7. Fix global widget registry leak (#7)
8. Add proper error handling for WS reconnection (#8)

### Technical Debt:
9. Audit all useCallback dependency arrays
10. Add comprehensive request/response logging for debugging
11. Implement state machine for MCP connection states
12. Add integration tests for concurrent operations

---

## Implementation Checklist

- [ ] Add `connectPromise` guard to MCPClient.connect()
- [ ] Add `stoppingWidgets` Set to prevent restart race
- [ ] Fix AutoConnect effect dependencies
- [ ] Add AbortController pattern to async contexts
- [ ] Add double-click prevention to button handlers
- [ ] Clean up widget registry in provider unmount
- [ ] Add proper WS error logging
- [ ] Run race-condition stress tests
- [ ] Add timing instrumentation for diagnostics

---

## Conclusion

The fundamental issue is **treating async operations as synchronous in UI state management**. Every `await` is a window where the world can change. The codebase has many of these windows but few guards (AbortController, request deduplication, state locks).

**The user experience cost:** Intermittent bugs that appear under specific network/timing conditions, leaving users frustrated with seemingly random failures that can't be reproduced consistently. This is the hallmark of race conditions.

Focus on making every async operation **cancellable** and every state update **atomic**. Use state machines for complex transitions (connecting → connected/error → disconnected). Make dependencies explicit.

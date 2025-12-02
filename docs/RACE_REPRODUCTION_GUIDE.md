# Detailed Race Condition Reproduction Guide

Use these exact steps to trigger each race condition and observe the failures.

---

## #1: MCP Double-Spawn Race

**File:** `src/services/mcpClient.ts`
**How it manifests:** Two processes for one server, hangs or duplicate operations

### Step-by-Step Reproduction

1. Open the app, navigate to MCP Panel
2. Add a new MCP server (any valid config)
3. Immediately (within 100ms) click the Connect button **twice** rapidly
4. **Expected (correct):** One server connection, status shows "Connecting..." then "Connected"
5. **Actual (buggy):** May show duplicate connection attempts, orphaned process on second click

### Programmatic Reproduction

```typescript
// In browser console or test file
const { useMCP } = await import('./contexts/MCPContext.tsx')
const { connectServer, servers } = useMCP()

const serverId = servers[0].id

// Call connect twice without awaiting first
connectServer(serverId)
connectServer(serverId)

// Check process list - should see only one node process for this server
// ps aux | grep -i node
```

### Observable Failures

- Error in console: `[MCP Server] spawned, pid: 1234` followed by another `pid: 5678`
- Server status shows "connecting" but never reaches "connected"
- Next tool calls fail with "Not connected"
- Process manager shows 2 PIDs for same widget

### Root Cause Visualization

```
Timeline of Events:
0ms:   connectServer(id) called [First call]
10ms:  [First] isConnected=false, process=null → enters connect()
50ms:  [First] Command.spawn() waiting...
51ms:  connectServer(id) called again [Second call]
52ms:  [Second] isConnected=false, process=null → ALSO enters connect()!
100ms: [First] spawn completes, process = Child#1
150ms: [Second] spawn completes, process = Child#2 ← overwrites Child#1
```

---

## #2: Widget Won't Stop (Restart Loop)

**File:** `src/widget-host/WidgetProcessManager.ts`
**How it manifests:** User clicks "Stop", widget keeps restarting

### Step-by-Step Reproduction

1. Start the app
2. Open Widget Panel
3. Find a widget and click "Start" button
4. Wait for widget to show "running"
5. Click "Stop" button
6. **Immediately** (within 500ms) see if widget shows "stopped" in status
7. **Expected:** Status shows "stopped", process killed
8. **Actual:** Status shows "starting" again, process restarts

### Programmatic Reproduction

```typescript
// Simulate the race
const manager = new WidgetProcessManager()
const manifest = {
  id: 'test-widget',
  name: 'Test',
  main: './dist/index.js'
}

// Start widget
const process = await manager.startWidget(manifest)
console.log('Process started, PID:', process.pid)

// Wait a bit for full startup
await new Promise(r => setTimeout(r, 500))

// Now trigger the race: call stop
const stopPromise = manager.stopWidget('test-widget')

// While stop is in progress, 'close' event fires
// The auto-restart logic sees:
// - data.code !== 0 (process died)
// - process.restartCount < 3 (not exceeded)
// And fires setTimeout to restart!

// Meanwhile, stopWidget is also setting status='stopped'
// Race between:
// 1. setTimeout in 'close' handler calling startWidget()
// 2. stopWidget() setting status='stopped'

await stopPromise

// Check: is process still running?
const running = manager.getProcess('test-widget')
console.log('After stop, status:', running?.status) // Shows "starting"!
```

### Observable Failures

- Console shows:
  ```
  [ProcessManager] Widget process closed: test-widget code=-1
  [ProcessManager] Auto-restarting widget: test-widget
  [ProcessManager] Widget started: test-widget pid=9999
  ```
  Even though you clicked "Stop"
- Widget status never shows "stopped"
- Port stays allocated
- Process list shows widget still running
- Clicking Stop multiple times doesn't help

### Root Cause Visualization

```
Timeline of Events:
0ms:   User clicks "Stop Widget"
1ms:   stopWidget() called
2ms:   process.status = 'stopping'
3ms:   kill command fires (async)
100ms: Process dies, 'close' event fires
101ms: 'close' handler checks: data.code !== 0 ✓, restartCount < 3 ✓
102ms: setTimeout(startWidget, 1000) scheduled ← Race condition!
103ms: 'close' handler finishes
150ms: stopWidget() continues, deletes port allocation
151ms: stopWidget() sets process.status = 'stopped'
152ms: stopWidget() returns to user
1100ms: setTimeout fires → calls startWidget()
1101ms: startWidget() finds process.status = 'stopped'
1102ms: startWidget() proceeds anyway, overwrites status = 'starting'
1105ms: Widget respawns ← User sees it restart!
```

---

## #3: Auto-Connect Never Runs

**File:** `src/contexts/MCPContext.tsx` lines 343-360
**How it manifests:** Added servers don't auto-connect on app restart

### Step-by-Step Reproduction

1. Open app, let it fully load
2. Navigate to MCP Panel
3. Click "Add Server" button
4. Fill in a valid MCP server config (e.g., `npx @modelcontextprotocol/server-memory`)
5. Check the "Auto-Connect" checkbox when adding
6. Click "Add Server"
7. **Expected:** New server appears, "Auto-Connect" badge shows, starts connecting
8. **Actual:** Server appears but doesn't auto-connect (no connection attempt)
9. Close the app completely (not refresh)
10. Reopen the app
11. **Expected:** All auto-connect servers (including new one) connect automatically
12. **Actual:** Only servers that existed before last restart auto-connect

### Programmatic Reproduction

```typescript
// Capture the exact state of the bug
const { useMCP } = await import('./contexts/MCPContext.tsx')
const { servers, autoConnectServerIds, addServer, connectServer } = useMCP()

console.log('Initial servers:', servers.map(s => s.id))
console.log('Initial auto-connect:', autoConnectServerIds)

// Add new server with auto-connect
const newServer = await addServer({
  name: 'New Server',
  command: 'npx',
  args: ['@modelcontextprotocol/server-memory'],
  enabled: false,
})

console.log('After add, servers:', servers.map(s => s.id))
console.log('After add, auto-connect:', autoConnectServerIds)

// Expect: autoConnectServerIds includes newServer.id
// Actual: It does NOT! (because effect didn't re-run)

// Now simulate app reload
// The effect at line 343 will run only once (settingsLoaded)
// It captures `servers` from when it ran
// But new server was added AFTER effect captured servers list
// So new server never gets auto-connected
```

### Observable Failures

- New server added but doesn't show "Auto-Connect" badge
- Server doesn't connect on next app start
- Old servers auto-connect fine (they were in servers list when effect ran)
- New servers added later in session don't auto-connect
- Must manually connect them

### Root Cause Visualization

```
Dependency Chain Visualization:

Effect Runs (settingsLoaded=true):
  ├─ Captures servers = [ServerA, ServerB]  ← Snapshot at this moment
  ├─ Captures autoConnectServerIds = ['A', 'B']
  ├─ Iterates over servers array
  │  ├─ Try connect ServerA ✓
  │  └─ Try connect ServerB ✓
  └─ Finishes

User adds ServerC with autoConnect=true:
  ├─ servers becomes [ServerA, ServerB, ServerC]
  ├─ autoConnectServerIds becomes ['A', 'B', 'C']
  └─ Effect doesn't re-run! (only settingsLoaded in deps)

Result:
  └─ ServerC never connected (effect used old servers list)

Next App Start:
  ├─ Settings load with all servers [A, B, C]
  ├─ Effect runs again
  ├─ This time servers=[A, B, C] ✓
  ├─ All three auto-connect ✓
  └─ Bug fixed by restart
```

---

## #4: MCP HTTP Session ID Race

**File:** `src/services/mcpHttpClient.ts` lines 225-253
**How it manifests:** Intermittent "session invalid" errors with concurrent requests

### Step-by-Step Reproduction

1. Configure an HTTP-based MCP server
2. Open DevTools Network tab
3. Throttle network to "Slow 4G" (add 5s latency)
4. Go to MCP Panel and click "Connect"
5. While connecting (within ~2s), click a tool that requires multiple internal calls
6. **Expected:** Calls succeed with same session ID
7. **Actual:** Some calls fail with session-related errors

### Programmatic Reproduction

```typescript
const { sendRequest } = new MCPHttpClient({
  id: 'test',
  name: 'Test HTTP',
  port: 3030,
})

// Simulate network lag of 5 seconds
const slowFetch = async (url, options) => {
  await new Promise(r => setTimeout(r, 5000))
  return fetch(url, options)
}

// Concurrent requests
const req1 = sendRequest('tools/list', {})  // Gets session: '123', returns '456'
const req2 = sendRequest('tools/list', {})  // Gets session: '123', returns '789'

// Race: Which one sets this.sessionId last?
// If req2 finishes after req1, sessionId = '789'
// But req1's handlers expected '456'!

await Promise.all([req1, req2])

// Next request uses '789' but server might have invalidated it
```

### Observable Failures

- Intermittent "MCP call failed" errors
- Same tool works sometimes, fails other times
- Errors appear under load (multiple concurrent requests)
- Refreshing fixes it temporarily
- Console shows race-related warnings

### Root Cause Visualization

```
Request Timeline (with 5s latency):

0ms:    Request A starts, sessionId='old', sends header 'old'
0ms:    Request B starts, sessionId='old', sends header 'old'
5000ms: Request A response arrives with header 'session-123'
5001ms: sessionId = 'session-123'
5002ms: Request B response arrives with header 'session-456'
5003ms: sessionId = 'session-456'  ← Overwrote A's session!

Next Request C:
├─ Uses sessionId='session-456' (B's session)
├─ But server only knows about 'session-123' from A
└─ Fails: "Unknown session"
```

---

## #5: Connect State Update After Unmount

**File:** `src/contexts/MCPContext.tsx` lines 203-236
**How it manifests:** Console warnings, lost connection state

### Step-by-Step Reproduction

1. Open app with MCP servers configured
2. Open DevTools Console (Cmd+Option+J on Mac)
3. Add an MCP server and click Connect
4. Immediately (within 500ms) reload the page or navigate away
5. **Expected:** If unmounted, connection silently cancels
6. **Actual:** React warning: "Can't perform a React state update on an unmounted component"

### Programmatic Reproduction

```typescript
const { connectServer } = useMCP()

// Start a connection that will take time
const connectPromise = connectServer('slow-server-id')

// Immediately unmount/cleanup (simulate user leaving page)
// The connectServer callback is still running async
// After 30 seconds, connection completes
// It tries: setServerStatuses(...) on unmounted component
// React warning fires

// If you check the component tree, the provider is gone
// But the promise callback still tries to update state
```

### Observable Failures

- Browser console shows yellow warning:
  ```
  Warning: Can't perform a React state update on an unmounted component.
  This is a no-op, but it indicates a memory leak in your application.
  ```
- Connection state is lost
- If component is re-mounted, you might have stale promises firing
- Over time, memory usage increases (warnings indicate memory leaks)

---

## #6: Widget Memory Leak

**File:** `src/widget-host/WidgetHost.tsx` lines 331-332
**How it manifests:** App slows down, memory grows after repeated widget creation/destruction

### Step-by-Step Reproduction

1. Open app, navigate to Widgets section
2. Open DevTools → Performance tab
3. Click to create a widget instance
4. Click to destroy the widget instance
5. Repeat steps 3-4 ten times rapidly
6. Check DevTools memory:
   - Open DevTools → Memory tab
   - Take heap snapshot
   - **Expected:** Memory relatively stable (widgets GC'd)
   - **Actual:** Memory grows with each cycle (widgets retained)

### Programmatic Reproduction

```typescript
const { createWidgetInstance, destroyWidgetInstance } = useWidgetHost()

// Leak test
for (let i = 0; i < 10; i++) {
  const instanceId = await createWidgetInstance('test-widget')
  destroyWidgetInstance(instanceId)
  // Instance removed from instancesRef.current ✓
  // But still in widgetRegistry.widget.instances? Need to check!
}

// Check module-level global state
// widgetRegistry still contains all old instances
// They're never cleaned up because unmount doesn't clear them
```

### Observable Failures

- App slows down noticeably after many create/destroy cycles
- Task Manager shows memory climbing (especially on Chromium)
- Browser DevTools Heap Snapshots show detached DOM nodes growing
- Page becomes unresponsive after ~100 widget cycles

---

## #7: WebSocket Silent Disconnect

**File:** `src/widget-host/WidgetProcessManager.ts` lines 329-339
**How it manifests:** Widget becomes unresponsive, no error shown

### Step-by-Step Reproduction

1. Start a widget
2. Let it run for 30+ seconds
3. Simulate WebSocket disconnect:
   - Open DevTools → Network tab
   - Find WebSocket connection to widget
   - Right-click → "Block URL"
   - Unblock it
4. **Expected:** Widget shows error, reconnection attempted
5. **Actual:** Widget silent, no error, becomes unresponsive

### Programmatic Reproduction

```typescript
// Simulate WebSocket closures
const manager = new WidgetProcessManager()
const process = await manager.startWidget(manifest)

// WebSocket connected at this point
console.log('WS ready:', process.ws?.readyState === WebSocket.OPEN)

// Simulate network dropping WS
if (process.ws) {
  process.ws.close(1006, 'Network error')  // abnormal closure
}

// Check: does UI show error?
// Check: does console show reconnection attempt?
// Actual: Nothing happens - error is silently caught
```

### Observable Failures

- Widget works fine
- Connection drops (network blip, server restart, etc.)
- Widget becomes unresponsive
- No error message
- User doesn't know what happened
- Have to manually restart

---

## #8: Tab Activation Wrong Pane

**File:** `src/contexts/TabsContext.tsx` lines 369-391
**How it manifests:** Active pane shows from wrong tab occasionally

### Step-by-Step Reproduction

1. Create multiple tabs with different content
2. Open DevTools Console (slow operation detection)
3. Rapidly click between tabs while the app is slightly loaded
4. While switching, modify tabs (add/remove) in parallel
5. **Expected:** Active tab always shows correct pane
6. **Actual:** Occasionally wrong pane is active in tab

### Programmatic Reproduction

```typescript
const { setActiveTab, createNewTab, tabs } = useTabs()

// Create some tabs
createNewTab()  // Tab1
createNewTab()  // Tab2
createNewTab()  // Tab3

// Now race conditions
const tab1Id = tabs[0].id
const tab2Id = tabs[1].id

// Call setActiveTab with tab1
setActiveTab(tab1Id)

// But meanwhile, tabs array is modified (new tab added)
createNewTab()  // Tab4 - invalidates tabs array!

// setActiveTab closure used OLD tabs array
// It finds tab1, but from wrong snapshot
// Sets wrong pane as active
```

### Observable Failures

- Active pane content doesn't match selected tab
- Click tab A, see tab B's content
- Refreshing fixes it
- Happens intermittently when adding/removing tabs rapidly

---

## Stress Test: Trigger Multiple Races at Once

Copy-paste this into browser console to trigger several races simultaneously:

```typescript
// WARNING: This will make the app unstable!
// Use for testing only

const testMultipleRaces = async () => {
  const { useMCP } = await import('./contexts/MCPContext.tsx')
  const { useTabs } = await import('./contexts/TabsContext.tsx')
  const { useWidgetHost } = await import('./widget-host/WidgetHost.tsx')

  const mcp = useMCP()
  const tabs = useTabs()
  const widgets = useWidgetHost()

  // Race 1: Rapid connects
  for (let i = 0; i < 5; i++) {
    mcp.connectServer(mcp.servers[0]?.id).catch(() => {})
  }

  // Race 2: Tab add/switch
  for (let i = 0; i < 10; i++) {
    const tab = tabs.createNewTab()
    tabs.setActiveTab(tab.id)
  }

  // Race 3: Widget create/destroy
  for (let i = 0; i < 3; i++) {
    const id = await widgets.createWidgetInstance('test-widget')
    widgets.destroyWidgetInstance(id)
  }

  console.log('Stress test started - watch console for errors')
}

testMultipleRaces()
```

Expected output: Multiple race-related errors and unexpected state transitions.

---

## Summary: How to Identify Each Race

| # | Look for | File | Line |
|---|----------|------|------|
| 1 | Duplicate process PIDs | mcpClient.ts | 66 |
| 2 | Status stuck in "starting" | WidgetProcessManager.ts | 87 |
| 3 | New servers don't auto-connect | MCPContext.tsx | 360 |
| 4 | "Session invalid" errors | mcpHttpClient.ts | 252 |
| 5 | "Can't update unmounted" warnings | MCPContext.tsx | 298 |
| 6 | Memory grows after widget cycles | WidgetHost.tsx | 331 |
| 7 | WebSocket drops silently | WidgetProcessManager.ts | 329 |
| 8 | Wrong pane shows in tab | TabsContext.tsx | 391 |

Use these reproduction steps to verify each bug exists, then verify fixes work.

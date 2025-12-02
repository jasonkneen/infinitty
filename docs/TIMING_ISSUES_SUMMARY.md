# Timing Issues - Executive Summary

## Quick Diagnosis: When Will These Bugs Appear?

### Bug #1: Double MCP Spawns
**When:** Rapid "Connect" button clicks or stale component callbacks
**User Experience:** Server appears to connect, then hangs or shows double connections
**File:** `mcpClient.ts` line 66

### Bug #2: Widget Won't Stop
**When:** User clicks "Stop Widget" while process is restarting
**User Experience:** Widget keeps restarting even after user stops it (feels broken)
**File:** `WidgetProcessManager.ts` line 87

### Bug #3: Servers Don't Auto-Connect After Add
**When:** User adds new server with auto-connect enabled
**User Experience:** New servers never auto-connect on app restart
**File:** `MCPContext.tsx` line 360

### Bug #4: Session ID Silent Failures
**When:** Multiple concurrent tool calls to MCP HTTP server
**User Experience:** Intermittent "session invalid" errors under load
**File:** `mcpHttpClient.ts` line 252

### Bug #5: State Updates After Unmount
**When:** User closes tab/window while MCP server is connecting (30s timeout)
**User Experience:** Console warnings, lost state, potential crashes
**File:** `MCPContext.tsx` line 298

### Bug #6: Widget Memory Leak
**When:** Create/destroy widgets multiple times
**User Experience:** App slows down over time, memory usage grows
**File:** `WidgetHost.tsx` line 331

### Bug #7: WebSocket Reconnection Fails Silent
**When:** Widget process WebSocket disconnects
**User Experience:** Widget becomes unresponsive, no error shown
**File:** `WidgetProcessManager.ts` line 329

### Bug #8: Tab Activation Wrong Pane
**When:** Rapid tab switching while tabs are being added
**User Experience:** Active pane shows from wrong tab
**File:** `TabsContext.tsx` line 391

---

## One-Line Root Causes

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | Double spawn | No guard on concurrent connect() calls | Add connectPromise guard |
| 2 | Won't stop | No flag tracking "stopping" state | Add stoppingWidgets Set |
| 3 | No auto-connect | Effect dependency array missing servers | Add to deps array |
| 4 | Session ID race | Multiple requests overwrite sessionId | Capture at request time |
| 5 | Unmount updates | No cancellation token for async ops | Use AbortController |
| 6 | Memory leak | Global registry never cleaned | Add cleanup effect |
| 7 | Silent WS fail | Error caught but not propagated | Remove catch, emit error |
| 8 | Wrong pane | Uses stale `tabs` variable | Use setState callback pattern |

---

## Danger Patterns to Hunt

**Pattern 1: Async wait with no guard**
```typescript
// DANGEROUS
async connect() {
  if (this.isConnected) return  // ← Check
  // User calls connect again here!
  await this.doAsyncThing()  // ← Long async gap
  this.isConnected = true  // ← State set
}
```

**Pattern 2: Global state mutated without lock**
```typescript
// DANGEROUS
const widgetRegistry = new Map()  // Global
widget.instances.set(id, instance)  // No synchronization
widgetRegistry.set(id, widget)  // Can race
```

**Pattern 3: useCallback with stale closure**
```typescript
// DANGEROUS
const handleConnect = useCallback(async (server) => {
  const status = serverStatuses[server.id]  // ← Stale!
  // ...
}, [serverStatuses])  // ← Missing deps
```

**Pattern 4: Promise chain with no error boundary**
```typescript
// DANGEROUS
connectServer(id).catch(err => {
  // Error silently logged, UI never updates
  console.error(err)
})
```

**Pattern 5: setTimeout without cancellation**
```typescript
// DANGEROUS
setTimeout(() => {
  if (process.status === 'running') {  // ← Stale check
    this.reconnect()  // ← Fires even after stop
  }
}, 1000)
```

---

## Testing Checklist

- [ ] Rapid connect/disconnect button clicks
- [ ] Network throttle to 5G speed (add 5s latency)
- [ ] Add server with auto-connect while app is starting
- [ ] Multiple concurrent tool calls
- [ ] Close tab while MCP server connecting
- [ ] Create/destroy 10 widgets in a loop
- [ ] Disconnect WebSocket simulator during widget run
- [ ] Switch tabs rapidly while adding tabs
- [ ] Reload app in middle of auto-connect sequence

---

## Impact Assessment

| Severity | Count | User Impact |
|----------|-------|-------------|
| Critical (ship blocker) | 5 | App crashes, data loss, hangs |
| High (bad UX) | 8 | Flaky features, weird behavior |
| Medium (code debt) | 12 | Tech debt, harder to debug future issues |

---

## Quick Fix Timeline

- **1 hour:** Fix #1 (double spawn guard)
- **1 hour:** Fix #2 (widget stop race)
- **30 min:** Fix #3 (auto-connect deps)
- **1 hour:** Fix #4 (HTTP session safety)
- **2 hours:** Fix #5 (AbortController) - requires architecture change
- **1 hour:** Fix #6 (widget registry cleanup)
- **30 min:** Fix #7 (WS error logging)
- **1 hour:** Fix #8 (tab closure)

**Total:** ~8 hours for all critical/high fixes

---

## Prevention Strategy Going Forward

1. **Think about async gaps:** Every `await` is a race window
2. **Make operations cancellable:** Always use AbortController for async context
3. **Guard concurrent entries:** Use promises or flags to prevent re-entrance
4. **Explicit dependencies:** Use ESLint rule to enforce useCallback/useEffect deps
5. **State machines for complex flows:** Not just booleans (isLoading) but state enums
6. **Instrument timing:** Log entry/exit of async operations with timestamps

```typescript
// SAFE PATTERN
private connectPromise: Promise<void> | null = null

async connect(): Promise<void> {
  if (this.connectPromise) return this.connectPromise

  this.connectPromise = (async () => {
    try {
      // Do the thing
    } catch (err) {
      this.emit('error', err)
      throw err
    } finally {
      this.connectPromise = null
    }
  })()

  return this.connectPromise
}
```

---

## Files with Most Issues

| File | Issues | Priority |
|------|--------|----------|
| `services/mcpClient.ts` | 2 critical + 1 high | Highest |
| `widget-host/WidgetProcessManager.ts` | 1 critical + 2 high | Highest |
| `contexts/MCPContext.tsx` | 2 critical + 1 high | Highest |
| `services/mcpHttpClient.ts` | 1 critical | High |
| `contexts/TabsContext.tsx` | 1 high + 2 medium | High |
| `components/MCPPanel.tsx` | 1 high | Medium |
| `widget-host/WidgetHost.tsx` | 1 high + 1 medium | Medium |

---

## Debugging Tips

**When races are suspected:**

1. Add logging with timestamps:
   ```typescript
   const start = performance.now()
   console.log(`[${start.toFixed(0)}ms] Event: connect start`)
   ```

2. Simulate slow network:
   ```typescript
   const slowFetch = (url, opts) => {
     return new Promise(r => setTimeout(r, 5000))
       .then(() => fetch(url, opts))
   }
   ```

3. Use Chrome DevTools to slow down async operations:
   - Throttle network to "Slow 4G"
   - Slow CPU to "10x slowdown"
   - Set breakpoints in async handlers

4. Check for orphaned processes:
   ```bash
   ps aux | grep node  # Look for stray widget processes
   lsof -i :3030      # Check port allocations
   ```

5. Watch for "setState" console warnings - indicates unmount race

---

## Conclusion

The codebase has **professional-quality race condition vulnerabilities** that manifest as:
- Intermittent hangs
- Zombie processes
- Silent state corruption
- Janky UI under load

They're not showstoppers today because:
1. No heavy concurrent usage yet
2. Fast local network (no latency to expose races)
3. Users not stress-testing in ways that trigger them

But they **will** bite you in production. Fix them before they're user-facing bugs.

The pattern is always the same: **async operations without guards, closures without dependencies, state without synchronization**. Fix the pattern, fix the problems.

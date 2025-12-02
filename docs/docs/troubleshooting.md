---
sidebar_position: 10
---

# Troubleshooting

Common issues and solutions.

## Build Issues

### "Module not found: '@infinitty/widget-sdk'"

**Problem:** TypeScript can't find the SDK module.

**Solutions:**

1. Install the SDK:
```bash
npm install @infinitty/widget-sdk
```

2. Check your import paths:
```typescript
// Correct
import { useWidgetSDK } from '@infinitty/widget-sdk'
import { createDevSimulator } from '@infinitty/widget-sdk/dev-simulator'

// Incorrect
import { useWidgetSDK } from './widget-sdk'
```

3. Update tsconfig.json:
```json
{
  "compilerOptions": {
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true
  }
}
```

### TypeScript Errors

**Problem:** Type checking fails during build.

**Solutions:**

1. Run type check:
```bash
npm run typecheck
```

2. Check for any types:
```bash
grep -r ": any" src/
```

3. Add proper types:
```typescript
// Bad
const result: any = api.showQuickPick(items)

// Good
const result: QuickPickItem | undefined = await api.showQuickPick(items)
```

### Vite Build Fails

**Problem:** Build completes but creates empty dist/

**Solutions:**

1. Check entry point in vite.config.ts:
```typescript
export default defineConfig({
  build: {
    lib: {
      entry: 'src/index.tsx',  // Correct path
      formats: ['es'],
    },
  },
})
```

2. Verify src/index.tsx exports correctly:
```typescript
export default defineWidget({/* ... */})
```

3. Clear cache:
```bash
rm -rf dist/ node_modules/.vite
npm run build
```

## Runtime Issues

### Widget Won't Display

**Problem:** Widget loads but no component appears.

**Possible causes:**

1. No Component exported:
```typescript
export default defineWidget({
  Component: MyComponent,  // Must export Component
})
```

2. Component throws error - check browser console

3. Context provider missing - ensure widget is wrapped with WidgetSDKContext

### "useWidgetSDK must be used within a WidgetSDKProvider"

**Problem:** SDK hook called outside context.

**Solution:**

Ensure component is wrapped in SDK context. This is typically handled automatically in the simulator/host, but if you're testing:

```typescript
import { WidgetSDKContext } from '@infinitty/widget-sdk'

<WidgetSDKContext.Provider value={{ context, api, events }}>
  <YourComponent />
</WidgetSDKContext.Provider>
```

### useEffect Running Too Many Times

**Problem:** useEffect dependency is missing or wrong.

**Solution:**

Check dependencies:
```typescript
// Bad - runs every render
useEffect(() => {
  console.log('Effect')
}, [api, events, context])  // Too many dependencies!

// Good - minimal dependencies
useEffect(() => {
  const sub = events.onDidResize(() => {})
  return () => sub.dispose()
}, [events])
```

## Storage Issues

### Storage.set() Not Persisting

**Problem:** Data not saved after calling setStorage().

**Possible causes:**

1. Not awaiting the promise:
```typescript
// Bad - doesn't wait for save
const handleSave = () => {
  setCount(42)  // Not awaited!
}

// Good
const handleSave = async () => {
  await setCount(42)
}
```

2. Widget unmounting before save completes - wrap in useEffect cleanup

3. Storage quota exceeded - check browser storage limits

### "Storage is undefined"

**Problem:** Storage accessed before initialization.

**Solution:**

Always provide default values:
```typescript
const [data, setData] = useStorage('key', defaultValue)  // defaultValue is required
```

Check for null:
```typescript
const handleClick = async () => {
  const currentData = data ?? defaultValue
  await setData(currentData + 1)
}
```

## API Issues

### "API method returns undefined"

**Problem:** API call seems to work but returns nothing.

**Solution:**

Check return types:
```typescript
// showMessage returns void
api.showMessage('hello')  // No return

// showQuickPick returns Promise
const result = await api.showQuickPick(items)  // Must await

// showInputBox returns Promise<string | undefined>
const text = await api.showInputBox()  // Can be undefined
if (text) {
  // Use text
}
```

### "Tool not found" Error

**Problem:** callTool() fails with "Tool not found"

**Possible causes:**

1. Tool not registered - ensure useTool() is called during activate
2. Tool name mismatch - check name spelling
3. Tool handler throws - check console for errors

**Solution:**

```typescript
// Register tool
useTool({
  name: 'my_tool',  // Exact name
  description: '...',
  inputSchema: schema,
  handler: async (args) => { /* ... */ },
})

// Call with exact name
const result = await api.callTool('my_tool', args)  // Must match!
```

### Clipboard Operations Fail

**Problem:** readClipboard() or writeClipboard() throws.

**Possible causes:**

1. Browser security restrictions - HTTPS required for clipboard in production
2. User denied permission - request permission
3. Invalid data - ensure text is string

**Solution:**

```typescript
try {
  const text = await api.readClipboard()
} catch (error) {
  api.showMessage('Clipboard access denied', 'error')
}

try {
  await api.writeClipboard(JSON.stringify(data))
} catch (error) {
  api.showMessage('Failed to copy', 'error')
}
```

## Event Issues

### Event Listener Never Called

**Problem:** onDidReceiveMessage not being triggered.

**Possible causes:**

1. No postMessage being called - verify sender is working
2. Event unsubscribed before message sent - check cleanup
3. Widget ID mismatch - verify target ID

**Solution:**

```typescript
// Ensure subscription stays active
useEffect(() => {
  const sub = events.onDidReceiveMessage((msg) => {
    console.log('Received:', msg)  // Should log
  })

  return () => sub.dispose()  // Cleanup on unmount only
}, [events])

// Send test message
useMessage((msg) => {
  console.log('Message:', msg)
})
```

### Memory Leak Warnings

**Problem:** Browser console shows subscription leak warnings.

**Solution:**

Always dispose subscriptions:
```typescript
// Bad - leak
events.onDidResize(() => {})

// Good
useEffect(() => {
  const sub = events.onDidResize(() => {})
  return () => sub.dispose()
}, [events])

// Or use disposable store
const { add, clear } = useDisposables()
add(events.onDidResize(() => {}))
// clear() in cleanup
```

## Dev Simulator Issues

### DevTools Panel Closed

**Problem:** Can't see DevTools in simulator.

**Solution:**

1. Click **🔧 DevTools** button in toolbar
2. Check `devTools: true` in simulator options:
```typescript
createDevSimulator(Widget, {
  devTools: true,  // Show dev panel
})
```

### Theme Toggle Not Working

**Problem:** Light/Dark button doesn't change theme.

**Possible causes:**

1. useTheme() not returning theme - check SDK context
2. Styles not using theme - verify color usage

**Solution:**

```typescript
const theme = useTheme()

return (
  <div style={{
    backgroundColor: theme.background,  // Use theme
    color: theme.foreground,
  }}>
    Content
  </div>
)
```

### Mock Tools Not Called

**Problem:** Registered tools don't show in DevTools.

**Solution:**

1. Verify tool registration in activate():
```typescript
api.registerTool({
  name: 'my_tool',
  /* ... */
})
```

2. Check tool appears in DevTools Tools tab

3. Call it to test:
```typescript
await api.callTool('my_tool', args)
```

## Testing Issues

### Tests Timeout

**Problem:** Tests hang or timeout.

**Possible causes:**

1. Async operation not awaited - use `await`
2. Promise never resolves - check mock implementations
3. Memory leak - infinite loops in useEffect

**Solution:**

```typescript
// Bad - doesn't wait
test('should fetch data', () => {
  api.showQuickPick(items)
})

// Good - awaits
test('should fetch data', async () => {
  const result = await api.showQuickPick(items)
  expect(result).toBeDefined()
})
```

### Mock SDK Context Not Working

**Problem:** useWidgetSDK() returns null or undefined.

**Solution:**

Provide complete mock:
```typescript
const mockContext = {
  widgetId: 'test',
  config: {},
  theme: { /* all colors */ },
  storage: {
    get: vi.fn(),
    set: vi.fn().mockResolvedValue(undefined),
    delete: vi.fn(),
    keys: vi.fn(() => []),
  },
  // ... all other properties
}
```

## Performance Issues

### Widget Slow to Render

**Problem:** Widget rendering is sluggish.

**Possible causes:**

1. Expensive computations in render - move to useMemo
2. Missing React.memo - memoize components
3. Large state updates - batch updates

**Solution:**

```typescript
// Memoize expensive computation
const sortedItems = useMemo(() => {
  return items.sort((a, b) => a.name.localeCompare(b.name))
}, [items])

// Memoize component
const ItemRow = React.memo(({ item }) => {
  return <div>{item.name}</div>
})
```

### Memory Usage Grows

**Problem:** Widget uses more memory over time.

**Possible causes:**

1. Event listeners not disposed - memory leak
2. setInterval/setTimeout not cleared - use cleanup
3. Large data cached - implement cleanup

**Solution:**

```typescript
useEffect(() => {
  const timer = setInterval(() => {}, 1000)
  return () => clearInterval(timer)  // Cleanup!
}, [])
```

## Getting Help

### Collect Debug Information

When reporting issues, gather:

1. Browser console errors
2. Widget logs (useLogger output)
3. Steps to reproduce
4. Widget manifest.json
5. Relevant code snippets

### Debug Checklist

- [ ] Run `npm run build` without errors
- [ ] Run tests: `npm run test`
- [ ] Check console for errors (F12)
- [ ] Verify manifest.json is valid
- [ ] Check dependencies are installed
- [ ] Clear node_modules if stuck: `rm -rf node_modules && npm install`
- [ ] Try in dev simulator: `npm run dev`
- [ ] Check latest SDK version

### Resources

- [SDK Documentation](./intro)
- [Examples](./examples/hello-world)
- [GitHub Issues](https://github.com/flows/hybrid-terminal/issues)
- [Type Definitions](./sdk-reference/types)

## Quick Solutions

| Issue | Solution |
|-------|----------|
| Build fails | `npm run build` and check errors |
| Types missing | Check imports, run `npm run typecheck` |
| Widget won't show | Check Component export, browser console |
| Storage not saving | Await setStorage(), check persistence |
| Tools not registered | Verify activate() is called |
| useEffect loops | Check dependencies |
| Memory leaks | Dispose subscriptions |
| Tests timeout | Await async operations |
| Theme not applied | Use theme colors in styles |
| DevTools missing | Click 🔧 button, set `devTools: true` |

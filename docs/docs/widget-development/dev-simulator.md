---
sidebar_position: 1
---

# Development Simulator

The Infinitty Widget Dev Simulator lets you test and develop widgets without running the full Infinitty application.

## Starting the Simulator

Run the dev server:

```bash
npm run dev
```

This starts a local dev server (usually on `http://localhost:5173`) with your widget loaded in the simulator environment.

## Simulator Features

### Theme Toggle

Switch between light and dark themes with the **☀️ Light/🌙 Dark** button in the toolbar.

Useful for:
- Testing color schemes
- Verifying contrast ratios
- Ensuring theme-aware styling works

### DevTools Panel

The right panel provides:

#### Messages Tab
View all messages displayed via `api.showMessage()`:
- Message type (info, warning, error)
- Timestamp
- Full message text

#### Tools Tab
Lists registered tools and tracks tool calls:
- **Registered Tools** - All tools your widget provides
- **Tool Calls** - History of calls with arguments and results

#### Config Tab
Edit widget configuration in real-time:
- Modify any config value
- Changes are immediate
- Send test messages to widget

## Configuration

### Initial Setup

Pass options when creating the simulator:

```typescript
// dev.tsx
import { createDevSimulator } from '@infinitty/widget-sdk/dev-simulator'
import MyWidget from './index'

createDevSimulator(MyWidget, {
  widgetId: 'com.example.my-widget',
  theme: 'dark',
  config: {
    apiKey: 'test-key',
    timeout: 5000,
  },
  size: { width: 800, height: 600 },
  devTools: true,
})
```

### Mock Tools

Provide mock implementations of tools:

```typescript
createDevSimulator(MyWidget, {
  mockTools: {
    search_docs: async (args) => {
      return [
        { title: 'Doc 1', url: 'https://...' },
        { title: 'Doc 2', url: 'https://...' },
      ]
    },
    calculate: async (args) => {
      return { result: args.a + args.b }
    },
  },
})
```

## Debugging Tips

### Console Logging

All logs appear in the browser console and DevTools panel:

```typescript
const logger = useLogger()

logger.trace('Detailed info')
logger.debug('Debug message')
logger.info('Information')
logger.warn('Warning message')
logger.error('Error message')
```

Open browser DevTools (F12) to see all logs.

### Component State Inspection

Use React DevTools browser extension:
1. Install React DevTools extension
2. Open browser DevTools (F12)
3. Go to "Components" tab
4. Inspect widget component tree
5. View props and state in real-time

### Storage Inspection

Check what's persisted in localStorage:

1. Open browser DevTools (F12)
2. Go to "Application" or "Storage" tab
3. Click "Local Storage"
4. Look for keys starting with `widget-dev:`
5. View and modify storage values

### Event Debugging

Track all events:

```typescript
function DebugComponent() {
  const { context, events } = useWidgetSDK()

  useEffect(() => {
    const handlers = {
      activate: () => context.log.info('onDidActivate'),
      deactivate: () => context.log.info('onWillDeactivate'),
      resize: (size) => context.log.info('onDidResize', size),
      visibility: (visible) => context.log.info('onDidChangeVisibility', visible),
      focus: () => context.log.info('onDidFocus'),
      blur: () => context.log.info('onDidBlur'),
      message: (msg) => context.log.info('onDidReceiveMessage', msg),
      config: (cfg) => context.log.info('onDidChangeConfig', cfg),
    }

    const subs = [
      events.onDidActivate(handlers.activate),
      events.onWillDeactivate(handlers.deactivate),
      events.onDidResize(handlers.resize),
      events.onDidChangeVisibility(handlers.visibility),
      events.onDidFocus(handlers.focus),
      events.onDidBlur(handlers.blur),
      events.onDidReceiveMessage(handlers.message),
      events.onDidChangeConfig(handlers.config),
    ]

    return () => subs.forEach(s => s.dispose())
  }, [context, events])

  return <div>Check console for events</div>
}
```

## Testing in Simulator

### Simulating Messages

In the Config tab under "SEND TEST MESSAGE":

```json
{
  "action": "update",
  "data": {
    "userId": 123,
    "name": "John"
  }
}
```

Press Cmd+Enter (or Ctrl+Enter) to send.

Your widget receives it via `useMessage()`:

```typescript
useMessage((message) => {
  console.log('Received:', message)
})
```

### Simulating Configuration Changes

Edit values in the Config tab to test how your widget responds to config changes:

```typescript
const timeout = useConfigValue('timeout', 5000)

useEffect(() => {
  console.log('Timeout changed:', timeout)
}, [timeout])
```

### Simulating Theme Changes

Click the theme toggle to test dark/light mode:

```typescript
const theme = useTheme()

useEffect(() => {
  console.log('Theme changed:', theme.background)
}, [theme])
```

### Simulating Resize

Resize your browser window to test responsive behavior:

```typescript
const { width, height } = useWidgetSize()

return (
  <div>
    <p>Size: {width}x{height}</p>
  </div>
)
```

## Common Testing Scenarios

### Test Message Handling

1. Register a message handler
2. Use DevTools to send a test message
3. Verify handler is called
4. Check console for output

### Test Tool Registration

1. Register a tool with useTool()
2. Check Tools tab shows registered tool
3. Mock tool in simulator options
4. Call api.callTool() and verify result

### Test Storage

1. Use useStorage() to save data
2. Modify value and save
3. Open browser Storage tab
4. Verify data in localStorage
5. Reload widget - data should persist

### Test Configuration

1. Define config in manifest
2. Edit in Config tab
3. Verify useConfig() updates
4. Check useEffect dependencies

## Performance Testing

### Monitor Re-renders

Wrap component with performance monitor:

```typescript
function PerformanceMonitor({ children }) {
  useEffect(() => {
    console.log('Render')
    return () => console.log('Unmount')
  })
  return children
}
```

Check console to see how often component re-renders.

### Memory Leaks

In DevTools:
1. Go to Memory tab
2. Take heap snapshot
3. Perform action multiple times
4. Take another snapshot
5. Compare - should not increase significantly

### Event Listener Leaks

Check that you're properly disposing subscriptions:

```typescript
// Good - disposed
useEffect(() => {
  const sub = events.onDidResize(() => {})
  return () => sub.dispose()
}, [events])

// Bad - not disposed
useEffect(() => {
  events.onDidResize(() => {})  // Memory leak!
}, [events])
```

## Troubleshooting

### DevTools Panel Won't Show

- Check `devTools: true` in options
- Verify browser console for errors
- Try hiding/showing with button

### Messages Not Appearing

- Verify `api.showMessage()` is being called
- Check console for errors
- Verify message type is 'info', 'warning', or 'error'

### Tools Not Registering

- Check useTool() dependencies
- Verify tool name matches registration
- Check inputSchema is valid JSON Schema

### Storage Not Persisting

- Open browser Storage > Local Storage
- Look for `widget-dev:` prefixed keys
- Clear storage if needed
- Check storage.set() is being called

### Theme Changes Not Applying

- Verify useTheme() is called
- Check theme object is being used in styles
- Try clicking theme toggle button

## Best Practices

1. **Use consistent dev configuration** - Create a `.devrc.json` for common settings
2. **Test all features** - Messages, tools, storage, config changes
3. **Check console regularly** - For errors and logs
4. **Use React DevTools** - Inspect component state and props
5. **Monitor performance** - Watch for memory leaks and excessive re-renders
6. **Clean up properly** - Dispose all subscriptions and resources

## Advanced: Custom Dev Simulator

Create a custom dev entry point:

```typescript
// src/dev.tsx
import { createDevSimulator, DARK_THEME } from '@infinitty/widget-sdk/dev-simulator'
import MyWidget from './index'

// Custom theme
const customTheme = {
  ...DARK_THEME,
  background: '#0a0e27',
  foreground: '#d4d4d4',
}

createDevSimulator(MyWidget, {
  widgetId: 'com.example.my-widget',
  theme: customTheme,
  config: {
    apiKey: process.env.DEV_API_KEY,
    environment: 'development',
  },
  size: { width: 1200, height: 800 },
  devTools: true,
  mockTools: {
    // Mock implementations
  },
})
```

Then in `package.json`:

```json
{
  "scripts": {
    "dev": "vite --config vite.dev.config.ts",
    "dev:prod": "vite"
  }
}
```

## Next Steps

- [Testing Widgets](testing-widgets)
- [Best Practices](best-practices)
- [Widget Examples](../examples/hello-world)

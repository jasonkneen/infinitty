---
sidebar_position: 1
---

# React Hooks Reference

The Infinitty Widget SDK provides React hooks to access widget functionality.

## useWidgetSDK

Access the full SDK context (context, api, events).

```typescript
const { context, api, events } = useWidgetSDK()
```

Must be used inside a widget component wrapped with `WidgetSDKContext.Provider`.

### Example

```typescript
function MyComponent() {
  const { context, api, events } = useWidgetSDK()

  return (
    <div>
      <h1>Widget: {context.widgetId}</h1>
      <button onClick={() => api.showMessage('Hello!')}>
        Show Message
      </button>
    </div>
  )
}
```

## useTheme

Get the current theme colors.

```typescript
const theme = useTheme()
```

Returns `ThemeColors` object with all terminal colors.

### Example

```typescript
function ThemedComponent() {
  const theme = useTheme()

  return (
    <div style={{
      backgroundColor: theme.background,
      color: theme.foreground,
    }}>
      <h1>Themed Content</h1>
    </div>
  )
}
```

### Available Colors

```typescript
{
  background: string
  foreground: string
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
  cursor: string
  cursorAccent: string
  selection: string
}
```

## useConfig

Get the widget's configuration.

```typescript
const config = useConfig<ConfigType>()
```

Or get a specific config value:

```typescript
const value = useConfigValue<ValueType>('key', defaultValue)
```

### Example

```typescript
interface WidgetConfig {
  apiKey: string
  timeout: number
  enabled: boolean
}

function ConfigWidget() {
  const config = useConfig<WidgetConfig>()
  const timeout = useConfigValue('timeout', 5000)

  return (
    <div>
      <p>API Key set: {config.apiKey ? 'Yes' : 'No'}</p>
      <p>Timeout: {timeout}ms</p>
    </div>
  )
}
```

## useStorage

Persist data per widget instance.

```typescript
const [value, setValue] = useStorage<T>('key', defaultValue)
```

Returns `[value, setValue]` tuple similar to `useState`.

### Example

```typescript
function CounterWidget() {
  const [count, setCount] = useStorage('count', 0)

  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={() => setCount((count ?? 0) + 1)}>
        Increment
      </button>
    </div>
  )
}
```

The value is persisted to disk and survives widget unmount/remount.

## useGlobalState

Access state shared across all instances of this widget.

```typescript
const [value, setValue] = useGlobalState<T>('key', defaultValue)
```

Same API as `useStorage`, but state is global to the widget type.

### Example

```typescript
function GlobalWidget() {
  const [shared, setShared] = useGlobalState('theme-pref', 'auto')

  return (
    <div>
      <p>Shared preference: {shared}</p>
      <select value={shared} onChange={(e) => setShared(e.target.value)}>
        <option>auto</option>
        <option>light</option>
        <option>dark</option>
      </select>
    </div>
  )
}
```

## useTool

Register a tool that Claude can call.

```typescript
useTool(
  { name, description, inputSchema },
  async (args) => { /* handler */ }
)
```

### Example

```typescript
import { z } from 'zod'

function ToolWidget() {
  useTool(
    {
      name: 'search_docs',
      description: 'Search the documentation',
      inputSchema: z.object({
        query: z.string(),
        limit: z.number().optional(),
      }),
    },
    async (args) => {
      const results = await searchDocs(args.query)
      return results.slice(0, args.limit ?? 10)
    }
  )

  return <div>Tool registered</div>
}
```

## useTools

Register multiple tools at once.

```typescript
useTools([
  {
    name: 'tool1',
    description: 'First tool',
    inputSchema: { type: 'object' },
    handler: async (args) => {},
  },
  {
    name: 'tool2',
    description: 'Second tool',
    inputSchema: { type: 'object' },
    handler: async (args) => {},
  },
])
```

## useCommand

Register a custom command.

```typescript
useCommand('my-widget.action', (...args) => {
  // Handle command
})
```

### Example

```typescript
function CommandWidget() {
  useCommand('my-widget.clear', () => {
    setData([])
    return true
  })

  return <div>Command registered</div>
}
```

## useMessage

Listen for messages sent to this widget.

```typescript
useMessage<MessageType>((message) => {
  // Handle message
})
```

### Example

```typescript
interface CustomMessage {
  action: string
  payload?: unknown
}

function MessageWidget() {
  useMessage<CustomMessage>((msg) => {
    if (msg.action === 'update') {
      console.log('Update received:', msg.payload)
    }
  })

  return <div>Listening for messages</div>
}
```

## useSendMessage

Send a message to another widget.

```typescript
const sendMessage = useSendMessage()

sendMessage(targetWidgetId, { action: 'update', data: {...} })
```

### Example

```typescript
function SenderWidget() {
  const sendMessage = useSendMessage()

  const notifyOtherWidget = () => {
    sendMessage('com.example.other-widget', {
      action: 'data-changed',
      data: { count: 42 },
    })
  }

  return (
    <button onClick={notifyOtherWidget}>
      Notify Other Widget
    </button>
  )
}
```

## useBroadcast

Listen for broadcast messages on a channel.

```typescript
useBroadcast<MessageType>('channel-name', (message) => {
  // Handle broadcast
})
```

### Example

```typescript
function BroadcastListener() {
  const [events, setEvents] = useState<string[]>([])

  useBroadcast<{ event: string }>('app-events', (msg) => {
    setEvents(prev => [...prev, msg.event])
  })

  return (
    <div>
      <h3>Events</h3>
      <ul>
        {events.map((e, i) => <li key={i}>{e}</li>)}
      </ul>
    </div>
  )
}
```

## useBroadcastSend

Send a broadcast message to all listeners.

```typescript
const broadcast = useBroadcastSend()

broadcast('channel-name', { message: 'data' })
```

### Example

```typescript
function BroadcastSender() {
  const broadcast = useBroadcastSend()

  const notifyAll = (event: string) => {
    broadcast('app-events', { event })
  }

  return (
    <button onClick={() => notifyAll('data-updated')}>
      Broadcast Event
    </button>
  )
}
```

## useWidgetSize

Get the widget's current dimensions.

```typescript
const { width, height } = useWidgetSize()
```

### Example

```typescript
function ResponsiveWidget() {
  const { width, height } = useWidgetSize()

  return (
    <div>
      <p>Size: {width}x{height}</p>
      {width < 400 ? (
        <CompactLayout />
      ) : (
        <FullLayout />
      )}
    </div>
  )
}
```

## useWidgetVisibility

Check if the widget is currently visible.

```typescript
const visible = useWidgetVisibility()
```

### Example

```typescript
function VisiblityAwareWidget() {
  const visible = useWidgetVisibility()

  useEffect(() => {
    if (visible) {
      // Start animation/polling
    } else {
      // Stop animation/polling
    }
  }, [visible])

  return <div>{visible ? 'Visible' : 'Hidden'}</div>
}
```

## useWidgetFocus

Check if the widget currently has focus.

```typescript
const focused = useWidgetFocus()
```

### Example

```typescript
function FocusAwareWidget() {
  const focused = useWidgetFocus()

  return (
    <div style={{
      border: focused ? '2px solid blue' : '2px solid gray',
    }}>
      {focused ? 'Focused' : 'Not Focused'}
    </div>
  )
}
```

## useLogger

Access the widget's logger.

```typescript
const logger = useLogger()
```

### Example

```typescript
function LoggingWidget() {
  const logger = useLogger()

  useEffect(() => {
    logger.debug('Component mounted')
    logger.info('Widget ready')

    return () => {
      logger.debug('Component unmounting')
    }
  }, [logger])

  return (
    <div>
      <button onClick={() => logger.warn('Warning logged')}>
        Log Warning
      </button>
    </div>
  )
}
```

### Log Levels

- `trace()` - Most detailed, development only
- `debug()` - Debug information
- `info()` - General information
- `warn()` - Warning messages
- `error()` - Error messages

## useDisposables

Manage multiple disposable resources.

```typescript
const { add, clear } = useDisposables()

const sub = events.onDidActivate(() => {})
add(sub)  // Add to managed list

clear()   // Dispose all at once
```

### Example

```typescript
function ResourceWidget() {
  const { context, events } = useWidgetSDK()
  const { add, clear } = useDisposables()

  useEffect(() => {
    // Register multiple subscriptions
    add(events.onDidActivate(() => {}))
    add(events.onDidFocus(() => {}))
    add(events.onDidBlur(() => {}))

    // Clean them all up on unmount
    return clear
  }, [context, events])

  return <div>Managing resources</div>
}
```

## Hook Dependencies

Always include the right dependencies in `useEffect`:

```typescript
// Good
useEffect(() => {
  const sub = events.onDidResize(handler)
  return () => sub.dispose()
}, [events])  // Include events as dependency

// Bad
useEffect(() => {
  const sub = events.onDidResize(handler)
  return () => sub.dispose()
}, [])  // Missing events dependency
```

## Next Steps

- [Host API Reference](host-api)
- [Types Reference](types)
- [Create Your First Widget](../getting-started/first-widget)

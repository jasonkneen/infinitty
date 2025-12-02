---
sidebar_position: 3
---

# Widget Lifecycle

Understanding the widget lifecycle helps you write better, more efficient widgets.

## Lifecycle Stages

```
┌─────────────────────────────────────────┐
│ 1. Discovery                            │
│ Widget is discovered and loaded         │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ 2. Activation                           │
│ activate() is called                    │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ 3. Mount (React)                        │
│ Component is rendered                   │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ 4. Running                              │
│ Widget responds to events/interactions  │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ 5. Unmount (React)                      │
│ Component is unmounted                  │
└────────────────┬────────────────────────┘
                 │
┌────────────────▼────────────────────────┐
│ 6. Deactivation                         │
│ deactivate() is called, cleanup occurs  │
└─────────────────────────────────────────┘
```

## Stage 1: Discovery

When Infinitty starts, it discovers widgets by:
1. Scanning the widgets directory
2. Reading each widget's `manifest.json`
3. Registering the widget metadata
4. Checking `activationEvents`

A widget's code is **not yet loaded** at this stage.

## Stage 2: Activation

The widget is activated when:
- An `activationEvent` is triggered
- The widget tab is opened
- A command is invoked
- A tool is called

When activated, the `activate()` function is called:

```typescript
export default defineWidget({
  id: 'com.example.my-widget',

  async activate(context, api, events) {
    console.log('Widget activated!')

    // Initialize widget-level state
    let globalCounter = 0

    // Register commands
    api.registerCommand('my-widget.increment', () => {
      globalCounter++
      api.showMessage(`Count: ${globalCounter}`)
    })

    // Register tools
    api.registerTool({
      name: 'get_count',
      description: 'Get current count',
      inputSchema: { type: 'object' },
      handler: async () => ({ count: globalCounter }),
    })

    // Listen to events
    const sub = events.onDidReceiveMessage((msg) => {
      context.log.debug('Message:', msg)
    })

    // Return cleanup function (optional)
    return () => {
      context.log.debug('Widget cleanup')
      sub.dispose()
    }
  },
})
```

### Activation Events

```json
"activationEvents": [
  "onStartup",                    // Load on app startup
  "onCommand:my-widget.action",   // Load when command invoked
  "onWidget:com.example.type",    // Load when widget type opened
  "onEvent:custom-event"          // Load on custom event
]
```

If no activation events are specified, the widget is lazy-loaded when first used.

## Stage 3: Mount (React)

After activation, if a React component is exported, it's mounted:

```typescript
export default defineWidget({
  Component: function MyWidget() {
    const { context, api, events } = useWidgetSDK()

    useEffect(() => {
      context.log.info('Component mounted')

      // Handle visibility changes
      const visibility = events.onDidChangeVisibility((visible) => {
        console.log('Visible:', visible)
      })

      return () => visibility.dispose()
    }, [context, events])

    return <div>Widget content</div>
  },
})
```

### Initialization in Component

Use `useEffect` with empty dependency array for initialization:

```typescript
useEffect(() => {
  // This runs once when component mounts
  console.log('Initialize widget UI')
}, [])
```

## Stage 4: Running

The widget is now active and interactive:

```typescript
function WidgetComponent() {
  const { api, context, events } = useWidgetSDK()
  const [count, setCount] = useStorage('count', 0)

  // Respond to user interaction
  const handleClick = async () => {
    const newCount = (count ?? 0) + 1
    await setCount(newCount)
  }

  // Listen to events
  useEffect(() => {
    const resize = events.onDidResize(({ width, height }) => {
      context.log.debug(`Resized to ${width}x${height}`)
    })

    const focus = events.onDidFocus(() => {
      context.log.debug('Widget focused')
    })

    return () => {
      resize.dispose()
      focus.dispose()
    }
  }, [context, events])

  return (
    <button onClick={handleClick}>
      Count: {count}
    </button>
  )
}
```

## Stage 5: Unmount (React)

When the widget tab is closed or hidden, the React component unmounts:

```typescript
useEffect(() => {
  return () => {
    // Cleanup code runs here
    console.log('Component unmounting')
  }
}, [])
```

Cleanup should:
- Dispose of event subscriptions
- Cancel pending async operations
- Save important state
- Release resources (workers, connections, etc)

## Stage 6: Deactivation

When the widget is unloaded, `deactivate()` is called:

```typescript
export default defineWidget({
  deactivate() {
    console.log('Widget deactivating')
    // Clean up widget-level resources
  },
})
```

Deactivation happens when:
- Infinitty shuts down
- Widget is uninstalled
- Widget encounters unrecoverable error

### Best Practices for Deactivation

```typescript
let subscription
let worker

export default defineWidget({
  activate(context, api, events) {
    // Start resources
    subscription = events.onDidActivate(() => {})
    worker = new Worker('worker.js')

    // Return cleanup
    return () => {
      subscription?.dispose()
      worker?.terminate()
    }
  },

  deactivate() {
    // Final cleanup
    subscription?.dispose()
    worker?.terminate()
  },
})
```

## State Management Across Lifecycle

### Instance Storage (per widget instance)

```typescript
// Persists between unmount and remount
const [saved, setSaved] = useStorage('key', defaultValue)
```

### Global State (per widget type)

```typescript
// Shared across all instances
const [shared, setShared] = useGlobalState('key', defaultValue)
```

### Component State (ephemeral)

```typescript
// Lost when component unmounts
const [temp, setTemp] = useState(initialValue)
```

## Complete Lifecycle Example

```typescript
import { defineWidget } from '@infinitty/widget-sdk'
import { useEffect, useState } from 'react'
import { useWidgetSDK, useStorage } from '@infinitty/widget-sdk'

let widgetState = { initialized: false }

export default defineWidget({
  id: 'com.example.lifecycle-demo',
  name: 'Lifecycle Demo',
  version: '1.0.0',

  async activate(context, api, events) {
    context.log.info('1. ACTIVATE - Widget loaded')
    widgetState.initialized = true

    // Register command
    api.registerCommand('my-widget.refresh', async () => {
      api.showMessage('Refreshing...')
    })

    // Return cleanup function
    return () => {
      context.log.info('6. DEACTIVATE - Cleanup')
    }
  },

  Component() {
    const { context, events } = useWidgetSDK()
    const [count, setCount] = useStorage('count', 0)
    const [temp, setTemp] = useState(0)

    useEffect(() => {
      context.log.info('3. MOUNT - Component mounted')

      // Setup lifecycle listeners
      const visibility = events.onDidChangeVisibility((visible) => {
        context.log.info(`4. VISIBILITY: ${visible ? 'shown' : 'hidden'}`)
      })

      const resize = events.onDidResize(({ width, height }) => {
        context.log.debug(`RESIZE: ${width}x${height}`)
      })

      // Cleanup on unmount
      return () => {
        context.log.info('5. UNMOUNT - Component cleanup')
        visibility.dispose()
        resize.dispose()
      }
    }, [context, events])

    return (
      <div style={{ padding: '20px' }}>
        <h2>Lifecycle Demo</h2>
        <p>Persistent Count: {count}</p>
        <p>Temp State: {temp}</p>
        <button onClick={() => setCount((count ?? 0) + 1)}>
          Increment Persistent
        </button>
        <button onClick={() => setTemp(temp + 1)}>
          Increment Temp
        </button>
        <p style={{ fontSize: '12px', opacity: 0.6 }}>
          Check console for lifecycle logs
        </p>
      </div>
    )
  },
})
```

## Error Handling in Lifecycle

Always handle errors in async operations:

```typescript
async activate(context, api, events) {
  try {
    // Do setup
    const config = await api.executeCommand('load-config')
  } catch (error) {
    context.log.error('Activation failed:', error)
    api.showMessage('Widget failed to load', 'error')
    // Still return cleanup function
    return () => {}
  }
}
```

## Performance Considerations

1. **Lazy Activation** - Don't use `onStartup` unless necessary
2. **Event Cleanup** - Always dispose subscriptions
3. **Memory Leaks** - Watch for uncleaned event listeners
4. **Large Data** - Use instance storage for data larger than state
5. **Background Tasks** - Consider workers for heavy computation

## Next Steps

- [SDK Reference - Hooks](../sdk-reference/hooks)
- [SDK Reference - Types](../sdk-reference/types)
- [Widget Development Guide](../widget-development/dev-simulator)

---
sidebar_position: 4
---

# Utilities Reference

Helper functions and utilities provided by the SDK.

## Core Utilities

### defineWidget

Define a widget module with activation and component.

```typescript
function defineWidget(definition: {
  id: string
  name: string
  version: string
  description?: string
  activate?: (context, api, events) => void | Promise<void>
  deactivate?: () => void | Promise<void>
  Component?: React.ComponentType<WidgetComponentProps>
}): WidgetModule
```

**Example:**

```typescript
import { defineWidget } from '@infinitty/widget-sdk'

export default defineWidget({
  id: 'com.example.widget',
  name: 'My Widget',
  version: '1.0.0',
  description: 'A helpful widget',

  activate(context, api, events) {
    context.log.info('Widget activated')
  },

  deactivate() {
    console.log('Cleanup')
  },

  Component() {
    return <div>Widget UI</div>
  },
})
```

### createEventEmitter

Create a custom event emitter.

```typescript
function createEventEmitter<T>(): EventEmitter<T>
```

**Example:**

```typescript
import { createEventEmitter } from '@infinitty/widget-sdk'

const myEmitter = createEventEmitter<string>()

// Fire events
myEmitter.fire('hello')

// Listen to events
myEmitter.event((message) => {
  console.log('Event:', message)
})

// Cleanup
myEmitter.dispose()
```

### toDisposable

Convert a function to a Disposable.

```typescript
function toDisposable(fn: () => void): Disposable
```

**Example:**

```typescript
import { toDisposable } from '@infinitty/widget-sdk'

const disposable = toDisposable(() => {
  console.log('Disposing')
})

disposable.dispose()
```

### DisposableStore

Manage multiple disposables.

```typescript
class DisposableStore implements Disposable {
  add<T extends Disposable>(disposable: T): T
  dispose(): void
}
```

**Example:**

```typescript
import { DisposableStore } from '@infinitty/widget-sdk'

const store = new DisposableStore()

const sub1 = events.onDidActivate(() => {})
const sub2 = events.onDidFocus(() => {})

store.add(sub1)
store.add(sub2)

// Dispose all at once
store.dispose()
```

## Async Utilities

### createDeferredPromise

Create a promise you can resolve/reject from outside.

```typescript
function createDeferredPromise<T>(): DeferredPromise<T>
```

**Example:**

```typescript
import { createDeferredPromise } from '@infinitty/widget-sdk'

const deferred = createDeferredPromise<string>()

// Resolve from somewhere else
setTimeout(() => {
  deferred.resolve('Done!')
}, 1000)

// Wait for it
const result = await deferred.promise
console.log(result)  // 'Done!'
```

Use cases:
- Bridging callback-based APIs to promises
- External event coordination
- Custom async control flow

## Performance Utilities

### throttle

Limit function call frequency.

```typescript
function throttle<T extends (...args: unknown[]) => void>(
  fn: T,
  limit: number
): T
```

**Example:**

```typescript
import { throttle } from '@infinitty/widget-sdk'

const handleResize = throttle((width: number, height: number) => {
  console.log(`Resized: ${width}x${height}`)
}, 500)  // Max once per 500ms

window.addEventListener('resize', () => {
  handleResize(window.innerWidth, window.innerHeight)
})
```

Use cases:
- Resize events
- Scroll events
- Frequent input events
- Performance optimization

### debounce

Delay function execution until activity stops.

```typescript
function debounce<T extends (...args: unknown[]) => void>(
  fn: T,
  delay: number
): T
```

**Example:**

```typescript
import { debounce } from '@infinitty/widget-sdk'

const saveData = debounce((data: any) => {
  console.log('Saving:', data)
}, 1000)  // Wait 1s after typing stops

const handleInputChange = (value: string) => {
  saveData(value)
}
```

Use cases:
- Search input
- Auto-save
- Form validation
- API calls on user input

## Comparison

| Feature | throttle | debounce |
|---------|----------|----------|
| Purpose | Limit frequency | Wait for pause |
| Call count | Multiple | Single at end |
| Timing | Regular intervals | Delayed |
| Best for | Resize/scroll | Search/save |

## Dev Simulator Utilities

### createDevSimulator

Run widgets in development mode locally.

```typescript
function createDevSimulator(
  widget: WidgetModule,
  options?: DevSimulatorOptions
): void
```

**Options:**

```typescript
interface DevSimulatorOptions {
  widgetId?: string              // Override widget ID
  theme?: 'dark' | 'light' | ThemeColors  // Initial theme
  config?: Record<string, unknown>  // Initial config
  size?: { width: number; height: number }  // Window size
  containerId?: string            // DOM element ID
  devTools?: boolean              // Show dev panel
  mockTools?: Record<string, (args) => Promise<unknown>>  // Mock tools
}
```

**Example:**

```typescript
// In your dev entry (e.g., dev.tsx)
import { createDevSimulator, DARK_THEME } from '@infinitty/widget-sdk/dev-simulator'
import MyWidget from './index'

createDevSimulator(MyWidget, {
  widgetId: 'com.example.test',
  theme: DARK_THEME,
  config: { myOption: 'test-value' },
  size: { width: 800, height: 600 },
  devTools: true,
  mockTools: {
    my_tool: async (args) => ({ success: true }),
  },
})
```

### isDevMode

Check if widget is running in dev simulator.

```typescript
function isDevMode(): boolean
```

**Example:**

```typescript
import { isDevMode } from '@infinitty/widget-sdk/dev-simulator'

if (isDevMode()) {
  console.log('Running in dev simulator')
  // Can enable debug features
}
```

### Theme Presets

Pre-defined color schemes.

```typescript
import { DARK_THEME, LIGHT_THEME } from '@infinitty/widget-sdk/dev-simulator'

createDevSimulator(MyWidget, {
  theme: DARK_THEME,  // or LIGHT_THEME
})
```

## Hook Utilities

### useDisposables

Manage resource cleanup.

```typescript
function useDisposables(): {
  add(disposable: Disposable): void
  clear(): void
}
```

**Example:**

```typescript
import { useDisposables } from '@infinitty/widget-sdk'

function MyComponent() {
  const { add, clear } = useDisposables()

  useEffect(() => {
    add(events.onDidActivate(() => {}))
    add(events.onDidFocus(() => {}))

    return clear  // Cleanup all on unmount
  }, [])

  return <div>Content</div>
}
```

## Context & Provider

### WidgetSDKContext

React context for SDK access.

```typescript
const { context, api, events } = useContext(WidgetSDKContext)
```

Must wrap components with provider:

```typescript
<WidgetSDKContext.Provider value={{ context, api, events }}>
  <YourComponent />
</WidgetSDKContext.Provider>
```

## Validation

### JSON Schema Validation

For tool input schemas, use Zod:

```typescript
import { z } from 'zod'

const schema = z.object({
  name: z.string().min(1),
  age: z.number().positive(),
  email: z.string().email().optional(),
})

useTool(
  {
    name: 'create_user',
    description: 'Create a user',
    inputSchema: schema,
  },
  async (args) => {
    // args is typed and validated
    const validated = schema.parse(args)
    return { userId: 123 }
  }
)
```

## Common Patterns

### Safe Event Subscription

```typescript
function useSafeEvent(event: Event<T>, handler: (e: T) => void) {
  const { add, clear } = useDisposables()

  useEffect(() => {
    add(event(handler))
    return clear
  }, [event, handler])
}
```

### Protected Async State

```typescript
async function safeSetState<T>(
  setter: (value: T) => Promise<void>,
  value: T,
  onError?: (error: unknown) => void
) {
  try {
    await setter(value)
  } catch (error) {
    onError?.(error)
  }
}
```

### Retry Logic

```typescript
async function retryAsync<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  delay = 1000
): Promise<T> {
  let lastError
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn()
    } catch (error) {
      lastError = error
      await new Promise(r => setTimeout(r, delay))
    }
  }
  throw lastError
}
```

## Best Practices

1. **Always dispose resources** - Use DisposableStore or useDisposables
2. **Clean up in useEffect** - Return cleanup function
3. **Use throttle/debounce** - For high-frequency events
4. **Validate with Zod** - For tool input schemas
5. **Handle errors gracefully** - Use try-catch in async code
6. **Avoid memory leaks** - Dispose subscriptions on unmount

## Next Steps

- [Hooks Reference](hooks)
- [Types Reference](types)
- [Widget Development](../widget-development/best-practices)

---
sidebar_position: 1
---

# Widget SDK Overview

The Infinitty Widget SDK provides everything you need to build extensions for the Infinitty terminal.

## Architecture

The Widget SDK is built on a layered architecture:

```
┌────────────────────────────────────┐
│   Your Widget (React Component)     │
├────────────────────────────────────┤
│   SDK Hooks & Utilities             │
│   (useTheme, useStorage, useTool)   │
├────────────────────────────────────┤
│   Widget Context & Events           │
│   (WidgetContext, WidgetEvents)     │
├────────────────────────────────────┤
│   Host API                          │
│   (UI, Commands, Tools, etc)        │
├────────────────────────────────────┤
│   Infinitty Core                    │
│   (Terminal, File System, etc)      │
└────────────────────────────────────┘
```

## Core Concepts

### Widget Manifest

Every widget has a `manifest.json` that declares its capabilities:

```json
{
  "id": "com.example.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "activationEvents": ["onStartup"],
  "contributes": {
    "commands": [],
    "tools": [],
    "configuration": {}
  }
}
```

### Widget Context

The `WidgetContext` provides access to widget metadata and system resources:

```typescript
interface WidgetContext {
  widgetId: string
  widgetType: string
  instanceId: string
  config: Record<string, unknown>
  theme: ThemeColors
  storage: WidgetStorage
  globalState: WidgetStorage
  secrets: SecretsStorage
  log: WidgetLogger
}
```

### Host API

The `WidgetHostAPI` is your bridge to Infinitty's features:

```typescript
interface WidgetHostAPI {
  // UI
  showMessage(message: string, type?: 'info' | 'warning' | 'error'): void
  showQuickPick<T>(items: T[]): Promise<T | undefined>
  showInputBox(options?: InputBoxOptions): Promise<string | undefined>

  // Commands
  executeCommand(id: string, ...args: unknown[]): Promise<unknown>
  registerCommand(id: string, handler: (...args: unknown[]) => unknown): Disposable

  // Tools (AI/MCP)
  registerTool(tool: ToolDefinition): Disposable
  callTool(name: string, args: Record<string, unknown>): Promise<unknown>

  // Clipboard
  readClipboard(): Promise<string>
  writeClipboard(text: string): Promise<void>

  // Inter-widget communication
  postMessage(targetId: string, message: unknown): void
  broadcast(channel: string, message: unknown): void
  subscribe(channel: string, handler: (message: unknown) => void): Disposable

  // And more...
}
```

### Events

The `WidgetEvents` interface provides lifecycle and activity events:

```typescript
interface WidgetEvents {
  onDidActivate: Event<void>
  onWillDeactivate: Event<void>
  onDidResize: Event<{ width: number; height: number }>
  onDidChangeVisibility: Event<boolean>
  onDidFocus: Event<void>
  onDidBlur: Event<void>
  onDidReceiveMessage: Event<unknown>
  onDidChangeConfig: Event<Record<string, unknown>>
}
```

## Widget Lifecycle

Widgets follow a predictable lifecycle:

1. **Creation** - Widget instance is created
2. **Activation** - `activate()` is called, widget initializes
3. **Mount** - React component is mounted if provided
4. **Runtime** - Widget responds to events and user interaction
5. **Unmount** - React component is unmounted
6. **Deactivation** - `deactivate()` is called for cleanup

```typescript
import { defineWidget } from '@infinitty/widget-sdk'

export default defineWidget({
  id: 'com.example.widget',
  name: 'My Widget',
  version: '1.0.0',

  async activate(context, api, events) {
    // Initialize widget
    context.log.info('Widget activated')

    // Register event listeners
    const subscription = events.onDidReceiveMessage((message) => {
      context.log.debug('Received message', message)
    })

    // Store disposable for cleanup
    return () => subscription.dispose()
  },

  deactivate() {
    // Clean up resources
    console.log('Widget deactivated')
  },

  Component: MyWidgetComponent,
})
```

## Storage Layers

Infinitty provides three storage layers:

### Instance Storage

Persisted per widget instance, local to this specific instance:

```typescript
const [value, setValue] = useStorage('key', defaultValue)
await setValue(newValue)
```

### Global State

Shared across all instances of this widget type:

```typescript
const [sharedValue, setSharedValue] = useGlobalState('key', defaultValue)
```

### Secrets Storage

Encrypted storage for sensitive data like API keys:

```typescript
const secret = await context.secrets.get('api-key')
await context.secrets.store('api-key', 'secret-value')
```

## Tools & AI Integration

Register AI tools that Claude and other models can use:

```typescript
const useTool('my_tool', {
  description: 'Do something useful',
  inputSchema: z.object({
    input: z.string(),
  }),
}, async (args) => {
  return { result: 'success' }
})
```

## Inter-widget Communication

Widgets can communicate with each other:

```typescript
// Widget A sends message to Widget B
api.postMessage('widget-b-id', { action: 'update', data: {...} })

// Widget B listens
useMessage((message) => {
  console.log('Received:', message)
})

// Or use broadcast channels
api.broadcast('channel-name', { data: 'shared' })

useBroadcast('channel-name', (message) => {
  console.log('Broadcast received:', message)
})
```

## React Hooks

The SDK provides React hooks for common tasks:

- **`useWidgetSDK()`** - Access full SDK context
- **`useTheme()`** - Get current theme colors
- **`useConfig()`** - Access widget configuration
- **`useStorage()`** - Persist instance data
- **`useGlobalState()`** - Shared widget state
- **`useTool()`** - Register AI tools
- **`useCommand()`** - Register commands
- **`useMessage()`** - Receive widget messages
- **`useBroadcast()`** - Subscribe to broadcast channels
- **`useLogger()`** - Access logging
- **`useWidgetSize()`** - Get widget dimensions
- **`useWidgetVisibility()`** - Check visibility
- **`useWidgetFocus()`** - Check focus state

## Execution Models

Widgets can run in different execution contexts:

- **Inline** (default) - React component directly in Infinitty
- **Process** - Separate Node.js process with IPC communication
- **WebWorker** - Browser WebWorker for heavy computation

```json
{
  "executionModel": "inline",
  "port": 3000
}
```

## TypeScript Support

The SDK is fully typed with TypeScript:

```typescript
import type {
  WidgetContext,
  WidgetHostAPI,
  WidgetEvents,
  WidgetManifest,
  WidgetStorage,
  ThemeColors,
} from '@infinitty/widget-sdk'

import {
  defineWidget,
  createEventEmitter,
  useWidgetSDK,
  useTheme,
  useStorage,
} from '@infinitty/widget-sdk'
```

## Error Handling

Always handle errors gracefully:

```typescript
async function riskyOperation() {
  try {
    const result = await api.executeCommand('some-command')
    return result
  } catch (error) {
    context.log.error('Command failed:', error)
    api.showMessage('Operation failed', 'error')
    return null
  }
}
```

## Development Simulator

The SDK includes a development simulator for local testing without Infinitty:

```bash
npm run dev
```

The simulator provides:
- Full mock implementations of all APIs
- Real-time hot reloading
- DevTools panel for debugging
- Theme switching
- Configuration editing
- Message inspection

## Next Steps

- [Widget Manifest Reference](manifest)
- [Widget Lifecycle](lifecycle)
- [SDK Reference - Hooks](../sdk-reference/hooks)
- [SDK Reference - Host API](../sdk-reference/host-api)

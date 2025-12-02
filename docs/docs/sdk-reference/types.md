---
sidebar_position: 3
---

# Types Reference

TypeScript type definitions for the Infinitty Widget SDK.

## Widget Manifest

```typescript
interface WidgetManifest {
  // Identity
  id: string                    // Unique ID: com.vendor.name
  name: string                  // Display name
  version: string               // Semantic version
  description?: string
  author?: string | AuthorInfo
  license?: string
  icon?: string

  // Entry points
  main: string                  // Main JS entry
  ui?: string                   // React component entry
  styles?: string               // CSS stylesheet

  // Execution model
  executionModel?: 'inline' | 'process' | 'webworker'
  port?: number

  // Capabilities
  activationEvents?: ActivationEvent[]
  contributes?: Contributes
  engines?: { infinitty: string }
  dependencies?: Record<string, string>
}

type ActivationEvent =
  | 'onStartup'
  | `onCommand:${string}`
  | `onWidget:${string}`
  | `onEvent:${string}`
```

## Widget Context

```typescript
interface WidgetContext {
  // Identity
  widgetId: string
  widgetType: string
  instanceId: string

  // Configuration
  config: Record<string, unknown>
  getConfig<T>(key: string, defaultValue?: T): T | undefined

  // Theme
  theme: ThemeColors
  onThemeChange(callback: (theme: ThemeColors) => void): Disposable

  // Storage
  storage: WidgetStorage
  globalState: WidgetStorage
  secrets: SecretsStorage

  // Utilities
  log: WidgetLogger
  extensionPath: string
  extensionUri: string
}
```

## Theme Colors

```typescript
interface ThemeColors {
  // Base colors
  background: string
  foreground: string

  // ANSI colors
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string

  // Bright ANSI colors
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string

  // UI colors
  cursor: string
  cursorAccent: string
  selection: string
  selectionBackground: string
}
```

## Storage

```typescript
interface WidgetStorage {
  get<T>(key: string, defaultValue?: T): T | undefined
  set(key: string, value: unknown): Promise<void>
  delete(key: string): Promise<void>
  keys(): string[]
}

interface SecretsStorage {
  get(key: string): Promise<string | undefined>
  store(key: string, value: string): Promise<void>
  delete(key: string): Promise<void>
}
```

## Logger

```typescript
interface WidgetLogger {
  trace(message: string, ...args: unknown[]): void
  debug(message: string, ...args: unknown[]): void
  info(message: string, ...args: unknown[]): void
  warn(message: string, ...args: unknown[]): void
  error(message: string, ...args: unknown[]): void
}
```

## Events

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

type Event<T> = (listener: (e: T) => void) => Disposable
```

## Event Emitter

```typescript
interface EventEmitter<T> {
  event: Event<T>
  fire(data: T): void
  dispose(): void
}
```

## UI Types

```typescript
interface QuickPickItem {
  label: string
  description?: string
  detail?: string
  picked?: boolean
  alwaysShow?: boolean
}

interface QuickPickOptions {
  title?: string
  placeholder?: string
  canPickMany?: boolean
  matchOnDescription?: boolean
  matchOnDetail?: boolean
}

interface InputBoxOptions {
  title?: string
  placeholder?: string
  value?: string
  password?: boolean
  validateInput?(value: string): string | undefined
}

interface Progress {
  report(value: { message?: string; increment?: number }): void
}

interface ProgressOptions {
  title: string
  cancellable?: boolean
}
```

## Tool Definition

```typescript
interface ToolDefinition {
  name: string
  description: string
  inputSchema: Record<string, unknown> | z.ZodType
  handler(args: Record<string, unknown>): Promise<unknown>
}

interface ToolContribution {
  name: string
  description: string
  inputSchema: Record<string, unknown>  // JSON Schema
}
```

## File System

```typescript
interface OpenDialogOptions {
  title?: string
  defaultPath?: string
  filters?: { name: string; extensions: string[] }[]
  canSelectFiles?: boolean
  canSelectFolders?: boolean
  canSelectMany?: boolean
}

interface SaveDialogOptions {
  title?: string
  defaultPath?: string
  filters?: { name: string; extensions: string[] }[]
}
```

## Terminal

```typescript
interface TerminalOptions {
  name?: string
  cwd?: string
  env?: Record<string, string>
  shellPath?: string
  shellArgs?: string[]
}

interface TerminalInstance {
  id: string
  name: string
  sendText(text: string, addNewLine?: boolean): void
  show(preserveFocus?: boolean): void
  hide(): void
  dispose(): void
}
```

## Widget Component

```typescript
interface WidgetComponentProps {
  context: WidgetContext
  api: WidgetHostAPI
  events: WidgetEvents
}

interface WidgetModule {
  activate(
    context: WidgetContext,
    api: WidgetHostAPI,
    events: WidgetEvents
  ): void | Promise<void>

  deactivate?(): void | Promise<void>

  Component?: React.ComponentType<WidgetComponentProps>
}
```

## Disposable

```typescript
interface Disposable {
  dispose(): void
}

class DisposableStore implements Disposable {
  add<T extends Disposable>(disposable: T): T
  dispose(): void
}
```

## Deferred Promise

```typescript
interface DeferredPromise<T> {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (error: unknown) => void
}
```

## Configuration

```typescript
interface ConfigurationContribution {
  title: string
  properties: Record<string, ConfigPropertySchema>
}

interface ConfigPropertySchema {
  type: 'string' | 'number' | 'boolean' | 'array' | 'object'
  default?: unknown
  description?: string
  enum?: unknown[]
  enumDescriptions?: string[]
  minimum?: number
  maximum?: number
}
```

## Contributes

```typescript
interface Contributes {
  tools?: ToolContribution[]
  commands?: CommandContribution[]
  configuration?: ConfigurationContribution
  menus?: MenuContribution[]
}

interface CommandContribution {
  id: string
  title: string
  category?: string
  icon?: string
  shortcut?: string
}

interface MenuContribution {
  command: string
  group?: string
  when?: string
}
```

## Usage Examples

### Creating typed widget

```typescript
import type { WidgetContext, WidgetHostAPI, WidgetEvents } from '@infinitty/widget-sdk'
import { defineWidget } from '@infinitty/widget-sdk'

export default defineWidget({
  id: 'com.example.typed',
  name: 'Typed Widget',
  version: '1.0.0',

  activate(context: WidgetContext, api: WidgetHostAPI, events: WidgetEvents) {
    context.log.info('Initialized with full types')
  },
})
```

### Typed storage

```typescript
interface UserData {
  name: string
  email: string
  count: number
}

const [data, setData] = useStorage<UserData>('user', {
  name: '',
  email: '',
  count: 0,
})
```

### Typed configuration

```typescript
interface WidgetConfig {
  apiKey: string
  timeout: number
  enabled: boolean
}

const config = useConfig<WidgetConfig>()
```

### Typed tool

```typescript
import { z } from 'zod'

const InputSchema = z.object({
  query: z.string().describe('Search query'),
  limit: z.number().optional().describe('Result limit'),
})

useTool(
  {
    name: 'search',
    description: 'Search items',
    inputSchema: InputSchema,
  },
  async (args) => {
    // args is fully typed
    const results = await search(args.query, args.limit)
    return results
  }
)
```

## Next Steps

- [Hooks Reference](hooks)
- [Host API Reference](host-api)
- [Utilities Reference](utilities)

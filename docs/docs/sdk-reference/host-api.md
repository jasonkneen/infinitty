---
sidebar_position: 2
---

# Host API Reference

The WidgetHostAPI provides access to Infinitty's functionality.

## UI Methods

### showMessage

Display a message to the user.

```typescript
api.showMessage(message: string, type?: 'info' | 'warning' | 'error'): void
```

**Parameters:**
- `message` (string) - The message to display
- `type` (optional) - Message type: 'info', 'warning', or 'error'

**Example:**

```typescript
api.showMessage('Operation completed', 'info')
api.showMessage('Warning: This action may not be reversible', 'warning')
api.showMessage('An error occurred', 'error')
```

### showQuickPick

Show a selection menu with multiple options.

```typescript
api.showQuickPick<T extends QuickPickItem>(
  items: T[],
  options?: QuickPickOptions
): Promise<T | undefined>
```

**Parameters:**
- `items` - Array of items to choose from
- `options` - Optional configuration

**Returns:** Promise resolving to selected item or undefined

**Example:**

```typescript
const result = await api.showQuickPick([
  { label: 'Option 1', description: 'First choice' },
  { label: 'Option 2', description: 'Second choice' },
  { label: 'Option 3', description: 'Third choice' },
], {
  title: 'Choose an option',
  placeholder: 'Select one...',
  canPickMany: false,
})

if (result) {
  console.log('Selected:', result.label)
}
```

**QuickPickOptions:**
- `title` (string) - Dialog title
- `placeholder` (string) - Placeholder text
- `canPickMany` (boolean) - Allow multiple selections
- `matchOnDescription` (boolean) - Filter on descriptions
- `matchOnDetail` (boolean) - Filter on details

### showInputBox

Request text input from the user.

```typescript
api.showInputBox(options?: InputBoxOptions): Promise<string | undefined>
```

**Parameters:**
- `options` - Optional configuration

**Returns:** Promise resolving to input string or undefined

**Example:**

```typescript
const name = await api.showInputBox({
  title: 'Enter your name',
  placeholder: 'John Doe',
  validateInput: (value) => {
    if (value.length < 2) {
      return 'Name too short'
    }
    return undefined  // Valid
  },
})

if (name) {
  console.log('Hello,', name)
}
```

**InputBoxOptions:**
- `title` (string) - Dialog title
- `placeholder` (string) - Placeholder text
- `value` (string) - Default value
- `password` (boolean) - Hide input for passwords
- `validateInput` (function) - Validation callback

### showProgress

Show a progress indicator while performing a task.

```typescript
api.showProgress<T>(
  task: (progress: Progress) => Promise<T>,
  options?: ProgressOptions
): Promise<T>
```

**Example:**

```typescript
const result = await api.showProgress(
  async (progress) => {
    progress.report({ message: 'Starting...', increment: 0 })

    for (let i = 0; i < 10; i++) {
      await doWork()
      progress.report({ increment: 10 })
    }

    return 'Done!'
  },
  { title: 'Processing...', cancellable: true }
)
```

## Command Methods

### registerCommand

Register a command that can be invoked.

```typescript
api.registerCommand(
  id: string,
  handler: (...args: unknown[]) => unknown
): Disposable
```

**Example:**

```typescript
const disposable = api.registerCommand('my-widget.action', (arg1, arg2) => {
  console.log('Action invoked with:', arg1, arg2)
  return true
})

// Later, dispose the command
disposable.dispose()
```

### executeCommand

Execute a registered command.

```typescript
api.executeCommand(commandId: string, ...args: unknown[]): Promise<unknown>
```

**Example:**

```typescript
try {
  const result = await api.executeCommand('my-widget.action', 'arg1', 'arg2')
  console.log('Command result:', result)
} catch (error) {
  console.error('Command failed:', error)
}
```

## Tool Methods

### registerTool

Register a tool that Claude can invoke.

```typescript
api.registerTool(tool: ToolDefinition): Disposable
```

**Parameters:**
- `tool.name` (string) - Tool name
- `tool.description` (string) - Human-readable description
- `tool.inputSchema` (object) - JSON Schema or Zod schema
- `tool.handler` (function) - Async handler function

**Example:**

```typescript
import { z } from 'zod'

api.registerTool({
  name: 'calculate_sum',
  description: 'Add two numbers together',
  inputSchema: z.object({
    a: z.number(),
    b: z.number(),
  }),
  handler: async (args) => {
    return { result: args.a + args.b }
  },
})
```

### callTool

Call a registered tool.

```typescript
api.callTool(name: string, args: Record<string, unknown>): Promise<unknown>
```

**Example:**

```typescript
const result = await api.callTool('calculate_sum', { a: 5, b: 3 })
console.log('Result:', result.result)  // 8
```

## Clipboard Methods

### readClipboard

Read the system clipboard.

```typescript
api.readClipboard(): Promise<string>
```

**Example:**

```typescript
const clipboard = await api.readClipboard()
console.log('Clipboard contains:', clipboard)
```

### writeClipboard

Write to the system clipboard.

```typescript
api.writeClipboard(text: string): Promise<void>
```

**Example:**

```typescript
await api.writeClipboard('Hello, clipboard!')
```

## File System Methods

### readFile

Read a file (sandboxed).

```typescript
api.readFile(path: string): Promise<Uint8Array>
```

### writeFile

Write a file (sandboxed).

```typescript
api.writeFile(path: string, content: Uint8Array): Promise<void>
```

### showOpenDialog

Show file open dialog.

```typescript
api.showOpenDialog(options?: OpenDialogOptions): Promise<string[] | undefined>
```

**Example:**

```typescript
const files = await api.showOpenDialog({
  title: 'Select a file',
  filters: [
    { name: 'JSON', extensions: ['json'] },
    { name: 'All', extensions: ['*'] },
  ],
  canSelectMany: true,
})

if (files) {
  console.log('Selected:', files)
}
```

### showSaveDialog

Show file save dialog.

```typescript
api.showSaveDialog(options?: SaveDialogOptions): Promise<string | undefined>
```

**Example:**

```typescript
const path = await api.showSaveDialog({
  title: 'Save file as...',
  filters: [{ name: 'JSON', extensions: ['json'] }],
})

if (path) {
  // Save to path
}
```

## Terminal Methods

### createTerminal

Create a new terminal instance.

```typescript
api.createTerminal(options?: TerminalOptions): TerminalInstance
```

**Example:**

```typescript
const terminal = api.createTerminal({
  name: 'My Terminal',
  cwd: '/home/user',
})

terminal.sendText('ls -la')
terminal.show()
```

### sendToActiveTerminal

Send text to the active terminal.

```typescript
api.sendToActiveTerminal(text: string): void
```

**Example:**

```typescript
api.sendToActiveTerminal('echo "Hello from widget"')
```

## Pane Management Methods

### openWidget

Open another widget.

```typescript
api.openWidget(
  widgetType: string,
  config?: Record<string, unknown>
): Promise<string>
```

Returns the ID of the opened widget.

### openWebView

Open a web view with a URL.

```typescript
api.openWebView(url: string, title?: string): Promise<string>
```

Returns the ID of the opened web view.

### closePane

Close a pane by ID.

```typescript
api.closePane(paneId: string): void
```

## Messaging Methods

### postMessage

Send a message to a specific widget.

```typescript
api.postMessage(targetWidgetId: string, message: unknown): void
```

**Example:**

```typescript
api.postMessage('com.example.other-widget', {
  action: 'update',
  data: { count: 42 },
})
```

### broadcast

Send a message to all listeners on a channel.

```typescript
api.broadcast(channel: string, message: unknown): void
```

**Example:**

```typescript
api.broadcast('app-events', {
  event: 'data-changed',
  timestamp: Date.now(),
})
```

### subscribe

Subscribe to broadcast messages on a channel.

```typescript
api.subscribe(
  channel: string,
  handler: (message: unknown) => void
): Disposable
```

**Example:**

```typescript
const sub = api.subscribe('app-events', (message) => {
  console.log('Event received:', message)
})

// Later
sub.dispose()
```

## Error Handling

Always handle errors in API calls:

```typescript
try {
  const result = await api.showQuickPick([
    { label: 'A' },
    { label: 'B' },
  ])
  if (!result) {
    console.log('User cancelled')
  }
} catch (error) {
  api.showMessage('Operation failed: ' + error.message, 'error')
}
```

## Disposables

Many methods return `Disposable` objects:

```typescript
interface Disposable {
  dispose(): void
}
```

Always clean up resources:

```typescript
const commands: Disposable[] = []

commands.push(api.registerCommand('cmd1', () => {}))
commands.push(api.registerCommand('cmd2', () => {}))

// Later, clean up
commands.forEach(c => c.dispose())
```

## Next Steps

- [Types Reference](types)
- [React Hooks](hooks)
- [Widget Examples](../examples/hello-world)

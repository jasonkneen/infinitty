# Infinitty Widget SDK - Quick Reference Guide

Fast reference for the most common widget development tasks.

## Installation & Setup

```bash
# 1. Install dependencies
npm install

# 2. Start documentation site
npm run start

# 3. In your widget project: npm run dev
npm run dev
```

## File Structure

```
your-widget/
├── src/
│   ├── index.tsx          # Widget entry point
│   ├── Component.tsx      # React component
│   └── types.ts           # Custom types
├── manifest.json          # Widget metadata
├── package.json           # Dependencies
├── tsconfig.json          # TypeScript config
└── vite.config.ts         # Build config
```

## Basic Widget Template

```typescript
// src/index.tsx
import { defineWidget } from '@infinitty/widget-sdk'
import { Component } from './Component'

export default defineWidget({
  id: 'com.example.my-widget',
  name: 'My Widget',
  version: '1.0.0',
  activate(context, api, events) {
    context.log.info('Widget activated')
  },
  Component,
})
```

```typescript
// src/Component.tsx
import { useWidgetSDK, useTheme } from '@infinitty/widget-sdk'

export function Component() {
  const { api, context } = useWidgetSDK()
  const theme = useTheme()

  return (
    <div style={{ color: theme.foreground }}>
      <h1>Hello World</h1>
    </div>
  )
}
```

## Most Used Hooks

```typescript
import {
  useWidgetSDK,      // Full SDK context
  useTheme,          // Theme colors
  useConfig,         // Widget config
  useStorage,        // Persist data
  useLogger,         // Logging
  useTool,           // Register tools
  useCommand,        // Register commands
  useMessage,        // Receive messages
  useBroadcast,      // Receive broadcasts
} from '@infinitty/widget-sdk'
```

## Most Used API Methods

```typescript
const { api } = useWidgetSDK()

// UI
api.showMessage('text', 'info')                    // Show message
await api.showQuickPick([items])                   // Menu picker
await api.showInputBox({ title: 'Enter text' })    // Input dialog

// Commands
api.registerCommand('id', handler)                 // Register command
await api.executeCommand('id', ...args)            // Execute command

// Tools
api.registerTool({ name, description, inputSchema, handler })
await api.callTool('name', args)

// Clipboard
await api.readClipboard()                          // Read clipboard
await api.writeClipboard('text')                   // Write clipboard

// Messaging
api.postMessage(widgetId, message)                 // Send to widget
api.broadcast('channel', message)                  // Broadcast
api.subscribe('channel', handler)                  // Listen
```

## Common Patterns

### Persistent Storage

```typescript
const [count, setCount] = useStorage('count', 0)

const handleClick = async () => {
  await setCount((count ?? 0) + 1)
}
```

### AI Tool

```typescript
import { z } from 'zod'

useTool({
  name: 'search',
  description: 'Search items',
  inputSchema: z.object({ query: z.string() }),
  handler: async (args) => {
    return { results: search(args.query) }
  },
})
```

### Styled Component

```typescript
function Component() {
  const theme = useTheme()

  return (
    <div style={{
      backgroundColor: theme.background,
      color: theme.foreground,
    }}>
      Content
    </div>
  )
}
```

### Event Handling

```typescript
useEffect(() => {
  const sub = events.onDidResize(({ width, height }) => {
    console.log(`Size: ${width}x${height}`)
  })

  return () => sub.dispose()
}, [events])
```

## Manifest.json Structure

```json
{
  "id": "com.vendor.widget-name",
  "name": "Widget Name",
  "version": "1.0.0",
  "description": "What it does",
  "author": "Your Name",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "activationEvents": ["onStartup"],
  "contributes": {
    "commands": [
      { "id": "widget.action", "title": "Do something" }
    ],
    "tools": [
      { "name": "my_tool", "description": "..." }
    ]
  }
}
```

## Build Commands

```bash
npm run dev          # Start dev simulator
npm run build        # Production build
npm run test         # Run tests
npm run lint         # Check code quality
npm run typecheck    # TypeScript check
```

## Dev Simulator Features

- **Theme Toggle** - Switch light/dark mode
- **DevTools Panel** - View messages, tools, config
- **Configuration** - Edit config in real-time
- **Test Messaging** - Send test messages
- **Storage Inspection** - View persisted data

## Debugging Tips

```typescript
const logger = useLogger()

logger.trace('Detailed')
logger.debug('Debug info')
logger.info('Information')
logger.warn('Warning')
logger.error('Error')
```

Check browser console (F12) for all logs.

## Testing Template

```typescript
import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { WidgetSDKContext } from '@infinitty/widget-sdk'
import { Component } from './Component'

describe('Component', () => {
  const mockContext = { /* ... */ }
  const mockApi = { /* ... */ }
  const mockEvents = { /* ... */ }

  it('should render', () => {
    render(
      <WidgetSDKContext.Provider value={{ context: mockContext, api: mockApi, events: mockEvents }}>
        <Component />
      </WidgetSDKContext.Provider>
    )
    expect(screen.getByText(/Welcome/i)).toBeInTheDocument()
  })
})
```

## Quick Examples

### Counter Widget
[See counter example](docs/examples/counter-widget.md)

### Tool Widget
[See tool example](docs/examples/tool-widget.md)

### Storage Widget
[See storage example](docs/examples/storage-widget.md)

## SDK Reference

- [React Hooks](docs/sdk-reference/hooks.md)
- [Host API](docs/sdk-reference/host-api.md)
- [Types](docs/sdk-reference/types.md)
- [Utilities](docs/sdk-reference/utilities.md)

## Full Documentation

[See complete documentation site](docs/intro.md)

## Common Issues

| Issue | Solution |
|-------|----------|
| Build fails | Run `npm run build` and check errors |
| Widget won't show | Verify Component export, check console |
| Storage not saving | Await `setCount()` promise |
| Types missing | Check imports, run `npm run typecheck` |
| Test timeout | Add `async`/`await` to test |
| useEffect loops | Check dependency array |

## Keyboard Shortcuts (in DevTools)

- **Cmd+Enter** (Mac) / **Ctrl+Enter** (Linux/Windows) - Send test message
- **F12** - Open browser DevTools
- **🔧 Button** - Toggle DevTools panel

## Useful Links

- [GitHub Repository](https://github.com/flows/hybrid-terminal)
- [Widget Examples](docs/examples/hello-world.md)
- [Best Practices](docs/widget-development/best-practices.md)
- [Troubleshooting](docs/troubleshooting.md)

## Next Steps

1. **Install**: Follow [Installation Guide](docs/getting-started/installation.md)
2. **Learn**: Read [Widget SDK Overview](docs/widget-sdk/overview.md)
3. **Build**: Create [First Widget](docs/getting-started/first-widget.md)
4. **Explore**: Check out [Examples](docs/examples/hello-world.md)
5. **Reference**: Use [SDK Reference](docs/sdk-reference/hooks.md)
6. **Master**: Study [Best Practices](docs/widget-development/best-practices.md)

---

For detailed documentation, visit the full site in `docs/` directory.

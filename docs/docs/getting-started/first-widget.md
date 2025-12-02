---
sidebar_position: 2
---

# Create Your First Widget

Let's build a simple "Hello World" widget to understand the basics.

## Widget Structure

A widget consists of:
- **Manifest** (`manifest.json`) - Widget metadata
- **Entry Point** (`src/index.tsx`) - React component and activation logic
- **Types** (optional) - TypeScript definitions

## The Simplest Widget

Here's a minimal widget:

```typescript
// src/index.tsx
import { defineWidget } from '@infinitty/widget-sdk'
import { WidgetComponent } from './Component'

export default defineWidget({
  id: 'com.example.hello-world',
  name: 'Hello World',
  version: '1.0.0',
  description: 'Your first Infinitty widget',
  Component: WidgetComponent,
})
```

```typescript
// src/Component.tsx
import { useWidgetSDK } from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const { context } = useWidgetSDK()

  return (
    <div style={{ padding: '20px', fontFamily: 'monospace' }}>
      <h1>Hello from {context.widgetId}!</h1>
      <p>Welcome to the Infinitty Widget SDK</p>
    </div>
  )
}
```

```json
{
  "manifest.json"
  "id": "com.example.hello-world",
  "name": "Hello World Widget",
  "version": "1.0.0",
  "description": "A simple hello world widget",
  "author": "Your Name",
  "main": "dist/index.js",
  "ui": "dist/index.tsx"
}
```

## Adding Interactivity

Let's add some interactive features:

```typescript
// src/Component.tsx
import { useState } from 'react'
import { useWidgetSDK, useTheme } from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const { api } = useWidgetSDK()
  const theme = useTheme()
  const [count, setCount] = useState(0)

  const handleClick = () => {
    const newCount = count + 1
    setCount(newCount)
    api.showMessage(`Count is now: ${newCount}`)
  }

  return (
    <div style={{
      padding: '20px',
      fontFamily: 'system-ui',
      color: theme.foreground,
      backgroundColor: theme.background,
    }}>
      <h1>Counter Widget</h1>
      <p>Count: {count}</p>
      <button
        onClick={handleClick}
        style={{
          padding: '8px 16px',
          backgroundColor: theme.blue,
          color: theme.background,
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          fontSize: '14px',
        }}
      >
        Increment
      </button>
    </div>
  )
}
```

## Using Widget Hooks

The SDK provides several useful hooks:

```typescript
import {
  useTheme,           // Get current theme colors
  useConfig,          // Access widget configuration
  useStorage,         // Persist data
  useLogger,          // Log messages
  useWidgetSDK,       // Access full SDK context
  useWidgetSize,      // Get widget dimensions
  useWidgetVisibility, // Check if widget is visible
} from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const theme = useTheme()
  const [count, setCount] = useStorage('count', 0)
  const logger = useLogger()

  const handleClick = async () => {
    const newCount = (count ?? 0) + 1
    await setCount(newCount)
    logger.info(`Count updated to ${newCount}`)
  }

  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={handleClick}>Increment</button>
    </div>
  )
}
```

## Accessing the Host API

The host API provides access to system features:

```typescript
import { useWidgetSDK } from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const { api } = useWidgetSDK()

  const handleShowMessage = () => {
    api.showMessage('Hello from the widget!', 'info')
  }

  const handleQuickPick = async () => {
    const result = await api.showQuickPick([
      { label: 'Option 1', description: 'First option' },
      { label: 'Option 2', description: 'Second option' },
    ])
    console.log('Selected:', result?.label)
  }

  const handleInputBox = async () => {
    const result = await api.showInputBox({
      title: 'Enter your name',
      placeholder: 'John Doe',
    })
    console.log('Input:', result)
  }

  return (
    <div style={{ padding: '20px' }}>
      <button onClick={handleShowMessage}>Show Message</button>
      <button onClick={handleQuickPick}>Pick Option</button>
      <button onClick={handleInputBox}>Get Input</button>
    </div>
  )
}
```

## Lifecycle Hooks

Widgets have a lifecycle you can hook into:

```typescript
import { useEffect } from 'react'
import { useWidgetSDK } from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const { context, events } = useWidgetSDK()

  useEffect(() => {
    // Handle activation
    const activate = events.onDidActivate(() => {
      context.log.info('Widget activated')
    })

    // Handle visibility changes
    const visibility = events.onDidChangeVisibility((visible) => {
      context.log.info(`Widget ${visible ? 'shown' : 'hidden'}`)
    })

    // Handle resize
    const resize = events.onDidResize(({ width, height }) => {
      context.log.info(`Widget resized: ${width}x${height}`)
    })

    // Cleanup
    return () => {
      activate.dispose()
      visibility.dispose()
      resize.dispose()
    }
  }, [context, events])

  return <div>Widget content</div>
}
```

## Manifest Configuration

The `manifest.json` defines how your widget integrates with Infinitty:

```json
{
  "id": "com.example.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "description": "Description of your widget",
  "author": {
    "name": "Your Name",
    "email": "you@example.com"
  },
  "license": "MIT",
  "icon": "icon.png",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "activationEvents": [
    "onStartup"
  ],
  "contributes": {
    "commands": [
      {
        "id": "my-widget.action",
        "title": "My Widget Action",
        "category": "My Widget"
      }
    ],
    "tools": [
      {
        "name": "my_tool",
        "description": "A tool provided by this widget"
      }
    ],
    "configuration": {
      "title": "My Widget Settings",
      "properties": {
        "my-widget.enabled": {
          "type": "boolean",
          "default": true,
          "description": "Enable/disable the widget"
        }
      }
    }
  }
}
```

## Build and Test

```bash
# Build your widget
npm run build

# Start dev server with simulator
npm run dev

# Run tests
npm run test
```

Visit `http://localhost:5173` to see your widget in the development simulator.

## Next Steps

- [Test Your Widget](testing)
- [SDK Reference](../sdk-reference/hooks)
- [See More Examples](../examples/counter-widget)
- [Development Tips](../widget-development/dev-simulator)

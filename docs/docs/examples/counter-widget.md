---
sidebar_position: 2
---

# Counter Widget Example

A stateful widget that persists data using storage.

## Full Example

### src/Component.tsx

```typescript
import { useState } from 'react'
import {
  useWidgetSDK,
  useTheme,
  useStorage,
  useLogger,
} from '@infinitty/widget-sdk'

export function Component() {
  const { api, context } = useWidgetSDK()
  const theme = useTheme()
  const logger = useLogger()

  // Persistent counter stored in widget storage
  const [count, setCount] = useStorage('count', 0)

  // Temporary state (lost on unmount)
  const [lastAction, setLastAction] = useState<string>('')

  const handleIncrement = async () => {
    const newCount = (count ?? 0) + 1
    await setCount(newCount)
    setLastAction('incremented')
    logger.info(`Counter incremented to ${newCount}`)
  }

  const handleDecrement = async () => {
    const newCount = (count ?? 0) - 1
    await setCount(newCount)
    setLastAction('decremented')
    logger.info(`Counter decremented to ${newCount}`)
  }

  const handleReset = async () => {
    await setCount(0)
    setLastAction('reset')
    api.showMessage('Counter reset to 0', 'info')
    logger.info('Counter reset')
  }

  const handleExport = async () => {
    const data = {
      count: count ?? 0,
      timestamp: new Date().toISOString(),
      widgetId: context.widgetId,
    }

    try {
      await api.writeClipboard(JSON.stringify(data, null, 2))
      api.showMessage('Counter data copied to clipboard', 'info')
    } catch (error) {
      api.showMessage('Failed to copy to clipboard', 'error')
      logger.error('Export failed:', error)
    }
  }

  return (
    <div style={{
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      minHeight: '100vh',
      padding: '20px',
      backgroundColor: theme.background,
      color: theme.foreground,
      fontFamily: 'system-ui, -apple-system, sans-serif',
    }}>
      <h1 style={{ fontSize: '32px', marginBottom: '32px' }}>
        Counter Widget
      </h1>

      {/* Counter Display */}
      <div style={{
        fontSize: '80px',
        fontWeight: 'bold',
        color: theme.cyan,
        marginBottom: '32px',
        fontVariantNumeric: 'tabular-nums',
      }}>
        {count ?? 0}
      </div>

      {/* Action Buttons */}
      <div style={{
        display: 'flex',
        gap: '12px',
        marginBottom: '24px',
        flexWrap: 'wrap',
        justifyContent: 'center',
      }}>
        <button
          onClick={handleDecrement}
          style={{
            padding: '12px 24px',
            backgroundColor: theme.red,
            color: theme.background,
            border: 'none',
            borderRadius: '6px',
            cursor: 'pointer',
            fontSize: '16px',
            fontWeight: '500',
            transition: 'opacity 0.2s',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.opacity = '0.8'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.opacity = '1'
          }}
        >
          Decrease
        </button>

        <button
          onClick={handleIncrement}
          style={{
            padding: '12px 24px',
            backgroundColor: theme.green,
            color: theme.background,
            border: 'none',
            borderRadius: '6px',
            cursor: 'pointer',
            fontSize: '16px',
            fontWeight: '500',
            transition: 'opacity 0.2s',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.opacity = '0.8'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.opacity = '1'
          }}
        >
          Increase
        </button>

        <button
          onClick={handleReset}
          style={{
            padding: '12px 24px',
            backgroundColor: theme.yellow,
            color: theme.background,
            border: 'none',
            borderRadius: '6px',
            cursor: 'pointer',
            fontSize: '16px',
            fontWeight: '500',
            transition: 'opacity 0.2s',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.opacity = '0.8'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.opacity = '1'
          }}
        >
          Reset
        </button>
      </div>

      {/* Last Action */}
      {lastAction && (
        <p style={{
          fontSize: '14px',
          color: theme.brightBlack,
          marginBottom: '16px',
          fontStyle: 'italic',
        }}>
          Last action: {lastAction}
        </p>
      )}

      {/* Export Button */}
      <button
        onClick={handleExport}
        style={{
          padding: '8px 16px',
          backgroundColor: theme.brightBlack + '30',
          color: theme.foreground,
          border: `1px solid ${theme.brightBlack}60`,
          borderRadius: '4px',
          cursor: 'pointer',
          fontSize: '12px',
        }}
      >
        📋 Copy to Clipboard
      </button>

      {/* Info Box */}
      <div style={{
        marginTop: '32px',
        padding: '16px',
        backgroundColor: theme.brightBlack + '20',
        borderRadius: '6px',
        fontSize: '12px',
        color: theme.brightBlack,
        maxWidth: '400px',
      }}>
        <p>
          <strong>Widget ID:</strong> {context.widgetId}
        </p>
        <p>
          <strong>Instance ID:</strong> {context.instanceId}
        </p>
        <p>
          The counter value is persisted and will be restored when you
          close and reopen this widget.
        </p>
      </div>
    </div>
  )
}
```

### src/index.tsx

```typescript
import { defineWidget } from '@infinitty/widget-sdk'
import { Component } from './Component'

export default defineWidget({
  id: 'com.example.counter-widget',
  name: 'Counter Widget',
  version: '1.0.0',
  description: 'A persistent counter with increment/decrement',

  activate(context, api, events) {
    context.log.info('Counter widget activated')

    // Optional: Register a command to get current count
    api.registerCommand('counter.get-value', () => {
      return context.storage.get('count', 0)
    })
  },

  Component,
})
```

## Key Features

### Storage

- **`useStorage()`** - Persists the counter value
- Value survives widget unmount/remount
- Stored in browser's localStorage

### User Feedback

- **`api.showMessage()`** - Feedback on reset
- **`useLogger()`** - Debug logging
- **Last action display** - UI feedback

### Clipboard Integration

- **`api.writeClipboard()`** - Export counter data
- JSON format for easy sharing
- Error handling for clipboard access

### Theme Support

- Uses all theme colors appropriately
- Works in light and dark modes
- Hover effects for interactivity

### Widget Metadata

- Displays widget IDs
- Shows lifecycle information
- Educational component

## Testing

### Test Increment

```typescript
it('should increment counter', async () => {
  const { getByText } = render(<Component />)
  const button = getByText('Increase')

  fireEvent.click(button)

  expect(screen.getByText('1')).toBeInTheDocument()
})
```

### Test Storage

```typescript
it('should persist count', async () => {
  const { container, unmount } = render(<Component />)

  fireEvent.click(screen.getByText('Increase'))
  expect(screen.getByText('1')).toBeInTheDocument()

  unmount()

  const { container: container2 } = render(<Component />)
  expect(screen.getByText('1')).toBeInTheDocument()
})
```

## Running the Example

```bash
# Setup
npm install

# Build
npm run build

# Dev server
npm run dev
```

Visit `http://localhost:5173` and test:
1. Click buttons to change counter
2. Check DevTools Console tab for logs
3. Refresh page - count persists
4. Click "Copy to Clipboard" button
5. Toggle theme to test dark/light mode

## Learning Points

1. **Storage** - How to persist data
2. **State Management** - useState vs useStorage
3. **Async Operations** - Handling setCount promises
4. **Error Handling** - Try-catch for API calls
5. **User Feedback** - Messages and logging
6. **UI Styling** - Theme colors and interactions
7. **Commands** - Registering custom commands

## Enhancements

Try extending this widget:

- Add increment by custom amount
- Add minimum/maximum bounds
- Show history of actions
- Add keyboard shortcuts (↑/↓)
- Export to file
- Import from file
- Share between widget instances using `useGlobalState()`
- Add analytics tool for Claude

## Next Steps

- [Tool Widget Example](tool-widget)
- [Storage Widget Example](storage-widget)
- [SDK Reference - Hooks](../sdk-reference/hooks)
- [Best Practices](../widget-development/best-practices)

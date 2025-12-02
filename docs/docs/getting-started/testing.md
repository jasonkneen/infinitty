---
sidebar_position: 3
---

# Testing Widgets

Learn how to test your Infinitty widgets effectively.

## Development Simulator

The built-in development simulator allows you to test widgets locally without running the full Infinitty application.

### Starting the Simulator

```bash
npm run dev
```

This starts a local dev server (usually on `http://localhost:5173`) that loads your widget in an interactive development environment.

### Simulator Features

The dev simulator includes:

- **Theme Toggling** - Switch between light and dark themes
- **Message Logging** - View all `showMessage()` calls
- **Tool Inspection** - See registered tools and view tool calls
- **Configuration Panel** - Update widget configuration in real-time
- **Storage Inspection** - View and modify persisted data
- **Test Messaging** - Send test messages to your widget

### Using the Dev Tools Panel

The right panel in the simulator shows:

1. **Messages Tab** - All messages shown via `api.showMessage()`
2. **Tools Tab** - Registered tools and their calls/results
3. **Config Tab** - Widget configuration with live editing

## Unit Testing

Use Vitest for unit testing your widget code.

### Setup

Add test dependencies:

```bash
npm install -D vitest @testing-library/react @testing-library/jest-dom
```

### Example Test

```typescript
// src/utils.test.ts
import { describe, it, expect } from 'vitest'
import { formatMessage, parseConfig } from './utils'

describe('Utils', () => {
  it('should format messages correctly', () => {
    const result = formatMessage('hello', 'world')
    expect(result).toBe('hello world')
  })

  it('should parse config', () => {
    const config = parseConfig({ foo: 'bar' })
    expect(config.foo).toBe('bar')
  })
})
```

### Testing React Components

```typescript
// src/Component.test.tsx
import { render, screen } from '@testing-library/react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { WidgetComponent } from './Component'
import { WidgetSDKContext } from '@infinitty/widget-sdk'

describe('WidgetComponent', () => {
  beforeEach(() => {
    // Mock SDK context
    const mockApi = {
      showMessage: vi.fn(),
      showQuickPick: vi.fn(),
      // ... other API methods
    }

    const mockContext = {
      widgetId: 'test-widget',
      config: {},
      theme: { background: '#000', foreground: '#fff' },
      // ... other context properties
    }

    const mockEvents = {
      onDidActivate: () => ({ dispose: () => {} }),
      // ... other events
    }

    // Wrap component with SDK provider for testing
    render(
      <WidgetSDKContext.Provider value={{ api: mockApi, context: mockContext, events: mockEvents }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )
  })

  it('should render component', () => {
    expect(screen.getByText(/Hello/i)).toBeInTheDocument()
  })

  it('should handle button click', async () => {
    const button = screen.getByRole('button')
    button.click()
    // Assert expected behavior
  })
})
```

## Integration Testing

Test how your widget integrates with the host API:

```typescript
// src/integration.test.ts
import { describe, it, expect, vi } from 'vitest'
import { createDevSimulator } from '@infinitty/widget-sdk/dev-simulator'
import MyWidget from './index'

describe('Widget Integration', () => {
  it('should call host API methods', async () => {
    const mockTools = {
      my_tool: vi.fn().mockResolvedValue({ success: true }),
    }

    // Create simulator instance for testing
    createDevSimulator(MyWidget, {
      widgetId: 'com.example.test',
      mockTools,
      devTools: false, // Hide dev panel in tests
    })

    // Verify widget behavior through simulator
    expect(mockTools.my_tool).toHaveBeenCalled()
  })
})
```

## Running Tests

```bash
# Run all tests
npm run test

# Run tests in watch mode
npm run test:watch

# Run single test file
npm run test src/Component.test.tsx

# Check coverage
npm run test:coverage
```

## Testing Best Practices

### 1. Mock the SDK Context

Always provide mock implementations of the SDK context:

```typescript
const mockSDK = {
  context: {
    widgetId: 'test-widget',
    config: { /* ... */ },
    theme: { /* ... */ },
    storage: {
      get: vi.fn(),
      set: vi.fn(),
      delete: vi.fn(),
      keys: vi.fn(),
    },
    log: {
      info: vi.fn(),
      debug: vi.fn(),
      error: vi.fn(),
      warn: vi.fn(),
      trace: vi.fn(),
    },
  },
  api: {
    showMessage: vi.fn(),
    showQuickPick: vi.fn().mockResolvedValue(null),
    showInputBox: vi.fn().mockResolvedValue(undefined),
    executeCommand: vi.fn().mockResolvedValue(undefined),
    // ... other methods
  },
  events: {
    onDidActivate: () => ({ dispose: () => {} }),
    onDidReceiveMessage: () => ({ dispose: () => {} }),
    // ... other events
  },
}
```

### 2. Test Storage Persistence

```typescript
it('should persist data to storage', async () => {
  const storage = new Map()
  const mockStorage = {
    get: (key) => storage.get(key),
    set: (key, value) => storage.set(key, value),
    delete: (key) => storage.delete(key),
    keys: () => Array.from(storage.keys()),
  }

  // Simulate storage operations
  await mockStorage.set('count', 42)
  expect(mockStorage.get('count')).toBe(42)
})
```

### 3. Test Theme Changes

```typescript
it('should respond to theme changes', () => {
  const themeCallback = vi.fn()
  const mockContext = {
    theme: DARK_THEME,
    onThemeChange: (cb) => {
      // Call callback with new theme
      cb(LIGHT_THEME)
      return { dispose: () => {} }
    },
  }

  mockContext.onThemeChange(themeCallback)
  expect(themeCallback).toHaveBeenCalledWith(LIGHT_THEME)
})
```

### 4. Test Async Operations

```typescript
it('should handle async operations', async () => {
  const api = {
    showQuickPick: vi.fn().mockResolvedValue({ label: 'Option 1' }),
  }

  const result = await api.showQuickPick([
    { label: 'Option 1' },
    { label: 'Option 2' },
  ])

  expect(result?.label).toBe('Option 1')
})
```

## Debugging

### Enable Debug Logging

```typescript
// src/Component.tsx
import { useLogger } from '@infinitty/widget-sdk'

export function WidgetComponent() {
  const logger = useLogger()

  logger.debug('Widget mounted')
  logger.info('Processing data')
  logger.warn('Unexpected value')
  logger.error('Something went wrong')

  return <div>Widget</div>
}
```

### Browser DevTools

When running the dev simulator:
1. Open browser DevTools (F12)
2. Check the Console tab for logs
3. Use React DevTools extension to inspect component state
4. Monitor Network tab for API calls

### Vitest UI

For a visual test runner:

```bash
npm install -D vitest-ui

# Run with UI
npx vitest --ui
```

## Next Steps

- [Widget Development Guide](../widget-development/testing-widgets)
- [Examples](../examples/counter-widget)
- [SDK Reference](../sdk-reference/hooks)

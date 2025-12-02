---
sidebar_position: 2
---

# Testing Widgets

Comprehensive guide to testing Infinitty widgets.

## Test Setup

Install testing dependencies:

```bash
npm install -D vitest @testing-library/react @testing-library/jest-dom @vitest/ui
```

Create `vitest.config.ts`:

```typescript
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
  },
})
```

Create `src/test/setup.ts`:

```typescript
import '@testing-library/jest-dom'
import { vi } from 'vitest'

// Mock SDK if needed
global.window.__INFINITTY_DEV__ = true
```

## Unit Tests

### Testing Utility Functions

```typescript
// src/utils.test.ts
import { describe, it, expect } from 'vitest'
import { formatDate, parseConfig } from './utils'

describe('Utils', () => {
  it('should format date correctly', () => {
    const date = new Date('2024-01-15')
    expect(formatDate(date)).toBe('01/15/2024')
  })

  it('should parse config with defaults', () => {
    const config = parseConfig({ timeout: 5000 })
    expect(config.timeout).toBe(5000)
    expect(config.retries).toBe(3)  // default
  })
})
```

### Testing React Hooks

```typescript
// src/hooks/useCounter.test.ts
import { renderHook, act } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { useCounter } from './useCounter'

describe('useCounter', () => {
  it('should increment count', () => {
    const { result } = renderHook(() => useCounter())

    act(() => {
      result.current.increment()
    })

    expect(result.current.count).toBe(1)
  })

  it('should decrement count', () => {
    const { result } = renderHook(() => useCounter())

    act(() => {
      result.current.decrement()
    })

    expect(result.current.count).toBe(-1)
  })
})
```

### Testing SDK Hooks

```typescript
// src/Component.test.tsx
import { render, screen } from '@testing-library/react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { WidgetSDKContext } from '@infinitty/widget-sdk'
import { WidgetComponent } from './Component'

const mockContext = {
  widgetId: 'test-widget',
  widgetType: 'test',
  instanceId: 'test-instance',
  config: {},
  getConfig: vi.fn(),
  theme: {
    background: '#000',
    foreground: '#fff',
    // ... other colors
  },
  storage: {
    get: vi.fn(),
    set: vi.fn(),
    delete: vi.fn(),
    keys: vi.fn(() => []),
  },
  globalState: {
    get: vi.fn(),
    set: vi.fn(),
    delete: vi.fn(),
    keys: vi.fn(() => []),
  },
  secrets: {
    get: vi.fn(),
    store: vi.fn(),
    delete: vi.fn(),
  },
  log: {
    trace: vi.fn(),
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  },
  extensionPath: '/test',
  extensionUri: 'file:///test',
  onThemeChange: vi.fn(() => ({ dispose: () => {} })),
}

const mockApi = {
  showMessage: vi.fn(),
  showQuickPick: vi.fn(),
  showInputBox: vi.fn(),
  showProgress: vi.fn(),
  executeCommand: vi.fn(),
  registerCommand: vi.fn(() => ({ dispose: () => {} })),
  registerTool: vi.fn(() => ({ dispose: () => {} })),
  callTool: vi.fn(),
  readClipboard: vi.fn(),
  writeClipboard: vi.fn(),
  readFile: vi.fn(),
  writeFile: vi.fn(),
  showOpenDialog: vi.fn(),
  showSaveDialog: vi.fn(),
  createTerminal: vi.fn(),
  sendToActiveTerminal: vi.fn(),
  openWidget: vi.fn(),
  openWebView: vi.fn(),
  closePane: vi.fn(),
  postMessage: vi.fn(),
  broadcast: vi.fn(),
  subscribe: vi.fn(() => ({ dispose: () => {} })),
}

const mockEvents = {
  onDidActivate: vi.fn(() => ({ dispose: () => {} })),
  onWillDeactivate: vi.fn(() => ({ dispose: () => {} })),
  onDidResize: vi.fn(() => ({ dispose: () => {} })),
  onDidChangeVisibility: vi.fn(() => ({ dispose: () => {} })),
  onDidFocus: vi.fn(() => ({ dispose: () => {} })),
  onDidBlur: vi.fn(() => ({ dispose: () => {} })),
  onDidReceiveMessage: vi.fn(() => ({ dispose: () => {} })),
  onDidChangeConfig: vi.fn(() => ({ dispose: () => {} })),
}

describe('WidgetComponent', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('should render component', () => {
    render(
      <WidgetSDKContext.Provider value={{ context: mockContext, api: mockApi, events: mockEvents }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )

    expect(screen.getByText(/Welcome/i)).toBeInTheDocument()
  })

  it('should handle button click', () => {
    render(
      <WidgetSDKContext.Provider value={{ context: mockContext, api: mockApi, events: mockEvents }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )

    const button = screen.getByRole('button')
    button.click()

    expect(mockApi.showMessage).toHaveBeenCalled()
  })
})
```

## Integration Tests

Test how components integrate with the SDK:

```typescript
// src/integration.test.tsx
import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { WidgetSDKContext } from '@infinitty/widget-sdk'
import { WidgetComponent } from './Component'

describe('Widget Integration', () => {
  it('should use storage', async () => {
    const storage = new Map()
    const mockContext = {
      // ... other mocks
      storage: {
        get: (key) => storage.get(key),
        set: (key, value) => {
          storage.set(key, value)
          return Promise.resolve()
        },
        delete: (key) => {
          storage.delete(key)
          return Promise.resolve()
        },
        keys: () => Array.from(storage.keys()),
      },
      // ...
    }

    const mockApi = { /* ... */ }
    const mockEvents = { /* ... */ }

    render(
      <WidgetSDKContext.Provider value={{ context: mockContext, api: mockApi, events: mockEvents }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )

    // Trigger storage operation
    const button = screen.getByText('Save')
    fireEvent.click(button)

    // Verify storage was updated
    expect(storage.has('count')).toBe(true)
  })

  it('should call API methods', async () => {
    const mockApi = {
      showMessage: vi.fn(),
      // ...
    }

    const mockContext = { /* ... */ }
    const mockEvents = { /* ... */ }

    render(
      <WidgetSDKContext.Provider value={{ context: mockContext, api: mockApi, events: mockEvents }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )

    const button = screen.getByText('Show Message')
    fireEvent.click(button)

    expect(mockApi.showMessage).toHaveBeenCalledWith(
      'Operation complete',
      'info'
    )
  })
})
```

## Async Testing

Test asynchronous operations:

```typescript
// src/async.test.ts
import { describe, it, expect, vi } from 'vitest'
import { fetchData } from './api'

describe('Async Operations', () => {
  it('should fetch data', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ data: [1, 2, 3] })
    global.fetch = mockFetch

    const result = await fetchData('https://api.example.com/data')

    expect(result).toEqual({ data: [1, 2, 3] })
    expect(mockFetch).toHaveBeenCalledWith('https://api.example.com/data')
  })

  it('should handle errors', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'))
    global.fetch = mockFetch

    await expect(fetchData('https://api.example.com/data')).rejects.toThrow(
      'Network error'
    )
  })
})
```

## Tool Testing

Test tool implementations:

```typescript
// src/tools.test.ts
import { describe, it, expect, vi } from 'vitest'
import { z } from 'zod'
import { myToolHandler } from './tools'

describe('Tools', () => {
  it('should handle tool input', async () => {
    const schema = z.object({
      query: z.string(),
    })

    const result = await myToolHandler({ query: 'test' })

    expect(result).toHaveProperty('results')
    expect(Array.isArray(result.results)).toBe(true)
  })

  it('should validate input schema', () => {
    const schema = z.object({
      query: z.string().min(1),
    })

    expect(() => schema.parse({ query: '' })).toThrow()
    expect(schema.parse({ query: 'valid' })).toEqual({ query: 'valid' })
  })
})
```

## Snapshot Testing

Test UI structure:

```typescript
// src/Component.snapshot.test.tsx
import { render } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { WidgetSDKContext } from '@infinitty/widget-sdk'
import { WidgetComponent } from './Component'

describe('WidgetComponent Snapshot', () => {
  it('should match snapshot', () => {
    const { container } = render(
      <WidgetSDKContext.Provider value={{ /* mocks */ }}>
        <WidgetComponent />
      </WidgetSDKContext.Provider>
    )

    expect(container.firstChild).toMatchSnapshot()
  })
})
```

## Running Tests

```bash
# Run all tests
npm run test

# Watch mode
npm run test:watch

# Single file
npm run test src/Component.test.tsx

# With UI
npm run test:ui

# Coverage
npm run test:coverage
```

## Test Coverage

Generate coverage report:

```bash
npm run test:coverage
```

Add to `vitest.config.ts`:

```typescript
export default defineConfig({
  test: {
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: [
        'node_modules/',
        'src/test/',
      ],
    },
  },
})
```

View report in `coverage/index.html`.

## Best Practices

1. **Mock the SDK** - Always provide complete mocks
2. **Test behavior** - Not implementation details
3. **Keep tests focused** - One thing per test
4. **Use meaningful names** - Describe what's being tested
5. **Clean up** - Clear mocks between tests
6. **Test edge cases** - Errors, empty values, etc.
7. **Avoid flakiness** - Don't depend on timing

## Next Steps

- [Best Practices](best-practices)
- [Packaging & Distribution](packaging-distribution)
- [Widget Examples](../examples/hello-world)

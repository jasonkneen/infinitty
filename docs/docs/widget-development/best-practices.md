---
sidebar_position: 4
---

# Best Practices

Guidelines for building high-quality Infinitty widgets.

## Code Quality

### TypeScript Strictness

Enable strict TypeScript checking:

```json
{
  "compilerOptions": {
    "strict": true,
    "strictNullChecks": true,
    "noImplicitAny": true,
    "noImplicitThis": true,
    "strictFunctionTypes": true,
    "strictPropertyInitialization": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true
  }
}
```

### Avoid any

Never suppress types with `any`:

```typescript
// Bad
const data: any = result

// Good
interface Result {
  id: string
  name: string
}
const data: Result = result
```

### Function Return Types

Always specify return types:

```typescript
// Bad
function calculate(a, b) {
  return a + b
}

// Good
function calculate(a: number, b: number): number {
  return a + b
}
```

### Import Organization

Organize imports with groups:

```typescript
// 1. React
import React, { useState, useEffect } from 'react'

// 2. External packages
import { z } from 'zod'

// 3. SDK
import { useWidgetSDK, useTheme, useStorage } from '@infinitty/widget-sdk'

// 4. Internal modules
import { formatData } from './utils'
import { MyComponent } from './components/MyComponent'

// 5. Types
import type { WidgetContext } from '@infinitty/widget-sdk'
import type { MyType } from './types'
```

## Performance

### Memoization

Use `useMemo` for expensive calculations:

```typescript
function ExpensiveComponent() {
  const [items, setItems] = useState<Item[]>([])

  // Memoize sorted list
  const sorted = useMemo(() => {
    console.log('Sorting...')
    return [...items].sort((a, b) => a.name.localeCompare(b.name))
  }, [items])

  return <div>{sorted.map(item => <div>{item.name}</div>)}</div>
}
```

### Callback Memoization

Use `useCallback` for stable function references:

```typescript
function Parent() {
  const [count, setCount] = useState(0)

  // Memoize callback
  const handleClick = useCallback(() => {
    setCount(c => c + 1)
  }, [])

  return <Child onClick={handleClick} />
}
```

### Avoid Unnecessary Re-renders

Use proper dependencies:

```typescript
// Bad - runs every render
useEffect(() => {
  fetch('/api/data')
}, [])

// Good - runs only once
useEffect(() => {
  fetch('/api/data')
}, [])

// Good - runs when dependency changes
useEffect(() => {
  api.showMessage(`Count: ${count}`)
}, [count, api])
```

### Lazy Loading

Load large widgets lazily:

```typescript
import { lazy, Suspense } from 'react'

const HeavyComponent = lazy(() => import('./HeavyComponent'))

export function MyWidget() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <HeavyComponent />
    </Suspense>
  )
}
```

## Error Handling

### Always Catch Errors

```typescript
// Bad - unhandled promise rejection
useEffect(() => {
  api.showInputBox().then(result => {
    setData(result)
  })
}, [api])

// Good - error handling
useEffect(() => {
  api.showInputBox()
    .then(result => setData(result))
    .catch(error => {
      context.log.error('Input failed:', error)
    })
}, [api, context])
```

### Type Error Objects

```typescript
// Bad
catch (error) {
  console.error(error)
}

// Good
catch (error) {
  if (error instanceof Error) {
    context.log.error('Error:', error.message)
  } else {
    context.log.error('Unknown error:', error)
  }
}
```

### Show User-Friendly Messages

```typescript
// Bad - technical error
api.showMessage('TypeError: Cannot read property x of undefined', 'error')

// Good - user-friendly
api.showMessage('Failed to load data. Please try again.', 'error')
```

## Memory Management

### Dispose Resources Properly

```typescript
// Bad - memory leak
useEffect(() => {
  events.onDidActivate(() => {
    // ...
  })
}, [events])

// Good - disposed
useEffect(() => {
  const sub = events.onDidActivate(() => {})
  return () => sub.dispose()
}, [events])
```

### Limit Event Listeners

```typescript
// Bad - multiple listeners
useEffect(() => {
  events.onDidResize(() => console.log('resized'))
  events.onDidResize(() => setSize({...}))
  events.onDidResize(() => recalculate())
}, [events])

// Good - single listener
useEffect(() => {
  const sub = events.onDidResize(() => {
    console.log('resized')
    setSize({...})
    recalculate()
  })
  return () => sub.dispose()
}, [events])
```

### Clear Intervals/Timeouts

```typescript
// Bad - leak
useEffect(() => {
  setInterval(() => refresh(), 5000)
}, [])

// Good
useEffect(() => {
  const timer = setInterval(() => refresh(), 5000)
  return () => clearInterval(timer)
}, [])
```

## UI/UX

### Accessible Components

```typescript
function AccessibleButton() {
  return (
    <button
      aria-label="Save document"
      onClick={handleSave}
      disabled={isLoading}
    >
      {isLoading ? 'Saving...' : 'Save'}
    </button>
  )
}
```

### Loading States

```typescript
function DataComponent() {
  const [loading, setLoading] = useState(true)
  const [data, setData] = useState<Data | null>(null)

  useEffect(() => {
    fetchData()
      .then(d => {
        setData(d)
        setLoading(false)
      })
      .catch(error => {
        api.showMessage('Failed to load', 'error')
        setLoading(false)
      })
  }, [api])

  if (loading) return <div>Loading...</div>
  if (!data) return <div>No data</div>
  return <div>{data.name}</div>
}
```

### Responsive Design

```typescript
function ResponsiveWidget() {
  const { width } = useWidgetSize()
  const isSmall = width < 400

  return (
    <div style={{
      display: isSmall ? 'flex' : 'grid',
      flexDirection: 'column',
      gridTemplateColumns: 'repeat(2, 1fr)',
    }}>
      {/* content */}
    </div>
  )
}
```

## Security

### Validate Input

```typescript
// Bad - XSS vulnerability
const userInput = await api.showInputBox()
return <div>{userInput}</div>

// Good - validate and escape
const userInput = await api.showInputBox()
const validated = sanitizeInput(userInput)
return <div>{validated}</div>
```

### Secure Secrets

```typescript
// Bad - hardcoded
const apiKey = 'sk-xxx...'

// Good - from secrets storage
const apiKey = await context.secrets.get('api-key')
if (!apiKey) {
  api.showMessage('API key not configured', 'error')
  return
}
```

### Validate Tool Input

```typescript
import { z } from 'zod'

const schema = z.object({
  username: z.string().min(1).max(50),
  email: z.string().email(),
})

useTool(
  {
    name: 'create_user',
    description: 'Create a user',
    inputSchema: schema,
  },
  async (args) => {
    // Schema validates input
    const validated = schema.parse(args)
    return createUser(validated)
  }
)
```

## Testing

### Test Critical Paths

```typescript
// Test happy path
test('should calculate sum', () => {
  expect(calculate(2, 3)).toBe(5)
})

// Test error cases
test('should handle invalid input', () => {
  expect(() => calculate('a', 'b')).toThrow()
})

// Test edge cases
test('should handle zero', () => {
  expect(calculate(0, 0)).toBe(0)
})
```

### Test Storage

```typescript
test('should persist data', async () => {
  const { result } = renderHook(() => useStorage('key', 0))

  act(() => {
    result.current[1](42)
  })

  expect(result.current[0]).toBe(42)
})
```

### Test API Calls

```typescript
test('should show message on button click', () => {
  const mockApi = { showMessage: vi.fn() }
  // ... render with mock

  fireEvent.click(screen.getByRole('button'))

  expect(mockApi.showMessage).toHaveBeenCalledWith(
    'Success',
    'info'
  )
})
```

## Documentation

### Code Comments

```typescript
// Bad - obvious
const count = count + 1  // increment count

// Good - explains why
// Increment counter and persist to storage
// (we do this immediately rather than batch to ensure
//  data is saved even if widget closes unexpectedly)
await setCount((count ?? 0) + 1)
```

### JSDoc for Public APIs

```typescript
/**
 * Calculate the sum of two numbers
 * @param a - First number
 * @param b - Second number
 * @returns The sum of a and b
 * @throws {TypeError} If arguments are not numbers
 */
function add(a: number, b: number): number {
  return a + b
}
```

### README Examples

Include code examples in README:

```markdown
## Example Usage

### Basic Counter

\`\`\`typescript
import { useStorage } from '@infinitty/widget-sdk'

function Counter() {
  const [count, setCount] = useStorage('count', 0)
  return (
    <button onClick={() => setCount((count ?? 0) + 1)}>
      Count: {count}
    </button>
  )
}
\`\`\`
```

## Logging

### Strategic Logging

```typescript
const logger = useLogger()

// Debug level - detailed, development
logger.debug('Processing item:', item)

// Info level - notable events
logger.info('Data loaded successfully')

// Warn level - potentially problematic
logger.warn('Missing required field:', fieldName)

// Error level - failures
logger.error('Failed to save:', error.message)
```

### Don't Log Sensitive Data

```typescript
// Bad - logs API key
logger.info('Using API key:', apiKey)

// Good - logs safe info
logger.info('API key configured')
logger.debug('Making request to:', endpoint)
```

## Git Workflow

### Commit Messages

```
# Bad
git commit -m "fix"

# Good
git commit -m "Fix memory leak in event listeners

- Properly dispose subscriptions on unmount
- Add cleanup function to useEffect
- Fixes #42"
```

### Branch Names

```bash
# Feature
git checkout -b feature/dark-mode

# Bug fix
git checkout -b fix/memory-leak

# Documentation
git checkout -b docs/api-reference
```

## Checklist Before Publishing

- [ ] Code is typed (no `any`)
- [ ] Tests pass
- [ ] Linting passes
- [ ] No console errors
- [ ] Documentation complete
- [ ] README has examples
- [ ] No hardcoded secrets
- [ ] Version updated
- [ ] Changelog updated
- [ ] Performance acceptable
- [ ] Memory leaks addressed
- [ ] Error handling complete

## Tools & Linting

Setup ESLint:

```bash
npm install -D eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin
```

`.eslintrc.json`:

```json
{
  "parser": "@typescript-eslint/parser",
  "extends": [
    "plugin:@typescript-eslint/recommended"
  ],
  "rules": {
    "@typescript-eslint/no-explicit-any": "error",
    "@typescript-eslint/explicit-function-return-types": "error"
  }
}
```

## Next Steps

- [Testing Widgets](testing-widgets)
- [Packaging & Distribution](packaging-distribution)
- [Widget Examples](../examples/hello-world)

---
sidebar_position: 3
---

# Tool Widget Example

Create AI tools that Claude can use.

## Widget with Tool

### src/index.tsx

```typescript
import { defineWidget } from '@infinitty/widget-sdk'
import { z } from 'zod'
import { Component } from './Component'

// Define the tool schema
const SearchSchema = z.object({
  query: z.string().describe('What to search for'),
  limit: z.number().int().min(1).max(50).optional().describe('Max results (1-50)'),
})

export default defineWidget({
  id: 'com.example.search-tool-widget',
  name: 'Search Tool Widget',
  version: '1.0.0',
  description: 'Provides a search tool for Claude',

  activate(context, api, events) {
    context.log.info('Search tool widget activated')

    // Register the search tool
    api.registerTool({
      name: 'search_items',
      description: 'Search through a list of items. Returns matching items with names and descriptions.',
      inputSchema: SearchSchema,
      handler: async (args) => {
        // Validate input
        const validated = SearchSchema.parse(args)

        // Perform search
        const results = searchItems(
          validated.query,
          validated.limit ?? 10
        )

        context.log.info(`Search: "${validated.query}" returned ${results.length} results`)

        return {
          query: validated.query,
          count: results.length,
          results,
        }
      },
    })
  },

  Component,
})

// Mock data
const items = [
  { id: 1, name: 'TypeScript Guide', description: 'Complete TypeScript documentation' },
  { id: 2, name: 'React Hooks', description: 'Learning React hooks and patterns' },
  { id: 3, name: 'Widget SDK', description: 'Infinitty widget development guide' },
  { id: 4, name: 'API Reference', description: 'Complete API documentation' },
  { id: 5, name: 'Best Practices', description: 'Widget development best practices' },
  { id: 6, name: 'Testing Guide', description: 'How to test widgets' },
  { id: 7, name: 'Storage API', description: 'Storage and persistence in widgets' },
  { id: 8, name: 'Themes & Colors', description: 'Theme support and color schemes' },
]

// Search function
function searchItems(query: string, limit: number) {
  const normalizedQuery = query.toLowerCase()

  return items
    .filter(item =>
      item.name.toLowerCase().includes(normalizedQuery) ||
      item.description.toLowerCase().includes(normalizedQuery)
    )
    .slice(0, limit)
    .map(item => ({
      id: item.id,
      name: item.name,
      description: item.description,
      url: `https://docs.example.com/items/${item.id}`,
    }))
}
```

### src/Component.tsx

```typescript
import { useEffect, useState } from 'react'
import { useWidgetSDK, useTheme, useLogger } from '@infinitty/widget-sdk'

interface SearchResult {
  query: string
  count: number
  timestamp: Date
}

export function Component() {
  const { api, context, events } = useWidgetSDK()
  const theme = useTheme()
  const logger = useLogger()
  const [searchHistory, setSearchHistory] = useState<SearchResult[]>([])

  // Listen for tool calls
  useEffect(() => {
    const sub = events.onDidReceiveMessage((message: any) => {
      if (message.type === 'tool-call' && message.tool === 'search_items') {
        logger.info('Tool called:', message.args)
      }
    })

    return () => sub.dispose()
  }, [events, logger])

  const handleTestSearch = async () => {
    try {
      const result = await api.callTool('search_items', {
        query: 'TypeScript',
        limit: 5,
      })

      logger.info('Search result:', result)

      setSearchHistory(prev => [
        {
          query: 'TypeScript',
          count: (result as any).count || 0,
          timestamp: new Date(),
        },
        ...prev,
      ])

      api.showMessage(`Found ${(result as any).count || 0} results`, 'info')
    } catch (error) {
      logger.error('Search failed:', error)
      api.showMessage('Search failed', 'error')
    }
  }

  return (
    <div style={{
      padding: '20px',
      backgroundColor: theme.background,
      color: theme.foreground,
      fontFamily: 'system-ui, -apple-system, sans-serif',
      minHeight: '100vh',
    }}>
      <h1>Search Tool Widget</h1>

      <p style={{ marginBottom: '20px' }}>
        This widget provides a <code>search_items</code> tool that Claude can use to search through items.
      </p>

      {/* Tool Info */}
      <div style={{
        padding: '16px',
        backgroundColor: theme.brightBlack + '20',
        borderRadius: '6px',
        marginBottom: '20px',
        fontSize: '14px',
      }}>
        <h3 style={{ marginTop: 0 }}>Tool: search_items</h3>
        <p>
          <strong>Description:</strong> Search through a list of items
        </p>
        <p>
          <strong>Input Schema:</strong>
        </p>
        <pre style={{
          backgroundColor: theme.brightBlack + '40',
          padding: '12px',
          borderRadius: '4px',
          overflow: 'auto',
          fontSize: '12px',
        }}>
{`{
  query: string    // What to search for
  limit?: number   // Max results (1-50, default: 10)
}`}
        </pre>
      </div>

      {/* Test Button */}
      <button
        onClick={handleTestSearch}
        style={{
          padding: '8px 16px',
          backgroundColor: theme.cyan,
          color: theme.background,
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          marginBottom: '20px',
        }}
      >
        Test Search Tool
      </button>

      {/* Search History */}
      {searchHistory.length > 0 && (
        <div>
          <h3>Recent Searches</h3>
          <ul style={{ listStyle: 'none', padding: 0 }}>
            {searchHistory.map((result, i) => (
              <li
                key={i}
                style={{
                  padding: '12px',
                  backgroundColor: theme.brightBlack + '20',
                  borderRadius: '4px',
                  marginBottom: '8px',
                  fontSize: '14px',
                }}
              >
                <div style={{ fontWeight: 'bold' }}>
                  "{result.query}"
                </div>
                <div style={{ color: theme.brightBlack, fontSize: '12px' }}>
                  {result.count} results • {result.timestamp.toLocaleTimeString()}
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Usage Instructions */}
      <div style={{
        marginTop: '32px',
        padding: '16px',
        backgroundColor: theme.brightBlack + '10',
        borderRadius: '6px',
        fontSize: '13px',
        color: theme.brightBlack,
      }}>
        <h3 style={{ marginTop: 0 }}>How to Use</h3>
        <ol style={{ marginBottom: 0 }}>
          <li>Claude can automatically use this tool</li>
          <li>Claude will call search_items with a query</li>
          <li>The tool returns matching items</li>
          <li>Claude presents results to the user</li>
        </ol>
      </div>
    </div>
  )
}
```

## Tool Best Practices

### 1. Clear Descriptions

```typescript
// Good - clear what the tool does
{
  name: 'search_docs',
  description: 'Search documentation for a topic. Returns matching docs with URLs.',
  inputSchema: z.object({
    query: z.string().describe('Search query (e.g., "React hooks")'),
    limit: z.number().optional().describe('Maximum results to return (1-50)'),
  }),
  handler: async (args) => { /* ... */ },
}
```

### 2. Comprehensive Schema

```typescript
// Good - describes all parameters
const schema = z.object({
  query: z.string()
    .min(1, 'Query must not be empty')
    .max(100, 'Query too long')
    .describe('What to search for'),

  category: z.enum(['docs', 'api', 'examples'])
    .optional()
    .describe('Limit search to category'),

  limit: z.number()
    .int()
    .min(1)
    .max(50)
    .default(10)
    .describe('Results per page'),
})
```

### 3. Meaningful Return Values

```typescript
// Good - returns structured data
handler: async (args) => {
  const results = search(args.query)
  return {
    query: args.query,
    count: results.length,
    results: results.map(r => ({
      id: r.id,
      title: r.title,
      url: r.url,
      relevance: r.score,
    })),
  }
}
```

### 4. Error Handling

```typescript
handler: async (args) => {
  try {
    const results = await search(args.query)
    return { success: true, results }
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error',
    }
  }
}
```

## Multiple Tools

Register multiple tools:

```typescript
api.registerTool({
  name: 'search_docs',
  description: '...',
  inputSchema: SearchSchema,
  handler: searchDocs,
})

api.registerTool({
  name: 'get_doc_content',
  description: '...',
  inputSchema: z.object({ id: z.string() }),
  handler: getDocContent,
})

api.registerTool({
  name: 'list_categories',
  description: '...',
  inputSchema: z.object({}),
  handler: async () => ({ categories: ['api', 'guides', 'examples'] }),
})
```

## Testing Tools

```typescript
// Test tool registration
it('should register search tool', () => {
  const mockApi = { registerTool: vi.fn() }
  // Render widget with mock
  // ...
  expect(mockApi.registerTool).toHaveBeenCalled()
})

// Test tool handler
it('should search items correctly', async () => {
  const result = await searchItems('TypeScript', 10)
  expect(result).toHaveProperty('query')
  expect(result).toHaveProperty('count')
  expect(Array.isArray(result.results)).toBe(true)
})
```

## Next Steps

- [Storage Widget Example](storage-widget)
- [Host API Reference](../sdk-reference/host-api)
- [Best Practices](../widget-development/best-practices)

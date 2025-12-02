---
sidebar_position: 1
---

# Hello World Example

Your first Infinitty widget - a simple introduction to the SDK.

## Complete Hello World Widget

### manifest.json

```json
{
  "id": "com.example.hello-world",
  "name": "Hello World Widget",
  "version": "1.0.0",
  "description": "A simple Hello World widget",
  "author": "Your Name",
  "main": "dist/index.js",
  "ui": "dist/index.tsx"
}
```

### src/index.tsx

```typescript
import { defineWidget } from '@infinitty/widget-sdk'
import { Component } from './Component'

export default defineWidget({
  id: 'com.example.hello-world',
  name: 'Hello World',
  version: '1.0.0',
  description: 'Your first Infinitty widget',

  activate(context, api, events) {
    context.log.info('Hello World widget activated')
  },

  Component,
})
```

### src/Component.tsx

```typescript
import { useWidgetSDK, useTheme } from '@infinitty/widget-sdk'

export function Component() {
  const { context, api } = useWidgetSDK()
  const theme = useTheme()

  const handleClick = () => {
    api.showMessage('Hello from Infinitty!', 'info')
  }

  return (
    <div style={{
      padding: '20px',
      backgroundColor: theme.background,
      color: theme.foreground,
      fontFamily: 'system-ui, -apple-system, sans-serif',
      minHeight: '100vh',
    }}>
      <h1>Hello, World! 👋</h1>
      <p>
        This is your first Infinitty widget running in widget ID:
        <code style={{
          display: 'block',
          marginTop: '8px',
          padding: '8px 12px',
          backgroundColor: theme.brightBlack + '20',
          borderRadius: '4px',
          fontFamily: 'monospace',
          fontSize: '12px',
        }}>
          {context.widgetId}
        </code>
      </p>
      <button
        onClick={handleClick}
        style={{
          marginTop: '16px',
          padding: '8px 16px',
          backgroundColor: theme.cyan,
          color: theme.background,
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          fontSize: '14px',
          fontWeight: '500',
        }}
      >
        Click Me
      </button>
    </div>
  )
}
```

### package.json

```json
{
  "name": "@mycompany/hello-world-widget",
  "version": "1.0.0",
  "description": "Hello World widget for Infinitty",
  "main": "dist/index.js",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "test": "vitest"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "@infinitty/widget-sdk": "^0.1.0"
  },
  "devDependencies": {
    "@types/react": "^18.2.0",
    "@types/react-dom": "^18.2.0",
    "@vitejs/plugin-react": "^4.0.0",
    "typescript": "^5.0.0",
    "vite": "^4.0.0",
    "vitest": "^0.34.0"
  }
}
```

### vite.config.ts

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    lib: {
      entry: 'src/index.tsx',
      name: 'HelloWorldWidget',
      formats: ['es'],
    },
    rollupOptions: {
      external: ['react', 'react-dom'],
      output: {
        globals: {
          react: 'React',
          'react-dom': 'ReactDOM',
        },
      },
    },
  },
})
```

### tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "esModuleInterop": true,
    "strict": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "jsx": "react-jsx",
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.app.json" }]
}
```

## Running the Example

### Setup

```bash
# Install dependencies
npm install

# Build the widget
npm run build

# Start dev server
npm run dev
```

Visit `http://localhost:5173` to see your widget in the dev simulator.

### Using the Widget

1. Click the "Click Me" button
2. A message appears in the DevTools panel
3. Check "Messages" tab to see the message
4. Toggle between light/dark theme using the toolbar buttons

## What's Happening

### Widget Lifecycle

1. **Activation** - `activate()` called, logs "widget activated"
2. **Mount** - `Component` renders with theme and context
3. **Interaction** - User clicks button, `handleClick()` called
4. **API Call** - `api.showMessage()` displays message

### SDK Usage

- **`useWidgetSDK()`** - Access context, api, events
- **`useTheme()`** - Get theme colors for styling
- **`api.showMessage()`** - Show message to user
- **Theme colors** - Used for accessible, themeable UI

## Next Steps

- [Add Storage](../examples/storage-widget)
- [Create Tools](../examples/tool-widget)
- [Build Counter](../examples/counter-widget)
- [SDK Reference](../sdk-reference/hooks)

## Try It

Modify the component to:

1. Add a counter that persists
2. Show different messages based on clicks
3. Change colors based on theme
4. Add a second button

See the [Counter Example](counter-widget) for inspiration!

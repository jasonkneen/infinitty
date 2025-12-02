# Tauri 2.x Hybrid Build - Implementation Starter

Quick reference for getting started with the dual-build approach.

---

## Quick Start: 3-Step Setup

### Step 1: Create API Abstraction Files

Create these files in your `src/services/api/` directory:

**a) `src/services/api/types.ts`** - Interface definitions

```typescript
export interface FileSystemService {
  readFile(path: string): Promise<string>
  writeFile(path: string, contents: string): Promise<void>
  listDirectory(path: string): Promise<string[]>
  exists(path: string): Promise<boolean>
}

export interface ShellService {
  execute(program: string, args?: string[]): Promise<string>
}

export interface DialogService {
  openFile(): Promise<string | null>
  saveFile(): Promise<string | null>
}

export interface APIClient {
  fs: FileSystemService
  shell: ShellService
  dialog: DialogService
}
```

**b) `src/services/api/platform.ts`** - Runtime detection

```typescript
export const isPlatformTauri = (): boolean => {
  try {
    return typeof window !== 'undefined' && '__TAURI__' in window
  } catch {
    return false
  }
}

export const getPlatform = () => (isPlatformTauri() ? 'tauri' : 'web')
```

**c) `src/services/api/tauri-impl.ts`** - Desktop implementation

```typescript
import { readTextFile, writeTextFile, readDir } from '@tauri-apps/plugin-fs'
import { Command } from '@tauri-apps/plugin-shell'
import { open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'
import type { APIClient } from './types'

export const tauriImpl: APIClient = {
  fs: {
    async readFile(path: string): Promise<string> {
      return await readTextFile(path)
    },
    async writeFile(path: string, contents: string): Promise<void> {
      return await writeTextFile(path, contents)
    },
    async listDirectory(path: string): Promise<string[]> {
      const entries = await readDir(path)
      return entries.map((e) => e.name)
    },
    async exists(path: string): Promise<boolean> {
      try {
        await readTextFile(path)
        return true
      } catch {
        return false
      }
    },
  },
  shell: {
    async execute(program: string, args?: string[]): Promise<string> {
      const command = new Command(program, args)
      const output = await command.execute()
      return output.stdout
    },
  },
  dialog: {
    async openFile(): Promise<string | null> {
      return await openDialog()
    },
    async saveFile(): Promise<string | null> {
      return await saveDialog()
    },
  },
}
```

**d) `src/services/api/web-impl.ts`** - Web implementation

```typescript
import type { APIClient } from './types'

export const webImpl: APIClient = {
  fs: {
    async readFile(path: string): Promise<string> {
      const res = await fetch(path)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      return await res.text()
    },
    async writeFile(path: string, contents: string): Promise<void> {
      console.warn('File write not available in web mode')
      // Could use IndexedDB here
    },
    async listDirectory(path: string): Promise<string[]> {
      console.warn('Directory listing not available in web mode')
      return []
    },
    async exists(path: string): Promise<boolean> {
      try {
        const res = await fetch(path, { method: 'HEAD' })
        return res.ok
      } catch {
        return false
      }
    },
  },
  shell: {
    async execute(): Promise<string> {
      throw new Error('Shell execution not available in web mode')
    },
  },
  dialog: {
    async openFile(): Promise<string | null> {
      return new Promise((resolve) => {
        const input = document.createElement('input')
        input.type = 'file'
        input.onchange = (e) => {
          const file = (e.target as HTMLInputElement).files?.[0]
          resolve(file?.name ?? null)
        }
        input.click()
      })
    },
    async saveFile(): Promise<string | null> {
      return prompt('Enter filename:')
    },
  },
}
```

**e) `src/services/api/factory.ts`** - Factory pattern

```typescript
import { isPlatformTauri } from './platform'
import { tauriImpl } from './tauri-impl'
import { webImpl } from './web-impl'
import type { APIClient } from './types'

export function createAPIClient(): APIClient {
  return isPlatformTauri() ? tauriImpl : webImpl
}

export const api = createAPIClient()
```

**f) `src/services/api/index.ts`** - Public exports

```typescript
export { api } from './factory'
export { isPlatformTauri, getPlatform } from './platform'
export type { APIClient, FileSystemService, ShellService, DialogService } from './types'
```

### Step 2: Update Vite Configuration

**File: `vite.config.ts`**

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const buildTarget = process.env.BUILD_TARGET || 'tauri'

export default defineConfig({
  plugins: [react()],

  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },

  define: {
    __BUILD_TARGET__: JSON.stringify(buildTarget),
    __IS_TAURI__: buildTarget === 'tauri',
  },

  server: {
    port: 1420,
    strictPort: buildTarget === 'tauri',
    host: process.env.TAURI_DEV_HOST || 'localhost',
  },

  build: {
    outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
  },

  clearScreen: buildTarget === 'tauri' ? false : true,
})
```

### Step 3: Update package.json Scripts

```json
{
  "scripts": {
    "dev": "vite",
    "dev:web": "BUILD_TARGET=web vite",
    "build": "tsc && vite build",
    "build:web": "tsc && BUILD_TARGET=web vite build",
    "preview:web": "BUILD_TARGET=web vite preview"
  }
}
```

---

## Usage Examples

### Using File Operations

```typescript
import { api, isPlatformTauri } from '@/services/api'

export function FileEditor() {
  const [canSave, setCanSave] = useState(isPlatformTauri())

  const handleSave = async (content: string) => {
    try {
      const path = await api.dialog.saveFile()
      if (path) {
        await api.fs.writeFile(path, content)
      }
    } catch (error) {
      console.error('Save failed:', error)
    }
  }

  return (
    <div>
      <button disabled={!canSave} onClick={() => handleSave('content')}>
        Save
      </button>
      {!canSave && <p>Save not available in web mode</p>}
    </div>
  )
}
```

### Using Shell Commands

```typescript
import { api, isPlatformTauri } from '@/services/api'

export function Terminal() {
  const [output, setOutput] = useState('')

  const executeCommand = async (cmd: string) => {
    try {
      const result = await api.shell.execute('sh', ['-c', cmd])
      setOutput(result)
    } catch (error) {
      if (!isPlatformTauri()) {
        setOutput('Shell execution not available in web mode')
      } else {
        setOutput(`Error: ${error}`)
      }
    }
  }

  return (
    <div>
      <input onKeyDown={(e) => {
        if (e.key === 'Enter') {
          executeCommand(e.currentTarget.value)
        }
      }} />
      <pre>{output}</pre>
    </div>
  )
}
```

### Using Dialogs

```typescript
import { api } from '@/services/api'

export function FileSelector() {
  const selectFile = async () => {
    try {
      const path = await api.dialog.openFile()
      if (path) {
        const content = await api.fs.readFile(path)
        console.log('File content:', content)
      }
    } catch (error) {
      console.error('Failed to select file:', error)
    }
  }

  return <button onClick={selectFile}>Open File</button>
}
```

---

## Build Commands Reference

```bash
# Development
npm run dev              # Develop for Tauri
npm run dev:web         # Develop for web

# Production
npm run build           # Build for Tauri
npm run build:web       # Build for web
npm run preview:web     # Preview web build

# Testing
npm run test            # Run tests (always web mode)
```

---

## File Structure After Implementation

```
src/
├── services/
│   └── api/
│       ├── index.ts           # Public API
│       ├── types.ts           # Interface definitions
│       ├── platform.ts        # Runtime detection
│       ├── factory.ts         # Factory pattern
│       ├── tauri-impl.ts      # Desktop implementation
│       ├── web-impl.ts        # Web implementation
│       └── __tests__/
│           └── factory.test.ts
├── components/
│   ├── FileEditor.tsx         # Updated to use api
│   └── Terminal.tsx           # Updated to use api
└── App.tsx                    # Root component
```

---

## Common Patterns

### Pattern 1: Feature Gating

```typescript
import { isPlatformTauri } from '@/services/api'

export function AdvancedFeature() {
  if (!isPlatformTauri()) {
    return <p>This feature requires the desktop application</p>
  }
  return <RealFeature />
}
```

### Pattern 2: Graceful Fallback

```typescript
export async function loadFile(path: string) {
  try {
    return await api.fs.readFile(path)
  } catch (error) {
    console.warn('File load failed, using default:', error)
    return 'Default content'
  }
}
```

### Pattern 3: Error Handling

```typescript
export async function executeWithFallback(cmd: string) {
  try {
    return await api.shell.execute('sh', ['-c', cmd])
  } catch (error) {
    if (!isPlatformTauri()) {
      return '[Web mode] ' + cmd
    }
    throw error
  }
}
```

---

## Troubleshooting

### Tauri Imports Failing in Web Build

**Problem:** Build fails with "Cannot find module '@tauri-apps/plugin-fs'"

**Solution:** Make sure web-impl.ts doesn't import Tauri modules. Check your imports:

```typescript
// WRONG
import { readTextFile } from '@tauri-apps/plugin-fs'

// RIGHT
// Web implementation uses native APIs only
const response = await fetch(path)
```

### Type Errors in Tests

**Problem:** TypeScript errors about Tauri globals

**Solution:** Add to `src/vite-env.d.ts`:

```typescript
/// <reference types="vite/client" />

declare global {
  const __BUILD_TARGET__: string
  const __IS_TAURI__: boolean
}
```

### Build Target Not Detected

**Problem:** `BUILD_TARGET` env var not working

**Solution:** Make sure to set it in the npm script:

```bash
# RIGHT
BUILD_TARGET=web npm run build

# WRONG (env var not propagated)
npm run build BUILD_TARGET=web
```

---

## Next Steps

1. Copy the API abstraction files above
2. Update vite.config.ts with new build target logic
3. Update package.json scripts
4. Test: `npm run dev` and `npm run dev:web`
5. Migrate components to use the abstracted API
6. Add feature gates for platform-specific features
7. Test both build outputs

---

## Quick Testing Checklist

- [ ] `npm run dev` starts Tauri dev server
- [ ] `npm run dev:web` starts web dev server
- [ ] `npm run build` creates `dist/` folder
- [ ] `npm run build:web` creates `web-dist/` folder
- [ ] File operations work in Tauri mode
- [ ] File operations fail gracefully in web mode
- [ ] Shell commands work in Tauri mode
- [ ] Shell commands fail gracefully in web mode
- [ ] All tests pass with `npm run test`

---

**Last Updated:** December 9, 2025

# Tauri 2.x + Web Hybrid Build Guide

**Last Updated:** December 9, 2025
**Framework Versions:**
- Tauri: 2.x (v2.0+)
- Vite: 7.x (v7.0.4)
- React: 19.x

---

## Summary

This guide provides a comprehensive approach to structuring a Tauri 2.x project for both native desktop and web deployments. The strategy involves creating abstraction layers for Tauri-specific APIs, conditional compilation based on build target, and a unified Vite configuration that supports both outputs.

**Current Project Context:**
- Application: `infinitty` - a terminal/IDE interface
- Frontend: React 19 with TypeScript
- Backend: Tauri 2.x with Rust
- Dependencies: CodeMirror, xterm.js, Tauri plugins (fs, shell, dialog, opener)

---

## 1. Project Structure for Hybrid Builds

### 1.1 Recommended Directory Organization

```
hybrid-terminal/
├── src/                           # Shared frontend code (React + TS)
│   ├── main.tsx                   # Entry point
│   ├── App.tsx                    # Root component
│   ├── components/                # React components
│   ├── services/                  # Business logic
│   │   ├── api/                   # API abstraction layer
│   │   │   ├── tauri-api.ts       # Tauri-specific implementations
│   │   │   ├── web-api.ts         # Web-compatible alternatives
│   │   │   └── api-factory.ts     # Conditional factory
│   │   └── ...
│   ├── hooks/                     # React hooks
│   ├── contexts/                  # React contexts
│   ├── types/                     # TypeScript definitions
│   └── lib/                       # Utilities
│
├── src-tauri/                     # Tauri Rust backend
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs
│   │   ├── commands/
│   │   └── ...
│   └── tauri.conf.json
│
├── vite.config.ts                # Unified build configuration
├── vite.env.d.ts
├── tsconfig.json
├── package.json
│
├── dist/                         # Tauri build output
├── web-dist/                     # Web build output (optional)
└── .env files                    # Environment variables per target
```

### 1.2 Environment-Specific Configurations

Create environment files for conditional behavior:

```
.env                              # Default
.env.tauri                        # Tauri desktop build
.env.web                          # Web deployment
```

---

## 2. Tauri API Abstraction Layer

### 2.1 Abstraction Strategy

**Core Principle:** All Tauri-specific operations should be abstracted through a factory pattern that returns either Tauri implementations (desktop) or web-compatible alternatives (browser).

### 2.2 API Abstraction Implementation

**File: `src/services/api/api-factory.ts`**

```typescript
// Detect runtime environment
const isTauri = () => {
  try {
    // Check for Tauri-specific globals
    return '__TAURI__' in window && window.__TAURI__ !== undefined
  } catch {
    return false
  }
}

export const API_PLATFORM = isTauri() ? 'tauri' : 'web'

// Factory function pattern
export function createAPI() {
  if (isTauri()) {
    return tauriAPI
  } else {
    return webAPI
  }
}
```

**File: `src/services/api/tauri-api.ts`** (Tauri Desktop Implementation)

```typescript
import { invoke } from '@tauri-apps/api/core'
import { open, readTextFile, writeTextFile, readDir } from '@tauri-apps/plugin-fs'
import { Command } from '@tauri-apps/plugin-shell'
import { open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'

interface FileSystemAPI {
  readFile(path: string): Promise<string>
  writeFile(path: string, contents: string): Promise<void>
  listDirectory(path: string): Promise<string[]>
  exists(path: string): Promise<boolean>
}

interface CommandAPI {
  execute(program: string, args: string[]): Promise<string>
}

interface DialogAPI {
  openFile(): Promise<string | null>
  saveFile(): Promise<string | null>
}

export const tauriAPI = {
  fs: {
    async readFile(path: string): Promise<string> {
      try {
        return await readTextFile(path)
      } catch (error) {
        throw new Error(`Failed to read file: ${error}`)
      }
    },

    async writeFile(path: string, contents: string): Promise<void> {
      try {
        await writeTextFile(path, contents)
      } catch (error) {
        throw new Error(`Failed to write file: ${error}`)
      }
    },

    async listDirectory(path: string): Promise<string[]> {
      try {
        const entries = await readDir(path)
        return entries.map((e) => e.name)
      } catch (error) {
        throw new Error(`Failed to list directory: ${error}`)
      }
    },

    async exists(path: string): Promise<boolean> {
      try {
        await readTextFile(path)
        return true
      } catch {
        return false
      }
    },
  } as FileSystemAPI,

  shell: {
    async execute(program: string, args: string[] = []): Promise<string> {
      try {
        const command = new Command(program, args)
        const output = await command.execute()
        return output.stdout
      } catch (error) {
        throw new Error(`Command failed: ${error}`)
      }
    },
  } as CommandAPI,

  dialog: {
    async openFile(): Promise<string | null> {
      try {
        return await openDialog({
          multiple: false,
          filters: [{ name: 'All Files', extensions: ['*'] }],
        })
      } catch (error) {
        console.error('Failed to open file dialog:', error)
        return null
      }
    },

    async saveFile(): Promise<string | null> {
      try {
        return await saveDialog({
          filters: [{ name: 'All Files', extensions: ['*'] }],
        })
      } catch (error) {
        console.error('Failed to open save dialog:', error)
        return null
      }
    },
  } as DialogAPI,
}
```

**File: `src/services/api/web-api.ts`** (Web Browser Alternative)

```typescript
// Web-compatible implementations with graceful degradation

export const webAPI = {
  fs: {
    async readFile(path: string): Promise<string> {
      // Use FileReader API or IndexedDB fallback
      try {
        const response = await fetch(path)
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`)
        }
        return await response.text()
      } catch (error) {
        throw new Error(`Failed to read file: ${error}`)
      }
    },

    async writeFile(path: string, contents: string): Promise<void> {
      // Use IndexedDB for persistent storage
      return new Promise((resolve, reject) => {
        const request = indexedDB.open('FileSystemDB', 1)

        request.onerror = () => reject(new Error('Failed to open IndexedDB'))

        request.onsuccess = () => {
          const db = request.result
          const transaction = db.transaction(['files'], 'readwrite')
          const store = transaction.objectStore('files')
          store.put({ path, contents, timestamp: Date.now() })

          transaction.oncomplete = () => resolve()
          transaction.onerror = () => reject(transaction.error)
        }

        request.onupgradeneeded = (event) => {
          const db = (event.target as IDBOpenDBRequest).result
          if (!db.objectStoreNames.contains('files')) {
            db.createObjectStore('files', { keyPath: 'path' })
          }
        }
      })
    },

    async listDirectory(path: string): Promise<string[]> {
      // Return empty array - directory listing not available in web
      console.warn('Directory listing not available in web mode')
      return []
    },

    async exists(path: string): Promise<boolean> {
      try {
        const response = await fetch(path, { method: 'HEAD' })
        return response.ok
      } catch {
        return false
      }
    },
  },

  shell: {
    async execute(program: string, args: string[] = []): Promise<string> {
      // Fallback: return error message
      throw new Error(
        `Shell command execution not available in web mode: ${program} ${args.join(' ')}`
      )
    },
  },

  dialog: {
    async openFile(): Promise<string | null> {
      // Use HTML5 File Input
      return new Promise((resolve) => {
        const input = document.createElement('input')
        input.type = 'file'
        input.onchange = (e) => {
          const file = (e.target as HTMLInputElement).files?.[0]
          if (file) {
            resolve(file.name)
          } else {
            resolve(null)
          }
        }
        input.click()
      })
    },

    async saveFile(): Promise<string | null> {
      // Use HTML5 Download
      return new Promise((resolve) => {
        const filename = prompt('Enter filename:')
        resolve(filename)
      })
    },
  },
}
```

**File: `src/services/api/index.ts`** (Unified Export)

```typescript
import { API_PLATFORM, createAPI } from './api-factory'

export const api = createAPI()
export { API_PLATFORM }

// Type exports for consumers
export type { FileSystemAPI, CommandAPI, DialogAPI }
```

### 2.3 Usage in Components

```typescript
// src/components/FileEditor.tsx
import { api, API_PLATFORM } from '../services/api'

export function FileEditor() {
  const [content, setContent] = useState('')
  const [isNative] = useState(API_PLATFORM === 'tauri')

  const handleOpen = async () => {
    try {
      const file = await api.dialog.openFile()
      if (file) {
        const contents = await api.fs.readFile(file)
        setContent(contents)
      }
    } catch (error) {
      console.error('Failed to open file:', error)
      // Show user-friendly error
    }
  }

  return (
    <div>
      <button onClick={handleOpen}>
        {isNative ? 'Open File' : 'Load (Limited)'}
      </button>
      {!isNative && (
        <p className="text-yellow-600 text-sm">
          Running in web mode - file operations have limited functionality
        </p>
      )}
    </div>
  )
}
```

---

## 3. Tauri-Specific APIs to Abstract/Mock

### 3.1 Critical APIs Requiring Abstraction

Based on your dependencies, abstract these Tauri APIs:

| API | Desktop (Tauri) | Web Fallback | Status |
|-----|-----------------|--------------|--------|
| **File System** | `@tauri-apps/plugin-fs` | IndexedDB / Fetch | Essential |
| **Shell Commands** | `@tauri-apps/plugin-shell` | Error stub / Web APIs | Critical |
| **File Dialogs** | `@tauri-apps/plugin-dialog` | HTML5 File Input | Essential |
| **Opener** | `@tauri-apps/plugin-opener` | `window.open()` | Important |
| **Window Control** | `@tauri-apps/api/window` | Error stub | Important |
| **Process Info** | `@tauri-apps/api/os` | Browser info | Nice-to-have |

### 3.2 xterm.js + Terminal Emulation (Special Case)

Your project uses `@xterm/xterm` for terminal emulation. This requires special handling:

**Desktop (Tauri):** Can execute real shell commands via `@tauri-apps/plugin-shell`

**Web:** Limited options - use:
1. WebSockets to a remote server
2. Local terminal simulation (mock/demo mode)
3. Web Terminal libraries (Pyodide, xterm.js with mock backend)

**File: `src/services/terminal-service.ts`**

```typescript
import { api, API_PLATFORM } from './api'

interface TerminalSession {
  execute(command: string): Promise<string>
  close(): void
}

export async function createTerminalSession(): Promise<TerminalSession> {
  if (API_PLATFORM === 'tauri') {
    // Real shell via Tauri
    return new TauriTerminalSession()
  } else {
    // Mock terminal for web
    return new MockTerminalSession()
  }
}

class TauriTerminalSession implements TerminalSession {
  async execute(command: string): Promise<string> {
    try {
      return await api.shell.execute(command)
    } catch (error) {
      throw new Error(`Command failed: ${error}`)
    }
  }

  close(): void {
    // No cleanup needed for shell
  }
}

class MockTerminalSession implements TerminalSession {
  private history: string[] = []

  async execute(command: string): Promise<string> {
    // Mock implementations for common commands
    const output = this.mockExecute(command)
    this.history.push(`$ ${command}`)
    this.history.push(output)
    return output
  }

  private mockExecute(command: string): string {
    const cmd = command.trim().toLowerCase()

    if (cmd.startsWith('ls') || cmd.startsWith('dir')) {
      return '[mock] index.ts\n[mock] App.tsx\n[mock] components/'
    }
    if (cmd === 'pwd') {
      return '/home/user/project'
    }
    if (cmd === 'whoami') {
      return 'web-user'
    }
    if (cmd.startsWith('echo ')) {
      return command.substring(5)
    }

    return `[mock] ${command}: command not found`
  }

  close(): void {
    // No cleanup needed
  }
}
```

---

## 4. Vite Configuration for Dual Builds

### 4.1 Unified Vite Configuration

**File: `vite.config.ts`** (Enhanced for Both Targets)

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const isTauriDevMode = process.env.TAURI_DEV_HOST !== undefined
const buildTarget = process.env.BUILD_TARGET || (isTauriDevMode ? 'tauri' : 'web')

export default defineConfig(async () => ({
  plugins: [react()],

  // Shared configuration
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },

  define: {
    __TAURI_BUILD_TARGET__: JSON.stringify(buildTarget),
    __IS_TAURI__: buildTarget === 'tauri',
  },

  // Development server configuration
  server: {
    port: 1420,
    strictPort: isTauriDevMode,
    host: process.env.TAURI_DEV_HOST || 'localhost',
    hmr: process.env.TAURI_DEV_HOST
      ? {
          protocol: 'ws',
          host: process.env.TAURI_DEV_HOST,
          port: 1421,
        }
      : undefined,
    watch: {
      ignored: ['**/src-tauri/**'],
    },
  },

  // Build configuration
  build: {
    outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
    sourcemap: process.env.NODE_ENV === 'development',
    minify: process.env.NODE_ENV === 'production' ? 'esbuild' : false,
    rollupOptions: {
      output: {
        manualChunks: {
          // Separate vendor chunks for better caching
          'vendor-ui': ['react', 'react-dom'],
          'vendor-codemirror': [
            '@codemirror/view',
            '@codemirror/state',
            '@codemirror/lang-javascript',
          ],
          'vendor-terminal': ['@xterm/xterm', '@xterm/addon-fit'],
        },
      },
    },
  },

  // CSS configuration
  css: {
    postcss: './postcss.config.js',
  },

  clearScreen: buildTarget === 'tauri' ? false : true,
}))
```

### 4.2 Environment-Specific Build Scripts

**File: `package.json`** (Updated Scripts)

```json
{
  "scripts": {
    "dev": "vite",
    "dev:web": "BUILD_TARGET=web vite",
    "build": "tsc && vite build",
    "build:tauri": "VITE_INTERFACE_MODE=ghostty BUILD_TARGET=tauri vite build",
    "build:web": "tsc && BUILD_TARGET=web vite build",
    "preview": "vite preview",
    "preview:web": "BUILD_TARGET=web vite preview",
    "tauri": "tauri",
    "test": "vitest",
    "test:run": "vitest run",
    "test:coverage": "vitest run --coverage"
  }
}
```

---

## 5. Handling Platform-Specific Code

### 5.1 Conditional Imports Pattern

```typescript
// src/services/platform.ts

export const isPlatformTauri =
  typeof window !== 'undefined' && '__TAURI__' in window

// Conditional imports at module level
let fileSystem: any

if (isPlatformTauri) {
  // Only imported on desktop
  import('@tauri-apps/plugin-fs').then((module) => {
    fileSystem = module
  })
} else {
  // Web polyfill/mock
  fileSystem = {
    readTextFile: () => Promise.reject('Not available in web'),
  }
}

export { fileSystem }
```

### 5.2 Runtime Feature Detection

```typescript
// src/lib/features.ts

interface FeatureFlags {
  hasFileSystem: boolean
  hasShell: boolean
  hasNativeDialogs: boolean
  hasWindowControl: boolean
  isNativeApp: boolean
}

export function getFeatureFlags(): FeatureFlags {
  const isTauri = typeof window !== 'undefined' && '__TAURI__' in window

  return {
    hasFileSystem: isTauri,
    hasShell: isTauri,
    hasNativeDialogs: isTauri,
    hasWindowControl: isTauri,
    isNativeApp: isTauri,
  }
}

// Usage in components
import { getFeatureFlags } from '../lib/features'

export function Editor() {
  const features = getFeatureFlags()

  return (
    <div>
      {features.hasFileSystem && <FileOpenButton />}
      {!features.hasFileSystem && (
        <p className="text-amber-600">
          File operations not available in this mode
        </p>
      )}
    </div>
  )
}
```

---

## 6. Static File Serving Configuration

### 6.1 Vite Public Assets

Create a `public/` directory for assets needed in both builds:

```
public/
├── favicon.ico
├── assets/
│   ├── icons/
│   ├── fonts/
│   └── images/
└── robots.txt
```

### 6.2 Vite Asset Handling

```typescript
// vite.config.ts - Asset configuration

export default defineConfig({
  build: {
    assetsInlineLimit: 4096, // Inline assets smaller than 4kb
    assetsDir: 'assets',
    rollupOptions: {
      output: {
        assetFileNames: (assetInfo) => {
          const info = assetInfo.name.split('.')
          const ext = info[info.length - 1]
          if (/png|jpe?g|gif|svg/.test(ext)) {
            return `assets/images/[name]-[hash][extname]`
          } else if (/woff|woff2|eot|ttf|otf/.test(ext)) {
            return `assets/fonts/[name]-[hash][extname]`
          }
          return `assets/[name]-[hash][extname]`
        },
      },
    },
  },
})
```

### 6.3 Asset Import Examples

```typescript
// Recommended: Explicit URL imports
import logoUrl from '../assets/logo.png?url'
import shaderCode from '../assets/shader.glsl?raw'
import WorkerClass from '../lib/worker.js?worker'
import InlineWorker from '../lib/small-worker.js?worker&inline'

export function App() {
  return (
    <div>
      <img src={logoUrl} alt="Logo" />
      {/* shader code as string */}
      {/* worker instances */}
    </div>
  )
}
```

---

## 7. Best Practices for Hybrid Projects

### 7.1 API Contract Pattern

Define clear interfaces at the service layer:

```typescript
// src/services/contracts.ts

export interface FileSystemService {
  readFile(path: string): Promise<string>
  writeFile(path: string, content: string): Promise<void>
  listDirectory(path: string): Promise<FileEntry[]>
  exists(path: string): Promise<boolean>
}

export interface CommandExecutor {
  execute(command: string, args?: string[]): Promise<CommandOutput>
}

export interface DialogProvider {
  openFile(options?: OpenFileOptions): Promise<string | null>
  saveFile(options?: SaveFileOptions): Promise<string | null>
  showAlert(message: string): Promise<void>
}

// Implementations must satisfy these contracts
```

### 7.2 Error Handling Strategy

```typescript
// src/lib/errors.ts

export class PlatformNotSupportedError extends Error {
  constructor(feature: string, platform: string = 'web') {
    super(`${feature} is not available on ${platform}`)
    this.name = 'PlatformNotSupportedError'
  }
}

export class FileAccessError extends Error {
  constructor(path: string, operation: string, cause?: Error) {
    super(`Failed to ${operation} file "${path}": ${cause?.message}`)
    this.name = 'FileAccessError'
  }
}

// Usage
import { api, API_PLATFORM } from '../services/api'

async function openProjectFile(path: string) {
  if (API_PLATFORM !== 'tauri') {
    throw new PlatformNotSupportedError('Project file loading', 'web')
  }

  try {
    return await api.fs.readFile(path)
  } catch (error) {
    throw new FileAccessError(path, 'read', error as Error)
  }
}
```

### 7.3 Graceful Degradation UI Pattern

```typescript
// src/components/FeatureGuard.tsx

interface FeatureGuardProps {
  feature: keyof ReturnType<typeof getFeatureFlags>
  fallback?: React.ReactNode
  children: React.ReactNode
}

export function FeatureGuard({
  feature,
  fallback,
  children,
}: FeatureGuardProps) {
  const features = getFeatureFlags()
  const isSupported = features[feature]

  if (!isSupported) {
    return (
      fallback || (
        <div className="p-4 bg-amber-100 border border-amber-300 rounded">
          <p className="text-amber-900">
            This feature is not available in your current environment.
          </p>
        </div>
      )
    )
  }

  return <>{children}</>
}

// Usage
export function FileOperations() {
  return (
    <FeatureGuard
      feature="hasFileSystem"
      fallback={<p>File operations require desktop app</p>}
    >
      <FileEditor />
    </FeatureGuard>
  )
}
```

---

## 8. Testing Strategy for Hybrid Builds

### 8.1 Vitest Configuration with Environment Flag

**File: `vitest.config.ts`**

```typescript
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
    },
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  define: {
    __IS_TAURI__: false, // Tests always run in web mode
  },
})
```

### 8.2 Mock Tauri APIs for Testing

**File: `src/test/setup.ts`**

```typescript
import { vi } from 'vitest'

// Mock Tauri globally
global.__TAURI__ = {
  core: {
    invoke: vi.fn(),
  },
} as any

// Mock Tauri plugins
vi.mock('@tauri-apps/plugin-fs', () => ({
  readTextFile: vi.fn(),
  writeTextFile: vi.fn(),
  readDir: vi.fn(),
}))

vi.mock('@tauri-apps/plugin-shell', () => ({
  Command: class MockCommand {
    constructor(program: string, args?: string[]) {
      this.program = program
      this.args = args || []
    }
    async execute() {
      return { stdout: '', stderr: '' }
    }
  },
}))

vi.mock('@tauri-apps/plugin-dialog', () => ({
  open: vi.fn(),
  save: vi.fn(),
}))
```

### 8.3 Test Examples

```typescript
// src/services/api/__tests__/api-factory.test.ts

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createAPI, API_PLATFORM } from '../api-factory'

describe('API Factory', () => {
  beforeEach(() => {
    // Reset window context
    ;(window as any).__TAURI__ = undefined
  })

  it('should create web API when Tauri is not available', () => {
    const api = createAPI()
    expect(API_PLATFORM).toBe('web')
    expect(api).toBeDefined()
  })

  it('should handle file operations in web mode', async () => {
    const api = createAPI()
    // Mock fetch for web API
    global.fetch = vi.fn(() =>
      Promise.resolve(
        new Response('file contents', { status: 200 })
      )
    )

    const content = await api.fs.readFile('/test.txt')
    expect(content).toBe('file contents')
  })

  it('should throw error for shell commands in web mode', async () => {
    const api = createAPI()
    await expect(api.shell.execute('ls')).rejects.toThrow(
      'not available in web mode'
    )
  })
})
```

---

## 9. Deployment Considerations

### 9.1 Tauri Desktop Build

```bash
# Build for desktop
npm run build:tauri

# Creates: dist/ directory
# Outputs: Platform-specific binaries (.dmg, .exe, .AppImage)
```

### 9.2 Web Deployment

```bash
# Build for web
npm run build:web

# Creates: web-dist/ directory
# Outputs: Static assets ready for CDN/hosting
```

### 9.3 Docker Deployment (Web)

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY . .
RUN npm install && npm run build:web

FROM nginx:alpine
COPY --from=builder /app/web-dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## 10. Common Issues & Solutions

### 10.1 xterm.js Terminal in Web Mode

**Problem:** Terminal commands fail in web.
**Solution:**

```typescript
// Implement mock terminal or WebSocket backend
if (API_PLATFORM === 'web') {
  term.writeln('Warning: Running in web mode with limited terminal')
  // Use mock or remote backend
} else {
  // Use real shell via Tauri
}
```

### 10.2 File Operations Without FileSystem API

**Problem:** `@tauri-apps/plugin-fs` not available in web.
**Solution:** Use IndexedDB + Fetch pattern (already implemented in web-api.ts)

### 10.3 Dynamic Imports of Tauri Modules

**Problem:** Build fails with Tauri imports on web.
**Solution:**

```typescript
// Use dynamic imports in try-catch
let shellAPI: any = null
if (typeof window !== 'undefined' && '__TAURI__' in window) {
  import('@tauri-apps/plugin-shell').then((m) => {
    shellAPI = m
  })
}
```

### 10.4 Environment Variable Access

**Problem:** Environment variables from Tauri not available in web.
**Solution:**

```typescript
// Define via Vite's define option
export const BUILD_TARGET = import.meta.env.__TAURI_BUILD_TARGET__
export const IS_TAURI = import.meta.env.__IS_TAURI__
```

---

## 11. Official Documentation References

### Tauri 2.x
- [Tauri 2.0 Stable Release](https://v2.tauri.app/blog/tauri-20/)
- [Tauri Architecture](https://v2.tauri.app/concept/architecture/)
- [Frontend Configuration Guide](https://v2.tauri.app/start/frontend/)
- [Tauri API Documentation](https://v2.tauri.app/reference/javascript/)
- [Plugin System](https://v2.tauri.app/plugin/)

### Vite
- [Vite Build Configuration](https://vite.dev/config/build-options)
- [Library Mode](https://vite.dev/guide/build.html#library-mode)
- [Environment Variables](https://vite.dev/guide/env-and-mode.html)
- [Backend Integration](https://vite.dev/guide/backend-integration.html)

### WRY & TAO (Tauri Internal Libraries)
- [WRY - WebView Library](https://github.com/tauri-apps/wry)
- [TAO - Window Management](https://github.com/tauri-apps/tao)

---

## 12. Implementation Roadmap for Your Project

Based on the current `infinitty` structure:

### Phase 1: API Abstraction (Week 1)
- [ ] Create `services/api/` folder structure
- [ ] Implement `tauri-api.ts` and `web-api.ts`
- [ ] Create API factory pattern
- [ ] Update `package.json` with new build scripts

### Phase 2: Component Updates (Week 2)
- [ ] Audit existing components for Tauri dependencies
- [ ] Add FeatureGuard wrapper components
- [ ] Update file operations to use abstracted API
- [ ] Add graceful degradation messages

### Phase 3: Terminal Handling (Week 3)
- [ ] Implement `terminal-service.ts` with mock backend
- [ ] Update xterm integration to use terminal service
- [ ] Test in both modes
- [ ] Add terminal mode indicator

### Phase 4: Testing & Validation (Week 4)
- [ ] Implement test suite for API layer
- [ ] Test both build outputs
- [ ] Deploy web version to staging
- [ ] Performance benchmarking

---

## 13. Key Takeaways

1. **Abstraction is Critical:** All platform-specific code must be abstracted through factory patterns
2. **Graceful Degradation:** UI should adapt based on available features
3. **Feature Detection:** Use runtime checks, not just build-time flags
4. **Unified Builds:** Single Vite config with environment variables for dual targets
5. **Separation of Concerns:** Keep Tauri code isolated from React components
6. **Testing:** Mock all Tauri APIs for unit tests
7. **Documentation:** Clearly document which APIs are available in which contexts

---

**Last Updated:** December 9, 2025
**Maintainer:** J. Kneen
**Status:** Complete Research Document

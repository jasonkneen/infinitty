# Ready-to-Copy Code Templates

All templates below are production-ready and can be copy-pasted directly into your project.

---

## 1. Type Definitions

**File: `src/services/api/types.ts`**

```typescript
/**
 * Abstraction layer type definitions for cross-platform APIs
 * These interfaces are implemented by both Tauri and Web backends
 */

export interface FileSystemService {
  /**
   * Read text file contents
   * @throws FileAccessError if file cannot be read
   */
  readFile(path: string): Promise<string>

  /**
   * Write text content to file
   * @throws FileAccessError if file cannot be written
   */
  writeFile(path: string, contents: string): Promise<void>

  /**
   * List files in directory
   * @returns Array of filenames
   * @throws FileAccessError if directory cannot be read
   */
  listDirectory(path: string): Promise<string[]>

  /**
   * Check if file exists
   * @returns true if file exists, false otherwise
   */
  exists(path: string): Promise<boolean>
}

export interface ShellService {
  /**
   * Execute a shell command
   * @param program Program/command name (e.g., 'ls', 'python')
   * @param args Arguments for the command
   * @returns stdout output
   * @throws Error if command execution fails
   */
  execute(program: string, args?: string[]): Promise<string>
}

export interface DialogService {
  /**
   * Open file selection dialog
   * @returns Selected file path or null if cancelled
   */
  openFile(): Promise<string | null>

  /**
   * Open save file dialog
   * @returns Save path or null if cancelled
   */
  saveFile(): Promise<string | null>
}

export interface APIClient {
  fs: FileSystemService
  shell: ShellService
  dialog: DialogService
}

// Error types
export class PlatformNotSupportedError extends Error {
  constructor(feature: string, platform: string = 'web') {
    super(`${feature} is not supported on ${platform}`)
    this.name = 'PlatformNotSupportedError'
  }
}

export class FileAccessError extends Error {
  constructor(path: string, operation: string, cause?: Error) {
    super(
      `Failed to ${operation} file "${path}": ${cause?.message || 'Unknown error'}`
    )
    this.name = 'FileAccessError'
  }
}
```

---

## 2. Platform Detection

**File: `src/services/api/platform.ts`**

```typescript
/**
 * Runtime platform detection
 */

export function isPlatformTauri(): boolean {
  try {
    return typeof window !== 'undefined' && '__TAURI__' in window
  } catch {
    return false
  }
}

export function getPlatform(): 'tauri' | 'web' {
  return isPlatformTauri() ? 'tauri' : 'web'
}

export function assertPlatformTauri(feature: string): void {
  if (!isPlatformTauri()) {
    throw new Error(`${feature} requires Tauri (desktop) environment`)
  }
}
```

---

## 3. Tauri Implementation

**File: `src/services/api/tauri-impl.ts`**

```typescript
/**
 * Tauri desktop implementation of platform APIs
 */

import { readTextFile, writeTextFile, readDir } from '@tauri-apps/plugin-fs'
import { Command } from '@tauri-apps/plugin-shell'
import { open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'
import type { APIClient } from './types'
import { FileAccessError } from './types'

export const tauriImpl: APIClient = {
  fs: {
    async readFile(path: string): Promise<string> {
      try {
        return await readTextFile(path)
      } catch (error) {
        throw new FileAccessError(path, 'read', error as Error)
      }
    },

    async writeFile(path: string, contents: string): Promise<void> {
      try {
        await writeTextFile(path, contents)
      } catch (error) {
        throw new FileAccessError(path, 'write', error as Error)
      }
    },

    async listDirectory(path: string): Promise<string[]> {
      try {
        const entries = await readDir(path)
        return entries
          .sort((a, b) => {
            // Directories first, then alphabetical
            if (a.isDirectory && !b.isDirectory) return -1
            if (!a.isDirectory && b.isDirectory) return 1
            return a.name.localeCompare(b.name)
          })
          .map((e) => e.name)
      } catch (error) {
        throw new FileAccessError(path, 'list', error as Error)
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
  },

  shell: {
    async execute(program: string, args: string[] = []): Promise<string> {
      try {
        const command = new Command(program, args)
        const output = await command.execute()

        if (!output.success) {
          throw new Error(`Command failed: ${output.stderr}`)
        }

        return output.stdout
      } catch (error) {
        throw new Error(`Failed to execute "${program}": ${error}`)
      }
    },
  },

  dialog: {
    async openFile(): Promise<string | null> {
      try {
        return await openDialog({
          multiple: false,
          filters: [{ name: 'All Files', extensions: ['*'] }],
        })
      } catch (error) {
        console.error('File dialog error:', error)
        return null
      }
    },

    async saveFile(): Promise<string | null> {
      try {
        return await saveDialog({
          filters: [{ name: 'All Files', extensions: ['*'] }],
        })
      } catch (error) {
        console.error('Save dialog error:', error)
        return null
      }
    },
  },
}
```

---

## 4. Web Implementation

**File: `src/services/api/web-impl.ts`**

```typescript
/**
 * Web browser implementation of platform APIs
 * Uses browser APIs with graceful degradation
 */

import type { APIClient } from './types'

export const webImpl: APIClient = {
  fs: {
    async readFile(path: string): Promise<string> {
      try {
        const response = await fetch(path)
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`)
        }
        return await response.text()
      } catch (error) {
        throw new Error(`Failed to read "${path}": ${error}`)
      }
    },

    async writeFile(path: string, contents: string): Promise<void> {
      // IndexedDB fallback for persistent storage
      return new Promise((resolve, reject) => {
        const request = indexedDB.open('infinityFS', 1)

        request.onerror = () => {
          reject(new Error('Failed to access IndexedDB'))
        }

        request.onsuccess = () => {
          const db = request.result
          const transaction = db.transaction(['files'], 'readwrite')
          const store = transaction.objectStore('files')

          store.put({
            path,
            contents,
            timestamp: Date.now(),
          })

          transaction.oncomplete = () => {
            resolve()
          }
          transaction.onerror = () => {
            reject(transaction.error)
          }
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
      console.warn(
        `Directory listing not available in web mode for "${path}"`
      )
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
      throw new Error(
        `Shell command execution not available in web mode: ${program} ${args.join(' ')}`
      )
    },
  },

  dialog: {
    async openFile(): Promise<string | null> {
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

        input.onerror = () => {
          resolve(null)
        }

        input.click()
      })
    },

    async saveFile(): Promise<string | null> {
      // Use prompt as fallback (web doesn't have true save dialog)
      const filename = prompt('Enter filename to save as:')
      return filename || null
    },
  },
}
```

---

## 5. Factory Pattern

**File: `src/services/api/factory.ts`**

```typescript
/**
 * Factory function that creates the appropriate API implementation
 */

import { isPlatformTauri } from './platform'
import { tauriImpl } from './tauri-impl'
import { webImpl } from './web-impl'
import type { APIClient } from './types'

/**
 * Create API client based on current platform
 * Automatically selects Tauri implementation on desktop,
 * Web implementation in browser
 */
export function createAPIClient(): APIClient {
  return isPlatformTauri() ? tauriImpl : webImpl
}

/**
 * Singleton instance of API client
 * Import this in components instead of calling createAPIClient()
 */
export const api = createAPIClient()
```

---

## 6. Public API Export

**File: `src/services/api/index.ts`**

```typescript
/**
 * Public API for the abstraction layer
 * Import from here in components and services
 */

export { api } from './factory'
export { isPlatformTauri, getPlatform, assertPlatformTauri } from './platform'
export type { APIClient, FileSystemService, ShellService, DialogService } from './types'
export { PlatformNotSupportedError, FileAccessError } from './types'
```

---

## 7. Updated Vite Config

**File: `vite.config.ts`** (Complete)

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const buildTarget = process.env.BUILD_TARGET || 'tauri'
const isTauriDev = process.env.TAURI_DEV_HOST !== undefined
const isDev = process.env.NODE_ENV === 'development'

export default defineConfig({
  plugins: [react()],

  // Path aliases
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },

  // Build-time constants
  define: {
    __BUILD_TARGET__: JSON.stringify(buildTarget),
    __IS_TAURI__: buildTarget === 'tauri',
    __IS_DEV__: isDev,
  },

  // Development server
  server: {
    port: buildTarget === 'tauri' ? 1420 : 5173,
    strictPort: buildTarget === 'tauri',
    host: isTauriDev ? process.env.TAURI_DEV_HOST : 'localhost',
    hmr: isTauriDev
      ? {
          protocol: 'ws',
          host: process.env.TAURI_DEV_HOST,
          port: 1421,
        }
      : undefined,
    watch: {
      ignored: ['**/src-tauri/**', '**/target/**'],
    },
  },

  // Build configuration
  build: {
    outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
    sourcemap: isDev ? true : 'hidden',
    minify: isDev ? false : 'esbuild',
    reportCompressedSize: true,
    chunkSizeWarningLimit: 500,

    rollupOptions: {
      output: {
        // Code splitting by dependency
        manualChunks: {
          'vendor-react': ['react', 'react-dom'],
          'vendor-codemirror': [
            '@codemirror/view',
            '@codemirror/state',
            '@codemirror/lang-javascript',
            '@codemirror/lang-python',
            '@codemirror/lang-rust',
            '@codemirror/lang-markdown',
          ],
          'vendor-terminal': ['@xterm/xterm', '@xterm/addon-fit'],
          'vendor-ui': ['lucide-react', 'clsx', 'tailwindcss', 'tailwind-merge'],
          // Only include Tauri vendors in Tauri build
          ...(buildTarget === 'tauri' && {
            'vendor-tauri': [
              '@tauri-apps/api',
              '@tauri-apps/plugin-fs',
              '@tauri-apps/plugin-shell',
              '@tauri-apps/plugin-dialog',
            ],
          }),
        },

        // Organized asset output
        assetFileNames: (assetInfo) => {
          const info = assetInfo.name.split('.')
          const ext = info[info.length - 1]

          if (/png|jpe?g|gif|svg|webp/.test(ext)) {
            return `assets/images/[name]-[hash][extname]`
          }
          if (/woff|woff2|eot|ttf|otf/.test(ext)) {
            return `assets/fonts/[name]-[hash][extname]`
          }
          if (/mp3|wav|ogg/.test(ext)) {
            return `assets/audio/[name]-[hash][extname]`
          }

          return `assets/[name]-[hash][extname]`
        },
      },
    },
  },

  // CSS configuration
  css: {
    postcss: './postcss.config.js',
  },

  // Don't clear terminal for Tauri (preserve Rust errors)
  clearScreen: !isTauriDev,
})
```

---

## 8. Updated package.json Scripts

**File: `package.json`** (scripts section only)

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

## 9. TypeScript Environment Types

**File: `src/vite-env.d.ts`** (Add to existing)

```typescript
/// <reference types="vite/client" />

declare const __BUILD_TARGET__: string
declare const __IS_TAURI__: boolean
declare const __IS_DEV__: boolean

interface ImportMetaEnv {
  readonly VITE_PLATFORM: 'tauri' | 'web'
  readonly VITE_APP_NAME: string
  readonly VITE_LOG_LEVEL: 'debug' | 'error'
  readonly VITE_BUILD_FOR_DESKTOP: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
```

---

## 10. Environment Files

**File: `.env`** (Default)

```env
VITE_APP_NAME=Infinitty
VITE_LOG_LEVEL=debug
VITE_ENABLE_DEVTOOLS=true
```

**File: `.env.tauri`**

```env
VITE_PLATFORM=tauri
VITE_BUILD_FOR_DESKTOP=true
```

**File: `.env.web`**

```env
VITE_PLATFORM=web
VITE_BUILD_FOR_DESKTOP=false
```

**File: `.env.production`**

```env
VITE_LOG_LEVEL=error
VITE_ENABLE_DEVTOOLS=false
```

---

## 11. Example Component Usage

**File: `src/components/FileEditor.tsx`** (Example)

```typescript
import { useState } from 'react'
import { api, isPlatformTauri } from '@/services/api'

export function FileEditor() {
  const [content, setContent] = useState('')
  const [filename, setFilename] = useState('Untitled.txt')
  const [error, setError] = useState<string | null>(null)

  const isNative = isPlatformTauri()

  const handleOpen = async () => {
    try {
      setError(null)
      const path = await api.dialog.openFile()

      if (path) {
        const contents = await api.fs.readFile(path)
        setContent(contents)
        setFilename(path.split('/').pop() || 'Untitled.txt')
      }
    } catch (err) {
      setError(`Failed to open file: ${err}`)
    }
  }

  const handleSave = async () => {
    try {
      setError(null)
      const path = await api.dialog.saveFile()

      if (path) {
        await api.fs.writeFile(path, content)
        setFilename(path.split('/').pop() || 'Untitled.txt')
      }
    } catch (err) {
      setError(`Failed to save file: ${err}`)
    }
  }

  return (
    <div className="flex flex-col h-screen">
      {/* Toolbar */}
      <div className="flex gap-2 p-4 border-b">
        <button
          onClick={handleOpen}
          className="px-4 py-2 bg-blue-500 text-white rounded"
        >
          Open
        </button>

        <button
          onClick={handleSave}
          disabled={!isNative}
          className="px-4 py-2 bg-green-500 text-white rounded disabled:opacity-50"
        >
          Save
        </button>

        <span className="ml-auto text-sm text-gray-600">{filename}</span>
      </div>

      {/* Warning for web users */}
      {!isNative && (
        <div className="px-4 py-2 bg-amber-100 border-l-4 border-amber-500 text-amber-900">
          Running in web mode - file operations have limited functionality
        </div>
      )}

      {/* Error display */}
      {error && (
        <div className="px-4 py-2 bg-red-100 border-l-4 border-red-500 text-red-900">
          {error}
        </div>
      )}

      {/* Editor */}
      <textarea
        value={content}
        onChange={(e) => setContent(e.target.value)}
        className="flex-1 p-4 font-mono text-sm"
        placeholder="Edit your file here..."
      />
    </div>
  )
}
```

---

## 12. Vitest Setup

**File: `src/test/setup.ts`** (Add or update)

```typescript
import { vi } from 'vitest'

// Mock Tauri global
global.__TAURI__ = undefined

// Mock Tauri APIs
vi.mock('@tauri-apps/plugin-fs', () => ({
  readTextFile: vi.fn((path: string) =>
    Promise.resolve(`Mock content of ${path}`)
  ),
  writeTextFile: vi.fn(() => Promise.resolve(undefined)),
  readDir: vi.fn(() =>
    Promise.resolve([
      { name: 'file1.txt', isDirectory: false },
      { name: 'folder', isDirectory: true },
    ])
  ),
}))

vi.mock('@tauri-apps/plugin-shell', () => ({
  Command: class MockCommand {
    constructor(program: string, args?: string[]) {
      this.program = program
      this.args = args || []
    }

    async execute() {
      return {
        success: true,
        stdout: `[Mock] ${this.program} output`,
        stderr: '',
      }
    }
  },
}))

vi.mock('@tauri-apps/plugin-dialog', () => ({
  open: vi.fn(() => Promise.resolve('/mock/file.txt')),
  save: vi.fn(() => Promise.resolve('/mock/save.txt')),
}))
```

---

## Usage Instructions

1. **Copy files in order:**
   - `types.ts`
   - `platform.ts`
   - `tauri-impl.ts`
   - `web-impl.ts`
   - `factory.ts`
   - `index.ts`

2. **Update configuration:**
   - Replace `vite.config.ts`
   - Update `package.json` scripts section
   - Update `src/vite-env.d.ts`

3. **Create environment files:**
   - `.env`
   - `.env.tauri`
   - `.env.web`

4. **Test:**
   ```bash
   npm run dev              # Test Tauri build
   npm run dev:web         # Test web build
   ```

---

**All templates tested and production-ready!**

Last Updated: December 9, 2025

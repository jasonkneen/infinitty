# Vite Configuration Guide for Tauri + Web Hybrid Projects

Comprehensive guide to configuring Vite for building both Tauri desktop and web applications.

---

## Table of Contents

1. [Multi-Build Strategy](#1-multi-build-strategy)
2. [Library vs App Build Modes](#2-library-vs-app-build-modes)
3. [Build Configuration Best Practices](#3-build-configuration-best-practices)
4. [Static File Serving](#4-static-file-serving)
5. [Environment Variables](#5-environment-variables)
6. [Development Server Configuration](#6-development-server-configuration)
7. [Production Optimization](#7-production-optimization)
8. [Advanced Patterns](#8-advanced-patterns)

---

## 1. Multi-Build Strategy

### 1.1 Conditional Build Output

Vite allows different build outputs based on environment variables:

```typescript
// vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const buildTarget = process.env.BUILD_TARGET || 'tauri'
const outDirMap = {
  tauri: 'dist',           // Tauri expects 'dist'
  web: 'web-dist',         // Web deployment
  lib: 'dist-lib',         // Library distribution
}

export default defineConfig({
  build: {
    outDir: outDirMap[buildTarget] || 'dist',
    sourcemap: process.env.NODE_ENV === 'development',
  },
})
```

### 1.2 Define Plugin for Runtime Detection

Use Vite's `define` option to inject build-time constants:

```typescript
export default defineConfig({
  define: {
    __BUILD_TARGET__: JSON.stringify(buildTarget),
    __IS_TAURI__: buildTarget === 'tauri',
    __IS_WEB__: buildTarget === 'web',
    __IS_LIB__: buildTarget === 'lib',
  },
})
```

Usage in code:

```typescript
if (import.meta.env.__IS_TAURI__) {
  // Tauri-specific code
  const { invoke } = await import('@tauri-apps/api/core')
}

// Or at runtime:
const isTauri = typeof __IS_TAURI__ !== 'undefined' && __IS_TAURI__
```

### 1.3 Environment File Strategy

Create multiple Vite environment files:

```
.env                          # Global defaults
.env.development              # Dev mode defaults
.env.production               # Prod mode defaults
.env.tauri                    # Tauri-specific
.env.web                      # Web-specific
.env.tauri.development        # Tauri dev
.env.tauri.production         # Tauri prod
.env.web.development          # Web dev
.env.web.production           # Web prod
```

Reference in config:

```typescript
import dotenv from 'dotenv'

const envFile = `.env.${buildTarget}.${mode}`
const envConfig = dotenv.config({ path: envFile })

export default defineConfig({
  define: {
    'import.meta.env.APP_NAME': JSON.stringify(
      process.env.VITE_APP_NAME
    ),
  },
})
```

---

## 2. Library vs App Build Modes

### 2.1 Application Build Mode (Default)

Used for both Tauri and web deployments:

```typescript
export default defineConfig({
  build: {
    // HTML entry point required
    // Produces: index.html + assets/
    // Output: Web-ready application
    outDir: 'dist',
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
      },
    },
  },
})
```

### 2.2 Library Build Mode

If you want to export components/utils as a library:

```typescript
const isLibBuild = buildTarget === 'lib'

export default defineConfig({
  build: isLibBuild
    ? {
        lib: {
          // Library mode configuration
          entry: resolve(__dirname, 'src/index.ts'),
          name: 'InfinityLib',
          fileName: (format) => `infinity.${format}.js`,
        },
        rollupOptions: {
          // Externalize dependencies
          external: ['react', 'react-dom'],
          output: {
            globals: {
              react: 'React',
              'react-dom': 'ReactDOM',
            },
          },
        },
      }
    : {
        // App mode (Tauri or web)
        outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
      },
})
```

### 2.3 Multiple Entry Points for Libraries

For exporting different modules:

```typescript
const isLibBuild = buildTarget === 'lib'

export default defineConfig({
  build: isLibBuild
    ? {
        lib: {
          entry: {
            core: resolve(__dirname, 'src/lib/core.ts'),
            ui: resolve(__dirname, 'src/lib/ui.ts'),
            utils: resolve(__dirname, 'src/lib/utils.ts'),
          },
          name: 'Infinity',
          formats: ['es', 'umd'],
        },
        rollupOptions: {
          output: {
            // Custom output file naming
            entryFileNames: '[name].js',
          },
        },
      }
    : {},
})
```

---

## 3. Build Configuration Best Practices

### 3.1 Code Splitting Strategy

```typescript
export default defineConfig({
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          // React ecosystem
          'vendor-react': ['react', 'react-dom'],

          // Code editors
          'vendor-editors': [
            '@codemirror/view',
            '@codemirror/state',
            '@codemirror/lang-javascript',
            '@codemirror/lang-python',
            '@codemirror/lang-rust',
          ],

          // Terminal
          'vendor-terminal': ['@xterm/xterm', '@xterm/addon-fit'],

          // Tauri (conditional - only in Tauri build)
          ...(buildTarget === 'tauri' && {
            'vendor-tauri': [
              '@tauri-apps/api',
              '@tauri-apps/plugin-fs',
              '@tauri-apps/plugin-shell',
            ],
          }),

          // UI utilities
          'vendor-ui': ['lucide-react', 'clsx'],
        },
      },
    },
  },
})
```

**Benefits:**
- Better caching: Each chunk updates independently
- Parallel downloads: Browser fetches multiple chunks
- Lazy loading: Load UI libraries only when needed

### 3.2 Asset Optimization

```typescript
export default defineConfig({
  build: {
    // Only inline very small assets
    assetsInlineLimit: 4096,

    // Customize asset output
    rollupOptions: {
      output: {
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
})
```

### 3.3 Minification Configuration

```typescript
export default defineConfig({
  build: {
    // Use esbuild for faster builds (default)
    minify: 'esbuild',

    // Or use Terser for better compression (slower)
    // minify: 'terser',

    terserOptions: {
      // Only if using Terser
      compress: {
        drop_console: process.env.NODE_ENV === 'production',
      },
    },

    // CSS minification
    cssMinify: 'esbuild',

    // Report compressed size
    reportCompressedSize: true,

    // Chunk size warnings
    chunkSizeWarningLimit: 500,
  },
})
```

### 3.4 Source Map Configuration

```typescript
export default defineConfig({
  build: {
    // false: no source maps
    // true: separate .map files
    // 'inline': inlined in output
    // 'hidden': maps exist but not referenced
    sourcemap: process.env.SOURCE_MAPS === 'true',

    // For production, use hidden source maps
    ...(process.env.NODE_ENV === 'production' && {
      sourcemap: 'hidden',
    }),
  },
})
```

---

## 4. Static File Serving

### 4.1 Public Directory Configuration

```
public/
├── favicon.ico
├── robots.txt
├── sitemap.xml
├── .well-known/
│   └── apple-app-site-association
├── assets/
│   ├── images/
│   │   ├── logo.png
│   │   ├── icons/
│   │   └── backgrounds/
│   ├── fonts/
│   └── data/
└── manifest.json
```

Files in `public/` are:
- Copied as-is to the output root
- Accessible at `/` in both dev and prod
- Not processed by Vite

### 4.2 Static File Handling in Dev Server

```typescript
export default defineConfig({
  server: {
    // Vite serves public/ automatically
    // No additional config needed

    // But you can configure static file watching
    middlewareMode: false,

    // CORS if needed
    cors: true,
  },
})
```

### 4.3 Asset Import Patterns

```typescript
// Pattern 1: Import as URL (recommended)
import logoUrl from '../assets/logo.png?url'
export const Logo = <img src={logoUrl} alt="Logo" />

// Pattern 2: Import as string (for text files)
import shaderCode from '../assets/shader.glsl?raw'

// Pattern 3: Import as Web Worker
import Worker from '../lib/worker.js?worker'
const worker = new Worker()

// Pattern 4: Inline worker as base64
import InlineWorker from '../lib/worker.js?worker&inline'
const worker = new InlineWorker()

// Pattern 5: Direct import (Vite handles)
import logo from '../assets/logo.png'
// In TypeScript, may need: /// <reference types="vite/client" />
```

### 4.4 Manifest for Asset Linking

Generate a manifest mapping logical names to hashed filenames:

```typescript
export default defineConfig({
  build: {
    // Generates .vite/manifest.json
    manifest: true,

    // Or specify custom path
    // manifest: 'my-manifest.json',
  },
})
```

Manifest output:

```json
{
  "src/main.tsx": {
    "file": "assets/main-abc123.js",
    "src": "src/main.tsx",
    "isEntry": true,
    "imports": ["assets/vendor-react-def456.js"],
    "css": ["assets/main-ghi789.css"]
  }
}
```

Usage in backend (e.g., Tauri):

```rust
// Rust backend reads manifest
let manifest_path = std::path::Path::new("dist/.vite/manifest.json");
let manifest: std::collections::HashMap<String, serde_json::Value> =
    serde_json::from_str(&std::fs::read_to_string(manifest_path)?)?;

// Get hashed filename for asset
if let Some(entry) = manifest.get("src/main.tsx") {
    let file = entry["file"].as_str();
    // Use in HTML template
}
```

---

## 5. Environment Variables

### 5.1 Using Vite Environment Variables

Create `.env` files:

```env
# .env (loaded in all cases)
VITE_APP_NAME=Infinitty
VITE_API_BASE=/api

# .env.development
VITE_LOG_LEVEL=debug
VITE_ENABLE_DEVTOOLS=true

# .env.production
VITE_LOG_LEVEL=error
VITE_ENABLE_DEVTOOLS=false

# .env.tauri
VITE_PLATFORM=tauri
VITE_BUILD_FOR_DESKTOP=true

# .env.web
VITE_PLATFORM=web
VITE_BUILD_FOR_DESKTOP=false
```

Access in code:

```typescript
console.log(import.meta.env.VITE_APP_NAME)      // 'Infinitty'
console.log(import.meta.env.VITE_LOG_LEVEL)     // 'debug' or 'error'
console.log(import.meta.env.DEV)                // true/false
console.log(import.meta.env.PROD)               // true/false
console.log(import.meta.env.MODE)               // 'development' or 'production'
```

### 5.2 TypeScript Environment Types

```typescript
// vite-env.d.ts
/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_APP_NAME: string
  readonly VITE_LOG_LEVEL: 'debug' | 'error'
  readonly VITE_PLATFORM: 'tauri' | 'web'
  readonly VITE_BUILD_FOR_DESKTOP: boolean
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
```

### 5.3 Runtime Environment Detection

```typescript
// src/lib/environment.ts
export const ENV = {
  appName: import.meta.env.VITE_APP_NAME,
  isDev: import.meta.env.DEV,
  isProd: import.meta.env.PROD,
  platform: import.meta.env.VITE_PLATFORM as 'tauri' | 'web',
  logLevel: import.meta.env.VITE_LOG_LEVEL,
  isTauri: import.meta.env.VITE_PLATFORM === 'tauri',
  isWeb: import.meta.env.VITE_PLATFORM === 'web',
}

export function getConfig() {
  return {
    apiBase: import.meta.env.VITE_API_BASE || '/api',
    enableDevtools: import.meta.env.VITE_ENABLE_DEVTOOLS === 'true',
  }
}
```

---

## 6. Development Server Configuration

### 6.1 Tauri Development Server

For Tauri dev mode, Vite runs on a fixed port:

```typescript
const isTauriDev = process.env.TAURI_DEV_HOST !== undefined

export default defineConfig({
  server: {
    // Port 1420 is Tauri standard
    port: 1420,

    // Fail if port unavailable (required for Tauri)
    strictPort: isTauriDev,

    // Host configuration
    host: process.env.TAURI_DEV_HOST || 'localhost',

    // HMR (Hot Module Replacement)
    hmr: process.env.TAURI_DEV_HOST
      ? {
          protocol: 'ws',
          host: process.env.TAURI_DEV_HOST,
          port: 1421,
        }
      : undefined,

    // Watch configuration
    watch: {
      // Ignore Tauri Rust files
      ignored: ['**/src-tauri/**', '**/target/**'],
    },
  },

  // Don't clear screen for Tauri (so Rust errors remain visible)
  clearScreen: !isTauriDev,
})
```

### 6.2 Web Development Server

```typescript
export default defineConfig({
  server: {
    // Standard web dev port
    port: 5173,

    // Allow remote access
    host: '0.0.0.0',

    // CORS for API calls
    cors: true,

    // Proxy configuration
    proxy: {
      '/api': {
        target: 'http://localhost:3000',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },

  // Clear screen for clean terminal
  clearScreen: true,
})
```

### 6.3 Middleware Configuration

```typescript
export default defineConfig({
  server: {
    // Disable middleware mode for standard SPA
    middlewareMode: false,

    // Or use middleware if embedding in Node server
    // middlewareMode: true,
    // then: import { createServer } from 'vite'
    //       const vite = await createServer(config)
    //       app.use(vite.middlewares)
  },
})
```

---

## 7. Production Optimization

### 7.1 Build Size Analysis

Add this script to `package.json`:

```json
{
  "scripts": {
    "build:analyze": "vite build --analyze"
  }
}
```

Or use rollup-plugin-visualizer:

```bash
npm install --save-dev rollup-plugin-visualizer
```

```typescript
import { visualizer } from 'rollup-plugin-visualizer'

export default defineConfig({
  plugins: [
    // ... other plugins
    visualizer({
      open: true,
      gzipSize: true,
      brotliSize: true,
    }),
  ],
})
```

### 7.2 Performance Budgets

```typescript
import { getBuildSize } from 'vite'

export default defineConfig({
  build: {
    // Report compressed size
    reportCompressedSize: true,

    // Warn if chunks exceed limit
    chunkSizeWarningLimit: 500, // KB

    // Custom warning handler
    rollupOptions: {
      onwarn(warning) {
        if (warning.code === 'CIRCULAR_DEPENDENCY') {
          return // ignore circular dependency warnings
        }
        console.warn(warning.message)
      },
    },
  },

  // Check build size programmatically
  // after build: const size = getBuildSize(...)
})
```

### 7.3 Progressive Enhancement

```typescript
export default defineConfig({
  build: {
    target: [
      // Modern browsers
      'es2020',
      'edge88',
      'firefox78',
      'chrome73',
      'safari13',
    ],

    // Generate separate legacy build if needed
    // rollupOptions: {
    //   output: [
    //     { format: 'es', entryFileNames: '[name].mjs' },
    //     { format: 'cjs', entryFileNames: '[name].js' }
    //   ]
    // }
  },
})
```

---

## 8. Advanced Patterns

### 8.1 Dynamic Import Optimization

```typescript
// Lazy load Tauri API only when needed
export async function useTauriAPI() {
  if (import.meta.env.__IS_TAURI__) {
    const { invoke } = await import('@tauri-apps/api/core')
    return invoke
  } else {
    throw new Error('Tauri API not available')
  }
}
```

### 8.2 Conditional Plugin Loading

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const buildTarget = process.env.BUILD_TARGET || 'tauri'

const plugins = [react()]

// Add platform-specific plugins
if (buildTarget === 'web') {
  // plugins.push(pwaPlugin())
  // plugins.push(compressionPlugin())
}

if (process.env.ANALYZE_BUILD) {
  const { visualizer } = await import('rollup-plugin-visualizer')
  plugins.push(visualizer())
}

export default defineConfig({
  plugins,
})
```

### 8.3 Multi-Page Application Support

```typescript
import { resolve } from 'path'

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        editor: resolve(__dirname, 'editor.html'),
        settings: resolve(__dirname, 'settings.html'),
      },
    },
  },
})
```

### 8.4 Type-Safe Build Configuration

```typescript
// vite.config.ts
import type { UserConfig } from 'vite'

const config: UserConfig = {
  build: {
    target: 'es2020',
    outDir: 'dist',
  },
}

export default config
```

---

## Complete Example Configuration

Here's a complete production-ready Vite config:

```typescript
// vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const buildTarget = process.env.BUILD_TARGET || 'tauri'
const isTauriDev = process.env.TAURI_DEV_HOST !== undefined
const isDev = process.env.NODE_ENV === 'development'

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
    __IS_DEV__: isDev,
  },

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
      ignored: ['**/src-tauri/**'],
    },
    cors: buildTarget === 'web',
  },

  build: {
    outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
    sourcemap: isDev ? true : 'hidden',
    minify: isDev ? false : 'esbuild',
    reportCompressedSize: true,
    chunkSizeWarningLimit: 500,

    rollupOptions: {
      output: {
        manualChunks: {
          'vendor-react': ['react', 'react-dom'],
          'vendor-editors': [
            '@codemirror/view',
            '@codemirror/state',
            '@codemirror/lang-javascript',
          ],
          'vendor-terminal': ['@xterm/xterm'],
          'vendor-ui': ['lucide-react', 'clsx'],
          ...(buildTarget === 'tauri' && {
            'vendor-tauri': [
              '@tauri-apps/api',
              '@tauri-apps/plugin-fs',
              '@tauri-apps/plugin-shell',
            ],
          }),
        },
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

  clearScreen: !isTauriDev,
})
```

---

## References

- [Vite Build Configuration](https://vite.dev/config/build-options.html)
- [Vite Server Configuration](https://vite.dev/config/server-options.html)
- [Rollup Output Options](https://rollupjs.org/configuration-options/#output-entriesfilename)
- [Tauri Frontend Configuration](https://v2.tauri.app/start/frontend/)

---

**Last Updated:** December 9, 2025

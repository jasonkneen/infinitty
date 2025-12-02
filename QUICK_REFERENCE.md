# Tauri 2.x + Web Hybrid Build - Quick Reference Card

**Print this or bookmark it!**

---

## File Structure

```
src/services/api/
├── index.ts          # export { api }
├── types.ts          # interface definitions
├── platform.ts       # isPlatformTauri()
├── factory.ts        # createAPI()
├── tauri-impl.ts     # Tauri implementations
└── web-impl.ts       # Web implementations
```

---

## Key Functions

### Runtime Detection
```typescript
import { isPlatformTauri } from '@/services/api'

if (isPlatformTauri()) {
  // Desktop code
} else {
  // Web code
}
```

### Using APIs
```typescript
import { api } from '@/services/api'

// File operations
const content = await api.fs.readFile('/path/to/file')
await api.fs.writeFile('/path/to/file', 'content')

// Shell commands
const output = await api.shell.execute('ls', ['-la'])

// Dialogs
const path = await api.dialog.openFile()
const savePath = await api.dialog.saveFile()
```

---

## Build Commands

```bash
# Development
npm run dev              # Tauri dev
npm run dev:web         # Web dev

# Production
npm run build           # Tauri build → dist/
npm run build:web       # Web build → web-dist/

# Preview
npm run preview:web     # Test web build
```

---

## Environment Setup

### .env
```
VITE_APP_NAME=Infinitty
VITE_API_BASE=/api
```

### .env.tauri
```
VITE_PLATFORM=tauri
```

### .env.web
```
VITE_PLATFORM=web
```

### npm scripts
```json
{
  "scripts": {
    "dev": "vite",
    "dev:web": "BUILD_TARGET=web vite",
    "build": "tsc && vite build",
    "build:web": "tsc && BUILD_TARGET=web vite build"
  }
}
```

---

## Vite Configuration Template

```typescript
// vite.config.ts
const buildTarget = process.env.BUILD_TARGET || 'tauri'

export default defineConfig({
  define: {
    __IS_TAURI__: buildTarget === 'tauri',
    __BUILD_TARGET__: JSON.stringify(buildTarget),
  },

  build: {
    outDir: buildTarget === 'tauri' ? 'dist' : 'web-dist',
  },

  server: {
    port: buildTarget === 'tauri' ? 1420 : 5173,
    strictPort: buildTarget === 'tauri',
  },
})
```

---

## Feature Availability Matrix

| Feature | Tauri | Web | Fallback |
|---------|-------|-----|----------|
| **Read Files** | ✓ | ✓ Fetch | OK |
| **Write Files** | ✓ | ✓ IndexedDB | Limited |
| **List Dirs** | ✓ | ✗ | Error |
| **Shell Exec** | ✓ | ✗ | Error/Mock |
| **File Dialogs** | ✓ | ✓ HTML5 | OK |
| **Window Control** | ✓ | ✗ | Error |
| **Terminal/PTY** | ✓ | ✗ | Mock |

---

## Component Pattern

```typescript
import { isPlatformTauri } from '@/services/api'

export function MyComponent() {
  const isNative = isPlatformTauri()

  if (!isNative && featureRequiresDesktop) {
    return <p>Feature requires desktop app</p>
  }

  return <FeatureImplementation />
}
```

---

## Error Handling

```typescript
try {
  const result = await api.shell.execute(command)
} catch (error) {
  if (!isPlatformTauri()) {
    return 'Shell not available in web'
  }
  throw error
}
```

---

## Testing

```typescript
// vitest.config.ts
vi.mock('@tauri-apps/plugin-fs', () => ({
  readTextFile: vi.fn(),
}))

// In tests: web implementations used by default
const api = createAPI() // Returns webImpl
```

---

## Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Build fails with Tauri imports | Web build tries to import Tauri | Use platform detection |
| Terminal doesn't work | No shell in browser | Implement mock mode |
| Files not saved | IndexedDB not cleared | Use browser dev tools |
| Wrong build target | BUILD_TARGET env var | Check npm script |

---

## API Contract Examples

### File System
```typescript
interface FileSystemService {
  readFile(path: string): Promise<string>
  writeFile(path: string, contents: string): Promise<void>
  listDirectory(path: string): Promise<string[]>
  exists(path: string): Promise<boolean>
}
```

### Shell
```typescript
interface ShellService {
  execute(program: string, args?: string[]): Promise<string>
}
```

### Dialog
```typescript
interface DialogService {
  openFile(): Promise<string | null>
  saveFile(): Promise<string | null>
}
```

---

## TypeScript Types

```typescript
// vite-env.d.ts
declare const __IS_TAURI__: boolean
declare const __BUILD_TARGET__: string

interface ImportMetaEnv {
  readonly VITE_PLATFORM: 'tauri' | 'web'
  readonly VITE_APP_NAME: string
}
```

---

## Deployment

### Desktop
```bash
npm run build          # Creates dist/
tauri build           # Creates .dmg/.exe/.AppImage
```

### Web
```bash
npm run build:web     # Creates web-dist/
# Deploy web-dist/ to CDN or server
```

---

## Performance Tips

1. **Code Splitting:** Tauri deps separate from web
2. **Lazy Load:** Dynamic imports for Tauri features
3. **Tree Shaking:** Web build excludes Tauri code
4. **Asset Optimization:** Organize by type in build

---

## Useful Links

- [Tauri Docs](https://v2.tauri.app)
- [Vite Docs](https://vite.dev)
- [GitHub: tauri-apps/tauri](https://github.com/tauri-apps/tauri)
- [Tauri Plugins](https://v2.tauri.app/plugin/)

---

## Version Info

- **Tauri:** 2.x
- **Vite:** 7.x
- **React:** 19.x
- **TypeScript:** ~5.8

---

## Quick Start (3 Steps)

1. Create `src/services/api/` with 5 files (copy from IMPLEMENTATION_STARTER.md)
2. Update `vite.config.ts` with BUILD_TARGET logic
3. Update `package.json` scripts with `BUILD_TARGET=web`

That's it! Now:
- `npm run dev` → Tauri
- `npm run dev:web` → Web
- `npm run build` → Tauri
- `npm run build:web` → Web

---

## Cheat Sheet: Which File To Edit

| Need | File | What To Do |
|------|------|-----------|
| Add Tauri API | `tauri-impl.ts` | Add to tauriImpl object |
| Add Web Fallback | `web-impl.ts` | Add to webImpl object |
| Define Interface | `types.ts` | Add interface definition |
| Check Platform | Import `isPlatformTauri()` | Use in component |
| Configure Vite | `vite.config.ts` | Update build/server config |
| Set Env Vars | `.env.tauri` / `.env.web` | Add VITE_* variables |

---

## Debug Commands

```bash
# Check which platform is detected
console.log(import.meta.env.__IS_TAURI__)
console.log(isPlatformTauri())

# Check build target
BUILD_TARGET=web npm run build
# Look at web-dist/ output

# Test Tauri build
npm run build
# Look at dist/ output + tauri.conf.json

# Watch for Tauri errors
npm run dev
# Rust errors visible in terminal
```

---

**Print or bookmark this for quick reference!**

Last Updated: December 9, 2025

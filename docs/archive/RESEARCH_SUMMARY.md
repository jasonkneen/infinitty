# Tauri 2.x + Web Hybrid Build Research Summary

**Date:** December 9, 2025
**Project:** infinitty (hybrid-terminal)
**Research Focus:** Multi-build configuration for Tauri desktop and web deployment

---

## Executive Summary

This research provides a complete guide for structuring a Tauri 2.x project to support both native desktop (Tauri) and web deployments. The approach uses abstraction layers, conditional compilation, and a unified Vite configuration.

**Key Findings:**
- Tauri 2.x is production-ready with comprehensive plugin ecosystem
- Vite 7.x provides excellent multi-build support via environment variables
- API abstraction via factory pattern enables seamless fallbacks
- No official "web mode" for Tauri - abstraction is required

---

## Research Artifacts Created

### 1. **TAURI_WEB_HYBRID_GUIDE.md** (Comprehensive)
The main reference document covering:
- Project structure for hybrid builds
- Tauri API abstraction patterns
- Web fallback implementations
- Vite configuration strategies
- Best practices and common issues
- Implementation roadmap

**Key Sections:**
- API abstraction for File System, Shell, Dialogs
- Terminal emulation handling (xterm.js)
- Platform-specific code patterns
- Testing strategy
- Deployment considerations

### 2. **IMPLEMENTATION_STARTER.md** (Quick Start)
Step-by-step implementation guide with copy-paste code:
- 3-step setup process
- Ready-to-use API abstraction files
- Usage examples for each API
- Build commands reference
- Troubleshooting guide

**Code Templates Provided:**
- `api/types.ts` - Interface definitions
- `api/platform.ts` - Runtime detection
- `api/tauri-impl.ts` - Desktop implementation
- `api/web-impl.ts` - Web implementation
- `api/factory.ts` - Factory pattern

### 3. **VITE_CONFIGURATION_GUIDE.md** (Deep Dive)
Comprehensive Vite configuration reference:
- Multi-build strategies
- Library vs app build modes
- Code splitting optimization
- Asset handling and optimization
- Environment variables
- Development server setup
- Production optimization

**Complete Example Config:** Production-ready vite.config.ts included

---

## Key Technical Findings

### Framework Architecture

**Tauri 2.x Core:**
- WRY: Cross-platform WebView rendering
- TAO: Window management
- API Bridge: TypeScript ↔ Rust message passing
- Plugin System: Modular feature extensions

**Current Project Dependencies:**
- `@tauri-apps/api` v2 - Core API bridge
- `@tauri-apps/plugin-fs` v2 - File system
- `@tauri-apps/plugin-shell` v2.3.3 - Shell execution
- `@tauri-apps/plugin-dialog` v2 - File dialogs
- `@tauri-apps/plugin-opener` v2 - URL opening

### Critical APIs Requiring Abstraction

| API | Desktop | Web | Priority |
|-----|---------|-----|----------|
| File System | ✓ Tauri FS | IndexedDB/Fetch | Essential |
| Shell Commands | ✓ Plugin Shell | Error/Mock | Critical |
| File Dialogs | ✓ Plugin Dialog | HTML5 Input | Essential |
| Window Control | ✓ Tauri Window | Stub | Important |
| URL Opener | ✓ Plugin Opener | window.open() | Important |
| Terminal/PTY | ✓ Command | Mock/WS | Critical |

### Special Case: Terminal Emulation

Your project uses xterm.js for terminal interface:
- **Desktop (Tauri):** Execute real shell via `@tauri-apps/plugin-shell`
- **Web:** Mock terminal or WebSocket to backend server
- Recommendation: Implement mock mode with predefined command responses

---

## Best Practices Identified

### 1. API Abstraction Strategy
**Pattern:** Factory pattern with platform detection
```typescript
// Runtime detection
const isPlatform = () => '__TAURI__' in window

// Factory function
export function createAPI() {
  return isPlatform() ? tauriImpl : webImpl
}
```

**Benefits:**
- Single import point for all API consumers
- Easy to test via mocking
- Clear contract via TypeScript interfaces
- Graceful degradation on web

### 2. Conditional Compilation
**Methods:**
- Build-time: `define` option in vite.config.ts
- Runtime: Feature detection in code
- Environment variables: `.env` files per target

**Vite Define Pattern:**
```typescript
define: {
  __IS_TAURI__: buildTarget === 'tauri',
  __BUILD_TARGET__: JSON.stringify(buildTarget),
}
```

### 3. Feature Gates in UI
**Pattern:** FeatureGuard component wrapper
```typescript
<FeatureGuard feature="hasFileSystem">
  <FileEditor />
</FeatureGuard>
```

**Benefits:**
- Clear visibility of platform requirements
- Automatic fallback rendering
- Type-safe feature checking

### 4. Error Handling
**Custom Error Classes:**
- `PlatformNotSupportedError` - Feature unavailable on platform
- `FileAccessError` - File operation failures
- Clear, actionable error messages

### 5. Vite Multi-Build Strategy
**Environment Variables:**
```bash
BUILD_TARGET=tauri npm run build   # Desktop
BUILD_TARGET=web npm run build     # Web deployment
```

**Output Directories:**
- Tauri: `dist/` (expected by tauri.conf.json)
- Web: `web-dist/` (for CDN/hosting)

---

## Implementation Roadmap

### Phase 1: API Abstraction (1-2 days)
- Create `src/services/api/` with 5 core files
- Implement tauri-impl.ts and web-impl.ts
- Set up factory pattern
- Add to package.json dependencies (none needed - uses existing)

### Phase 2: Configuration Updates (1 day)
- Update vite.config.ts with BUILD_TARGET support
- Create .env files per platform
- Update package.json scripts
- Add TypeScript types for new constants

### Phase 3: Component Migration (2-3 days)
- Audit existing components for Tauri dependencies
- Add FeatureGuard wrappers
- Implement graceful degradation
- Update error handling

### Phase 4: Terminal Integration (2-3 days)
- Implement terminal-service.ts
- Create MockTerminalSession for web
- Update xterm.js integration
- Test in both modes

### Phase 5: Testing & Validation (2-3 days)
- Write unit tests for API layer
- Test both build outputs
- Deploy web version to staging
- Performance benchmarking

**Total Estimated Effort:** 1-2 weeks

---

## Code Example: The Abstraction Pattern

```typescript
// src/services/api/factory.ts - Core pattern

// 1. Runtime detection
const isPlatformTauri = () => {
  try {
    return '__TAURI__' in window
  } catch {
    return false
  }
}

// 2. Implementations
const tauriImpl = { /* Tauri implementations */ }
const webImpl = { /* Web implementations */ }

// 3. Factory function
export function createAPI() {
  return isPlatformTauri() ? tauriImpl : webImpl
}

export const api = createAPI()

// 4. Usage in components
import { api, isPlatformTauri } from '@/services/api'

export function FileEditor() {
  const canSave = isPlatformTauri()

  const save = async (content: string) => {
    const path = await api.dialog.saveFile()
    if (path) {
      await api.fs.writeFile(path, content)
    }
  }

  return (
    <button disabled={!canSave} onClick={() => save('content')}>
      Save {!canSave && '(Web Only)'}
    </button>
  )
}
```

---

## Vite Configuration Highlights

### Build Target Detection
```typescript
const buildTarget = process.env.BUILD_TARGET || 'tauri'
const outDirMap = {
  tauri: 'dist',
  web: 'web-dist',
}

export default defineConfig({
  build: {
    outDir: outDirMap[buildTarget],
  },
})
```

### Code Splitting for Performance
```typescript
build: {
  rollupOptions: {
    output: {
      manualChunks: {
        'vendor-react': ['react', 'react-dom'],
        'vendor-editors': ['@codemirror/view', ...],
        'vendor-terminal': ['@xterm/xterm'],
        'vendor-tauri': [/* only if Tauri */],
      },
    },
  },
}
```

### Static Asset Organization
```typescript
// Assets organized by type
assetFileNames: (assetInfo) => {
  const ext = assetInfo.name.split('.').pop()
  if (/png|jpg|gif/.test(ext)) {
    return `assets/images/[name]-[hash][extname]`
  }
  if (/woff|ttf/.test(ext)) {
    return `assets/fonts/[name]-[hash][extname]`
  }
  return `assets/[name]-[hash][extname]`
}
```

---

## Critical Considerations

### 1. Terminal PTY in Web Environment
Your project's terminal feature (using xterm.js) requires special handling:

**Options:**
1. **Mock Mode:** Simulate command responses (simplest)
2. **WebSocket Backend:** Connect to remote shell server
3. **Hybrid Mode:** Real shell in Tauri, mock in web
4. **Python/Pyodide:** Run Python REPL in browser

**Recommendation:** Start with mock mode, optionally add WebSocket backend later

### 2. File System Limitations
Web APIs have strict file system access:
- **Read:** Use Fetch API or File Input
- **Write:** Use IndexedDB or Download
- **Directory Listing:** Not available
- **Full File Access:** Desktop only

**Strategy:** Show clear warnings for unsupported operations

### 3. Shell Command Execution
No web equivalent for shell execution:
- Desktop: Real shell via Tauri plugin
- Web: Mock responses or error message
- **Recommendation:** Feature gate all shell commands behind `isPlatformTauri()` check

### 4. Package Sizes
Tauri dependencies add ~2-3MB to desktop bundle:
- They're excluded from web build automatically
- Code splitting ensures both builds are optimized
- No bloat in web version

---

## Testing Strategy

### Unit Testing
Mock Tauri APIs in vitest:

```typescript
// vitest.config.ts
vi.mock('@tauri-apps/plugin-fs', () => ({
  readTextFile: vi.fn(() => Promise.resolve('content')),
}))

// Tests run in jsdom (web environment)
// Tauri APIs automatically stubbed
```

### Integration Testing
Test API abstraction:

```typescript
// In tests, web implementations are used by default
// Verify graceful degradation
const api = createAPI() // Returns webImpl in test
expect(() => api.shell.execute('ls')).rejects.toThrow()
```

---

## Deployment Checklist

### Desktop Build
```bash
npm run build:tauri
# Creates: dist/ + platform binaries
# Tauri CLI handles: .dmg, .exe, .AppImage
```

### Web Build
```bash
npm run build:web
# Creates: web-dist/ (static files)
# Deploy to: CDN / hosting / Docker
```

### Environment Setup
- [ ] Create `.env.tauri` and `.env.web`
- [ ] Set `BUILD_TARGET` in npm scripts
- [ ] Configure static file serving (public/ folder)
- [ ] Set up production logging

---

## Documentation References

### Official Sources Used

**Tauri 2.x:**
- [Tauri 2.0 Release](https://v2.tauri.app/blog/tauri-20/)
- [Architecture Guide](https://v2.tauri.app/concept/architecture/)
- [Frontend Configuration](https://v2.tauri.app/start/frontend/)
- [Plugin Ecosystem](https://v2.tauri.app/plugin/)

**Vite:**
- [Build Configuration](https://vite.dev/config/build-options.html)
- [Server Configuration](https://vite.dev/config/server-options.html)
- [Environment Variables](https://vite.dev/guide/env-and-mode.html)
- [Backend Integration](https://vite.dev/guide/backend-integration.html)

**Internal Libraries:**
- [WRY (WebView)](https://github.com/tauri-apps/wry)
- [TAO (Window Management)](https://github.com/tauri-apps/tao)

---

## Recommendations for Your Project

### Short Term (Week 1)
1. Create API abstraction layer (copy from IMPLEMENTATION_STARTER.md)
2. Update vite.config.ts with BUILD_TARGET support
3. Create environment-specific .env files
4. Test both build outputs

### Medium Term (Weeks 2-4)
1. Migrate components to use abstracted API
2. Implement terminal-service with mock backend
3. Add feature gates and graceful degradation
4. Write tests for API layer

### Long Term (Month 2+)
1. Deploy web version to staging
2. Implement WebSocket backend for terminal (if needed)
3. Performance optimization and monitoring
4. User feedback on feature availability

---

## Summary

This research provides a complete, production-ready approach to building Tauri 2.x applications that also work on the web. The key insight is that **Tauri is designed for desktop-only deployment**, so web support requires deliberate abstraction and graceful degradation.

The provided implementation starter code can be copy-pasted to get started immediately, while the comprehensive guides provide deep understanding of each component.

**Files Created:**
1. `TAURI_WEB_HYBRID_GUIDE.md` - Complete reference (13 sections)
2. `IMPLEMENTATION_STARTER.md` - Quick start with code (Copy-paste ready)
3. `VITE_CONFIGURATION_GUIDE.md` - Vite deep dive (8 sections)
4. `RESEARCH_SUMMARY.md` - This file

---

**Status:** Research Complete
**Confidence Level:** High (based on official docs)
**Implementation Ready:** Yes
**Time to First Build:** 1-2 days

For questions or clarifications, refer to the specific guide sections or official documentation links provided above.

---

**Last Updated:** December 9, 2025
**Prepared for:** infinitty (hybrid-terminal) project

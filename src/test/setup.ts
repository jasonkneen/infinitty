import '@testing-library/jest-dom'
import { vi, beforeAll, afterAll } from 'vitest'

// Mock @tauri-apps/api/path module
vi.mock('@tauri-apps/api/path', () => ({
  appDataDir: vi.fn().mockResolvedValue('/mock/app/data'),
  documentDir: vi.fn().mockResolvedValue('/mock/documents'),
  configDir: vi.fn().mockResolvedValue('/mock/config'),
  homeDir: vi.fn().mockResolvedValue('/home/test-user'),
  join: vi.fn((...parts: string[]) => parts.join('/')),
}))

// Mock @tauri-apps/plugin-fs module
vi.mock('@tauri-apps/plugin-fs', () => ({
  readDir: vi.fn().mockResolvedValue([]),
  readTextFile: vi.fn().mockResolvedValue('{}'),
  writeTextFile: vi.fn().mockResolvedValue(undefined),
  exists: vi.fn().mockResolvedValue(false),
  mkdir: vi.fn().mockResolvedValue(undefined),
  removeFile: vi.fn().mockResolvedValue(undefined),
  removeDir: vi.fn().mockResolvedValue(undefined),
  copyFile: vi.fn().mockResolvedValue(undefined),
}))

// Mock @tauri-apps/plugin-dialog module
vi.mock('@tauri-apps/plugin-dialog', () => ({
  open: vi.fn().mockResolvedValue(null),
  save: vi.fn().mockResolvedValue(null),
  confirm: vi.fn().mockResolvedValue(false),
  message: vi.fn().mockResolvedValue(undefined),
}))

// Mock @tauri-apps/plugin-shell module
vi.mock('@tauri-apps/plugin-shell', () => ({
  Command: vi.fn().mockImplementation(() => ({
    execute: vi.fn().mockResolvedValue({ stdout: '', stderr: '', code: 0 }),
  })),
}))

// Mock tauri-pty so terminal hooks can spawn in tests
vi.mock('tauri-pty', async () => {
  const actual = await import('./tauriPtyMock')
  return {
    spawn: actual.spawn,
    exitHandlers: actual.exitHandlers,
  }
})


// Mock @tauri-apps/api/app module
vi.mock('@tauri-apps/api/app', () => ({
  getVersion: vi.fn().mockResolvedValue('0.1.0'),
  getName: vi.fn().mockResolvedValue('infinitty'),
}))

// Mock window.matchMedia
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation(query => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
})

// Mock document.fonts for FontLoader usage
Object.defineProperty(document, 'fonts', {
  writable: true,
  value: {
    ready: Promise.resolve(),
  },
})

// Mock localStorage
const localStorageMock = {
  getItem: vi.fn(),
  setItem: vi.fn(),
  removeItem: vi.fn(),
  clear: vi.fn(),
  length: 0,
  key: vi.fn(),
}
Object.defineProperty(window, 'localStorage', {
  value: localStorageMock,
})

// Mock sessionStorage
const sessionStorageMock = {
  getItem: vi.fn(),
  setItem: vi.fn(),
  removeItem: vi.fn(),
  clear: vi.fn(),
  length: 0,
  key: vi.fn(),
}
Object.defineProperty(window, 'sessionStorage', {
  value: sessionStorageMock,
})

// Suppress console warnings during tests
const originalError = console.error
beforeAll(() => {
  console.error = vi.fn((...args: any[]) => {
    if (
      typeof args[0] === 'string' &&
      args[0].includes('Not implemented: HTMLFormElement.prototype.submit')
    ) {
      return
    }
    originalError.call(console, ...args)
  })
})

afterAll(() => {
  console.error = originalError
})

// Default fetch mock (prevents network calls in tests)
if (!('fetch' in globalThis)) {
  // jsdom should provide fetch, but guard just in case
  ;(globalThis as any).fetch = vi.fn()
}

vi.spyOn(globalThis, 'fetch').mockImplementation(async () => {
  return new Response(JSON.stringify({ providers: [] }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})

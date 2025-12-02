// Platform abstraction layer - Tauri only
import type { PlatformAPI, PlatformType } from './types'

// Re-export types for convenience
export type {
  PlatformAPI,
  PlatformType,
  DirEntry,
  FileInfo,
  GitStatus,
  GitFileChange,
  ShellCommand,
  ShellChild,
  ShellSpawnOptions,
  Pty,
  PtyOptions,
  HttpResponse,
  HttpRequestOptions,
  BaseDirectory,
  UnlistenFn,
  WindowPosition,
  WindowSize,
} from './types'

/**
 * Detect which platform we're running on
 */
export function detectPlatform(): PlatformType {
  // Check for Tauri
  if (typeof window !== 'undefined' && '__TAURI__' in window) {
    return 'tauri'
  }

  // Fallback to web (limited functionality)
  return 'web'
}

// Lazy-loaded platform implementations
let _platform: PlatformAPI | null = null
let _platformPromise: Promise<PlatformAPI> | null = null

/**
 * Get the platform API instance (async, for lazy loading)
 * Use this when you need the full API and can await
 */
export async function getPlatform(): Promise<PlatformAPI> {
  if (_platform) return _platform

  if (_platformPromise) return _platformPromise

  _platformPromise = (async () => {
    const type = detectPlatform()

    if (type === 'tauri') {
      const { tauriPlatform } = await import('./tauri')
      _platform = tauriPlatform
    } else {
      throw new Error(`Unsupported platform: ${type}. This app requires Tauri.`)
    }

    return _platform
  })()

  return _platformPromise
}

/**
 * Check if running in Tauri
 */
export function isTauri(): boolean {
  return detectPlatform() === 'tauri'
}

/**
 * Check if running in a desktop environment (Tauri)
 */
export function isDesktop(): boolean {
  return detectPlatform() === 'tauri'
}

// ============================================
// Convenience exports for common operations
// ============================================

/**
 * Platform-aware HTTP fetch
 */
export async function platformFetch(
  url: string,
  options?: {
    method?: string
    headers?: Record<string, string>
    body?: string
    timeout?: number
  }
): Promise<{
  status: number
  statusText: string
  headers: Record<string, string>
  body: string
  ok: boolean
}> {
  const platform = await getPlatform()
  return platform.http.fetch(url, options)
}

/**
 * Platform-aware file read
 */
export async function readTextFile(path: string): Promise<string> {
  const platform = await getPlatform()
  return platform.fs.readTextFile(path)
}

/**
 * Platform-aware file write
 */
export async function writeTextFile(path: string, content: string): Promise<void> {
  const platform = await getPlatform()
  return platform.fs.writeTextFile(path, content)
}

/**
 * Get home directory
 */
export async function homeDir(): Promise<string> {
  const platform = await getPlatform()
  return platform.path.homeDir()
}

/**
 * Join path segments
 */
export async function joinPath(...paths: string[]): Promise<string> {
  const platform = await getPlatform()
  return platform.path.join(...paths)
}

/**
 * Open URL in default browser
 */
export async function openUrl(url: string): Promise<void> {
  const platform = await getPlatform()
  return platform.system.openUrl(url)
}

// Tauri platform implementation
import type {
  PlatformAPI,
  PlatformType,
  DirEntry,
  FileInfo,
  GitStatus,
  ShellCommand,
  ShellChild,
  ShellSpawnOptions,
  Pty,
  PtyOptions,
  HttpResponse,
  HttpRequestOptions,
  BaseDirectory,
  UnlistenFn,
} from './types'

// Lazy imports to avoid loading Tauri APIs when not in Tauri environment
async function getTauriCore() {
  return await import('@tauri-apps/api/core')
}

async function getTauriPath() {
  return await import('@tauri-apps/api/path')
}

async function getTauriFs() {
  return await import('@tauri-apps/plugin-fs')
}

async function getTauriShell() {
  return await import('@tauri-apps/plugin-shell')
}

async function getTauriOpener() {
  return await import('@tauri-apps/plugin-opener')
}

async function getTauriEvent() {
  return await import('@tauri-apps/api/event')
}

// Map our BaseDirectory to Tauri's BaseDirectory
function mapBaseDir(baseDir?: BaseDirectory): number | undefined {
  if (!baseDir) return undefined
  // Tauri uses numeric enum values
  const mapping: Record<BaseDirectory, number> = {
    AppData: 14, // BaseDirectory.AppData
    AppConfig: 13, // BaseDirectory.AppConfig
    Home: 22, // BaseDirectory.Home
    Document: 6, // BaseDirectory.Document
    Desktop: 5, // BaseDirectory.Desktop
    Download: 7, // BaseDirectory.Download
  }
  return mapping[baseDir]
}

export const tauriPlatform: PlatformAPI = {
  type: 'tauri' as PlatformType,

  fs: {
    async readTextFile(path: string, options?: { baseDir?: BaseDirectory }): Promise<string> {
      const fs = await getTauriFs()
      return await fs.readTextFile(path, { baseDir: mapBaseDir(options?.baseDir) })
    },

    async writeTextFile(path: string, content: string, options?: { baseDir?: BaseDirectory }): Promise<void> {
      const fs = await getTauriFs()
      await fs.writeTextFile(path, content, { baseDir: mapBaseDir(options?.baseDir) })
    },

    async readDir(path: string): Promise<DirEntry[]> {
      const fs = await getTauriFs()
      const entries = await fs.readDir(path)
      return entries.map((e) => ({
        name: e.name,
        isDirectory: e.isDirectory,
        isFile: e.isFile,
        isSymlink: e.isSymlink,
      }))
    },

    async stat(path: string): Promise<FileInfo> {
      const fs = await getTauriFs()
      const info = await fs.stat(path)
      return {
        name: path.split('/').pop() || path,
        isDirectory: info.isDirectory,
        isFile: info.isFile,
        size: info.size,
        modifiedAt: info.mtime ? new Date(info.mtime) : undefined,
      }
    },

    async exists(path: string, options?: { baseDir?: BaseDirectory }): Promise<boolean> {
      const fs = await getTauriFs()
      return await fs.exists(path, { baseDir: mapBaseDir(options?.baseDir) })
    },

    async mkdir(path: string, options?: { baseDir?: BaseDirectory; recursive?: boolean }): Promise<void> {
      const fs = await getTauriFs()
      await fs.mkdir(path, { baseDir: mapBaseDir(options?.baseDir), recursive: options?.recursive })
    },

    async remove(path: string, options?: { recursive?: boolean }): Promise<void> {
      const { invoke } = await getTauriCore()
      // Use custom command that handles both files and directories
      await invoke('fs_delete', { path, isDirectory: options?.recursive ?? false })
    },

    async rename(oldPath: string, newPath: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('fs_rename', { oldPath, newPath })
    },

    async copy(src: string, dest: string, options?: { recursive?: boolean }): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('fs_copy', { source: src, destination: dest, isDirectory: options?.recursive ?? false })
    },
  },

  path: {
    async join(...paths: string[]): Promise<string> {
      const { join } = await getTauriPath()
      return await join(...paths)
    },

    async homeDir(): Promise<string> {
      const { homeDir } = await getTauriPath()
      return await homeDir()
    },

    async appDataDir(): Promise<string> {
      const { appDataDir } = await getTauriPath()
      return await appDataDir()
    },

    dirname(path: string): string {
      const parts = path.split('/')
      parts.pop()
      return parts.join('/') || '/'
    },

    basename(path: string): string {
      return path.split('/').pop() || path
    },
  },

  shell: {
    createCommand(program: string, args?: string[], options?: ShellSpawnOptions): ShellCommand {
      // Return a lazy command object that wraps Tauri's Command
      const stdoutCallbacks: ((data: string) => void)[] = []
      const stderrCallbacks: ((data: string) => void)[] = []
      const closeCallbacks: ((data: { code: number; signal?: string }) => void)[] = []
      const errorCallbacks: ((error: string) => void)[] = []

      return {
        stdout: {
          on(event: 'data', callback: (data: string) => void) {
            if (event === 'data') stdoutCallbacks.push(callback)
          },
        },
        stderr: {
          on(event: 'data', callback: (data: string) => void) {
            if (event === 'data') stderrCallbacks.push(callback)
          },
        },
        on(event: 'close' | 'error', callback: ((data: { code: number; signal?: string }) => void) | ((error: string) => void)) {
          if (event === 'close') closeCallbacks.push(callback as (data: { code: number; signal?: string }) => void)
          if (event === 'error') errorCallbacks.push(callback as (error: string) => void)
        },
        async spawn(): Promise<ShellChild> {
          const shell = await getTauriShell()
          const command = shell.Command.create(program, args ?? [], { env: options?.env })

          // Wire up callbacks
          command.stdout.on('data', (data) => {
            stdoutCallbacks.forEach((cb) => cb(data as string))
          })
          command.stderr.on('data', (data) => {
            stderrCallbacks.forEach((cb) => cb(data as string))
          })
          command.on('close', (data) => {
            closeCallbacks.forEach((cb) => cb({ code: data.code ?? 0, signal: data.signal?.toString() }))
          })
          command.on('error', (error) => {
            errorCallbacks.forEach((cb) => cb(error))
          })

          const child = await command.spawn()

          return {
            pid: child.pid,
            async write(data: string) {
              await child.write(data)
            },
            async kill() {
              await child.kill()
            },
          }
        },
      }
    },
  },

  pty: {
    spawn(shell: string, args: string[], options?: PtyOptions): Pty {
      // Synchronous wrapper - tauri-pty spawn is synchronous
      let ptyInstance: ReturnType<typeof import('tauri-pty').spawn> | null = null

      // We need to load this synchronously since spawn is used synchronously
      // This relies on tauri-pty being pre-loaded
      const tauriPty = require('tauri-pty')
      ptyInstance = tauriPty.spawn(shell, args, {
        cols: options?.cols ?? 80,
        rows: options?.rows ?? 24,
        cwd: options?.cwd,
        env: options?.env,
      })

      return {
        get pid() {
          return ptyInstance?.pid ?? 0
        },
        onData(callback: (data: string) => void) {
          ptyInstance?.onData(callback)
        },
        onExit(callback: (e: { exitCode: number }) => void) {
          ptyInstance?.onExit(callback)
        },
        write(data: string) {
          ptyInstance?.write(data)
        },
        resize(cols: number, rows: number) {
          ptyInstance?.resize(cols, rows)
        },
        kill() {
          ptyInstance?.kill()
        },
      }
    },
  },

  http: {
    async fetch(url: string, options?: HttpRequestOptions): Promise<HttpResponse> {
      // Tauri doesn't have CORS issues - use native fetch directly
      const response = await globalThis.fetch(url, {
        method: options?.method ?? 'GET',
        headers: options?.headers,
        body: options?.body,
        signal: options?.timeout ? AbortSignal.timeout(options.timeout) : undefined,
      })

      const headers: Record<string, string> = {}
      response.headers.forEach((value, key) => {
        headers[key] = value
      })

      return {
        status: response.status,
        statusText: response.statusText,
        headers,
        body: await response.text(),
        ok: response.ok,
      }
    },
  },

  window: {
    async createNew(): Promise<string> {
      const { invoke } = await getTauriCore()
      return await invoke<string>('create_new_window')
    },

    async close(): Promise<void> {
      const { getCurrentWindow } = await import('@tauri-apps/api/window')
      await getCurrentWindow().close()
    },

    async minimize(): Promise<void> {
      const { getCurrentWindow } = await import('@tauri-apps/api/window')
      await getCurrentWindow().minimize()
    },

    async maximize(): Promise<void> {
      const { getCurrentWindow } = await import('@tauri-apps/api/window')
      await getCurrentWindow().maximize()
    },

    async setVibrancy(effect: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('set_window_vibrancy', { vibrancy: effect })
    },

    async setOpacity(opacity: number): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('set_window_opacity', { opacity })
    },

    async getCount(): Promise<number> {
      const { invoke } = await getTauriCore()
      return await invoke<number>('get_window_count')
    },
  },

  webview: {
    async create(id: string, url: string, bounds: { x: number; y: number; width: number; height: number }): Promise<string> {
      const { invoke } = await getTauriCore()
      return await invoke<string>('create_embedded_webview', {
        webviewId: id,
        url,
        x: bounds.x,
        y: bounds.y,
        width: bounds.width,
        height: bounds.height,
      })
    },

    async updateBounds(id: string, bounds: { x: number; y: number; width: number; height: number }): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('update_webview_bounds', {
        webviewId: id,
        x: bounds.x,
        y: bounds.y,
        width: bounds.width,
        height: bounds.height,
      })
    },

    async navigate(id: string, url: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('navigate_webview', { webviewId: id, url })
    },

    async destroy(id: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('destroy_webview', { webviewId: id })
    },

    async executeScript(id: string, script: string): Promise<string> {
      const { invoke } = await getTauriCore()
      return await invoke<string>('execute_webview_script', { webviewId: id, script })
    },

    async hideAll(): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('hide_all_webviews')
    },

    async showAll(): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('show_all_webviews')
    },
  },

  git: {
    async status(repoPath: string): Promise<GitStatus> {
      const { invoke } = await getTauriCore()
      const result = await invoke<{
        current_branch: string
        branches: string[]
        staged: { path: string; status: string }[]
        unstaged: { path: string; status: string }[]
      }>('get_git_status', { path: repoPath })

      return {
        currentBranch: result.current_branch,
        branches: result.branches,
        staged: result.staged,
        unstaged: result.unstaged,
      }
    },

    async stageFile(repoPath: string, file: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('git_stage_file', { path: repoPath, file })
    },

    async unstageFile(repoPath: string, file: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('git_unstage_file', { path: repoPath, file })
    },

    async commit(repoPath: string, message: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('git_commit', { path: repoPath, message })
    },

    async push(repoPath: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('git_push', { path: repoPath })
    },

    async checkoutBranch(repoPath: string, branch: string): Promise<void> {
      const { invoke } = await getTauriCore()
      await invoke('git_checkout_branch', { path: repoPath, branch })
    },
  },

  system: {
    async openUrl(url: string): Promise<void> {
      const { openUrl } = await getTauriOpener()
      await openUrl(url)
    },

    async getCurrentDirectory(): Promise<string> {
      const { invoke } = await getTauriCore()
      return await invoke<string>('get_current_directory')
    },
  },

  events: {
    async listen<T>(event: string, callback: (payload: T) => void): Promise<UnlistenFn> {
      const { listen } = await getTauriEvent()
      return await listen(event, (e) => callback(e.payload as T))
    },

    async emit(event: string, payload?: unknown): Promise<void> {
      const { emit } = await getTauriEvent()
      await emit(event, payload)
    },
  },

  menu: {
    async showSplitContextMenu(x: number, y: number, paneId: string, canClose: boolean): Promise<string> {
      const { invoke } = await getTauriCore()
      return await invoke<string>('show_split_context_menu', { x, y, paneId, canClose })
    },
  },
}

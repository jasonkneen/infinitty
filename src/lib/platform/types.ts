// Platform abstraction types for Tauri

export type PlatformType = 'tauri' | 'web'

// File system types
export interface FileInfo {
  name: string
  isDirectory: boolean
  isFile: boolean
  size?: number
  modifiedAt?: Date
}

export interface DirEntry {
  name: string
  isDirectory: boolean
  isFile: boolean
  isSymlink: boolean
}

// Git types
export interface GitFileChange {
  path: string
  status: string
}

export interface GitStatus {
  currentBranch: string
  branches: string[]
  staged: GitFileChange[]
  unstaged: GitFileChange[]
}

// Shell types
export interface ShellChild {
  pid: number
  write(data: string): Promise<void>
  kill(): Promise<void>
}

export interface ShellSpawnOptions {
  cwd?: string
  env?: Record<string, string>
}

export interface ShellCommand {
  stdout: {
    on(event: 'data', callback: (data: string) => void): void
  }
  stderr: {
    on(event: 'data', callback: (data: string) => void): void
  }
  on(event: 'close', callback: (data: { code: number; signal?: string }) => void): void
  on(event: 'error', callback: (error: string) => void): void
  spawn(): Promise<ShellChild>
}

// PTY types
export interface PtyOptions {
  cols?: number
  rows?: number
  cwd?: string
  env?: Record<string, string>
}

export interface Pty {
  pid: number
  onData(callback: (data: string) => void): void
  onExit(callback: (e: { exitCode: number }) => void): void
  write(data: string): void
  resize(cols: number, rows: number): void
  kill(): void
}

// Window types
export interface WindowPosition {
  x: number
  y: number
}

export interface WindowSize {
  width: number
  height: number
}

// HTTP types (critical for CORS handling)
export interface HttpRequestOptions {
  method?: string
  headers?: Record<string, string>
  body?: string | ArrayBuffer
  timeout?: number
}

export interface HttpResponse {
  status: number
  statusText: string
  headers: Record<string, string>
  body: string
  ok: boolean
}

// Event listener cleanup function
export type UnlistenFn = () => void

// Base directory for file operations
export type BaseDirectory = 'AppData' | 'AppConfig' | 'Home' | 'Document' | 'Desktop' | 'Download'

/**
 * Platform API interface - abstracts native functionality
 * Implementation: TauriPlatform
 */
export interface PlatformAPI {
  // Platform identification
  readonly type: PlatformType

  // File system operations
  fs: {
    readTextFile(path: string, options?: { baseDir?: BaseDirectory }): Promise<string>
    writeTextFile(path: string, content: string, options?: { baseDir?: BaseDirectory }): Promise<void>
    readDir(path: string): Promise<DirEntry[]>
    stat(path: string): Promise<FileInfo>
    exists(path: string, options?: { baseDir?: BaseDirectory }): Promise<boolean>
    mkdir(path: string, options?: { baseDir?: BaseDirectory; recursive?: boolean }): Promise<void>
    remove(path: string, options?: { recursive?: boolean }): Promise<void>
    rename(oldPath: string, newPath: string): Promise<void>
    copy(src: string, dest: string, options?: { recursive?: boolean }): Promise<void>
  }

  // Path utilities
  path: {
    join(...paths: string[]): Promise<string>
    homeDir(): Promise<string>
    appDataDir(): Promise<string>
    dirname(path: string): string
    basename(path: string): string
  }

  // Shell execution (for spawning processes like MCP servers)
  shell: {
    createCommand(program: string, args?: string[], options?: ShellSpawnOptions): ShellCommand
  }

  // PTY (pseudo-terminal) for interactive terminal sessions
  pty: {
    spawn(shell: string, args: string[], options?: PtyOptions): Pty
  }

  // HTTP requests
  http: {
    fetch(url: string, options?: HttpRequestOptions): Promise<HttpResponse>
  }

  // Window management
  window: {
    createNew(): Promise<string>
    close(): Promise<void>
    minimize(): Promise<void>
    maximize(): Promise<void>
    setVibrancy(effect: string): Promise<void>
    setOpacity(opacity: number): Promise<void>
    getCount(): Promise<number>
  }

  // Webview management (embedded browser views)
  webview: {
    create(id: string, url: string, bounds: { x: number; y: number; width: number; height: number }): Promise<string>
    updateBounds(id: string, bounds: { x: number; y: number; width: number; height: number }): Promise<void>
    navigate(id: string, url: string): Promise<void>
    destroy(id: string): Promise<void>
    executeScript(id: string, script: string): Promise<string>
    hideAll(): Promise<void>
    showAll(): Promise<void>
  }

  // Git operations
  git: {
    status(repoPath: string): Promise<GitStatus>
    stageFile(repoPath: string, file: string): Promise<void>
    unstageFile(repoPath: string, file: string): Promise<void>
    commit(repoPath: string, message: string): Promise<void>
    push(repoPath: string): Promise<void>
    checkoutBranch(repoPath: string, branch: string): Promise<void>
  }

  // System utilities
  system: {
    openUrl(url: string): Promise<void>
    getCurrentDirectory(): Promise<string>
  }

  // Events (for menu actions, etc.)
  events: {
    listen<T>(event: string, callback: (payload: T) => void): Promise<UnlistenFn>
    emit(event: string, payload?: unknown): Promise<void>
  }

  // Context menu
  menu: {
    showSplitContextMenu(x: number, y: number, paneId: string, canClose: boolean): Promise<string>
  }
}

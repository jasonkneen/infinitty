// Shell Environment Utility
// Captures the user's shell environment (PATH, etc.) for GUI apps on macOS
// GUI apps don't inherit shell environment, so we need to capture it from a login shell

import { Command } from '@tauri-apps/plugin-shell'
import { homeDir } from '@tauri-apps/api/path'

interface ShellEnvironment {
  PATH: string
  HOME: string
  USER: string
  SHELL: string
  LANG: string
  [key: string]: string
}

let cachedEnv: ShellEnvironment | null = null
let envPromise: Promise<ShellEnvironment> | null = null

// Get the user's shell environment by spawning a login shell
async function captureShellEnvironment(): Promise<ShellEnvironment> {
  // Get home directory from Tauri
  let home = '/Users/unknown'
  try {
    home = await homeDir()
  } catch {
    // Fallback if Tauri not available
  }

  // Default fallback environment
  const defaultEnv: ShellEnvironment = {
    PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    HOME: home,
    USER: home.split('/').pop() || 'unknown',
    SHELL: '/bin/zsh',
    LANG: 'en_US.UTF-8',
  }

  try {
    // Spawn a login shell to get the full environment
    // This sources ~/.zprofile, ~/.zshrc, etc.
    // Note: Use 'zsh' which is the allowlist name in capabilities/default.json
    const cmd = Command.create('zsh', ['-l', '-c', 'env'])

    const output = await cmd.execute()

    if (output.code !== 0) {
      console.warn('[ShellEnv] Failed to capture shell environment, using defaults')
      return defaultEnv
    }

    // Parse the environment output
    const env: ShellEnvironment = { ...defaultEnv }
    const lines = output.stdout.split('\n')

    for (const line of lines) {
      const eqIndex = line.indexOf('=')
      if (eqIndex > 0) {
        const key = line.slice(0, eqIndex)
        const value = line.slice(eqIndex + 1)
        env[key] = value
      }
    }

    console.log('[ShellEnv] Captured shell environment, PATH has', env.PATH?.split(':').length || 0, 'entries')

    // Log some important paths for debugging
    const pathEntries = env.PATH?.split(':') || []
    const hasNvm = pathEntries.some(p => p.includes('nvm'))
    const hasBrew = pathEntries.some(p => p.includes('brew') || p.includes('Homebrew'))
    const hasLocal = pathEntries.some(p => p.includes('/usr/local/bin'))
    console.log('[ShellEnv] PATH includes: nvm=', hasNvm, 'brew=', hasBrew, 'local=', hasLocal)

    return env
  } catch (error) {
    console.error('[ShellEnv] Error capturing shell environment:', error)
    return defaultEnv
  }
}

// Get the shell environment (cached after first call)
export async function getShellEnv(): Promise<ShellEnvironment> {
  if (cachedEnv) {
    return cachedEnv
  }

  // Prevent multiple concurrent captures
  if (!envPromise) {
    envPromise = captureShellEnvironment().then(env => {
      cachedEnv = env
      return env
    })
  }

  return envPromise
}

// Get a merged environment with shell PATH and custom overrides
export async function getEnvWithPath(customEnv?: Record<string, string>): Promise<Record<string, string>> {
  const shellEnv = await getShellEnv()

  return {
    // Start with the captured shell environment
    PATH: shellEnv.PATH,
    HOME: shellEnv.HOME,
    USER: shellEnv.USER,
    SHELL: shellEnv.SHELL,
    LANG: shellEnv.LANG || 'en_US.UTF-8',
    // Terminal-specific vars
    TERM: 'xterm-256color',
    COLORTERM: 'truecolor',
    // Any custom overrides
    ...customEnv,
  }
}

// Initialize shell environment on app startup
// Call this early in the app lifecycle
export async function initShellEnv(): Promise<void> {
  console.log('[ShellEnv] Initializing shell environment...')
  await getShellEnv()
  console.log('[ShellEnv] Shell environment initialized')
}

// Find an executable in PATH
export async function which(executable: string): Promise<string | null> {
  const env = await getShellEnv()
  const pathDirs = env.PATH?.split(':') || []

  for (const dir of pathDirs) {
    const fullPath = `${dir}/${executable}`
    try {
      // Check if file exists and is executable using test command
      // Note: Use 'test' which is the allowlist name in capabilities/default.json
      const cmd = Command.create('test', ['-x', fullPath])
      const result = await cmd.execute()
      if (result.code === 0) {
        return fullPath
      }
    } catch {
      // Continue searching
    }
  }

  return null
}

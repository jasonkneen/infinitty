import { useState, useEffect } from 'react'
import { readTextFile } from '@tauri-apps/plugin-fs'
import { homeDir, join } from '@tauri-apps/api/path'

// Ghostty config file mapping to our settings
export interface GhosttyConfig {
  fontFamily?: string
  fontSize?: number
  foreground?: string
  background?: string
  fontThicken?: boolean
  adjustCellWidth?: number
  windowPaddingX?: number
  windowPaddingY?: number
  cursorStyle?: 'block' | 'underline' | 'bar'
  cursorBlink?: boolean
  scrollbackLines?: number
  // Raw config for access to all values
  raw: Record<string, string>
}

// Parse Ghostty config file format
function parseGhosttyConfig(content: string): GhosttyConfig {
  const raw: Record<string, string> = {}
  const lines = content.split('\n')

  for (const line of lines) {
    // Skip empty lines and comments
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    // Parse key = value
    const eqIndex = trimmed.indexOf('=')
    if (eqIndex === -1) continue

    const key = trimmed.substring(0, eqIndex).trim()
    const value = trimmed.substring(eqIndex + 1).trim()
    raw[key] = value
  }

  // Map to our config structure
  const config: GhosttyConfig = { raw }

  if (raw['font-family']) {
    config.fontFamily = raw['font-family']
  }
  if (raw['font-size']) {
    config.fontSize = parseInt(raw['font-size'], 10)
  }
  if (raw['foreground']) {
    config.foreground = raw['foreground']
  }
  if (raw['background']) {
    config.background = raw['background']
  }
  if (raw['font-thicken']) {
    config.fontThicken = raw['font-thicken'] === 'true'
  }
  if (raw['adjust-cell-width']) {
    config.adjustCellWidth = parseInt(raw['adjust-cell-width'], 10)
  }
  if (raw['window-padding-x']) {
    config.windowPaddingX = parseInt(raw['window-padding-x'], 10)
  }
  if (raw['window-padding-y']) {
    config.windowPaddingY = parseInt(raw['window-padding-y'], 10)
  }
  if (raw['cursor-style']) {
    const style = raw['cursor-style'].toLowerCase()
    if (style === 'block' || style === 'underline' || style === 'bar') {
      config.cursorStyle = style
    }
  }
  if (raw['cursor-blink']) {
    config.cursorBlink = raw['cursor-blink'] === 'true'
  }
  if (raw['scrollback-lines']) {
    config.scrollbackLines = parseInt(raw['scrollback-lines'], 10)
  }

  return config
}

// Hook to load Ghostty config
export function useGhosttyConfig() {
  const [config, setConfig] = useState<GhosttyConfig | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    async function loadConfig() {
      try {
        // Ghostty config location on macOS
        const home = await homeDir()
        const configPath = await join(home, 'Library', 'Application Support', 'com.mitchellh.ghostty', 'config')

        const content = await readTextFile(configPath)
        const parsed = parseGhosttyConfig(content)
        setConfig(parsed)
        setError(null)
      } catch (err) {
        // Config file doesn't exist or can't be read - this is fine
        console.log('Ghostty config not found or unreadable:', err)
        setConfig(null)
        setError(err instanceof Error ? err.message : 'Failed to load Ghostty config')
      } finally {
        setLoading(false)
      }
    }

    loadConfig()
  }, [])

  return { config, loading, error }
}

// Get default Ghostty config path
export async function getGhosttyConfigPath(): Promise<string> {
  const home = await homeDir()
  return join(home, 'Library', 'Application Support', 'com.mitchellh.ghostty', 'config')
}

// MCP Settings - Persistent storage for MCP server configurations
import { BaseDirectory, exists, mkdir, readTextFile, writeTextFile } from '@tauri-apps/plugin-fs'
import { z } from 'zod'
import type { MCPServerConfig } from '../types/mcp'

const SETTINGS_DIR = 'settings'
const SETTINGS_FILE = 'mcp.json'

// Zod schemas for runtime validation
const MCPServerConfigSchema = z.object({
  id: z.string().min(1).max(256),
  name: z.string().min(1).max(256),
  transport: z.enum(['stdio', 'http']).optional(),
  command: z.string().max(1024),
  args: z.array(z.string()).optional(),
  env: z.record(z.string(), z.string()).optional(),
  url: z.string().url().max(2048).optional(),
  port: z.number().int().min(1).max(65535).optional(),
  enabled: z.boolean(),
  autoStart: z.boolean().optional(),
  source: z.enum(['user', 'discovered', 'widget']).optional(),
})

const MCPSettingsSchema = z.object({
  version: z.literal(1),
  servers: z.array(MCPServerConfigSchema),
  hiddenServerIds: z.array(z.string()),
  autoConnectServerIds: z.array(z.string()),
  lastUpdated: z.string().datetime(),
})

export interface MCPSettings {
  version: 1
  servers: MCPServerConfig[]
  hiddenServerIds: string[]  // IDs of servers to hide from UI
  autoConnectServerIds: string[]  // IDs of servers to auto-connect on startup
  lastUpdated: string  // ISO timestamp
}

const DEFAULT_SETTINGS: MCPSettings = {
  version: 1,
  servers: [],
  hiddenServerIds: [],
  autoConnectServerIds: [],
  lastUpdated: new Date().toISOString(),
}

/**
 * Load MCP settings from disk with Zod validation
 */
export async function loadMCPSettings(): Promise<MCPSettings> {
  try {
    // Check if settings file exists
    const settingsPath = `${SETTINGS_DIR}/${SETTINGS_FILE}`
    const fileExists = await exists(settingsPath, { baseDir: BaseDirectory.AppData })

    if (!fileExists) {
      return DEFAULT_SETTINGS
    }

    const content = await readTextFile(settingsPath, { baseDir: BaseDirectory.AppData })
    const parsed = JSON.parse(content)

    // Validate against schema
    const result = MCPSettingsSchema.safeParse(parsed)
    if (!result.success) {
      console.warn('[MCP Settings] Validation failed:', result.error.flatten())
      return DEFAULT_SETTINGS
    }

    return result.data as MCPSettings
  } catch (error) {
    console.warn('[MCP Settings] Failed to load, using defaults:', error)
    return DEFAULT_SETTINGS
  }
}

/**
 * Save MCP settings to disk
 */
export async function saveMCPSettings(settings: MCPSettings): Promise<void> {
  try {
    // Ensure settings directory exists
    const dirExists = await exists(SETTINGS_DIR, { baseDir: BaseDirectory.AppData })
    if (!dirExists) {
      await mkdir(SETTINGS_DIR, { baseDir: BaseDirectory.AppData, recursive: true })
    }

    const settingsPath = `${SETTINGS_DIR}/${SETTINGS_FILE}`
    const content = JSON.stringify(
      {
        ...settings,
        lastUpdated: new Date().toISOString(),
      },
      null,
      2
    )

    await writeTextFile(settingsPath, content, { baseDir: BaseDirectory.AppData })
    console.log('[MCP Settings] Saved successfully')
  } catch (error) {
    console.error('[MCP Settings] Failed to save:', error)
    throw error
  }
}

/**
 * Add a server to settings
 */
export async function addServerToSettings(
  settings: MCPSettings,
  server: MCPServerConfig
): Promise<MCPSettings> {
  const existingIndex = settings.servers.findIndex(s => s.id === server.id)
  const updatedServers = existingIndex >= 0
    ? settings.servers.map((s, i) => i === existingIndex ? server : s)
    : [...settings.servers, server]

  const updated = {
    ...settings,
    servers: updatedServers,
  }

  await saveMCPSettings(updated)
  return updated
}

/**
 * Remove a server from settings
 */
export async function removeServerFromSettings(
  settings: MCPSettings,
  serverId: string
): Promise<MCPSettings> {
  const updated = {
    ...settings,
    servers: settings.servers.filter(s => s.id !== serverId),
    hiddenServerIds: settings.hiddenServerIds.filter(id => id !== serverId),
    autoConnectServerIds: settings.autoConnectServerIds.filter(id => id !== serverId),
  }

  await saveMCPSettings(updated)
  return updated
}

/**
 * Toggle server visibility
 */
export async function toggleServerHidden(
  settings: MCPSettings,
  serverId: string
): Promise<MCPSettings> {
  const isHidden = settings.hiddenServerIds.includes(serverId)
  const updated = {
    ...settings,
    hiddenServerIds: isHidden
      ? settings.hiddenServerIds.filter(id => id !== serverId)
      : [...settings.hiddenServerIds, serverId],
  }

  await saveMCPSettings(updated)
  return updated
}

/**
 * Toggle server auto-connect
 */
export async function toggleServerAutoConnect(
  settings: MCPSettings,
  serverId: string
): Promise<MCPSettings> {
  const isAutoConnect = settings.autoConnectServerIds.includes(serverId)
  const updated = {
    ...settings,
    autoConnectServerIds: isAutoConnect
      ? settings.autoConnectServerIds.filter(id => id !== serverId)
      : [...settings.autoConnectServerIds, serverId],
  }

  await saveMCPSettings(updated)
  return updated
}

/**
 * Update a server in settings
 */
export async function updateServerInSettings(
  settings: MCPSettings,
  serverId: string,
  updates: Partial<MCPServerConfig>
): Promise<MCPSettings> {
  const updated = {
    ...settings,
    servers: settings.servers.map(s =>
      s.id === serverId ? { ...s, ...updates } : s
    ),
  }

  await saveMCPSettings(updated)
  return updated
}

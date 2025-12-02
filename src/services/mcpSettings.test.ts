import { describe, it, expect, vi, beforeEach } from 'vitest'
import { readTextFile, writeTextFile, exists, mkdir } from '@tauri-apps/plugin-fs'
import {
  loadMCPSettings,
  saveMCPSettings,
  addServerToSettings,
  removeServerFromSettings,
  toggleServerHidden,
  toggleServerAutoConnect,
  updateServerInSettings,
  type MCPSettings,
} from './mcpSettings'
import type { MCPServerConfig } from '../types/mcp'

vi.mock('@tauri-apps/plugin-fs')

describe('mcpSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('loadMCPSettings', () => {
    it('returns default settings when file does not exist', async () => {
      vi.mocked(exists).mockResolvedValue(false)

      const settings = await loadMCPSettings()

      expect(settings).toEqual({
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: expect.any(String),
      })
    })

    it('loads and parses settings from file', async () => {
      const mockSettings: MCPSettings = {
        version: 1,
        servers: [
          {
            id: 'test-server',
            name: 'Test Server',
            command: 'node',
            enabled: true,
          },
        ],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(readTextFile).mockResolvedValue(JSON.stringify(mockSettings))

      const settings = await loadMCPSettings()

      expect(settings.servers).toHaveLength(1)
      expect(settings.servers[0].id).toBe('test-server')
    })

    it('returns defaults when file has invalid JSON', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(readTextFile).mockResolvedValue('invalid json')

      const settings = await loadMCPSettings()

      expect(settings).toEqual({
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: expect.any(String),
      })
    })

    it('returns defaults when validation fails', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(readTextFile).mockResolvedValue(
        JSON.stringify({ version: 2, servers: [] })
      )

      const settings = await loadMCPSettings()

      expect(settings.version).toBe(1)
    })
  })

  describe('saveMCPSettings', () => {
    it('creates settings directory if it does not exist', async () => {
      vi.mocked(exists).mockResolvedValue(false)
      vi.mocked(mkdir).mockResolvedValue()
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      await saveMCPSettings(settings)

      expect(mkdir).toHaveBeenCalled()
      expect(writeTextFile).toHaveBeenCalled()
    })

    it('writes settings to file with updated timestamp', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      await saveMCPSettings(settings)

      const call = vi.mocked(writeTextFile).mock.calls[0]
      expect(call[0]).toContain('mcp.json')
      const content = JSON.parse(call[1] as string)
      expect(content.lastUpdated).not.toBe('2024-01-01T00:00:00Z')
    })

    it('throws error when write fails', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockRejectedValue(new Error('Write failed'))

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      await expect(saveMCPSettings(settings)).rejects.toThrow('Write failed')
    })
  })

  describe('addServerToSettings', () => {
    it('adds new server to empty settings', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const newServer: MCPServerConfig = {
        id: 'new-server',
        name: 'New Server',
        command: 'node',
        enabled: true,
      }

      const result = await addServerToSettings(settings, newServer)

      expect(result.servers).toHaveLength(1)
      expect(result.servers[0].id).toBe('new-server')
    })

    it('replaces existing server with same id', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [
          {
            id: 'server-1',
            name: 'Server 1',
            command: 'node',
            enabled: true,
          },
        ],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const updatedServer: MCPServerConfig = {
        id: 'server-1',
        name: 'Updated Server',
        command: 'python',
        enabled: false,
      }

      const result = await addServerToSettings(settings, updatedServer)

      expect(result.servers).toHaveLength(1)
      expect(result.servers[0].name).toBe('Updated Server')
      expect(result.servers[0].command).toBe('python')
    })
  })

  describe('removeServerFromSettings', () => {
    it('removes server by id', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [
          {
            id: 'server-1',
            name: 'Server 1',
            command: 'node',
            enabled: true,
          },
        ],
        hiddenServerIds: ['server-1'],
        autoConnectServerIds: ['server-1'],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await removeServerFromSettings(settings, 'server-1')

      expect(result.servers).toHaveLength(0)
      expect(result.hiddenServerIds).toHaveLength(0)
      expect(result.autoConnectServerIds).toHaveLength(0)
    })
  })

  describe('toggleServerHidden', () => {
    it('hides a visible server', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await toggleServerHidden(settings, 'server-1')

      expect(result.hiddenServerIds).toContain('server-1')
    })

    it('shows a hidden server', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: ['server-1'],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await toggleServerHidden(settings, 'server-1')

      expect(result.hiddenServerIds).not.toContain('server-1')
    })
  })

  describe('toggleServerAutoConnect', () => {
    it('enables auto-connect for server', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await toggleServerAutoConnect(settings, 'server-1')

      expect(result.autoConnectServerIds).toContain('server-1')
    })

    it('disables auto-connect for server', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [],
        hiddenServerIds: [],
        autoConnectServerIds: ['server-1'],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await toggleServerAutoConnect(settings, 'server-1')

      expect(result.autoConnectServerIds).not.toContain('server-1')
    })
  })

  describe('updateServerInSettings', () => {
    it('updates server properties', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [
          {
            id: 'server-1',
            name: 'Server 1',
            command: 'node',
            enabled: true,
          },
        ],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await updateServerInSettings(settings, 'server-1', {
        name: 'Updated Name',
        enabled: false,
      })

      expect(result.servers[0].name).toBe('Updated Name')
      expect(result.servers[0].enabled).toBe(false)
      expect(result.servers[0].command).toBe('node')
    })

    it('does not affect other servers', async () => {
      vi.mocked(exists).mockResolvedValue(true)
      vi.mocked(writeTextFile).mockResolvedValue()

      const settings: MCPSettings = {
        version: 1,
        servers: [
          {
            id: 'server-1',
            name: 'Server 1',
            command: 'node',
            enabled: true,
          },
          {
            id: 'server-2',
            name: 'Server 2',
            command: 'python',
            enabled: false,
          },
        ],
        hiddenServerIds: [],
        autoConnectServerIds: [],
        lastUpdated: '2024-01-01T00:00:00Z',
      }

      const result = await updateServerInSettings(settings, 'server-1', {
        name: 'Updated',
      })

      expect(result.servers).toHaveLength(2)
      expect(result.servers[1].name).toBe('Server 2')
    })
  })
})

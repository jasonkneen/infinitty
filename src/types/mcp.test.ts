import { describe, it, expect } from 'vitest'
import {
  type MCPTool,
  type MCPServerConfig,
  type MCPServerStatus,
  DEFAULT_MCP_SERVERS,
} from './mcp'

describe('MCP Types', () => {
  describe('MCPTool', () => {
    it('creates a valid MCP tool', () => {
      const tool: MCPTool = {
        name: 'test_tool',
        description: 'A test tool',
        inputSchema: { type: 'object', properties: {} },
      }

      expect(tool.name).toBe('test_tool')
      expect(tool.description).toBe('A test tool')
      expect(tool.inputSchema).toBeDefined()
    })

    it('allows optional inputSchema', () => {
      const tool: MCPTool = {
        name: 'simple_tool',
        description: 'Simple tool',
      }

      expect(tool.inputSchema).toBeUndefined()
    })
  })

  describe('MCPServerConfig', () => {
    it('creates a valid stdio transport server config', () => {
      const config: MCPServerConfig = {
        id: 'test-server',
        name: 'Test Server',
        command: 'node',
        args: ['server.js'],
        enabled: true,
        transport: 'stdio',
      }

      expect(config.id).toBe('test-server')
      expect(config.transport).toBe('stdio')
      expect(config.enabled).toBe(true)
    })

    it('creates a valid http transport server config', () => {
      const config: MCPServerConfig = {
        id: 'http-server',
        name: 'HTTP Server',
        command: 'curl',
        url: 'http://localhost:3000',
        port: 3000,
        enabled: true,
        transport: 'http',
      }

      expect(config.url).toBe('http://localhost:3000')
      expect(config.port).toBe(3000)
      expect(config.transport).toBe('http')
    })

    it('supports environment variables', () => {
      const config: MCPServerConfig = {
        id: 'env-server',
        name: 'Server with Env',
        command: 'python',
        args: ['server.py'],
        env: { API_KEY: 'secret', DEBUG: 'true' },
        enabled: true,
      }

      expect(config.env).toEqual({ API_KEY: 'secret', DEBUG: 'true' })
    })

    it('supports optional source field', () => {
      const config: MCPServerConfig = {
        id: 'sourced-server',
        name: 'Sourced Server',
        command: 'node',
        enabled: true,
        source: 'user',
      }

      expect(config.source).toBe('user')
    })
  })

  describe('MCPServerStatus', () => {
    it('creates a status with connected state', () => {
      const status: MCPServerStatus = {
        id: 'test-server',
        status: 'connected',
        tools: [
          {
            name: 'tool1',
            description: 'Tool 1',
          },
        ],
        resources: [],
        prompts: [],
        lastConnected: Date.now(),
      }

      expect(status.status).toBe('connected')
      expect(status.tools).toHaveLength(1)
      expect(status.error).toBeUndefined()
    })

    it('includes error message when disconnected with error', () => {
      const status: MCPServerStatus = {
        id: 'test-server',
        status: 'error',
        error: 'Connection timeout',
        tools: [],
        resources: [],
        prompts: [],
      }

      expect(status.status).toBe('error')
      expect(status.error).toBe('Connection timeout')
    })

    it('handles multiple tools and resources', () => {
      const status: MCPServerStatus = {
        id: 'multi-server',
        status: 'connected',
        tools: [
          { name: 'tool1', description: 'First tool' },
          { name: 'tool2', description: 'Second tool' },
        ],
        resources: [
          { uri: 'file://path/to/file', name: 'file', mimeType: 'text/plain' },
          { uri: 'file://path/to/other', name: 'other' },
        ],
        prompts: [
          {
            name: 'prompt1',
            description: 'First prompt',
            arguments: [{ name: 'arg1', required: true }],
          },
        ],
      }

      expect(status.tools).toHaveLength(2)
      expect(status.resources).toHaveLength(2)
      expect(status.prompts).toHaveLength(1)
    })
  })

  describe('DEFAULT_MCP_SERVERS', () => {
    it('contains a list of predefined servers', () => {
      expect(DEFAULT_MCP_SERVERS.length).toBeGreaterThan(0)
    })

    it('includes file system server', () => {
      const fsServer = DEFAULT_MCP_SERVERS.find(s => s.name === 'File System')
      expect(fsServer).toBeDefined()
      expect(fsServer?.command).toBe('npx')
      expect(fsServer?.enabled).toBe(false)
    })

    it('includes git server', () => {
      const gitServer = DEFAULT_MCP_SERVERS.find(s => s.name === 'Git')
      expect(gitServer).toBeDefined()
      expect(gitServer?.enabled).toBe(false)
    })

    it('includes github server with env var', () => {
      const ghServer = DEFAULT_MCP_SERVERS.find(s => s.name === 'GitHub')
      expect(ghServer).toBeDefined()
      expect(ghServer?.env).toHaveProperty('GITHUB_PERSONAL_ACCESS_TOKEN')
    })

    it('all servers are disabled by default', () => {
      const allDisabled = DEFAULT_MCP_SERVERS.every(s => s.enabled === false)
      expect(allDisabled).toBe(true)
    })

    it('all servers have required name and command fields', () => {
      const allValid = DEFAULT_MCP_SERVERS.every(
        s => s.name && s.command && typeof s.name === 'string' && typeof s.command === 'string'
      )
      expect(allValid).toBe(true)
    })
  })
})

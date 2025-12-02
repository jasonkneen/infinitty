/**
 * LSP Service
 * Manages Language Server Protocol connections through Tauri
 */

import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import type {
  Diagnostic,
  Hover,
  CompletionItem,
  Location,
  ServerStatus,
  CacheInfo,
  LSPEvent,
  LSPResult,
} from './types'
import { getAllServers, getServersForExtension, getLanguageId } from './servers'

export * from './types'
export * from './servers'

/**
 * LSP Service singleton
 * Provides interface to LSP functionality through Tauri commands
 */
class LSPService {
  private projectPath: string | null = null
  private initialized = false
  private eventListeners: Array<(event: LSPEvent) => void> = []
  private unlistenFn: UnlistenFn | null = null
  private enabledServers = new Set<string>()
  private installedServers = new Set<string>()

  constructor() {
    // Enable all servers by default
    getAllServers().forEach(server => {
      this.enabledServers.add(server.id)
    })
  }

  /**
   * Check if service is initialized
   */
  get isInitialized(): boolean {
    return this.initialized
  }

  /**
   * Get current project path
   */
  get currentProjectPath(): string | null {
    return this.projectPath
  }

  /**
   * Initialize LSP service for a project
   */
  async init(projectPath: string): Promise<LSPResult<void>> {
    try {
      this.projectPath = projectPath

      // Set up event listener for LSP events from Tauri
      if (!this.unlistenFn) {
        this.unlistenFn = await listen<LSPEvent>('lsp-event', (event) => {
          this.eventListeners.forEach(listener => listener(event.payload))
        })
      }

      // Initialize LSP manager in Tauri backend
      await invoke('lsp_init', { projectPath })
      this.initialized = true

      return { success: true }
    } catch (error) {
      console.error('[LSP] Init failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Shutdown LSP service
   */
  async shutdown(): Promise<LSPResult<void>> {
    try {
      await invoke('lsp_shutdown')
      this.initialized = false

      if (this.unlistenFn) {
        this.unlistenFn()
        this.unlistenFn = null
      }

      return { success: true }
    } catch (error) {
      console.error('[LSP] Shutdown failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get hover information at a position
   */
  async hover(filePath: string, line: number, character: number): Promise<LSPResult<Hover | null>> {
    try {
      const result = await invoke<Hover | null>('lsp_hover', { filePath, line, character })
      return { success: true, data: result }
    } catch (error) {
      console.error('[LSP] Hover failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get completion items at a position
   */
  async completion(filePath: string, line: number, character: number): Promise<LSPResult<CompletionItem[]>> {
    try {
      const result = await invoke<CompletionItem[]>('lsp_completion', { filePath, line, character })
      return { success: true, data: result || [] }
    } catch (error) {
      console.error('[LSP] Completion failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Go to definition
   */
  async definition(filePath: string, line: number, character: number): Promise<LSPResult<Location | Location[] | null>> {
    try {
      const result = await invoke<Location | Location[] | null>('lsp_definition', { filePath, line, character })
      return { success: true, data: result }
    } catch (error) {
      console.error('[LSP] Definition failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Find references
   */
  async references(filePath: string, line: number, character: number): Promise<LSPResult<Location[]>> {
    try {
      const result = await invoke<Location[]>('lsp_references', { filePath, line, character })
      return { success: true, data: result || [] }
    } catch (error) {
      console.error('[LSP] References failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get diagnostics for all files
   */
  async getDiagnostics(): Promise<LSPResult<Record<string, Diagnostic[]>>> {
    try {
      const result = await invoke<Record<string, Diagnostic[]>>('lsp_get_diagnostics')
      return { success: true, data: result || {} }
    } catch (error) {
      console.error('[LSP] Get diagnostics failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get diagnostics for a specific file
   */
  async getDiagnosticsForFile(filePath: string): Promise<LSPResult<Diagnostic[]>> {
    try {
      const result = await invoke<Diagnostic[]>('lsp_get_diagnostics_for_file', { filePath })
      return { success: true, data: result || [] }
    } catch (error) {
      console.error('[LSP] Get diagnostics for file failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Notify that a file was changed
   */
  async fileChanged(filePath: string, content?: string): Promise<LSPResult<void>> {
    try {
      await invoke('lsp_file_changed', { filePath, content })
      return { success: true }
    } catch (error) {
      console.error('[LSP] File changed failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Notify that a file was saved
   */
  async fileSaved(filePath: string): Promise<LSPResult<void>> {
    try {
      await invoke('lsp_file_saved', { filePath })
      return { success: true }
    } catch (error) {
      console.error('[LSP] File saved failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get status of all servers
   */
  async getStatus(): Promise<LSPResult<ServerStatus[]>> {
    try {
      const servers = getAllServers()
      const status: ServerStatus[] = []

      for (const server of servers) {
        const installed = this.installedServers.has(server.id)
        status.push({
          id: server.id,
          name: server.name,
          extensions: server.extensions,
          enabled: this.enabledServers.has(server.id),
          installed,
          installable: true,
          running: false, // Will be updated from backend
          instances: [],
        })
      }

      // Try to get actual status from backend
      try {
        const backendStatus = await invoke<ServerStatus[]>('lsp_get_status')
        if (backendStatus) {
          return { success: true, data: backendStatus }
        }
      } catch {
        // Fall back to local status
      }

      return { success: true, data: status }
    } catch (error) {
      console.error('[LSP] Get status failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Enable or disable a server
   */
  async setServerEnabled(serverId: string, enabled: boolean): Promise<LSPResult<void>> {
    try {
      if (enabled) {
        this.enabledServers.add(serverId)
      } else {
        this.enabledServers.delete(serverId)
      }

      await invoke('lsp_set_server_enabled', { serverId, enabled })

      // Emit event
      this.eventListeners.forEach(listener => {
        listener({ type: 'server-status-changed', serverId, enabled })
      })

      return { success: true }
    } catch (error) {
      console.error('[LSP] Set server enabled failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Install a server
   */
  async installServer(serverId: string): Promise<LSPResult<void>> {
    try {
      await invoke('lsp_install_server', { serverId })
      this.installedServers.add(serverId)
      return { success: true }
    } catch (error) {
      console.error('[LSP] Install server failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Get cache info
   */
  async getCacheInfo(): Promise<LSPResult<CacheInfo>> {
    try {
      const result = await invoke<CacheInfo>('lsp_get_cache_info')
      return { success: true, data: result }
    } catch (error) {
      console.error('[LSP] Get cache info failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Clear cache
   */
  async clearCache(): Promise<LSPResult<void>> {
    try {
      await invoke('lsp_clear_cache')
      return { success: true }
    } catch (error) {
      console.error('[LSP] Clear cache failed:', error)
      return { success: false, error: String(error) }
    }
  }

  /**
   * Subscribe to LSP events
   */
  onEvent(callback: (event: LSPEvent) => void): () => void {
    this.eventListeners.push(callback)
    return () => {
      const index = this.eventListeners.indexOf(callback)
      if (index > -1) {
        this.eventListeners.splice(index, 1)
      }
    }
  }

  /**
   * Check if LSP is available for a file
   */
  isAvailableForFile(filePath: string): boolean {
    const ext = filePath.substring(filePath.lastIndexOf('.'))
    const servers = getServersForExtension(ext)
    return servers.some(s => this.enabledServers.has(s.id))
  }

  /**
   * Get language ID for a file
   */
  getLanguageId(filePath: string): string {
    const ext = filePath.substring(filePath.lastIndexOf('.'))
    return getLanguageId(ext)
  }
}

// Export singleton instance
export const lspService = new LSPService()

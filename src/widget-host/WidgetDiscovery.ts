// Widget Discovery - Scans and validates widget packages
import { readDir, readTextFile, writeTextFile, mkdir, remove, exists } from '@tauri-apps/plugin-fs'
import { join, appDataDir } from '@tauri-apps/api/path'
import type { WidgetManifest } from '../widget-sdk/types'

// Extended manifest with discovery metadata
export interface DiscoveredWidget {
  manifest: WidgetManifest
  path: string
  source: 'builtin' | 'user' | 'external'
  isValid: boolean
  validationErrors: string[]
}

// Manifest validation schema
interface ManifestSchema {
  id: string
  name: string
  version: string
  description?: string
  main: string
  ui?: string
  executionModel?: 'process' | 'inline' | 'webworker'
  port?: number
  activationEvents?: string[]
  contributes?: {
    tools?: Array<{
      name: string
      description: string
    }>
    commands?: Array<{
      id: string
      title: string
    }>
  }
}

// Validate manifest structure
function validateManifest(manifest: unknown): { valid: boolean; errors: string[] } {
  const errors: string[] = []

  if (!manifest || typeof manifest !== 'object') {
    return { valid: false, errors: ['Manifest must be an object'] }
  }

  const m = manifest as Record<string, unknown>

  // Required fields
  if (!m.id || typeof m.id !== 'string') {
    errors.push('Missing or invalid "id" field')
  } else if (!/^[a-z]+\.[a-z]+\.[a-z0-9-]+$/i.test(m.id)) {
    errors.push('Invalid "id" format. Expected reverse domain notation (e.g., com.company.widget)')
  }

  if (!m.name || typeof m.name !== 'string') {
    errors.push('Missing or invalid "name" field')
  }

  if (!m.version || typeof m.version !== 'string') {
    errors.push('Missing or invalid "version" field')
  } else if (!/^\d+\.\d+\.\d+/.test(m.version)) {
    errors.push('Invalid "version" format. Expected semver (e.g., 1.0.0)')
  }

  if (!m.main || typeof m.main !== 'string') {
    errors.push('Missing or invalid "main" field')
  }

  // Optional fields with type checking
  if (m.executionModel !== undefined &&
      !['process', 'inline', 'webworker'].includes(m.executionModel as string)) {
    errors.push('Invalid "executionModel". Expected: process, inline, or webworker')
  }

  if (m.port !== undefined && (typeof m.port !== 'number' || m.port < 1024 || m.port > 65535)) {
    errors.push('Invalid "port". Expected number between 1024 and 65535')
  }

  if (m.contributes && typeof m.contributes === 'object') {
    const contrib = m.contributes as Record<string, unknown>

    if (contrib.tools && Array.isArray(contrib.tools)) {
      contrib.tools.forEach((tool: unknown, i: number) => {
        const t = tool as Record<string, unknown>
        if (!t.name || typeof t.name !== 'string') {
          errors.push(`contributes.tools[${i}]: Missing or invalid "name"`)
        }
        if (!t.description || typeof t.description !== 'string') {
          errors.push(`contributes.tools[${i}]: Missing or invalid "description"`)
        }
      })
    }
  }

  return { valid: errors.length === 0, errors }
}

// Discovery class
export class WidgetDiscovery {
  private cache: Map<string, DiscoveredWidget> = new Map()
  private lastScanTime = 0
  private cacheTTL = 30000 // 30 seconds

  // Scan for widgets in all sources
  async discoverWidgets(forceRefresh = false): Promise<DiscoveredWidget[]> {
    // Return cached results if recent
    if (!forceRefresh && Date.now() - this.lastScanTime < this.cacheTTL) {
      return Array.from(this.cache.values())
    }

    console.log('[WidgetDiscovery] Scanning for widgets...')
    const widgets: DiscoveredWidget[] = []

    // 1. Scan built-in widgets (bundled with app)
    try {
      const builtinWidgets = await this.scanDirectory('src/widgets-external', 'builtin')
      widgets.push(...builtinWidgets)
    } catch (err) {
      console.warn('[WidgetDiscovery] Failed to scan builtin widgets:', err)
    }

    // 2. Scan user widgets (in app data directory)
    try {
      const userWidgetsPath = await join(await appDataDir(), 'widgets')
      const userWidgets = await this.scanDirectory(userWidgetsPath, 'user')
      widgets.push(...userWidgets)
    } catch (err) {
      console.warn('[WidgetDiscovery] Failed to scan user widgets:', err)
    }

    // Update cache
    this.cache.clear()
    widgets.forEach((w) => this.cache.set(w.manifest.id, w))
    this.lastScanTime = Date.now()

    console.log(`[WidgetDiscovery] Found ${widgets.length} widgets`)
    return widgets
  }

  // Get a specific widget
  async getWidget(widgetId: string): Promise<DiscoveredWidget | undefined> {
    // Ensure cache is populated
    if (this.cache.size === 0) {
      await this.discoverWidgets()
    }
    return this.cache.get(widgetId)
  }

  // Get only valid widgets
  async getValidWidgets(): Promise<DiscoveredWidget[]> {
    const widgets = await this.discoverWidgets()
    return widgets.filter((w) => w.isValid)
  }

  // Get widgets by execution model
  async getWidgetsByExecutionModel(model: 'process' | 'inline' | 'webworker'): Promise<DiscoveredWidget[]> {
    const widgets = await this.getValidWidgets()
    return widgets.filter((w) => w.manifest.executionModel === model)
  }

  // Scan a directory for widget packages (.infinitty directories)
  private async scanDirectory(
    basePath: string,
    source: 'builtin' | 'user' | 'external'
  ): Promise<DiscoveredWidget[]> {
    const widgets: DiscoveredWidget[] = []

    try {
      const entries = await readDir(basePath)

      for (const entry of entries) {
        // Only scan directories ending with .infinitty
        if (entry.isDirectory && entry.name && entry.name.endsWith('.infinitty')) {
          const widgetPath = await join(basePath, entry.name)
          const manifestPath = await join(widgetPath, 'manifest.json')

          try {
            const manifestContent = await readTextFile(manifestPath)
            const manifestData = JSON.parse(manifestContent)

            // Validate manifest
            const { valid, errors } = validateManifest(manifestData)

            // Convert to WidgetManifest type
            const manifest: WidgetManifest = {
              id: manifestData.id,
              name: manifestData.name,
              version: manifestData.version,
              description: manifestData.description,
              main: manifestData.main,
              ui: manifestData.ui,
              extensionPath: widgetPath,
              executionModel: manifestData.executionModel || 'process',
              port: manifestData.port,
              activationEvents: manifestData.activationEvents,
              contributes: manifestData.contributes,
            }

            widgets.push({
              manifest,
              path: widgetPath,
              source,
              isValid: valid,
              validationErrors: errors,
            })

            if (!valid) {
              console.warn(`[WidgetDiscovery] Invalid manifest for ${entry.name}:`, errors)
            }
          } catch (err) {
            // No manifest or invalid JSON - skip silently
            console.debug(`[WidgetDiscovery] Skipping ${entry.name}: no valid manifest`)
          }
        }
      }
    } catch (err) {
      // Directory doesn't exist or can't be read
      console.debug(`[WidgetDiscovery] Cannot read directory: ${basePath}`)
    }

    return widgets
  }

  // Install a widget from a URL or path
  async installWidget(source: string): Promise<DiscoveredWidget> {
    console.log(`[WidgetDiscovery] Installing widget from: ${source}`)

    // Determine if source is URL or local path
    const isUrl = source.startsWith('http://') || source.startsWith('https://')

    // Get user widgets directory
    const userWidgetsPath = await join(await appDataDir(), 'widgets')

    // Ensure widgets directory exists
    const dirExists = await exists(userWidgetsPath)
    if (!dirExists) {
      await mkdir(userWidgetsPath, { recursive: true })
    }

    let manifestData: ManifestSchema
    let widgetPath: string

    try {
      if (isUrl) {
        // Fetch manifest from URL (assumes source points to manifest.json or a directory)
        const manifestUrl = source.endsWith('manifest.json') ? source : `${source}/manifest.json`
        console.log(`[WidgetDiscovery] Fetching manifest from: ${manifestUrl}`)

        const response = await fetch(manifestUrl)
        if (!response.ok) {
          throw new Error(`Failed to fetch widget manifest: HTTP ${response.status}`)
        }

        const manifest = await response.json()

        // Validate manifest
        const { valid, errors } = validateManifest(manifest)
        if (!valid) {
          throw new Error(`Invalid manifest: ${errors.join(', ')}`)
        }

        manifestData = manifest as ManifestSchema
        widgetPath = await join(userWidgetsPath, manifestData.id)

        // Create widget directory
        const widgetDirExists = await exists(widgetPath)
        if (!widgetDirExists) {
          await mkdir(widgetPath, { recursive: true })
        }

        // Save manifest
        const manifestPath = await join(widgetPath, 'manifest.json')
        await writeTextFile(manifestPath, JSON.stringify(manifestData, null, 2))

        console.log(`[WidgetDiscovery] Widget manifest saved to: ${manifestPath}`)
      } else {
        // Local path - read and validate manifest
        const sourceManifestPath = await join(source, 'manifest.json')
        const manifestContent = await readTextFile(sourceManifestPath)
        const manifest = JSON.parse(manifestContent)

        // Validate manifest
        const { valid, errors } = validateManifest(manifest)
        if (!valid) {
          throw new Error(`Invalid manifest: ${errors.join(', ')}`)
        }

        manifestData = manifest as ManifestSchema
        widgetPath = await join(userWidgetsPath, manifestData.id)

        // Create widget directory
        const widgetDirExists = await exists(widgetPath)
        if (widgetDirExists) {
          // Remove existing version
          console.log(`[WidgetDiscovery] Removing existing widget version at: ${widgetPath}`)
          await remove(widgetPath, { recursive: true })
        }
        await mkdir(widgetPath, { recursive: true })

        // Copy manifest and main file(s)
        const manifestDest = await join(widgetPath, 'manifest.json')
        await writeTextFile(manifestDest, JSON.stringify(manifestData, null, 2))
        console.log(`[WidgetDiscovery] Manifest copied to: ${manifestDest}`)
      }

      // Refresh cache and return the installed widget
      console.log(`[WidgetDiscovery] Refreshing widget discovery cache`)
      await this.discoverWidgets(true)

      const installed = this.cache.get(manifestData.id)
      if (!installed) {
        throw new Error('Widget installed but not found in discovery')
      }

      console.log(`[WidgetDiscovery] Successfully installed widget: ${installed.manifest.name} (${manifestData.id})`)
      return installed
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err)
      console.error(`[WidgetDiscovery] Widget installation failed: ${errorMessage}`)
      throw new Error(`Widget installation failed: ${errorMessage}`)
    }
  }

  // Uninstall a widget
  async uninstallWidget(widgetId: string): Promise<void> {
    console.log(`[WidgetDiscovery] Uninstalling widget: ${widgetId}`)

    try {
      // Find the widget in cache
      const widget = this.cache.get(widgetId)
      if (!widget) {
        throw new Error(`Widget not found: ${widgetId}`)
      }

      // Only allow uninstalling user-installed widgets
      if (widget.source !== 'user') {
        throw new Error(`Cannot uninstall ${widget.source} widget "${widget.manifest.name}". Only user-installed widgets can be removed.`)
      }

      // Remove widget directory and all its contents
      console.log(`[WidgetDiscovery] Removing widget directory: ${widget.path}`)
      await remove(widget.path, { recursive: true })

      // Remove from cache
      this.cache.delete(widgetId)
      console.log(`[WidgetDiscovery] Removed from cache: ${widgetId}`)

      // Refresh cache to ensure consistency
      console.log(`[WidgetDiscovery] Refreshing widget discovery cache`)
      await this.discoverWidgets(true)

      console.log(`[WidgetDiscovery] Successfully uninstalled widget: ${widget.manifest.name} (${widgetId})`)
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err)
      console.error(`[WidgetDiscovery] Widget uninstallation failed: ${errorMessage}`)
      throw new Error(`Widget uninstallation failed: ${errorMessage}`)
    }
  }
}

// Singleton instance
let discovery: WidgetDiscovery | null = null

export function getWidgetDiscovery(): WidgetDiscovery {
  if (!discovery) {
    discovery = new WidgetDiscovery()
  }
  return discovery
}

// Export manifest utilities
export { validateManifest }
export type { ManifestSchema }

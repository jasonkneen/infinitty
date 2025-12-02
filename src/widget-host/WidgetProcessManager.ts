// Widget Process Manager - Spawns and manages external widget processes
import { Command } from '@tauri-apps/plugin-shell'
import type { WidgetManifest } from '../widget-sdk/types'
import { getEnvWithPath } from '../lib/shellEnv'

// Widget process state
export interface WidgetProcess {
  manifest: WidgetManifest
  pid?: number
  port: number
  status: 'starting' | 'running' | 'stopping' | 'stopped' | 'error'
  ws?: WebSocket
  error?: string
  startedAt?: number
  restartCount: number
}

// Event types
export type WidgetProcessEvent =
  | { type: 'started'; widgetId: string; port: number }
  | { type: 'stopped'; widgetId: string }
  | { type: 'error'; widgetId: string; error: string }
  | { type: 'message'; widgetId: string; data: unknown }
  | { type: 'tool_registered'; widgetId: string; toolName: string }

type EventHandler = (event: WidgetProcessEvent) => void

// Process manager class
export class WidgetProcessManager {
  private processes: Map<string, WidgetProcess> = new Map()
  private eventHandlers: Set<EventHandler> = new Set()
  private portAllocations: Set<number> = new Set()
  private basePort = 3030

  // Start a widget process
  async startWidget(manifest: WidgetManifest): Promise<WidgetProcess> {
    const widgetId = manifest.id

    // Check if already running
    if (this.processes.has(widgetId)) {
      const existing = this.processes.get(widgetId)!
      if (existing.status === 'running') {
        console.log(`[ProcessManager] Widget already running: ${widgetId}`)
        return existing
      }
    }

    // Allocate port
    const port = manifest.port || this.allocatePort()

    // Create process entry
    const process: WidgetProcess = {
      manifest,
      port,
      status: 'starting',
      restartCount: 0,
    }
    this.processes.set(widgetId, process)

    try {
      // Spawn the widget process using Tauri shell
      // The widget should be built and have an index.js entry point
      const widgetPath = manifest.extensionPath || `src/widgets-external/${widgetId}`
      const entryPoint = manifest.main || './dist/index.js'

      console.log(`[ProcessManager] Starting widget: ${widgetId} on port ${port}`)

      // Get shell environment with proper PATH for finding node
      const env = await getEnvWithPath({
        PORT: port.toString(),
        WIDGET_ID: widgetId,
      })

      // Use node or bun to run the widget
      const command = Command.create('node', [entryPoint, port.toString()], {
        cwd: widgetPath,
        env,
      })

      // Handle stdout
      command.stdout.on('data', (data) => {
        console.log(`[${widgetId}] ${data}`)
      })

      // Handle stderr
      command.stderr.on('data', (data) => {
        console.error(`[${widgetId}] ${data}`)
      })

      // Handle process close
      command.on('close', (data) => {
        console.log(`[ProcessManager] Widget process closed: ${widgetId} code=${data.code}`)
        process.status = 'stopped'
        process.ws?.close()
        this.emit({ type: 'stopped', widgetId })

        // Auto-restart if unexpected termination
        if (data.code !== 0 && process.restartCount < 3) {
          console.log(`[ProcessManager] Auto-restarting widget: ${widgetId}`)
          process.restartCount++
          setTimeout(() => this.startWidget(manifest), 1000 * process.restartCount)
        }
      })

      // Handle errors
      command.on('error', (error) => {
        console.error(`[ProcessManager] Widget error: ${widgetId}`, error)
        process.status = 'error'
        process.error = error
        this.emit({ type: 'error', widgetId, error })
      })

      // Spawn the process
      const child = await command.spawn()
      process.pid = child.pid
      process.startedAt = Date.now()

      // Wait for server to be ready and connect WebSocket
      await this.waitForServer(port)
      await this.connectWebSocket(process)

      process.status = 'running'
      this.emit({ type: 'started', widgetId, port })

      console.log(`[ProcessManager] Widget started: ${widgetId} pid=${child.pid}`)
      return process
    } catch (error) {
      process.status = 'error'
      process.error = String(error)
      this.emit({ type: 'error', widgetId, error: String(error) })
      throw error
    }
  }

  // Stop a widget process
  async stopWidget(widgetId: string): Promise<void> {
    const process = this.processes.get(widgetId)
    if (!process) {
      console.log(`[ProcessManager] Widget not found: ${widgetId}`)
      return
    }

    console.log(`[ProcessManager] Stopping widget: ${widgetId}`)
    process.status = 'stopping'

    // Close WebSocket
    if (process.ws) {
      process.ws.close()
      process.ws = undefined
    }

    // Kill the process
    if (process.pid) {
      try {
        // Send SIGTERM via kill command
        await Command.create('kill', [process.pid.toString()]).execute()
      } catch (err) {
        console.error(`[ProcessManager] Failed to kill process: ${widgetId}`, err)
      }
    }

    // Release port
    this.portAllocations.delete(process.port)
    process.status = 'stopped'
    this.emit({ type: 'stopped', widgetId })
  }

  // Stop all widget processes
  async stopAll(): Promise<void> {
    const widgets = Array.from(this.processes.keys())
    await Promise.all(widgets.map((id) => this.stopWidget(id)))
  }

  // Get process info
  getProcess(widgetId: string): WidgetProcess | undefined {
    return this.processes.get(widgetId)
  }

  // Get all processes
  getAllProcesses(): WidgetProcess[] {
    return Array.from(this.processes.values())
  }

  // Send message to widget via WebSocket
  sendMessage(widgetId: string, message: unknown): void {
    const process = this.processes.get(widgetId)
    if (!process?.ws || process.ws.readyState !== WebSocket.OPEN) {
      console.warn(`[ProcessManager] Cannot send message, WebSocket not connected: ${widgetId}`)
      return
    }

    process.ws.send(JSON.stringify(message))
  }

  // Call a tool on a widget (via MCP over HTTP)
  async callTool(widgetId: string, toolName: string, args: Record<string, unknown>): Promise<unknown> {
    const process = this.processes.get(widgetId)
    if (!process || process.status !== 'running') {
      throw new Error(`Widget not running: ${widgetId}`)
    }

    // Call tool via MCP HTTP endpoint
    const response = await fetch(`http://localhost:${process.port}/mcp`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: Date.now(),
        method: 'tools/call',
        params: {
          name: toolName,
          arguments: args,
        },
      }),
    })

    if (!response.ok) {
      throw new Error(`MCP call failed: ${response.statusText}`)
    }

    const result = await response.json()
    if (result.error) {
      throw new Error(result.error.message || 'Tool call failed')
    }

    return result.result
  }

  // List tools from a widget (via MCP)
  async listTools(widgetId: string): Promise<Array<{ name: string; description: string }>> {
    const process = this.processes.get(widgetId)
    if (!process || process.status !== 'running') {
      throw new Error(`Widget not running: ${widgetId}`)
    }

    const response = await fetch(`http://localhost:${process.port}/mcp`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: Date.now(),
        method: 'tools/list',
        params: {},
      }),
    })

    if (!response.ok) {
      throw new Error(`MCP call failed: ${response.statusText}`)
    }

    const result = await response.json()
    return result.result?.tools || []
  }

  // Subscribe to events
  on(handler: EventHandler): () => void {
    this.eventHandlers.add(handler)
    return () => this.eventHandlers.delete(handler)
  }

  // Emit event to handlers
  private emit(event: WidgetProcessEvent): void {
    this.eventHandlers.forEach((handler) => {
      try {
        handler(event)
      } catch (err) {
        console.error('[ProcessManager] Event handler error:', err)
      }
    })
  }

  // Allocate next available port
  private allocatePort(): number {
    let port = this.basePort
    while (this.portAllocations.has(port)) {
      port++
    }
    this.portAllocations.add(port)
    return port
  }

  // Wait for server to be ready
  private async waitForServer(port: number, timeout = 10000): Promise<void> {
    const start = Date.now()
    while (Date.now() - start < timeout) {
      try {
        const response = await fetch(`http://localhost:${port}/`)
        if (response.ok) {
          return
        }
      } catch {
        // Server not ready yet
      }
      await new Promise((resolve) => setTimeout(resolve, 200))
    }
    throw new Error(`Server did not start within ${timeout}ms`)
  }

  // Connect WebSocket to widget
  private async connectWebSocket(process: WidgetProcess): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://localhost:${process.port}/ws`)
      const timeout = setTimeout(() => {
        ws.close()
        reject(new Error('WebSocket connection timeout'))
      }, 5000)

      ws.onopen = () => {
        clearTimeout(timeout)
        process.ws = ws
        console.log(`[ProcessManager] WebSocket connected: ${process.manifest.id}`)
        resolve()
      }

      ws.onerror = (error) => {
        clearTimeout(timeout)
        reject(error)
      }

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data)
          this.emit({ type: 'message', widgetId: process.manifest.id, data })
        } catch (err) {
          console.error('[ProcessManager] Failed to parse WebSocket message:', err)
        }
      }

      ws.onclose = () => {
        if (process.status === 'running') {
          console.log(`[ProcessManager] WebSocket disconnected: ${process.manifest.id}`)
          // Try to reconnect
          setTimeout(() => {
            if (process.status === 'running') {
              this.connectWebSocket(process).catch(console.error)
            }
          }, 1000)
        }
      }
    })
  }
}

// Singleton instance
let processManager: WidgetProcessManager | null = null

export function getWidgetProcessManager(): WidgetProcessManager {
  if (!processManager) {
    processManager = new WidgetProcessManager()
  }
  return processManager
}

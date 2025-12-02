// Widget SDK Types - Core interfaces for widget development
import type { z } from 'zod'

// ============================================
// Widget Manifest (package.json-like config)
// ============================================

export interface WidgetManifest {
  // Identity
  id: string                    // Unique identifier, e.g., 'com.example.chart-widget'
  name: string                  // Display name
  version: string               // Semver
  description?: string
  author?: string | { name: string; email?: string; url?: string }
  license?: string
  icon?: string                 // URL or data URI

  // Entry points
  main: string                  // Main entry file (compiled JS)
  ui?: string                   // UI component entry (for process widgets)
  styles?: string               // Optional CSS file

  // Execution model (for process-based widgets)
  executionModel?: 'inline' | 'process' | 'webworker'
  port?: number                 // Default port for process-based widgets
  extensionPath?: string        // Path to widget directory (set by discovery)

  // Capabilities
  activationEvents?: ActivationEvent[]
  contributes?: {
    tools?: ToolContribution[]
    commands?: CommandContribution[]
    configuration?: ConfigurationContribution
    menus?: MenuContribution[]
  }

  // Requirements
  engines?: {
    'infinitty': string   // Required host version
  }
  dependencies?: Record<string, string>
}

export type ActivationEvent =
  | 'onStartup'                 // Activate immediately
  | `onCommand:${string}`       // Activate when command is invoked
  | `onWidget:${string}`        // Activate when widget type is opened
  | `onEvent:${string}`         // Activate on custom event

export interface ToolContribution {
  name: string
  description: string
  inputSchema: Record<string, unknown>  // JSON Schema
}

export interface CommandContribution {
  id: string
  title: string
  category?: string
  icon?: string
  shortcut?: string
}

export interface ConfigurationContribution {
  title: string
  properties: Record<string, ConfigPropertySchema>
}

export interface ConfigPropertySchema {
  type: 'string' | 'number' | 'boolean' | 'array' | 'object'
  default?: unknown
  description?: string
  enum?: unknown[]
  enumDescriptions?: string[]
  minimum?: number
  maximum?: number
}

export interface MenuContribution {
  command: string
  group?: string
  when?: string  // Context expression
}

// ============================================
// Widget Lifecycle & Context
// ============================================

export interface WidgetContext {
  // Widget identity
  widgetId: string
  widgetType: string
  instanceId: string

  // Configuration
  config: Record<string, unknown>
  getConfig<T>(key: string, defaultValue?: T): T | undefined

  // Theme access
  theme: ThemeColors
  onThemeChange(callback: (theme: ThemeColors) => void): Disposable

  // Storage (persisted per widget instance)
  storage: WidgetStorage

  // Global state (shared across all instances of this widget type)
  globalState: WidgetStorage

  // Secrets storage (encrypted)
  secrets: SecretsStorage

  // Logging
  log: WidgetLogger

  // Extension context
  extensionPath: string
  extensionUri: string
}

export interface ThemeColors {
  background: string
  foreground: string
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
  cursor: string
  cursorAccent: string
  selection: string
  selectionBackground: string
}

export interface WidgetStorage {
  get<T>(key: string, defaultValue?: T): T | undefined
  set(key: string, value: unknown): Promise<void>
  delete(key: string): Promise<void>
  keys(): string[]
}

export interface SecretsStorage {
  get(key: string): Promise<string | undefined>
  store(key: string, value: string): Promise<void>
  delete(key: string): Promise<void>
}

export interface WidgetLogger {
  trace(message: string, ...args: unknown[]): void
  debug(message: string, ...args: unknown[]): void
  info(message: string, ...args: unknown[]): void
  warn(message: string, ...args: unknown[]): void
  error(message: string, ...args: unknown[]): void
}

export interface Disposable {
  dispose(): void
}

// ============================================
// Event System
// ============================================

export interface EventEmitter<T> {
  event: Event<T>
  fire(data: T): void
  dispose(): void
}

export type Event<T> = (listener: (e: T) => void) => Disposable

export interface WidgetEvents {
  // Lifecycle events
  onDidActivate: Event<void>
  onWillDeactivate: Event<void>

  // UI events
  onDidResize: Event<{ width: number; height: number }>
  onDidChangeVisibility: Event<boolean>
  onDidFocus: Event<void>
  onDidBlur: Event<void>

  // Data events
  onDidReceiveMessage: Event<unknown>
  onDidChangeConfig: Event<Record<string, unknown>>
}

// ============================================
// Host API (provided by Infinitty)
// ============================================

export interface WidgetHostAPI {
  // UI
  showMessage(message: string, type?: 'info' | 'warning' | 'error'): void
  showQuickPick<T extends QuickPickItem>(items: T[], options?: QuickPickOptions): Promise<T | undefined>
  showInputBox(options?: InputBoxOptions): Promise<string | undefined>
  showProgress<T>(task: (progress: Progress) => Promise<T>, options?: ProgressOptions): Promise<T>

  // Commands
  executeCommand(commandId: string, ...args: unknown[]): Promise<unknown>
  registerCommand(id: string, handler: (...args: unknown[]) => unknown): Disposable

  // Tools (AI/MCP integration)
  registerTool(tool: ToolDefinition): Disposable
  callTool(name: string, args: Record<string, unknown>): Promise<unknown>

  // Clipboard
  readClipboard(): Promise<string>
  writeClipboard(text: string): Promise<void>

  // File system (sandboxed)
  readFile(path: string): Promise<Uint8Array>
  writeFile(path: string, content: Uint8Array): Promise<void>
  showOpenDialog(options?: OpenDialogOptions): Promise<string[] | undefined>
  showSaveDialog(options?: SaveDialogOptions): Promise<string | undefined>

  // Terminal integration
  createTerminal(options?: TerminalOptions): TerminalInstance
  sendToActiveTerminal(text: string): void

  // Tab/Pane management
  openWidget(widgetType: string, config?: Record<string, unknown>): Promise<string>
  openWebView(url: string, title?: string): Promise<string>
  closePane(paneId: string): void

  // Inter-widget communication
  postMessage(targetWidgetId: string, message: unknown): void
  broadcast(channel: string, message: unknown): void
  subscribe(channel: string, handler: (message: unknown) => void): Disposable
}

export interface QuickPickItem {
  label: string
  description?: string
  detail?: string
  picked?: boolean
  alwaysShow?: boolean
}

export interface QuickPickOptions {
  title?: string
  placeholder?: string
  canPickMany?: boolean
  matchOnDescription?: boolean
  matchOnDetail?: boolean
}

export interface InputBoxOptions {
  title?: string
  placeholder?: string
  value?: string
  password?: boolean
  validateInput?(value: string): string | undefined
}

export interface Progress {
  report(value: { message?: string; increment?: number }): void
}

export interface ProgressOptions {
  title: string
  cancellable?: boolean
}

export interface ToolDefinition {
  name: string
  description: string
  inputSchema: Record<string, unknown> | z.ZodType
  handler: (args: Record<string, unknown>) => Promise<unknown>
}

export interface OpenDialogOptions {
  title?: string
  defaultPath?: string
  filters?: { name: string; extensions: string[] }[]
  canSelectFiles?: boolean
  canSelectFolders?: boolean
  canSelectMany?: boolean
}

export interface SaveDialogOptions {
  title?: string
  defaultPath?: string
  filters?: { name: string; extensions: string[] }[]
}

export interface TerminalOptions {
  name?: string
  cwd?: string
  env?: Record<string, string>
  shellPath?: string
  shellArgs?: string[]
}

export interface TerminalInstance {
  id: string
  name: string
  sendText(text: string, addNewLine?: boolean): void
  show(preserveFocus?: boolean): void
  hide(): void
  dispose(): void
}

// ============================================
// Widget Entry Point
// ============================================

export interface WidgetModule {
  // Called when widget is activated
  activate(context: WidgetContext, api: WidgetHostAPI, events: WidgetEvents): void | Promise<void>

  // Called when widget is deactivated
  deactivate?(): void | Promise<void>

  // React component to render (optional - can also use vanilla JS)
  Component?: React.ComponentType<WidgetComponentProps>
}

export interface WidgetComponentProps {
  context: WidgetContext
  api: WidgetHostAPI
  events: WidgetEvents
}

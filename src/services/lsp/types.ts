/**
 * LSP Types
 * Core type definitions for the LSP client
 */

/**
 * LSP Diagnostic severity levels
 */
export enum DiagnosticSeverity {
  Error = 1,
  Warning = 2,
  Information = 3,
  Hint = 4,
}

/**
 * Position in a text document (0-indexed)
 */
export interface Position {
  line: number
  character: number
}

/**
 * Range in a text document
 */
export interface Range {
  start: Position
  end: Position
}

/**
 * LSP Diagnostic
 */
export interface Diagnostic {
  range: Range
  severity?: DiagnosticSeverity
  code?: string | number
  source?: string
  message: string
  relatedInformation?: DiagnosticRelatedInformation[]
  tags?: number[]
}

/**
 * Related information for a diagnostic
 */
export interface DiagnosticRelatedInformation {
  location: {
    uri: string
    range: Range
  }
  message: string
}

/**
 * Hover result
 */
export interface Hover {
  contents: MarkupContent | string
  range?: Range
}

/**
 * Markup content (markdown or plaintext)
 */
export interface MarkupContent {
  kind: 'plaintext' | 'markdown'
  value: string
}

/**
 * Completion item kinds (LSP standard)
 */
export enum CompletionItemKind {
  Text = 1,
  Method = 2,
  Function = 3,
  Constructor = 4,
  Field = 5,
  Variable = 6,
  Class = 7,
  Interface = 8,
  Module = 9,
  Property = 10,
  Unit = 11,
  Value = 12,
  Enum = 13,
  Keyword = 14,
  Snippet = 15,
  Color = 16,
  File = 17,
  Reference = 18,
  Folder = 19,
  EnumMember = 20,
  Constant = 21,
  Struct = 22,
  Event = 23,
  Operator = 24,
  TypeParameter = 25,
}

/**
 * Completion item
 */
export interface CompletionItem {
  label: string
  kind?: CompletionItemKind
  detail?: string
  documentation?: string | MarkupContent
  insertText?: string
  insertTextFormat?: number
  textEdit?: TextEdit
  additionalTextEdits?: TextEdit[]
  sortText?: string
  filterText?: string
  preselect?: boolean
}

/**
 * Text edit
 */
export interface TextEdit {
  range: Range
  newText: string
}

/**
 * Location (file + range)
 */
export interface Location {
  uri: string
  range: Range
}

/**
 * Server status for UI display
 */
export interface ServerStatus {
  id: string
  name: string
  extensions: string[]
  enabled: boolean
  installed: boolean
  installable: boolean
  running: boolean
  instances: ServerInstance[]
}

/**
 * Running server instance info
 */
export interface ServerInstance {
  root: string
  openDocuments: number
  diagnosticCount: number
}

/**
 * Cache info for UI display
 */
export interface CacheInfo {
  path: string
  size: number
  version: string
  packages: string[]
}

/**
 * Diagnostics event
 */
export interface DiagnosticsEvent {
  path: string
  diagnostics: Diagnostic[]
}

/**
 * LSP Event types
 */
export type LSPEvent =
  | { type: 'diagnostics'; path: string; diagnostics: Diagnostic[] }
  | { type: 'server-started'; serverId: string; root: string }
  | { type: 'server-closed'; serverId: string; root: string }
  | { type: 'server-status-changed'; serverId: string; enabled: boolean }

/**
 * Result wrapper for API calls
 */
export interface LSPResult<T> {
  success: boolean
  data?: T
  error?: string
}

// Tab and Split Pane Types for Infinitty

export type SplitDirection = 'horizontal' | 'vertical'

export type TerminalViewMode = 'classic' | 'blocks'

export interface TerminalPane {
  id: string
  type: 'terminal'
  title: string
  cwd?: string
  isActive: boolean
  viewMode?: TerminalViewMode // 'classic' (scrolling) or 'blocks' (Warp-style)
}

export interface WebViewPane {
  id: string
  type: 'webview'
  title: string
  url: string
  isActive: boolean
}

export interface WidgetPane {
  id: string
  type: 'widget'
  title: string
  widgetType: string // e.g., 'nodes', 'chart', 'markdown', etc.
  config?: Record<string, unknown> // Widget-specific configuration
  isActive: boolean
}

export interface EditorPane {
  id: string
  type: 'editor'
  title: string
  filePath: string
  language?: string // e.g., 'typescript', 'javascript', 'python', etc.
  isReadOnly?: boolean
  isActive: boolean
}

export interface SplitPane {
  id: string
  type: 'split'
  direction: SplitDirection
  ratio: number // 0-1, position of the divider
  first: PaneNode
  second: PaneNode
}

export type PaneNode = TerminalPane | WebViewPane | WidgetPane | EditorPane | SplitPane

// Available icons for pinned tabs
export type PinnedTabIcon = 'pin' | 'terminal' | 'code' | 'file' | 'folder' | 'star' | 'heart' | 'bookmark' | 'home' | 'settings' | 'globe' | 'zap'

// Available colors for pinned tabs
export type PinnedTabColor = 'cyan' | 'green' | 'yellow' | 'orange' | 'red' | 'magenta' | 'blue' | 'white'

// Tab colors (shared between pinned and non-pinned tabs)
export type TabColor = 'cyan' | 'green' | 'yellow' | 'orange' | 'red' | 'magenta' | 'blue' | 'white'

export interface Tab {
  id: string
  title: string
  root: PaneNode
  isActive: boolean
  order: number
  isPinned: boolean
  pinIcon?: PinnedTabIcon
  pinColor?: PinnedTabColor           // Icon/text foreground color (pinned tabs)
  pinBackgroundColor?: PinnedTabColor // Background color (pinned tabs)
  tabColor?: TabColor                 // Dot/text color (non-pinned tabs)
  tabBackgroundColor?: TabColor       // Background color (non-pinned tabs)
  resourcePath?: string               // File path, URL, or resource identifier for color persistence
}

export interface TabDragData {
  tabId: string
  sourceWindowId?: string
}

export interface SplitAction {
  type: 'split-left' | 'split-right' | 'split-top' | 'split-bottom'
  paneId: string
}

// Helper functions
export function isTerminalPane(node: PaneNode): node is TerminalPane {
  return node.type === 'terminal'
}

export function isWebViewPane(node: PaneNode): node is WebViewPane {
  return node.type === 'webview'
}

export function isWidgetPane(node: PaneNode): node is WidgetPane {
  return node.type === 'widget'
}

export function isEditorPane(node: PaneNode): node is EditorPane {
  return node.type === 'editor'
}

export function isSplitPane(node: PaneNode): node is SplitPane {
  return node.type === 'split'
}

export function isContentPane(node: PaneNode): node is TerminalPane | WebViewPane | WidgetPane | EditorPane {
  return node.type === 'terminal' || node.type === 'webview' || node.type === 'widget' || node.type === 'editor'
}

export function createTerminalPane(id: string, title: string, cwd?: string, viewMode?: TerminalViewMode): TerminalPane {
  return {
    id,
    type: 'terminal',
    title,
    cwd,
    viewMode: viewMode ?? 'classic',
    isActive: true,
  }
}

export function createWebViewPane(id: string, title: string, url: string): WebViewPane {
  return {
    id,
    type: 'webview',
    title,
    url,
    isActive: true,
  }
}

export function createWidgetPane(
  id: string,
  title: string,
  widgetType: string,
  config?: Record<string, unknown>
): WidgetPane {
  return {
    id,
    type: 'widget',
    title,
    widgetType,
    config,
    isActive: true,
  }
}

export function createEditorPane(
  id: string,
  title: string,
  filePath: string,
  language?: string,
  isReadOnly?: boolean
): EditorPane {
  return {
    id,
    type: 'editor',
    title,
    filePath,
    language,
    isReadOnly,
    isActive: true,
  }
}

export function createSplitPane(
  id: string,
  direction: SplitDirection,
  first: PaneNode,
  second: PaneNode,
  ratio = 0.5,
): SplitPane {
  return {
    id,
    type: 'split',
    direction,
    ratio,
    first,
    second,
  }
}

export function createTab(id: string, title: string, cwd?: string): Tab {
  return {
    id,
    title,
    root: createTerminalPane(`${id}-pane-0`, title, cwd),
    isActive: true,
    order: 0,
    isPinned: false,
  }
}

// Find a pane in the tree by ID
export function findPane(node: PaneNode, paneId: string): PaneNode | null {
  if (node.id === paneId) return node
  if (isSplitPane(node)) {
    const inFirst = findPane(node.first, paneId)
    if (inFirst) return inFirst
    return findPane(node.second, paneId)
  }
  return null
}

// Get all terminal panes from a tree
export function getAllTerminalPanes(node: PaneNode): TerminalPane[] {
  if (isTerminalPane(node)) return [node]
  if (isSplitPane(node)) {
    return [...getAllTerminalPanes(node.first), ...getAllTerminalPanes(node.second)]
  }
  return []
}

// Get all content panes (terminals, webviews, widgets, and editors) from a tree
export function getAllContentPanes(node: PaneNode): (TerminalPane | WebViewPane | WidgetPane | EditorPane)[] {
  if (isContentPane(node)) return [node]
  if (isSplitPane(node)) {
    return [...getAllContentPanes(node.first), ...getAllContentPanes(node.second)]
  }
  return []
}

// Replace a pane in the tree with a new node
export function replacePane(node: PaneNode, paneId: string, newNode: PaneNode): PaneNode {
  if (node.id === paneId) return newNode
  if (isSplitPane(node)) {
    return {
      ...node,
      first: replacePane(node.first, paneId, newNode),
      second: replacePane(node.second, paneId, newNode),
    }
  }
  return node
}

// Remove a pane and collapse its parent split
export function removePane(node: PaneNode, paneId: string): PaneNode | null {
  if (node.id === paneId) return null
  if (isSplitPane(node)) {
    if (node.first.id === paneId) return node.second
    if (node.second.id === paneId) return node.first
    const newFirst = removePane(node.first, paneId)
    const newSecond = removePane(node.second, paneId)
    if (!newFirst) return newSecond
    if (!newSecond) return newFirst
    return { ...node, first: newFirst, second: newSecond }
  }
  return node
}

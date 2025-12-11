import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
import {
  type Tab,
  type PaneNode,
  type SplitDirection,
  type PinnedTabIcon,
  type PinnedTabColor,
  type TabColor,
  type TerminalViewMode,
  createTab,
  createTerminalPane,
  createWebViewPane,
  createWidgetPane,
  createEditorPane,
  createSplitPane,
  replacePane,
  removePane,
  getAllTerminalPanes,
  getAllContentPanes,
  findPane,
  isSplitPane,
  isContentPane,
  isEditorPane,
  isTerminalPane,
} from '../types/tabs'
import { destroyPersistedTerminal } from '../hooks/useTerminal'
import { destroyPersistedBlocks } from '../hooks/useBlockTerminal'
import { emitPwdChanged } from '../hooks/useFileExplorer'
import { getErrorMessage } from '../lib/utils'

// ============================================
// URL Validation for XSS Prevention
// ============================================

const ALLOWED_PROTOCOLS = ['http:', 'https:']
const BLOCKED_HOSTS = ['localhost', '127.0.0.1', '0.0.0.0', '::1']

function validateWebViewUrl(urlString: string): void {
  let url: URL
  try {
    url = new URL(urlString)
  } catch {
    throw new Error(`Invalid URL: ${urlString}`)
  }

  // Only allow http/https protocols
  if (!ALLOWED_PROTOCOLS.includes(url.protocol)) {
    throw new Error(`Blocked URL protocol: ${url.protocol}. Only http and https are allowed.`)
  }

  // Block localhost (optional but recommended for security)
  if (BLOCKED_HOSTS.includes(url.hostname)) {
    throw new Error(`Blocked URL host: ${url.hostname}. Localhost is not allowed for security reasons.`)
  }

  // Block private IP ranges (optional but recommended for security)
  const ipMatch = url.hostname.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)
  if (ipMatch) {
    const [, a, b] = ipMatch.map(Number)
    // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) {
      throw new Error(`Blocked private IP: ${url.hostname}. Private IP addresses are not allowed for security reasons.`)
    }
  }
}

// ============================================
// Session Persistence
// ============================================

const STORAGE_KEY = 'infinitty-session'

interface SerializedPane {
  type: 'terminal' | 'webview' | 'widget' | 'editor' | 'split'
  title?: string
  cwd?: string
  url?: string
  widgetType?: string
  config?: Record<string, unknown>
  filePath?: string
  language?: string
  isReadOnly?: boolean
  direction?: SplitDirection
  ratio?: number
  first?: SerializedPane
  second?: SerializedPane
}

interface SerializedTab {
  title: string
  root: SerializedPane
  isPinned: boolean
  pinIcon?: PinnedTabIcon
  pinColor?: PinnedTabColor
  pinBackgroundColor?: PinnedTabColor
  tabColor?: TabColor
  tabBackgroundColor?: TabColor
  resourcePath?: string
}

interface SerializedSession {
  version: 1
  tabs: SerializedTab[]
  activeTabIndex: number
}

function serializePane(pane: PaneNode): SerializedPane {
  switch (pane.type) {
    case 'terminal':
      return { type: 'terminal', title: pane.title, cwd: pane.cwd }
    case 'webview':
      return { type: 'webview', title: pane.title, url: pane.url }
    case 'widget':
      return { type: 'widget', title: pane.title, widgetType: pane.widgetType, config: pane.config }
    case 'editor':
      return { type: 'editor', title: pane.title, filePath: pane.filePath, language: pane.language, isReadOnly: pane.isReadOnly }
    case 'split':
      return {
        type: 'split',
        direction: pane.direction,
        ratio: pane.ratio,
        first: serializePane(pane.first),
        second: serializePane(pane.second),
      }
  }
}

function deserializePane(serialized: SerializedPane, idGenerator: () => string): PaneNode {
  switch (serialized.type) {
    case 'terminal':
      return createTerminalPane(idGenerator(), serialized.title || 'Terminal', serialized.cwd)
    case 'webview': {
      const url = serialized.url || 'about:blank'
      // Validate URL from stored session to prevent XSS from corrupted/malicious storage
      if (url !== 'about:blank') {
        try {
          validateWebViewUrl(url)
        } catch (error: unknown) {
          console.error('[Tabs] Invalid stored URL, using about:blank:', getErrorMessage(error))
          return createWebViewPane(idGenerator(), serialized.title || 'Web', 'about:blank')
        }
      }
      return createWebViewPane(idGenerator(), serialized.title || 'Web', url)
    }
    case 'widget':
      return createWidgetPane(idGenerator(), serialized.title || 'Widget', serialized.widgetType || 'unknown', serialized.config)
    case 'editor':
      return createEditorPane(idGenerator(), serialized.title || 'Editor', serialized.filePath || '', serialized.language, serialized.isReadOnly)
    case 'split':
      return createSplitPane(
        idGenerator(),
        serialized.direction || 'horizontal',
        deserializePane(serialized.first!, idGenerator),
        deserializePane(serialized.second!, idGenerator),
        serialized.ratio ?? 0.5
      )
  }
}

function saveSession(tabs: Tab[], activeTabId: string | null): void {
  try {
    const activeTabIndex = tabs.findIndex(t => t.id === activeTabId)
    const session: SerializedSession = {
      version: 1,
      tabs: tabs.map(tab => ({
        title: tab.title,
        root: serializePane(tab.root),
        isPinned: tab.isPinned,
        pinIcon: tab.pinIcon,
        pinColor: tab.pinColor,
        pinBackgroundColor: tab.pinBackgroundColor,
        tabColor: tab.tabColor,
        tabBackgroundColor: tab.tabBackgroundColor,
        resourcePath: tab.resourcePath,
      })),
      activeTabIndex: activeTabIndex >= 0 ? activeTabIndex : 0,
    }
    localStorage.setItem(STORAGE_KEY, JSON.stringify(session))
  } catch (error: unknown) {
    console.warn('[Tabs] Failed to save session:', getErrorMessage(error))
  }
}

function loadSession(tabIdGenerator: () => string, paneIdGenerator: () => string): { tabs: Tab[], activeTabId: string, activePaneId: string } | null {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (!stored) return null

    const session: SerializedSession = JSON.parse(stored)

    // Validate session structure
    if (
      session.version !== 1 ||
      !Array.isArray(session.tabs) ||
      session.tabs.length === 0 ||
      typeof session.activeTabIndex !== 'number'
    ) {
      console.warn('[Tabs] Invalid session structure, resetting')
      return null
    }

    // Validate each tab has required fields
    if (!session.tabs.every((tab) => tab.title && tab.root)) {
      console.warn('[Tabs] Found corrupted tab data, resetting')
      return null
    }

    const tabs: Tab[] = session.tabs.map((serializedTab, index) => {
      const tabId = tabIdGenerator()
      const root = deserializePane(serializedTab.root, paneIdGenerator)
      return {
        id: tabId,
        title: serializedTab.title,
        root,
        isActive: index === session.activeTabIndex,
        order: index,
        isPinned: serializedTab.isPinned ?? false,
        pinIcon: serializedTab.pinIcon,
        pinColor: serializedTab.pinColor,
        pinBackgroundColor: serializedTab.pinBackgroundColor,
        tabColor: serializedTab.tabColor,
        tabBackgroundColor: serializedTab.tabBackgroundColor,
        resourcePath: serializedTab.resourcePath,
      }
    })

    // Validate activeTabIndex is within bounds
    const activeTabIndex = Math.max(0, Math.min(session.activeTabIndex, tabs.length - 1))
    const activeTab = tabs[activeTabIndex]
    const firstPane = getAllTerminalPanes(activeTab.root)[0]

    return {
      tabs,
      activeTabId: activeTab.id,
      activePaneId: firstPane?.id || activeTab.root.id,
    }
  } catch (error: unknown) {
    console.warn('[Tabs] Failed to load session:', getErrorMessage(error))
    return null
  }
}

interface TabsContextValue {
  tabs: Tab[]
  activeTabId: string | null
  activePaneId: string | null

  // Tab operations
  createNewTab: (title?: string, cwd?: string) => Tab
  createWebViewTab: (url: string, title?: string) => Tab
  createWidgetTab: (widgetType: string, title?: string, config?: Record<string, unknown>) => Tab
  createEditorTab: (filePath: string, title?: string, isReadOnly?: boolean) => Tab
  closeTab: (tabId: string) => void
  setActiveTab: (tabId: string) => void
  reorderTabs: (fromIndex: number, toIndex: number) => void
  updateTabTitle: (tabId: string, title: string) => void
  pinTab: (tabId: string) => void
  unpinTab: (tabId: string) => void
  togglePinTab: (tabId: string) => void
  updatePinnedTabStyle: (tabId: string, icon?: PinnedTabIcon, color?: PinnedTabColor, backgroundColor?: PinnedTabColor) => void
  updateTabStyle: (tabId: string, color?: TabColor, backgroundColor?: TabColor) => void

  // Pane operations
  splitPane: (paneId: string, direction: SplitDirection) => void
  splitPaneWithWebview: (paneId: string, direction: SplitDirection, url: string, title?: string) => void
  closePane: (paneId: string) => void
  setActivePane: (paneId: string) => void
  resizeSplit: (splitId: string, ratio: number) => void
  updateTerminalViewMode: (paneId: string, viewMode: TerminalViewMode) => void

  // Get current state
  getActiveTab: () => Tab | null
  getActivePane: () => PaneNode | null
}

const TabsContext = createContext<TabsContextValue | null>(null)

let tabCounter = 0
let paneCounter = 0

function generateTabId(): string {
  return `tab-${++tabCounter}-${Date.now()}`
}

function generatePaneId(): string {
  return `pane-${++paneCounter}-${Date.now()}`
}

export function TabsProvider({ children }: { children: ReactNode }) {
  // Initialize all state together to avoid closure issues
  const [state] = useState(() => {
    // Try to restore from saved session
    const restored = loadSession(generateTabId, generatePaneId)
    if (restored) {
      console.log('[Tabs] Restored session with', restored.tabs.length, 'tabs')
      return {
        initialTabs: restored.tabs,
        initialActiveTabId: restored.activeTabId,
        initialActivePaneId: restored.activePaneId,
      }
    }

    // Create fresh session
    const initialTab = createTab(generateTabId(), 'Terminal 1')
    const firstPane = getAllTerminalPanes(initialTab.root)[0]
    return {
      initialTabs: [initialTab],
      initialActiveTabId: initialTab.id,
      initialActivePaneId: firstPane?.id ?? null,
    }
  })

  const [tabs, setTabs] = useState<Tab[]>(state.initialTabs)
  const [activeTabId, setActiveTabId] = useState<string | null>(state.initialActiveTabId)
  const [activePaneId, setActivePaneId] = useState<string | null>(state.initialActivePaneId)

  // Save session immediately whenever tabs or activeTabId changes
  // localStorage is synchronous and atomic, so we save immediately to avoid data loss
  useEffect(() => {
    try {
      saveSession(tabs, activeTabId)
    } catch (error: unknown) {
      console.error('[Tabs] Failed to save session:', getErrorMessage(error))
    }
  }, [tabs, activeTabId])

  const createNewTab = useCallback((title?: string, cwd?: string): Tab => {
    const newTab = createTab(
      generateTabId(),
      title ?? `Terminal ${tabs.length + 1}`,
      cwd
    )
    newTab.order = tabs.length
    setTabs((prev) => [...prev.map(t => ({ ...t, isActive: false })), { ...newTab, isActive: true }])
    setActiveTabId(newTab.id)
    const firstPane = getAllTerminalPanes(newTab.root)[0]
    if (firstPane) setActivePaneId(firstPane.id)
    return newTab
  }, [tabs.length])

  const createWebViewTab = useCallback((url: string, title?: string): Tab => {
    // Validate URL before creating the webview
    validateWebViewUrl(url)

    const tabId = generateTabId()
    const paneId = generatePaneId()
    const webViewPane = createWebViewPane(paneId, title ?? 'Web', url)
    const newTab: Tab = {
      id: tabId,
      title: title ?? new URL(url).hostname,
      root: webViewPane,
      isActive: true,
      order: tabs.length,
      isPinned: false,
    }
    setTabs((prev) => [...prev.map(t => ({ ...t, isActive: false })), newTab])
    setActiveTabId(newTab.id)
    setActivePaneId(paneId)
    return newTab
  }, [tabs.length])

  const createWidgetTab = useCallback((widgetType: string, title?: string, config?: Record<string, unknown>): Tab => {
    const tabId = generateTabId()
    const paneId = generatePaneId()
    const widgetPane = createWidgetPane(paneId, title ?? widgetType, widgetType, config)
    const newTab: Tab = {
      id: tabId,
      title: title ?? widgetType.charAt(0).toUpperCase() + widgetType.slice(1),
      root: widgetPane,
      isActive: true,
      order: tabs.length,
      isPinned: false,
    }
    setTabs((prev) => [...prev.map(t => ({ ...t, isActive: false })), newTab])
    setActiveTabId(newTab.id)
    setActivePaneId(paneId)
    return newTab
  }, [tabs.length])

  const createEditorTab = useCallback((filePath: string, title?: string, isReadOnly?: boolean): Tab => {
    const tabId = generateTabId()
    const paneId = generatePaneId()
    const fileName = filePath.split('/').pop() || filePath
    const editorPane = createEditorPane(paneId, title ?? fileName, filePath, undefined, isReadOnly)
    const newTab: Tab = {
      id: tabId,
      title: title ?? fileName,
      root: editorPane,
      isActive: true,
      order: tabs.length,
      isPinned: false,
    }
    setTabs((prev) => [...prev.map(t => ({ ...t, isActive: false })), newTab])
    setActiveTabId(newTab.id)
    setActivePaneId(paneId)
    return newTab
  }, [tabs.length])

  const closeTab = useCallback((tabId: string) => {
    setTabs((prev) => {
      // Find the tab being closed and clean up all its terminals and blocks
      const tabToClose = prev.find((t) => t.id === tabId)
      if (tabToClose) {
        // Destroy terminals and blocks registries
        const terminalPanes = getAllTerminalPanes(tabToClose.root)
        terminalPanes.forEach((pane) => {
          destroyPersistedTerminal(pane.id)
          destroyPersistedBlocks(`blocks-${pane.id}`)
        })
      }

      const filtered = prev.filter((t) => t.id !== tabId)
      if (filtered.length === 0) {
        // Don't close the last tab, create a new one instead
        const newTab = createTab(generateTabId(), 'Terminal 1')
        setActiveTabId(newTab.id)
        const firstPane = getAllTerminalPanes(newTab.root)[0]
        if (firstPane) setActivePaneId(firstPane.id)
        return [newTab]
      }
      // If we closed the active tab, activate another
      if (tabId === activeTabId) {
        const closedIndex = prev.findIndex((t) => t.id === tabId)
        const newActiveIndex = Math.min(closedIndex, filtered.length - 1)
        const newActive = filtered[newActiveIndex]
        setActiveTabId(newActive.id)
        const firstPane = getAllTerminalPanes(newActive.root)[0]
        if (firstPane) setActivePaneId(firstPane.id)
        return filtered.map((t, i) => ({
          ...t,
          isActive: i === newActiveIndex,
          order: i,
        }))
      }
      return filtered.map((t, i) => ({ ...t, order: i }))
    })
  }, [activeTabId])

  const setActiveTab = useCallback((tabId: string) => {
    setActiveTabId(tabId)
    setTabs((prev) =>
      prev.map((t) => ({
        ...t,
        isActive: t.id === tabId,
      }))
    )
    // Also set active pane to first pane in the tab
    const tab = tabs.find((t) => t.id === tabId)
    if (tab) {
      const allPanes = getAllContentPanes(tab.root)
      const firstPane = allPanes[0]
      if (firstPane) {
        setActivePaneId(firstPane.id)
        // If it's an editor pane, broadcast the file's directory to file explorer
        if (isEditorPane(firstPane)) {
          const dir = firstPane.filePath.substring(0, firstPane.filePath.lastIndexOf('/'))
          if (dir) emitPwdChanged(dir)
        }
      }
    }
  }, [tabs])

  const reorderTabs = useCallback((fromIndex: number, toIndex: number) => {
    setTabs((prev) => {
      const newTabs = [...prev]
      const [moved] = newTabs.splice(fromIndex, 1)
      newTabs.splice(toIndex, 0, moved)
      return newTabs.map((t, i) => ({ ...t, order: i }))
    })
  }, [])

  const updateTabTitle = useCallback((tabId: string, title: string) => {
    setTabs((prev) =>
      prev.map((t) => (t.id === tabId ? { ...t, title } : t))
    )
  }, [])

  const pinTab = useCallback((tabId: string) => {
    setTabs((prev) => {
      // Move pinned tab to the front (after other pinned tabs)
      const tab = prev.find((t) => t.id === tabId)
      if (!tab || tab.isPinned) return prev

      const pinnedTabs = prev.filter((t) => t.isPinned)
      const unpinnedTabs = prev.filter((t) => !t.isPinned && t.id !== tabId)

      return [
        ...pinnedTabs,
        { ...tab, isPinned: true },
        ...unpinnedTabs,
      ].map((t, i) => ({ ...t, order: i }))
    })
  }, [])

  const unpinTab = useCallback((tabId: string) => {
    setTabs((prev) => {
      const tab = prev.find((t) => t.id === tabId)
      if (!tab || !tab.isPinned) return prev

      const pinnedTabs = prev.filter((t) => t.isPinned && t.id !== tabId)
      const unpinnedTabs = prev.filter((t) => !t.isPinned)

      return [
        ...pinnedTabs,
        { ...tab, isPinned: false },
        ...unpinnedTabs,
      ].map((t, i) => ({ ...t, order: i }))
    })
  }, [])

  const togglePinTab = useCallback((tabId: string) => {
    const tab = tabs.find((t) => t.id === tabId)
    if (tab?.isPinned) {
      unpinTab(tabId)
    } else {
      pinTab(tabId)
    }
  }, [tabs, pinTab, unpinTab])

  const updatePinnedTabStyle = useCallback((tabId: string, icon?: PinnedTabIcon, color?: PinnedTabColor, backgroundColor?: PinnedTabColor) => {
    setTabs((prev) =>
      prev.map((t) => {
        if (t.id !== tabId || !t.isPinned) return t
        return {
          ...t,
          pinIcon: icon,
          pinColor: color,
          pinBackgroundColor: backgroundColor,
        }
      })
    )
  }, [])

  const updateTabStyle = useCallback((tabId: string, color?: TabColor, backgroundColor?: TabColor) => {
    setTabs((prev) =>
      prev.map((t) => {
        if (t.id !== tabId) return t
        return {
          ...t,
          tabColor: color,
          tabBackgroundColor: backgroundColor,
        }
      })
    )
  }, [])

  const splitPane = useCallback((paneId: string, direction: SplitDirection) => {
    setTabs((prev) =>
      prev.map((tab) => {
        if (!tab.isActive) return tab

        const allPanes = getAllTerminalPanes(tab.root)
        const paneToSplit = allPanes.find((p) => p.id === paneId)
        if (!paneToSplit) return tab

        const newPane = createTerminalPane(
          generatePaneId(),
          `Terminal ${getAllTerminalPanes(tab.root).length + 1}`,
          paneToSplit.cwd
        )

        const newSplit = createSplitPane(
          generatePaneId(),
          direction,
          { ...paneToSplit, isActive: false },
          newPane,
          0.5
        )

        const newRoot = replacePane(tab.root, paneId, newSplit)
        setActivePaneId(newPane.id)

        return { ...tab, root: newRoot }
      })
    )
  }, [])

  const splitPaneWithWebview = useCallback((paneId: string, direction: SplitDirection, url: string, title?: string) => {
    // Validate URL before creating the webview
    try {
      validateWebViewUrl(url)
    } catch (err) {
      console.error('[TabsContext] Invalid URL for webview:', err)
      alert(`Cannot open webview: ${err instanceof Error ? err.message : 'Invalid URL'}`)
      return
    }

    setTabs((prev) => {
      return prev.map((tab) => {
        if (!tab.isActive) return tab

        // Find the pane to split (can be any content pane, not just terminal)
        const paneToSplit = findPane(tab.root, paneId)
        if (!paneToSplit || !isContentPane(paneToSplit)) {
          return tab
        }

        const newPane = createWebViewPane(
          generatePaneId(),
          title ?? new URL(url).hostname,
          url
        )

        const newSplit = createSplitPane(
          generatePaneId(),
          direction,
          { ...paneToSplit, isActive: false },
          newPane,
          0.5
        )

        const newRoot = replacePane(tab.root, paneId, newSplit)
        setActivePaneId(newPane.id)

        return { ...tab, root: newRoot }
      })
    })
  }, [])

  const closePane = useCallback((paneId: string) => {
    // Clean up the terminal and blocks from the registry
    destroyPersistedTerminal(paneId)
    destroyPersistedBlocks(`blocks-${paneId}`)

    setTabs((prev) =>
      prev.map((tab) => {
        if (!tab.isActive) return tab

        const allPanes = getAllTerminalPanes(tab.root)
        if (allPanes.length <= 1) {
          // Can't close the last pane, close the tab instead
          return tab
        }

        const newRoot = removePane(tab.root, paneId)
        if (!newRoot) return tab

        // If we closed the active pane, activate another
        if (paneId === activePaneId) {
          const remainingPanes = getAllTerminalPanes(newRoot)
          if (remainingPanes.length > 0) {
            setActivePaneId(remainingPanes[0].id)
          }
        }

        return { ...tab, root: newRoot }
      })
    )
  }, [activePaneId])

  // Just update the activePaneId - don't update the tree, as isActive is derived from activePaneId
  const setActivePane = useCallback((paneId: string) => {
    setActivePaneId(paneId)
  }, [])

  const resizeSplit = useCallback((splitId: string, ratio: number) => {
    setTabs((prev) =>
      prev.map((tab) => {
        if (!tab.isActive) return tab

        const updateSplitRatio = (node: PaneNode): PaneNode => {
          if (isSplitPane(node)) {
            if (node.id === splitId) {
              return { ...node, ratio: Math.max(0.1, Math.min(0.9, ratio)) }
            }
            return {
              ...node,
              first: updateSplitRatio(node.first),
              second: updateSplitRatio(node.second),
            }
          }
          return node
        }

        return { ...tab, root: updateSplitRatio(tab.root) }
      })
    )
  }, [])

  const updateTerminalViewMode = useCallback((paneId: string, viewMode: TerminalViewMode) => {
    setTabs((prev) =>
      prev.map((tab) => {
        const updateViewMode = (node: PaneNode): PaneNode => {
          if (isTerminalPane(node) && node.id === paneId) {
            return { ...node, viewMode }
          }
          if (isSplitPane(node)) {
            return {
              ...node,
              first: updateViewMode(node.first),
              second: updateViewMode(node.second),
            }
          }
          return node
        }

        return { ...tab, root: updateViewMode(tab.root) }
      })
    )
  }, [])

  const getActiveTab = useCallback((): Tab | null => {
    return tabs.find((t) => t.id === activeTabId) ?? null
  }, [tabs, activeTabId])

  const getActivePane = useCallback((): PaneNode | null => {
    const tab = getActiveTab()
    if (!tab || !activePaneId) return null
    const allPanes = getAllTerminalPanes(tab.root)
    return allPanes.find((p) => p.id === activePaneId) ?? null
  }, [getActiveTab, activePaneId])

  return (
    <TabsContext.Provider
      value={{
        tabs,
        activeTabId,
        activePaneId,
        createNewTab,
        createWebViewTab,
        createWidgetTab,
        createEditorTab,
        closeTab,
        setActiveTab,
        reorderTabs,
        updateTabTitle,
        pinTab,
        unpinTab,
        togglePinTab,
        updatePinnedTabStyle,
        updateTabStyle,
        splitPane,
        splitPaneWithWebview,
        closePane,
        setActivePane,
        resizeSplit,
        updateTerminalViewMode,
        getActiveTab,
        getActivePane,
      }}
    >
      {children}
    </TabsContext.Provider>
  )
}

export function useTabs() {
  const context = useContext(TabsContext)
  if (!context) {
    throw new Error('useTabs must be used within a TabsProvider')
  }
  return context
}

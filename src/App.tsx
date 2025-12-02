import { useState, useEffect, useCallback, useRef } from 'react'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { invoke } from '@tauri-apps/api/core'
import { type TerminalHandle } from './components/Terminal'
import { Sidebar } from './components/Sidebar'
import { CommandPalette } from './components/CommandPalette'
import { WarpInput } from './components/WarpInput'
import { BlocksView } from './components/BlocksView'
import { ErrorBoundary } from './components/ErrorBoundary'
import { SettingsDialog } from './components/SettingsDialog'
import { FontLoader } from './components/FontLoader'
import { TabBar } from './components/TabBar'
import { SplitPane } from './components/SplitPane'
import { TerminalPane } from './components/TerminalPane'
import { TerminalSettingsProvider, useTerminalSettings } from './contexts/TerminalSettingsContext'
import { TabsProvider, useTabs } from './contexts/TabsContext'
import { MCPProvider } from './contexts/MCPContext'
import { WidgetToolsProvider } from './contexts/WidgetToolsContext'
import { useBlockTerminal } from './hooks/useBlockTerminal'
import { useWindowManager } from './hooks/useWindowManager'
import { triggerWebviewCapture } from './hooks/useWebviewOverlay'
import { isGhosttyMode } from './config'
import { type TerminalPane as TerminalPaneType, getAllTerminalPanes } from './types/tabs'
import { CHANGE_TERMINAL_CWD_EVENT } from './hooks/useFileExplorer'
import { writeToTerminalByKey } from './hooks/useTerminal'

// Convert hex color to rgba with alpha
function hexToRgba(hex: string, alpha: number): string {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

function AppContent() {
  const [isSidebarOpen, setIsSidebarOpen] = useState(true)
  const [isCommandPaletteOpen, setIsCommandPaletteOpen] = useState(false)
  const [isSettingsOpen, setIsSettingsOpen] = useState(false)
  const [selectedModel, setSelectedModel] = useState('gpt-4o')
  const terminalRef = useRef<TerminalHandle>(null)
  const { settings, setFontSize } = useTerminalSettings()
  const { tabs, activePaneId, activeTabId, createNewTab, createWidgetTab, splitPane, closeTab, getActiveTab, setActiveTab } = useTabs()
  const { createNewWindow } = useWindowManager()

  const ghosttyMode = isGhosttyMode()

  // Helper to open settings - captures webview screenshots first for seamless swap
  const openSettings = useCallback(async () => {
    // Trigger capture - WebViewPanes will capture screenshot, display it, then hide webview
    triggerWebviewCapture()
    // Small delay to allow capture to complete (screenshots are async)
    await new Promise(resolve => setTimeout(resolve, 100))
    setIsSettingsOpen(true)
  }, [])

  // Helper to open command palette - captures webview screenshots first
  const openCommandPalette = useCallback(async () => {
    triggerWebviewCapture()
    await new Promise(resolve => setTimeout(resolve, 100))
    setIsCommandPaletteOpen(true)
  }, [])

  // Block-based terminal for OpenWarp mode
  const {
    blocks,
    executeCommand,
    executeAIQuery,
    clearBlocks,
    initPty,
    killPty,
    completeInteractiveBlock,
  } = useBlockTerminal()

  // Initialize PTY on mount for OpenWarp mode
  useEffect(() => {
    if (!ghosttyMode) {
      initPty()
      return () => killPty()
    }
  }, [ghosttyMode, initPty, killPty])

  const handleCommand = useCallback((command: string, isAI: boolean) => {
    if (ghosttyMode) {
      // Ghostty mode - direct to terminal
      if (terminalRef.current) {
        terminalRef.current.write(command + '\n')
      }
    } else {
      // OpenWarp mode - use blocks
      if (isAI) {
        executeAIQuery(command, selectedModel)
      } else {
        executeCommand(command)
      }
    }
  }, [ghosttyMode, executeCommand, executeAIQuery, selectedModel])

  const commands = [
    {
      id: 'toggle-sidebar',
      label: 'Toggle Sidebar',
      shortcut: 'Cmd+B',
      action: () => setIsSidebarOpen((prev) => !prev),
    },
    {
      id: 'new-tab',
      label: 'New Terminal Tab',
      shortcut: 'Cmd+T',
      action: () => createNewTab(),
    },
    {
      id: 'new-window',
      label: 'New Window',
      shortcut: 'Shift+Cmd+N',
      action: () => createNewWindow(),
    },
    {
      id: 'split-right',
      label: 'Split Pane Right',
      shortcut: 'Cmd+D',
      action: () => activePaneId && splitPane(activePaneId, 'vertical'),
    },
    {
      id: 'split-down',
      label: 'Split Pane Down',
      shortcut: 'Shift+Cmd+D',
      action: () => activePaneId && splitPane(activePaneId, 'horizontal'),
    },
    {
      id: 'nodes-widget',
      label: 'Open Nodes Widget',
      action: () => createWidgetTab('nodes', 'Nodes'),
    },
    {
      id: 'chart-widget',
      label: 'Open Chart Widget',
      action: () => createWidgetTab('chart', 'Chart'),
    },
    {
      id: 'settings',
      label: 'Open Settings',
      shortcut: 'Cmd+,',
      action: () => openSettings(),
    },
    {
      id: 'clear',
      label: 'Clear Blocks',
      shortcut: 'Cmd+K',
      action: () => ghosttyMode ? terminalRef.current?.clear() : clearBlocks(),
    },
    {
      id: 'zoom-in',
      label: 'Zoom In (Increase Font)',
      shortcut: 'Cmd+=',
      action: () => setFontSize(settings.fontSize + 1),
    },
    {
      id: 'zoom-out',
      label: 'Zoom Out (Decrease Font)',
      shortcut: 'Cmd+-',
      action: () => setFontSize(settings.fontSize - 1),
    },
    {
      id: 'zoom-reset',
      label: 'Reset Zoom',
      shortcut: 'Cmd+0',
      action: () => setFontSize(14),
    },
  ]

  // Global keyboard shortcuts
  const handleKeyDown = useCallback((e: KeyboardEvent) => {
    // Command palette
    if ((e.metaKey || e.ctrlKey) && e.key === 'p') {
      e.preventDefault()
      openCommandPalette()
    }
    // Toggle sidebar
    if ((e.metaKey || e.ctrlKey) && e.key === 'b' && !ghosttyMode) {
      e.preventDefault()
      setIsSidebarOpen((prev) => !prev)
    }
    // Clear blocks
    if ((e.metaKey || e.ctrlKey) && e.key === 'k' && !ghosttyMode) {
      e.preventDefault()
      clearBlocks()
    }
    // Settings
    if ((e.metaKey || e.ctrlKey) && e.key === ',') {
      e.preventDefault()
      openSettings()
    }
    // New tab
    if ((e.metaKey || e.ctrlKey) && e.key === 't') {
      e.preventDefault()
      createNewTab()
    }
    // New window
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'N') {
      e.preventDefault()
      createNewWindow()
    }
    // Split right
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === 'd') {
      e.preventDefault()
      if (activePaneId) splitPane(activePaneId, 'vertical')
    }
    // Split down
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'D') {
      e.preventDefault()
      if (activePaneId) splitPane(activePaneId, 'horizontal')
    }
    // Tab switching with Cmd/Ctrl+1-9
    if ((e.metaKey || e.ctrlKey) && e.key >= '1' && e.key <= '9') {
      e.preventDefault()
      const tabIndex = parseInt(e.key, 10) - 1
      if (tabIndex < tabs.length) {
        setActiveTab(tabs[tabIndex].id)
      }
    }
    // Font zoom in with Cmd+= or Cmd++
    if ((e.metaKey || e.ctrlKey) && (e.key === '=' || e.key === '+')) {
      e.preventDefault()
      setFontSize(settings.fontSize + 1)
    }
    // Font zoom out with Cmd+-
    if ((e.metaKey || e.ctrlKey) && e.key === '-') {
      e.preventDefault()
      setFontSize(settings.fontSize - 1)
    }
    // Font reset with Cmd+0
    if ((e.metaKey || e.ctrlKey) && e.key === '0') {
      e.preventDefault()
      setFontSize(14) // Default size
    }
  }, [ghosttyMode, clearBlocks, createNewTab, createNewWindow, activePaneId, splitPane, tabs, setActiveTab, settings.fontSize, setFontSize, openSettings, openCommandPalette])

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeyDown])

  // Listen for file explorer requests to change terminal CWD
  useEffect(() => {
    const handleChangeTerminalCwd = (event: CustomEvent<{ path: string }>) => {
      const path = event.detail.path
      if (!path) return

      // Find the active terminal pane and write cd command
      const tab = getActiveTab()
      if (!tab) return

      // Get all terminal panes in the active tab
      const terminalPanes = getAllTerminalPanes(tab.root)
      if (terminalPanes.length === 0) return

      // Use the active pane if it's a terminal, otherwise use the first terminal
      let targetPaneId = activePaneId
      const activePaneIsTerminal = terminalPanes.some(p => p.id === activePaneId)
      if (!activePaneIsTerminal) {
        targetPaneId = terminalPanes[0].id
      }

      if (targetPaneId) {
        // Write cd command to the terminal (clear line first, then cd)
        const cdCommand = `cd "${path}"\n`
        console.log('[App] Sending cd command to terminal:', targetPaneId, cdCommand)
        writeToTerminalByKey(targetPaneId, cdCommand)
      }
    }

    window.addEventListener(CHANGE_TERMINAL_CWD_EVENT, handleChangeTerminalCwd as EventListener)
    return () => {
      window.removeEventListener(CHANGE_TERMINAL_CWD_EVENT, handleChangeTerminalCwd as EventListener)
    }
  }, [getActiveTab, activePaneId])

  // Tauri file drop events - broadcast to widgets
  useEffect(() => {
    const setupDragDrop = async () => {
      // Tauri v2 uses webview.onDragDropEvent()
      const webview = getCurrentWebview()
      const unlisten = await webview.onDragDropEvent((event) => {
        console.log('[App] Tauri drag-drop event:', event.payload.type, event.payload)

        if (event.payload.type === 'over') {
          // Dragging over - show overlay
          window.dispatchEvent(new CustomEvent('tauri-drag-enter', {
            detail: { paths: event.payload.paths }
          }))
        } else if (event.payload.type === 'drop') {
          // Dropped - handle files
          const paths = event.payload.paths
          if (paths && paths.length > 0) {
            window.dispatchEvent(new CustomEvent('tauri-file-drop', {
              detail: { paths }
            }))
          }
          window.dispatchEvent(new CustomEvent('tauri-drag-leave'))
        } else if (event.payload.type === 'leave' || event.payload.type === 'cancel') {
          // Left or cancelled
          window.dispatchEvent(new CustomEvent('tauri-drag-leave'))
        }
      })

      return unlisten
    }

    const cleanup = setupDragDrop()
    return () => {
      cleanup.then(fn => fn())
    }
  }, [])

  // Listen for native menu events from Tauri
  useEffect(() => {
    const unlisten = listen<string>('menu-action', (event) => {
      const menuId = event.payload
      switch (menuId) {
        case 'new-tab':
          createNewTab()
          break
        case 'new-window':
          createNewWindow()
          break
        case 'close-tab':
          if (activeTabId) closeTab(activeTabId)
          break
        case 'toggle-sidebar':
          setIsSidebarOpen((prev) => !prev)
          break
        case 'zoom-in':
          setFontSize(settings.fontSize + 1)
          break
        case 'zoom-out':
          setFontSize(settings.fontSize - 1)
          break
        case 'zoom-reset':
          setFontSize(14)
          break
        case 'command-palette':
          openCommandPalette()
          break
        case 'split-right':
          if (activePaneId) splitPane(activePaneId, 'vertical')
          break
        case 'split-down':
          if (activePaneId) splitPane(activePaneId, 'horizontal')
          break
        case 'clear-terminal':
          if (ghosttyMode) {
            terminalRef.current?.clear()
          } else {
            clearBlocks()
          }
          break
        case 'settings':
          openSettings()
          break
      }
    })

    return () => {
      unlisten.then((fn) => fn())
    }
  }, [createNewTab, createNewWindow, closeTab, activeTabId, activePaneId, splitPane, settings.fontSize, setFontSize, ghosttyMode, clearBlocks, openSettings, openCommandPalette])

  // Apply native window vibrancy when transparency is enabled
  // This ensures blur persists even when window loses focus
  useEffect(() => {
    const applyVibrancy = async () => {
      try {
        if (settings.window.opacity < 100 && settings.window.blur > 0) {
          // Enable native vibrancy for consistent blur
          await invoke('set_window_vibrancy', { vibrancy: 'hudWindow' })
        } else {
          // Disable vibrancy when opacity is 100%
          await invoke('set_window_vibrancy', { vibrancy: 'none' })
        }
      } catch (e) {
        console.warn('Failed to set window vibrancy:', e)
      }
    }
    applyVibrancy()
  }, [settings.window.opacity, settings.window.blur])

  // Render a terminal pane with stable key
  const renderPane = useCallback((pane: TerminalPaneType) => {
    return <TerminalPane key={pane.id} pane={pane} />
  }, [])

  // Get active tab for rendering
  const activeTab = getActiveTab()

  // Calculate transparent background color
  const windowAlpha = settings.window.opacity / 100
  const transparentBg = hexToRgba(settings.theme.background, windowAlpha)

  // Ghostty Mode - Pure terminal with tabs and splits
  if (ghosttyMode) {
    return (
      <div
        className="h-screen w-screen flex overflow-hidden"
        style={{
          fontFamily: settings.uiFont.family,
          fontSize: `${settings.uiFontSize}px`,
          backgroundColor: transparentBg,
        }}
      >
        {/* Sidebar */}
        <Sidebar
          isOpen={isSidebarOpen}
          onToggle={() => setIsSidebarOpen((prev) => !prev)}
        />

        {/* Main content */}
        <div className="flex-1 flex flex-col min-w-0">
          {/* Tab Bar with native tab support */}
          <TabBar
            isSidebarOpen={isSidebarOpen}
            onToggleSidebar={() => setIsSidebarOpen((prev) => !prev)}
            onOpenSettings={openSettings}
          />

          {/* Terminal content with splits */}
          <div className="flex-1 overflow-hidden">
            {activeTab && (
              <SplitPane node={activeTab.root} renderPane={renderPane} />
            )}
          </div>
        </div>

        {/* Command Palette (still available) */}
        <CommandPalette
          isOpen={isCommandPaletteOpen}
          onClose={() => setIsCommandPaletteOpen(false)}
          commands={commands}
        />

        <SettingsDialog
          isOpen={isSettingsOpen}
          onClose={() => setIsSettingsOpen(false)}
        />
      </div>
    )
  }

  // OpenWarp Mode - Block-based with AI
  return (
    <div
      className="h-screen w-screen flex overflow-hidden relative"
      style={{
        fontFamily: settings.uiFont.family,
        fontSize: `${settings.uiFontSize}px`,
        backgroundColor: transparentBg,
        color: settings.theme.foreground,
      }}
    >
      {/* Background media layer - supports both image and video */}
      {settings.background.enabled && (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            zIndex: 0,
            opacity: settings.background.opacity / 100,
            filter: settings.background.blur > 0 ? `blur(${settings.background.blur}px)` : undefined,
            pointerEvents: 'none',
          }}
        >
          {settings.background.type === 'video' && settings.background.videoPath ? (
            <video
              src={settings.background.videoPath}
              autoPlay
              muted={settings.background.videoMuted}
              loop={settings.background.videoLoop}
              playsInline
              style={{
                width: '100%',
                height: '100%',
                objectFit: settings.background.position === 'tile' || settings.background.position === 'center'
                  ? 'none'
                  : (settings.background.position as 'cover' | 'contain'),
                objectPosition: 'center',
              }}
            />
          ) : settings.background.imagePath ? (
            <img
              src={settings.background.imagePath}
              alt="Background"
              style={{
                width: '100%',
                height: '100%',
                objectFit: settings.background.position === 'tile' || settings.background.position === 'center'
                  ? 'none'
                  : (settings.background.position as 'cover' | 'contain'),
                objectPosition: 'center',
              }}
            />
          ) : null}
        </div>
      )}

      {/* Content wrapper with relative z-index */}
      <div style={{ position: 'relative', zIndex: 1, display: 'flex', flex: 1, minWidth: 0 }}>
        {/* Sidebar */}
        <Sidebar
          isOpen={isSidebarOpen}
          onToggle={() => setIsSidebarOpen((prev) => !prev)}
        />

        {/* Main content area */}
        <div className="flex-1 flex flex-col min-w-0">
        {/* Tab bar */}
        <TabBar
          isSidebarOpen={isSidebarOpen}
          onToggleSidebar={() => setIsSidebarOpen((prev) => !prev)}
          onOpenSettings={openSettings}
        />

        {/* Blocks area */}
        <main className="flex-1 flex flex-col overflow-hidden">
          <div className="flex-1 relative overflow-hidden">
            <ErrorBoundary>
              <BlocksView blocks={blocks} onInteractiveExit={completeInteractiveBlock} />
            </ErrorBoundary>
          </div>

          <WarpInput
            onSubmit={handleCommand}
            onModelChange={setSelectedModel}
          />
        </main>
        </div>
      </div>

      <CommandPalette
        isOpen={isCommandPaletteOpen}
        onClose={() => setIsCommandPaletteOpen(false)}
        commands={commands}
      />

      <SettingsDialog
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
      />
    </div>
  )
}

// Wrapper component with context providers
function App() {
  return (
    <TerminalSettingsProvider>
      <TabsProvider>
        <MCPProvider>
          <WidgetToolsProvider>
            <FontLoader />
            <AppContent />
          </WidgetToolsProvider>
        </MCPProvider>
      </TabsProvider>
    </TerminalSettingsProvider>
  )
}

export default App

import { useRef, useCallback, useState, useEffect, memo, type MouseEvent } from 'react'
import { createPortal } from 'react-dom'
import { Terminal, type TerminalHandle } from './Terminal'
import { BlocksView } from './BlocksView'
import { SplitContextMenu } from './SplitPane'
import { WarpInput } from './WarpInput'
import { useTabs } from '../contexts/TabsContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { useBlockTerminal } from '../hooks/useBlockTerminal'
import type { ThinkingLevel } from '../services/claudecode'
import { type TerminalPane as TerminalPaneType, getAllContentPanes } from '../types/tabs'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { emitPwdChanged } from '../hooks/useFileExplorer'
import { isGhosttyMode } from '../config'

interface TerminalPaneProps {
  pane: TerminalPaneType
}

// Memoized to prevent re-renders when other panes change
export const TerminalPane = memo(function TerminalPane({ pane }: TerminalPaneProps) {
  const { settings } = useTerminalSettings()
  const { activePaneId, setActivePane, splitPane, splitPaneWithWebview, closePane, getActiveTab, createWebViewTab } = useTabs()
  const viewMode = pane.viewMode ?? 'classic'

  // Block terminal hook for blocks mode - use pane.id as persistKey to preserve blocks across tab switches
  const { blocks, executeCommand, executeAIQuery, completeInteractiveBlock, dismissBlock, loadOpenCodeSession, loadMoreMessages, canLoadMoreMessages } = useBlockTerminal({
    persistKey: `blocks-${pane.id}`,
    initialCwd: pane.cwd,
  })

  // Handle session selection from ConversationPicker
  const handleSessionSelect = useCallback(async (sessionId: string) => {
    console.log('[TerminalPane] Session selected:', sessionId)
    const result = await loadOpenCodeSession(sessionId)
    console.log('[TerminalPane] Loaded', result.loaded, 'of', result.total, 'blocks from session')
  }, [loadOpenCodeSession])

  // Context chip state - ghost block reference that can be locked as context
  const [pendingContextBlock, setPendingContextBlock] = useState<{ id: string; label: string; type: string } | null>(null)
  const [confirmedContextBlocks, setConfirmedContextBlocks] = useState<{ id: string; label: string; type: string }[]>([])

  // Handle single click on block - show ghost context chip
  const handleBlockClick = useCallback((blockId: string, blockType: string, label: string) => {
    // Set as pending (ghost) - only one at a time
    setPendingContextBlock({ id: blockId, label, type: blockType })
  }, [])

  // Handle double click on block - immediately lock as context
  const handleBlockDoubleClick = useCallback((blockId: string, blockType: string, label: string) => {
    // Skip if already in confirmed list
    if (confirmedContextBlocks.some(b => b.id === blockId)) return
    // Add directly to confirmed
    setConfirmedContextBlocks(prev => [...prev, { id: blockId, label, type: blockType }])
    setPendingContextBlock(null)
  }, [confirmedContextBlocks])

  const handleClearPendingContext = useCallback(() => {
    setPendingContextBlock(null)
  }, [])

  const handleConfirmContext = useCallback(() => {
    if (pendingContextBlock && !confirmedContextBlocks.some(b => b.id === pendingContextBlock.id)) {
      setConfirmedContextBlocks(prev => [...prev, pendingContextBlock])
    }
    setPendingContextBlock(null)
  }, [pendingContextBlock, confirmedContextBlocks])

  const handleRemoveConfirmedContext = useCallback((blockId: string) => {
    setConfirmedContextBlocks(prev => prev.filter(b => b.id !== blockId))
  }, [])

  // Handle WarpInput submissions
  const handleWarpSubmit = useCallback((command: string, isAI: boolean, providerId?: string, modelId?: string, _contextBlocks?: unknown, thinkingLevel?: ThinkingLevel) => {
    if (isAI) {
      executeAIQuery(command, modelId || 'auto', providerId as 'opencode' | 'anthropic' | 'openai' | 'claude-code' | 'codex' | 'cursor' | 'kilo-code' | 'local' | undefined, thinkingLevel)
    } else {
      executeCommand(command)
    }
  }, [executeCommand, executeAIQuery])

  const terminalRef = useRef<TerminalHandle>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const scrollToEndRef = useRef<(() => void) | null>(null)
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(null)

  // Scroll to end when input is focused/typed in
  const handleInputFocus = useCallback(() => {
    scrollToEndRef.current?.()
  }, [])

  const isActive = pane.id === activePaneId

  // Handle link clicks based on settings
  const handleLinkClick = useCallback((url: string) => {
    const behavior = settings.behavior.linkClickBehavior
    if (behavior === 'webview') {
      // Open in a new webview tab
      try {
        const hostname = new URL(url).hostname
        createWebViewTab(url, hostname)
      } catch {
        // Invalid URL, fall back to browser
        window.open(url, '_blank')
      }
    } else if (behavior === 'browser') {
      // Open in system browser
      window.open(url, '_blank')
    }
    // 'disabled' - do nothing
  }, [settings.behavior.linkClickBehavior, createWebViewTab])

  // Handle file path clicks (cmd+click on paths)
  const handleFilePathClick = useCallback((path: string) => {
    // Emit event to file explorer to navigate to this path
    // The file explorer will check if it's a file or directory
    if (!isGhosttyMode()) {
      emitPwdChanged(path)
    }
  }, [])

  // Handle pwd changes from terminal (OSC 7 sequences)
  const handlePwdChange = useCallback((path: string) => {
    if (!isGhosttyMode()) {
      emitPwdChanged(path)
    }
  }, [])

  // Listen for native menu events
  useEffect(() => {
    if (!settings.window.nativeContextMenus) return

    const unlisten = listen('menu', (event: { payload: { id: string } }) => {
      const menuId = event.payload?.id || ''
      if (menuId.startsWith('split-right:') && menuId.endsWith(pane.id)) {
        splitPane(pane.id, 'vertical')
      } else if (menuId.startsWith('split-down:') && menuId.endsWith(pane.id)) {
        splitPane(pane.id, 'horizontal')
      } else if (menuId.startsWith('close-pane:') && menuId.endsWith(pane.id)) {
        closePane(pane.id)
      }
    })

    return () => {
      unlisten.then(fn => fn())
    }
  }, [pane.id, splitPane, closePane, settings.window.nativeContextMenus])

  // Activate pane on focus (terminal captures focus on click)
  const handleFocus = useCallback(() => {
    if (!isActive) {
      setActivePane(pane.id)
    }
  }, [pane.id, isActive, setActivePane])

  // Only show context menu, don't set state unnecessarily
  const handleContextMenu = useCallback(async (e: MouseEvent) => {
    e.preventDefault()

    const tab = getActiveTab()
    const canClosePane = tab ? getAllContentPanes(tab.root).length > 1 : false

    // Use native context menu if enabled
    if (settings.window.nativeContextMenus) {
      try {
        await invoke('show_split_context_menu', {
          x: e.clientX,
          y: e.clientY,
          paneId: pane.id,
          canClose: canClosePane,
        })
      } catch (err) {
        console.error('Failed to show native context menu:', err)
        // Fall back to custom menu
        setContextMenu({ x: e.clientX, y: e.clientY })
      }
    } else {
      // Use custom context menu
      setContextMenu({ x: e.clientX, y: e.clientY })
    }
  }, [settings.window.nativeContextMenus, pane.id, getActiveTab])

  const handleCloseContextMenu = useCallback(() => {
    setContextMenu(null)
  }, [])

  const handleSplitLeft = useCallback(() => {
    splitPane(pane.id, 'vertical')
    handleCloseContextMenu()
  }, [pane.id, splitPane, handleCloseContextMenu])

  const handleSplitRight = useCallback(() => {
    splitPane(pane.id, 'vertical')
    handleCloseContextMenu()
  }, [pane.id, splitPane, handleCloseContextMenu])

  const handleSplitTop = useCallback(() => {
    splitPane(pane.id, 'horizontal')
    handleCloseContextMenu()
  }, [pane.id, splitPane, handleCloseContextMenu])

  const handleSplitBottom = useCallback(() => {
    splitPane(pane.id, 'horizontal')
    handleCloseContextMenu()
  }, [pane.id, splitPane, handleCloseContextMenu])

  const handleClosePane = useCallback(() => {
    closePane(pane.id)
    handleCloseContextMenu()
  }, [pane.id, closePane, handleCloseContextMenu])

  const handleSplitWithWebview = useCallback((direction: 'horizontal' | 'vertical', url: string) => {
    console.log('[TerminalPane] handleSplitWithWebview called, direction:', direction, 'url:', url)
    if (url && url !== 'https://') {
      console.log('[TerminalPane] Calling splitPaneWithWebview:', pane.id, direction, url)
      splitPaneWithWebview(pane.id, direction, url)
    }
    handleCloseContextMenu()
  }, [pane.id, splitPaneWithWebview, handleCloseContextMenu])

  const tab = getActiveTab()
  const hasSplits = tab ? getAllContentPanes(tab.root).length > 1 : false
  const canClose = hasSplits


  // Only dim inactive panes when in split view
  const shouldDim = hasSplits && !isActive

  return (
    <div
      ref={containerRef}
      onFocus={handleFocus}
      onContextMenu={handleContextMenu}
      style={{
        width: '100%',
        height: '100%',
        position: 'relative',
        backgroundColor: 'transparent',
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        opacity: shouldDim ? 0.5 : 1,
        transition: 'opacity 0.15s ease',
        zIndex: 1,
        display: 'flex',
        flexDirection: 'column',
      } as React.CSSProperties}
    >
      {/* Classic Terminal Mode */}
      {viewMode === 'classic' && (
        <div style={{ flex: 1, position: 'relative', minHeight: 0 }}>
          <Terminal
            key={`terminal-${pane.id}`}
            ref={terminalRef}
            persistKey={pane.id}
            onExit={(code) => console.log('Terminal exited:', code)}
            onLinkClick={handleLinkClick}
            onFilePathClick={handleFilePathClick}
            onPwdChange={handlePwdChange}
          />
        </div>
      )}

      {/* Blocks Mode - BlocksView + WarpInput */}
      {viewMode === 'blocks' && (
        <>
          <div style={{ flex: 1, position: 'relative', minHeight: 0 }}>
            <BlocksView
              blocks={blocks}
              onInteractiveExit={completeInteractiveBlock}
              onDismissBlock={dismissBlock}
              onBlockClick={handleBlockClick}
              onBlockDoubleClick={handleBlockDoubleClick}
              onScrollToEndRef={scrollToEndRef}
              onLoadMore={loadMoreMessages}
              canLoadMore={canLoadMoreMessages()}
            />
          </div>
          {/* Background shade gradient behind input */}
          <div
            style={{
              background: settings.window.opacity < 100
                ? 'transparent'
                : `linear-gradient(to top, ${settings.theme.background} 0%, ${settings.theme.background}ee 40%, transparent 100%)`,
              paddingTop: '48px',
              marginTop: '-48px',
            }}
          >
            <WarpInput
              onSubmit={handleWarpSubmit}
              onInputFocus={handleInputFocus}
              pendingContextBlock={pendingContextBlock}
              onClearPendingContext={handleClearPendingContext}
              onConfirmContext={handleConfirmContext}
              confirmedContextBlocks={confirmedContextBlocks}
              onRemoveConfirmedContext={handleRemoveConfirmedContext}
              onSessionSelect={handleSessionSelect}
            />
          </div>
        </>
      )}

      {/* Context menu - rendered via portal to escape stacking context */}
      {contextMenu && createPortal(
        <SplitContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          paneId={pane.id}
          onClose={handleCloseContextMenu}
          onSplitLeft={handleSplitLeft}
          onSplitRight={handleSplitRight}
          onSplitTop={handleSplitTop}
          onSplitBottom={handleSplitBottom}
          onSplitWithWebview={handleSplitWithWebview}
          onClosePane={handleClosePane}
          canClose={canClose}
        />,
        document.body
      )}
    </div>
  )
})

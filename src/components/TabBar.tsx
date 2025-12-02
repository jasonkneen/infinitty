import { useState, useCallback, useRef, useEffect, type DragEvent, type MouseEvent, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { X, Plus, PanelLeft, PanelRight, Settings, Columns2, Rows2, Pin, Globe, Terminal, Code, File, Folder, Star, Heart, Bookmark, Home, Zap } from 'lucide-react'
import { type PinnedTabIcon, type PinnedTabColor, type TabColor } from '../types/tabs'
import { invoke } from '@tauri-apps/api/core'
import { useTabs } from '../contexts/TabsContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { useWindowManager } from '../hooks/useWindowManager'
import { createPortal } from 'react-dom'
import { ViewModeToggle } from './ViewModeToggle'
import { getAllContentPanes, type TerminalPane } from '../types/tabs'
import { isGhosttyMode } from '../config'

interface TabBarProps {
  isSidebarOpen: boolean
  onToggleSidebar: () => void
  onOpenSettings: () => void
  isRightPanelOpen: boolean
  onToggleRightPanel: () => void
}

export function TabBar({ isSidebarOpen, onToggleSidebar, onOpenSettings, isRightPanelOpen, onToggleRightPanel }: TabBarProps) {
  const { settings } = useTerminalSettings()
  const { tabs, activeTabId, activePaneId, createNewTab, createWebViewTab, closeTab, setActiveTab, reorderTabs, splitPane, updateTabTitle, togglePinTab, updatePinnedTabStyle, updateTabStyle, updateTerminalViewMode } = useTabs()
  const { createNewWindow } = useWindowManager()
  const ghosttyMode = isGhosttyMode()

  // Tab border radius: fully rounded in ghostty mode, less rounded in infinitty mode
  const tabBorderRadius = ghosttyMode ? '9999px' : '8px'
  const [draggedTabId, setDraggedTabId] = useState<string | null>(null)
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null)
  const [isDraggingOutside, setIsDraggingOutside] = useState(false)
  const tabBarRef = useRef<HTMLDivElement>(null)
  const [showSplitMenu, setShowSplitMenu] = useState(false)
  const [editingTabId, setEditingTabId] = useState<string | null>(null)
  const [editingTitle, setEditingTitle] = useState('')
  const [contextMenuTabId, setContextMenuTabId] = useState<string | null>(null)
  const [contextMenuPos, setContextMenuPos] = useState<{ x: number; y: number } | null>(null)
  const [showWebViewInput, setShowWebViewInput] = useState(false)
  const [webViewUrl, setWebViewUrl] = useState('')
  const [hoveredPinnedTabId, setHoveredPinnedTabId] = useState<string | null>(null)
  const [stylePickerTabId, setStylePickerTabId] = useState<string | null>(null)
  const [stylePickerPos, setStylePickerPos] = useState<{ x: number; y: number } | null>(null)
  const [tabColorPickerTabId, setTabColorPickerTabId] = useState<string | null>(null)
  const [tabColorPickerPos, setTabColorPickerPos] = useState<{ x: number; y: number } | null>(null)
  const tabColorPickerRef = useRef<HTMLDivElement>(null)
  const [dragPreviewPos, setDragPreviewPos] = useState<{ x: number; y: number } | null>(null)
  const editInputRef = useRef<HTMLInputElement>(null)
  const stylePickerRef = useRef<HTMLDivElement>(null)
  const splitMenuRef = useRef<HTMLDivElement>(null)
  const contextMenuRef = useRef<HTMLDivElement>(null)
  const webViewInputRef = useRef<HTMLInputElement>(null)

  // Close split menu when clicking outside
  useEffect(() => {
    if (!showSplitMenu) return

    const handleClickOutside = (e: globalThis.MouseEvent) => {
      if (splitMenuRef.current && !splitMenuRef.current.contains(e.target as Node)) {
        setShowSplitMenu(false)
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [showSplitMenu])

  // Close context menu when clicking outside
  useEffect(() => {
    if (!contextMenuTabId) return

    const handleClickOutside = (e: globalThis.MouseEvent) => {
      if (contextMenuRef.current && !contextMenuRef.current.contains(e.target as Node)) {
        setContextMenuTabId(null)
        setContextMenuPos(null)
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [contextMenuTabId])

  // Close style picker when clicking outside
  useEffect(() => {
    if (!stylePickerTabId) return

    const handleClickOutside = (e: globalThis.MouseEvent) => {
      if (stylePickerRef.current && !stylePickerRef.current.contains(e.target as Node)) {
        setStylePickerTabId(null)
        setStylePickerPos(null)
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [stylePickerTabId])

  // Close tab color picker when clicking outside
  useEffect(() => {
    if (!tabColorPickerTabId) return

    const handleClickOutside = (e: globalThis.MouseEvent) => {
      if (tabColorPickerRef.current && !tabColorPickerRef.current.contains(e.target as Node)) {
        setTabColorPickerTabId(null)
        setTabColorPickerPos(null)
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [tabColorPickerTabId])

  // Hide webviews when any popup is open (native webviews render above DOM)
  useEffect(() => {
    const hasPopup = showSplitMenu || contextMenuTabId || showWebViewInput || stylePickerTabId || tabColorPickerTabId
    if (hasPopup) {
      invoke('hide_all_webviews').catch(console.error)
    } else {
      // Dispatch event to tell webviews to refresh their positions
      window.dispatchEvent(new CustomEvent('webviews-refresh'))
    }
  }, [showSplitMenu, contextMenuTabId, showWebViewInput, stylePickerTabId, tabColorPickerTabId])

  // Keyboard shortcuts for switching tabs (Cmd+1 through Cmd+9)
  useEffect(() => {
    const handleKeyDown = (e: globalThis.KeyboardEvent) => {
      // Check for Cmd+1 through Cmd+9 (Mac) or Ctrl+1 through Ctrl+9 (Windows/Linux)
      if ((e.metaKey || e.ctrlKey) && e.key >= '1' && e.key <= '9') {
        const tabIndex = parseInt(e.key, 10) - 1
        const nonPinnedTabs = tabs.filter(t => !t.isPinned)
        if (tabIndex < nonPinnedTabs.length) {
          e.preventDefault()
          setActiveTab(nonPinnedTabs[tabIndex].id)
        }
      }
    }

    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [tabs, setActiveTab])

  // Icon mapping for pinned tabs
  const getPinnedTabIcon = useCallback((iconName: PinnedTabIcon | undefined, size: number) => {
    const props = { size }
    switch (iconName) {
      case 'terminal': return <Terminal {...props} />
      case 'code': return <Code {...props} />
      case 'file': return <File {...props} />
      case 'folder': return <Folder {...props} />
      case 'star': return <Star {...props} />
      case 'heart': return <Heart {...props} />
      case 'bookmark': return <Bookmark {...props} />
      case 'home': return <Home {...props} />
      case 'settings': return <Settings {...props} />
      case 'globe': return <Globe {...props} />
      case 'zap': return <Zap {...props} />
      case 'pin':
      default: return <Pin {...props} style={{ transform: 'rotate(45deg)' }} />
    }
  }, [])

  // Color mapping for pinned tabs
  const getPinnedTabColor = useCallback((colorName: PinnedTabColor | undefined, isActive: boolean) => {
    const colors: Record<PinnedTabColor, string> = {
      cyan: settings.theme.cyan,
      green: settings.theme.green,
      yellow: settings.theme.yellow,
      orange: '#f97316',
      red: settings.theme.red,
      magenta: settings.theme.magenta,
      blue: settings.theme.blue,
      white: settings.theme.white,
    }
    if (!colorName) return isActive ? settings.theme.cyan : settings.theme.white
    return colors[colorName]
  }, [settings.theme])

  // Color mapping for non-pinned tabs
  const getTabColor = useCallback((colorName: TabColor | undefined) => {
    const colors: Record<TabColor, string> = {
      cyan: settings.theme.cyan,
      green: settings.theme.green,
      yellow: settings.theme.yellow,
      orange: '#f97316',
      red: settings.theme.red,
      magenta: settings.theme.magenta,
      blue: settings.theme.blue,
      white: settings.theme.white,
    }
    if (!colorName) return null
    return colors[colorName]
  }, [settings.theme])

  const handleDragStart = useCallback((e: DragEvent, tabId: string) => {
    setDraggedTabId(tabId)
    e.dataTransfer.setData('text/plain', tabId)
    e.dataTransfer.effectAllowed = 'move'
    // Create a transparent drag image to hide the default browser preview
    const dragImage = document.createElement('div')
    dragImage.style.opacity = '0'
    document.body.appendChild(dragImage)
    e.dataTransfer.setDragImage(dragImage, 0, 0)
    setTimeout(() => document.body.removeChild(dragImage), 0)
  }, [])

  // Track mouse position during drag for detecting when outside tab bar
  useEffect(() => {
    if (!draggedTabId) return

    const handleDragMove = (e: globalThis.DragEvent) => {
      // Check if dragging outside tab bar area
      if (tabBarRef.current) {
        const rect = tabBarRef.current.getBoundingClientRect()
        const isOutside = e.clientY > rect.bottom + 50 || e.clientY < rect.top - 50
        setIsDraggingOutside(isOutside)

        // Update drag preview position when outside
        if (isOutside && e.clientX > 0 && e.clientY > 0) {
          setDragPreviewPos({ x: e.clientX, y: e.clientY })
        } else {
          setDragPreviewPos(null)
        }
      }
    }

    document.addEventListener('drag', handleDragMove)
    return () => document.removeEventListener('drag', handleDragMove)
  }, [draggedTabId])

  const handleDragOver = useCallback((e: DragEvent, index: number) => {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'move'
    setDragOverIndex(index)
    setIsDraggingOutside(false)
  }, [])

  const handleDragLeave = useCallback(() => {
    setDragOverIndex(null)
  }, [])

  const handleDrop = useCallback((e: DragEvent, toIndex: number) => {
    e.preventDefault()
    if (!draggedTabId) return

    const fromIndex = tabs.findIndex((t) => t.id === draggedTabId)
    if (fromIndex !== -1 && fromIndex !== toIndex) {
      reorderTabs(fromIndex, toIndex)
    }

    setDraggedTabId(null)
    setDragOverIndex(null)
    setIsDraggingOutside(false)
  }, [draggedTabId, tabs, reorderTabs])

  const handleDragEnd = useCallback(async () => {
    // If dropped outside tab bar, create a new window and close the tab
    if (isDraggingOutside && draggedTabId && tabs.length > 1) {
      try {
        // Create new window
        await createNewWindow()
        // Close the tab in the current window (the new window starts with a fresh terminal)
        // Note: Full tab state transfer would require Tauri IPC to serialize and transfer the tab state
        closeTab(draggedTabId)
      } catch (error) {
        console.error('Failed to create new window:', error)
      }
    }

    setDraggedTabId(null)
    setDragOverIndex(null)
    setIsDraggingOutside(false)
    setDragPreviewPos(null)
  }, [isDraggingOutside, draggedTabId, tabs.length, createNewWindow, closeTab])

  const handleNewTab = useCallback(() => {
    createNewTab()
  }, [createNewTab])

  const handleNewWindow = useCallback(async () => {
    try {
      await createNewWindow()
    } catch (error) {
      console.error('Failed to create new window:', error)
    }
  }, [createNewWindow])

  const handleSplit = useCallback((direction: 'horizontal' | 'vertical') => {
    if (activePaneId) {
      splitPane(activePaneId, direction)
    }
    setShowSplitMenu(false)
  }, [activePaneId, splitPane])

  const handleContextMenu = useCallback((e: MouseEvent, tabId: string) => {
    e.preventDefault()
    setContextMenuTabId(tabId)
    setContextMenuPos({ x: e.clientX, y: e.clientY })
  }, [])

  const handleMiddleClick = useCallback((e: MouseEvent, tabId: string) => {
    if (e.button === 1) {
      e.preventDefault()
      // Don't close pinned tabs via middle-click
      const tab = tabs.find(t => t.id === tabId)
      if (tab && !tab.isPinned) {
        closeTab(tabId)
      }
    }
  }, [closeTab, tabs])

  const handlePinToggle = useCallback((tabId: string) => {
    togglePinTab(tabId)
    setContextMenuTabId(null)
    setContextMenuPos(null)
  }, [togglePinTab])

  const handleCloseFromMenu = useCallback((tabId: string) => {
    closeTab(tabId)
    setContextMenuTabId(null)
    setContextMenuPos(null)
  }, [closeTab])

  const handleOpenWebView = useCallback(() => {
    setShowSplitMenu(false)
    setShowWebViewInput(true)
    setWebViewUrl('')
    setTimeout(() => webViewInputRef.current?.focus(), 0)
  }, [])

  const handleWebViewSubmit = useCallback((e: React.FormEvent) => {
    e.preventDefault()
    if (webViewUrl.trim()) {
      createWebViewTab(webViewUrl.trim())
      setShowWebViewInput(false)
      setWebViewUrl('')
    }
  }, [webViewUrl, createWebViewTab])

  const handleWebViewCancel = useCallback(() => {
    setShowWebViewInput(false)
    setWebViewUrl('')
  }, [])

  // Double-click to edit tab title
  const handleDoubleClick = useCallback((tabId: string, currentTitle: string) => {
    setEditingTabId(tabId)
    setEditingTitle(currentTitle)
  }, [])

  // Focus input when editing starts
  useEffect(() => {
    if (editingTabId && editInputRef.current) {
      editInputRef.current.focus()
      editInputRef.current.select()
    }
  }, [editingTabId])

  // Handle editing completion
  const handleEditComplete = useCallback(() => {
    if (editingTabId && editingTitle.trim()) {
      updateTabTitle(editingTabId, editingTitle.trim())
    }
    setEditingTabId(null)
    setEditingTitle('')
  }, [editingTabId, editingTitle, updateTabTitle])

  // Handle edit key events
  const handleEditKeyDown = useCallback((e: ReactKeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      handleEditComplete()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      setEditingTabId(null)
      setEditingTitle('')
    }
  }, [handleEditComplete])

  return (
    <div
      ref={tabBarRef}
      style={{
        height: '36px',
        marginTop: '1px',
        backgroundColor: 'transparent',
        display: 'flex',
        alignItems: 'center',
        paddingLeft: isSidebarOpen ? '12px' : '80px',
        paddingRight: '12px',
        gap: '8px',
        WebkitAppRegion: 'drag',
        transition: 'padding-left 0.2s ease',
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        borderBottom: `1px solid ${settings.theme.brightBlack}20`,
      } as React.CSSProperties}
    >
      {/* Expand sidebar button when collapsed */}
      {!isSidebarOpen && (
        <button
          onClick={onToggleSidebar}
          style={{
            padding: '6px',
            backgroundColor: 'transparent',
            border: 'none',
            cursor: 'pointer',
            color: settings.theme.brightBlack,
            transition: 'color 0.15s ease',
            marginRight: '8px',
            WebkitAppRegion: 'no-drag',
          } as React.CSSProperties}
          onMouseEnter={(e) => {
            e.currentTarget.style.color = settings.theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.color = settings.theme.brightBlack
          }}
          title="Expand sidebar"
        >
          <PanelLeft size={16} />
        </button>
      )}

      {/* Tabs */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          overflowX: settings.window.tabStyle === 'fill' ? 'hidden' : 'auto',
          minWidth: 0,
          flex: settings.window.tabStyle === 'fill' ? 1 : 'none',
        } as React.CSSProperties}
      >
        {tabs.map((tab, index) => {
          const isFillMode = settings.window.tabStyle === 'fill'
          const shouldFill = isFillMode && !tab.isPinned
          const isPinnedHovered = tab.isPinned && hoveredPinnedTabId === tab.id
          return (
          <div
            key={tab.id}
            draggable={!tab.isPinned}
            onDragStart={(e) => !tab.isPinned && handleDragStart(e, tab.id)}
            onDragOver={(e) => handleDragOver(e, index)}
            onDragLeave={handleDragLeave}
            onDrop={(e) => handleDrop(e, index)}
            onDragEnd={handleDragEnd}
            onClick={() => setActiveTab(tab.id)}
            onContextMenu={(e) => handleContextMenu(e, tab.id)}
            onMouseDown={(e) => handleMiddleClick(e, tab.id)}
            onMouseEnter={(e) => {
              if (tab.isPinned) {
                setHoveredPinnedTabId(tab.id)
              }
              if (tab.id !== activeTabId) {
                e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}4d`
                e.currentTarget.style.color = settings.theme.foreground
              }
            }}
            onMouseLeave={(e) => {
              if (tab.isPinned) {
                setHoveredPinnedTabId(null)
              }
              if (tab.id !== activeTabId) {
                e.currentTarget.style.backgroundColor = 'transparent'
                e.currentTarget.style.color = settings.theme.white
              }
            }}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: shouldFill ? 'center' : 'flex-start',
              gap: tab.isPinned ? (isPinnedHovered ? '6px' : '0') : '6px',
              padding: tab.isPinned ? '4px 8px' : '2px 8px 2px 2px',
              backgroundColor: tab.isPinned && tab.pinBackgroundColor
                ? `${getPinnedTabColor(tab.pinBackgroundColor, true)}${tab.id === activeTabId ? 'cc' : '40'}`
                : !tab.isPinned && tab.tabBackgroundColor
                  ? `${getTabColor(tab.tabBackgroundColor)}${tab.id === activeTabId ? 'cc' : '40'}`
                  : tab.id === activeTabId
                    ? `${settings.theme.brightBlack}66`
                    : 'transparent',
              border: '1px solid',
              borderColor: dragOverIndex === index
                ? settings.theme.cyan
                : tab.isPinned && tab.pinBackgroundColor
                  ? getPinnedTabColor(tab.pinBackgroundColor, true)
                  : !tab.isPinned && tab.tabBackgroundColor
                    ? getTabColor(tab.tabBackgroundColor) || 'transparent'
                    : tab.id === activeTabId
                      ? `${settings.theme.brightBlack}66`
                      : 'transparent',
              borderRadius: tabBorderRadius,
              color: tab.id === activeTabId
                ? settings.theme.foreground
                : settings.theme.white,
              fontSize: '12px',
              fontWeight: 500,
              cursor: 'pointer',
              // Elastic spring animation for pinned tabs
              transition: tab.isPinned
                ? 'all 0.4s cubic-bezier(0.34, 1.56, 0.64, 1)'
                : 'all 0.15s ease',
              whiteSpace: 'nowrap',
              opacity: draggedTabId === tab.id ? 0.5 : 1,
              transform: dragOverIndex === index ? 'scale(1.02)' : 'scale(1)',
              WebkitAppRegion: 'no-drag',
              flex: shouldFill ? 1 : 'none',
              minWidth: shouldFill ? 0 : 'auto',
              overflow: 'hidden',
            } as React.CSSProperties}
            title={tab.isPinned && !isPinnedHovered ? tab.title : undefined}
          >
            {/* Close button on the LEFT - only for non-pinned tabs - ALWAYS visible */}
            {!tab.isPinned && (
              <button
                onClick={(e) => {
                  e.stopPropagation()
                  closeTab(tab.id)
                }}
                style={{
                  padding: '2px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  cursor: 'pointer',
                  color: settings.theme.white,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  borderRadius: '4px',
                  opacity: 0.6,
                  transition: 'opacity 0.15s ease, background-color 0.15s ease',
                  flexShrink: 0,
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.red}40`
                  e.currentTarget.style.color = settings.theme.red
                  e.currentTarget.style.opacity = '1'
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent'
                  e.currentTarget.style.color = settings.theme.white
                  e.currentTarget.style.opacity = '0.6'
                }}
              >
                <X size={12} />
              </button>
            )}

            {/* Pin icon for pinned tabs, dot for normal tabs */}
            {tab.isPinned ? (
              <span
                onDoubleClick={(e) => {
                  e.stopPropagation()
                  const rect = e.currentTarget.getBoundingClientRect()
                  setStylePickerTabId(tab.id)
                  setStylePickerPos({ x: rect.left, y: rect.bottom + 8 })
                }}
                style={{
                  color: getPinnedTabColor(tab.pinColor, tab.id === activeTabId),
                  display: 'flex',
                  alignItems: 'center',
                  cursor: 'pointer',
                }}
                title="Double-click to customize"
              >
                {getPinnedTabIcon(tab.pinIcon, 12)}
              </span>
            ) : (
              <span
                style={{
                  width: '5px',
                  height: '5px',
                  borderRadius: '50%',
                  backgroundColor: tab.tabColor
                    ? getTabColor(tab.tabColor) || settings.theme.cyan
                    : tab.id === activeTabId
                      ? settings.theme.cyan
                      : settings.theme.white,
                  flexShrink: 0,
                }}
              />
            )}

            {/* Show title for non-pinned tabs, or for hovered pinned tabs */}
            {(!tab.isPinned || isPinnedHovered) && (
              editingTabId === tab.id ? (
                <input
                  ref={editInputRef}
                  type="text"
                  value={editingTitle}
                  onChange={(e) => setEditingTitle(e.target.value)}
                  onBlur={handleEditComplete}
                  onKeyDown={handleEditKeyDown}
                  onClick={(e) => e.stopPropagation()}
                  style={{
                    width: '100px',
                    padding: '1px 4px',
                    fontSize: '12px',
                    fontWeight: 500,
                    backgroundColor: settings.theme.background,
                    border: `1px solid ${settings.theme.cyan}`,
                    borderRadius: '4px',
                    color: settings.theme.foreground,
                    outline: 'none',
                  }}
                />
              ) : (
                <span
                  onDoubleClick={(e) => {
                    e.stopPropagation()
                    handleDoubleClick(tab.id, tab.title)
                  }}
                  style={{
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    maxWidth: tab.isPinned ? '80px' : '120px',
                    opacity: isPinnedHovered ? 1 : 1,
                    transition: 'opacity 0.2s ease',
                  }}
                >
                  {tab.title}
                </span>
              )
            )}

            {/* Keyboard shortcut on the RIGHT - for first 9 non-pinned tabs */}
            {!tab.isPinned && (() => {
              // Calculate the position among non-pinned tabs
              const nonPinnedTabs = tabs.filter(t => !t.isPinned)
              const nonPinnedIndex = nonPinnedTabs.findIndex(t => t.id === tab.id)
              if (nonPinnedIndex >= 0 && nonPinnedIndex < 9) {
                return (
                  <span
                    onDoubleClick={(e) => {
                      e.stopPropagation()
                      const rect = e.currentTarget.getBoundingClientRect()
                      setTabColorPickerTabId(tab.id)
                      setTabColorPickerPos({ x: rect.left, y: rect.bottom + 8 })
                    }}
                    style={{
                      fontSize: '10px',
                      color: tab.tabColor
                        ? getTabColor(tab.tabColor) || settings.theme.foreground
                        : tab.id === activeTabId
                          ? settings.theme.foreground
                          : settings.theme.brightBlack,
                      opacity: tab.id === activeTabId ? 0.6 : 0.5,
                      marginLeft: '4px',
                      flexShrink: 0,
                      fontWeight: 400,
                      cursor: 'pointer',
                    }}
                    title="Double-click to customize colors"
                  >
                    ⌘{nonPinnedIndex + 1}
                  </span>
                )
              }
              return null
            })()}
          </div>
        )})}

        {/* New tab button */}
        <button
          onClick={handleNewTab}
          style={{
            width: '22px',
            height: '22px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: tabBorderRadius,
            color: settings.theme.brightBlack,
            cursor: 'pointer',
            transition: 'all 0.15s ease',
            flexShrink: 0,
            WebkitAppRegion: 'no-drag',
          } as React.CSSProperties}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
            e.currentTarget.style.color = settings.theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.backgroundColor = 'transparent'
            e.currentTarget.style.color = settings.theme.brightBlack
          }}
          title="New Tab (Cmd+T)"
        >
          <Plus size={16} />
        </button>
      </div>

      {/* Drag spacer - only show when tabs are compact */}
      {settings.window.tabStyle !== 'fill' && (
        <div style={{ flex: 1 }} />
      )}

      {/* View Mode Toggle - Only show if active pane is terminal */}
      {(() => {
        const activeTab = tabs.find(t => t.id === activeTabId)
        const activePane = activeTab && activePaneId 
          ? getAllContentPanes(activeTab.root).find(p => p.id === activePaneId)
          : null
        
        if (activePane && activePane.type === 'terminal') {
          const terminalPane = activePane as TerminalPane
          return (
            <ViewModeToggle 
              viewMode={terminalPane.viewMode || 'classic'} 
              onChange={(mode) => updateTerminalViewMode(activePane.id, mode)} 
            />
          )
        }
        return null
      })()}

      {/* Right side buttons */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          WebkitAppRegion: 'no-drag',
        } as React.CSSProperties}
      >
        {/* Split pane dropdown */}
        <div style={{ position: 'relative' }} ref={splitMenuRef}>
          <button
            onClick={() => setShowSplitMenu(!showSplitMenu)}
            style={{
              padding: '6px',
              backgroundColor: showSplitMenu ? `${settings.theme.brightBlack}40` : 'transparent',
              border: 'none',
              cursor: 'pointer',
              color: settings.theme.brightBlack,
              transition: 'all 0.15s ease',
              borderRadius: '6px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
              e.currentTarget.style.color = settings.theme.foreground
            }}
            onMouseLeave={(e) => {
              if (!showSplitMenu) {
                e.currentTarget.style.backgroundColor = 'transparent'
                e.currentTarget.style.color = settings.theme.brightBlack
              }
            }}
            title="Split Pane"
          >
            <Columns2 size={16} />
          </button>

          {showSplitMenu && createPortal(
            <div
              ref={splitMenuRef}
              style={{
                position: 'fixed',
                top: '44px',
                right: '52px',
                backgroundColor: settings.theme.background,
                border: `1px solid ${settings.theme.brightBlack}`,
                borderRadius: '8px',
                padding: '4px 0',
                zIndex: 99999,
                boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
                minWidth: '160px',
              }}
            >
              <button
                onClick={() => handleSplit('vertical')}
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  cursor: 'pointer',
                  color: settings.theme.foreground,
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  fontSize: '13px',
                  textAlign: 'left',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                <Columns2 size={14} />
                Split Right
                <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '11px' }}>⌘D</span>
              </button>
              <button
                onClick={() => handleSplit('horizontal')}
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  cursor: 'pointer',
                  color: settings.theme.foreground,
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  fontSize: '13px',
                  textAlign: 'left',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                <Rows2 size={14} />
                Split Down
                <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '11px' }}>⇧⌘D</span>
              </button>
              <div style={{ height: '1px', backgroundColor: settings.theme.brightBlack, margin: '4px 0' }} />
              <button
                onClick={handleNewWindow}
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  cursor: 'pointer',
                  color: settings.theme.foreground,
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  fontSize: '13px',
                  textAlign: 'left',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                <Plus size={14} />
                New Window
                <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '11px' }}>⇧⌘N</span>
              </button>
              <div style={{ height: '1px', backgroundColor: settings.theme.brightBlack, margin: '4px 0' }} />
              <button
                onClick={handleOpenWebView}
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  cursor: 'pointer',
                  color: settings.theme.foreground,
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  fontSize: '13px',
                  textAlign: 'left',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                <Globe size={14} />
                Open Web View
              </button>
            </div>,
            document.body
          )}

        </div>

        {/* Right Panel button */}
        <button
          onClick={onToggleRightPanel}
          style={{
            padding: '6px',
            backgroundColor: isRightPanelOpen ? `${settings.theme.brightBlack}40` : 'transparent',
            border: 'none',
            cursor: 'pointer',
            color: isRightPanelOpen ? settings.theme.foreground : settings.theme.brightBlack,
            transition: 'all 0.15s ease',
            borderRadius: '6px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
            e.currentTarget.style.color = settings.theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.backgroundColor = isRightPanelOpen ? `${settings.theme.brightBlack}40` : 'transparent'
            e.currentTarget.style.color = isRightPanelOpen ? settings.theme.foreground : settings.theme.brightBlack
          }}
          title="Toggle right panel"
        >
          <PanelRight size={16} />
        </button>

        {/* Settings button */}
        <button
          onClick={onOpenSettings}
          style={{
            padding: '6px',
            backgroundColor: 'transparent',
            border: 'none',
            cursor: 'pointer',
            color: settings.theme.brightBlack,
            transition: 'all 0.15s ease',
            borderRadius: '6px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
            e.currentTarget.style.color = settings.theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.backgroundColor = 'transparent'
            e.currentTarget.style.color = settings.theme.brightBlack
          }}
          title="Settings (Cmd+,)"
        >
          <Settings size={16} />
        </button>
      </div>

      {/* Tab Context Menu - rendered via portal */}
      {contextMenuTabId && contextMenuPos && createPortal(
        <div
          ref={contextMenuRef}
          style={{
            position: 'fixed',
            left: contextMenuPos.x,
            top: contextMenuPos.y,
            backgroundColor: settings.theme.background,
            border: `1px solid ${settings.theme.brightBlack}`,
            borderRadius: '8px',
            padding: '4px 0',
            zIndex: 999999,
            boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
            minWidth: '140px',
          }}
        >
          {(() => {
            const tab = tabs.find(t => t.id === contextMenuTabId)
            if (!tab) return null
            return (
              <>
                <button
                  onClick={() => handlePinToggle(contextMenuTabId)}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    backgroundColor: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                    color: settings.theme.foreground,
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    fontSize: '13px',
                    textAlign: 'left',
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.backgroundColor = 'transparent'
                  }}
                >
                  <Pin size={14} style={{ transform: tab.isPinned ? 'none' : 'rotate(45deg)' }} />
                  {tab.isPinned ? 'Unpin Tab' : 'Pin Tab'}
                </button>
                {!tab.isPinned && (
                  <>
                    <div style={{ height: '1px', backgroundColor: settings.theme.brightBlack, margin: '4px 0' }} />
                    <button
                      onClick={() => handleCloseFromMenu(contextMenuTabId)}
                      style={{
                        width: '100%',
                        padding: '8px 12px',
                        backgroundColor: 'transparent',
                        border: 'none',
                        cursor: 'pointer',
                        color: settings.theme.red,
                        display: 'flex',
                        alignItems: 'center',
                        gap: '8px',
                        fontSize: '13px',
                        textAlign: 'left',
                      }}
                      onMouseEnter={(e) => {
                        e.currentTarget.style.backgroundColor = `${settings.theme.red}20`
                      }}
                      onMouseLeave={(e) => {
                        e.currentTarget.style.backgroundColor = 'transparent'
                      }}
                    >
                      <X size={14} />
                      Close Tab
                    </button>
                  </>
                )}
              </>
            )
          })()}
        </div>,
        document.body
      )}

      {/* Web View URL Input - rendered via portal */}
      {showWebViewInput && createPortal(
        <div
          style={{
            position: 'fixed',
            top: '44px',
            right: '52px',
            backgroundColor: settings.theme.background,
            border: `1px solid ${settings.theme.brightBlack}`,
            borderRadius: '8px',
            padding: '12px',
            zIndex: 99999,
            boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
            minWidth: '300px',
          }}
        >
          <form onSubmit={handleWebViewSubmit}>
            <label style={{ color: settings.theme.foreground, fontSize: '12px', marginBottom: '8px', display: 'block' }}>
              Enter URL
            </label>
            <input
              ref={webViewInputRef}
              type="text"
              value={webViewUrl}
              onChange={(e) => setWebViewUrl(e.target.value)}
              placeholder="https://example.com"
              style={{
                width: '100%',
                padding: '8px 12px',
                backgroundColor: `${settings.theme.brightBlack}40`,
                border: `1px solid ${settings.theme.brightBlack}`,
                borderRadius: '6px',
                color: settings.theme.foreground,
                fontSize: '13px',
                outline: 'none',
                marginBottom: '12px',
              }}
              onKeyDown={(e) => {
                if (e.key === 'Escape') handleWebViewCancel()
              }}
            />
            <div style={{ display: 'flex', gap: '8px', justifyContent: 'flex-end' }}>
              <button
                type="button"
                onClick={handleWebViewCancel}
                style={{
                  padding: '6px 12px',
                  backgroundColor: 'transparent',
                  border: `1px solid ${settings.theme.brightBlack}`,
                  borderRadius: '6px',
                  color: settings.theme.foreground,
                  fontSize: '13px',
                  cursor: 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                type="submit"
                style={{
                  padding: '6px 12px',
                  backgroundColor: settings.theme.cyan,
                  border: 'none',
                  borderRadius: '6px',
                  color: '#000',
                  fontSize: '13px',
                  cursor: 'pointer',
                  fontWeight: 500,
                }}
              >
                Open
              </button>
            </div>
          </form>
        </div>,
        document.body
      )}

      {/* Pinned Tab Style Picker - rendered via portal */}
      {stylePickerTabId && stylePickerPos && createPortal(
        <div
          ref={stylePickerRef}
          style={{
            position: 'fixed',
            left: stylePickerPos.x,
            top: stylePickerPos.y,
            backgroundColor: settings.theme.background,
            border: `1px solid ${settings.theme.brightBlack}`,
            borderRadius: '12px',
            padding: '16px',
            zIndex: 999999,
            boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
            minWidth: '200px',
          }}
        >
          <div style={{ color: settings.theme.foreground, fontSize: '12px', fontWeight: 600, marginBottom: '12px' }}>
            Customize Pinned Tab
          </div>

          {/* Icons */}
          <div style={{ marginBottom: '16px' }}>
            <div style={{ color: settings.theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>Icon</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
              {(['pin', 'terminal', 'code', 'file', 'folder', 'star', 'heart', 'bookmark', 'home', 'settings', 'globe', 'zap'] as PinnedTabIcon[]).map((iconName) => {
                const tab = tabs.find(t => t.id === stylePickerTabId)
                const isSelected = tab?.pinIcon === iconName || (!tab?.pinIcon && iconName === 'pin')
                return (
                  <button
                    key={iconName}
                    onClick={() => {
                      const currentTab = tabs.find(t => t.id === stylePickerTabId)
                      updatePinnedTabStyle(stylePickerTabId, iconName, currentTab?.pinColor, currentTab?.pinBackgroundColor)
                    }}
                    style={{
                      width: '32px',
                      height: '32px',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      backgroundColor: isSelected ? `${settings.theme.cyan}30` : 'transparent',
                      border: isSelected ? `1px solid ${settings.theme.cyan}` : `1px solid ${settings.theme.brightBlack}40`,
                      borderRadius: '6px',
                      color: isSelected ? settings.theme.cyan : settings.theme.foreground,
                      cursor: 'pointer',
                      transition: 'all 0.15s ease',
                    }}
                    onMouseEnter={(e) => {
                      if (!isSelected) e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40`
                    }}
                    onMouseLeave={(e) => {
                      if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent'
                    }}
                  >
                    {getPinnedTabIcon(iconName, 14)}
                  </button>
                )
              })}
            </div>
          </div>

          {/* Foreground Color (Icon) */}
          <div style={{ marginBottom: '16px' }}>
            <div style={{ color: settings.theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>Icon Color</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
              {(['cyan', 'green', 'yellow', 'orange', 'red', 'magenta', 'blue', 'white'] as PinnedTabColor[]).map((colorName) => {
                const tab = tabs.find(t => t.id === stylePickerTabId)
                const isSelected = tab?.pinColor === colorName || (!tab?.pinColor && colorName === 'cyan')
                const colorValue = getPinnedTabColor(colorName, true)
                return (
                  <button
                    key={colorName}
                    onClick={() => {
                      const currentTab = tabs.find(t => t.id === stylePickerTabId)
                      updatePinnedTabStyle(stylePickerTabId, currentTab?.pinIcon, colorName, currentTab?.pinBackgroundColor)
                    }}
                    style={{
                      width: '24px',
                      height: '24px',
                      backgroundColor: colorValue,
                      border: isSelected ? `2px solid ${settings.theme.foreground}` : '2px solid transparent',
                      borderRadius: '50%',
                      cursor: 'pointer',
                      transition: 'all 0.15s ease',
                      transform: isSelected ? 'scale(1.1)' : 'scale(1)',
                    }}
                    title={colorName}
                  />
                )
              })}
            </div>
          </div>

          {/* Background Color */}
          <div>
            <div style={{ color: settings.theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>Background</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' }}>
              {/* None option */}
              <button
                onClick={() => {
                  const currentTab = tabs.find(t => t.id === stylePickerTabId)
                  updatePinnedTabStyle(stylePickerTabId, currentTab?.pinIcon, currentTab?.pinColor, undefined)
                }}
                style={{
                  width: '24px',
                  height: '24px',
                  backgroundColor: 'transparent',
                  border: !tabs.find(t => t.id === stylePickerTabId)?.pinBackgroundColor
                    ? `2px solid ${settings.theme.foreground}`
                    : `2px solid ${settings.theme.brightBlack}40`,
                  borderRadius: '50%',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: settings.theme.brightBlack,
                  fontSize: '10px',
                }}
                title="None"
              >
                ∅
              </button>
              {(['cyan', 'green', 'yellow', 'orange', 'red', 'magenta', 'blue', 'white'] as PinnedTabColor[]).map((colorName) => {
                const tab = tabs.find(t => t.id === stylePickerTabId)
                const isSelected = tab?.pinBackgroundColor === colorName
                const colorValue = getPinnedTabColor(colorName, true)
                return (
                  <button
                    key={colorName}
                    onClick={() => {
                      const currentTab = tabs.find(t => t.id === stylePickerTabId)
                      updatePinnedTabStyle(stylePickerTabId, currentTab?.pinIcon, currentTab?.pinColor, colorName)
                    }}
                    style={{
                      width: '24px',
                      height: '24px',
                      backgroundColor: colorValue,
                      border: isSelected ? `2px solid ${settings.theme.foreground}` : '2px solid transparent',
                      borderRadius: '50%',
                      cursor: 'pointer',
                      transition: 'all 0.15s ease',
                      transform: isSelected ? 'scale(1.1)' : 'scale(1)',
                    }}
                    title={colorName}
                  />
                )
              })}
            </div>
          </div>

          {/* Done button */}
          <div style={{ marginTop: '16px', display: 'flex', justifyContent: 'flex-end' }}>
            <button
              onClick={() => {
                setStylePickerTabId(null)
                setStylePickerPos(null)
              }}
              style={{
                padding: '6px 12px',
                backgroundColor: settings.theme.cyan,
                border: 'none',
                borderRadius: '6px',
                color: '#000',
                fontSize: '12px',
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              Done
            </button>
          </div>
        </div>,
        document.body
      )}

      {/* Tab Color Picker for non-pinned tabs - rendered via portal */}
      {tabColorPickerTabId && tabColorPickerPos && createPortal(
        <div
          ref={tabColorPickerRef}
          style={{
            position: 'fixed',
            left: tabColorPickerPos.x,
            top: tabColorPickerPos.y,
            backgroundColor: settings.theme.background,
            border: `1px solid ${settings.theme.brightBlack}`,
            borderRadius: '12px',
            padding: '16px',
            zIndex: 999999,
            boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
            minWidth: '180px',
          }}
        >
          <div style={{ color: settings.theme.foreground, fontSize: '12px', fontWeight: 600, marginBottom: '12px' }}>
            Tab Colors
          </div>

          {/* Dot/Text Color */}
          <div style={{ marginBottom: '16px' }}>
            <div style={{ color: settings.theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>Dot Color</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' }}>
              {/* None option */}
              <button
                onClick={() => {
                  const currentTab = tabs.find(t => t.id === tabColorPickerTabId)
                  updateTabStyle(tabColorPickerTabId, undefined, currentTab?.tabBackgroundColor)
                }}
                style={{
                  width: '24px',
                  height: '24px',
                  backgroundColor: 'transparent',
                  border: !tabs.find(t => t.id === tabColorPickerTabId)?.tabColor
                    ? `2px solid ${settings.theme.foreground}`
                    : `2px solid ${settings.theme.brightBlack}40`,
                  borderRadius: '50%',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: settings.theme.brightBlack,
                  fontSize: '10px',
                }}
                title="Default"
              >
                ∅
              </button>
              {(['cyan', 'green', 'yellow', 'orange', 'red', 'magenta', 'blue', 'white'] as TabColor[]).map((colorName) => {
                const tab = tabs.find(t => t.id === tabColorPickerTabId)
                const isSelected = tab?.tabColor === colorName
                const colorValue = getTabColor(colorName)
                return (
                  <button
                    key={colorName}
                    onClick={() => {
                      const currentTab = tabs.find(t => t.id === tabColorPickerTabId)
                      updateTabStyle(tabColorPickerTabId, colorName, currentTab?.tabBackgroundColor)
                    }}
                    style={{
                      width: '24px',
                      height: '24px',
                      backgroundColor: colorValue || 'transparent',
                      border: isSelected ? `2px solid ${settings.theme.foreground}` : '2px solid transparent',
                      borderRadius: '50%',
                      cursor: 'pointer',
                      transition: 'all 0.15s ease',
                      transform: isSelected ? 'scale(1.1)' : 'scale(1)',
                    }}
                    title={colorName}
                  />
                )
              })}
            </div>
          </div>

          {/* Background Color */}
          <div>
            <div style={{ color: settings.theme.brightBlack, fontSize: '11px', marginBottom: '8px' }}>Background</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' }}>
              {/* None option */}
              <button
                onClick={() => {
                  const currentTab = tabs.find(t => t.id === tabColorPickerTabId)
                  updateTabStyle(tabColorPickerTabId, currentTab?.tabColor, undefined)
                }}
                style={{
                  width: '24px',
                  height: '24px',
                  backgroundColor: 'transparent',
                  border: !tabs.find(t => t.id === tabColorPickerTabId)?.tabBackgroundColor
                    ? `2px solid ${settings.theme.foreground}`
                    : `2px solid ${settings.theme.brightBlack}40`,
                  borderRadius: '50%',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: settings.theme.brightBlack,
                  fontSize: '10px',
                }}
                title="None"
              >
                ∅
              </button>
              {(['cyan', 'green', 'yellow', 'orange', 'red', 'magenta', 'blue', 'white'] as TabColor[]).map((colorName) => {
                const tab = tabs.find(t => t.id === tabColorPickerTabId)
                const isSelected = tab?.tabBackgroundColor === colorName
                const colorValue = getTabColor(colorName)
                return (
                  <button
                    key={colorName}
                    onClick={() => {
                      const currentTab = tabs.find(t => t.id === tabColorPickerTabId)
                      updateTabStyle(tabColorPickerTabId, currentTab?.tabColor, colorName)
                    }}
                    style={{
                      width: '24px',
                      height: '24px',
                      backgroundColor: colorValue || 'transparent',
                      border: isSelected ? `2px solid ${settings.theme.foreground}` : '2px solid transparent',
                      borderRadius: '50%',
                      cursor: 'pointer',
                      transition: 'all 0.15s ease',
                      transform: isSelected ? 'scale(1.1)' : 'scale(1)',
                    }}
                    title={colorName}
                  />
                )
              })}
            </div>
          </div>

          {/* Done button */}
          <div style={{ marginTop: '16px', display: 'flex', justifyContent: 'flex-end' }}>
            <button
              onClick={() => {
                setTabColorPickerTabId(null)
                setTabColorPickerPos(null)
              }}
              style={{
                padding: '6px 12px',
                backgroundColor: settings.theme.cyan,
                border: 'none',
                borderRadius: '6px',
                color: '#000',
                fontSize: '12px',
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              Done
            </button>
          </div>
        </div>,
        document.body
      )}

      {/* Drag Preview - shows when dragging tab outside tab bar */}
      {draggedTabId && dragPreviewPos && isDraggingOutside && createPortal(
        <div
          style={{
            position: 'fixed',
            left: dragPreviewPos.x - 80,
            top: dragPreviewPos.y - 20,
            pointerEvents: 'none',
            zIndex: 99999,
          }}
        >
          {/* Tab preview card */}
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '8px',
              padding: '8px 14px',
              backgroundColor: settings.theme.background,
              border: `2px solid ${settings.theme.cyan}`,
              borderRadius: '10px',
              boxShadow: `0 8px 32px rgba(0,0,0,0.4), 0 0 0 1px ${settings.theme.cyan}40`,
              color: settings.theme.foreground,
              fontSize: '13px',
              fontWeight: 500,
            }}
          >
            <span
              style={{
                width: '6px',
                height: '6px',
                borderRadius: '50%',
                backgroundColor: settings.theme.cyan,
              }}
            />
            <span style={{ maxWidth: '120px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {tabs.find(t => t.id === draggedTabId)?.title}
            </span>
          </div>

          {/* New window indicator */}
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              marginTop: '8px',
              padding: '6px 12px',
              backgroundColor: `${settings.theme.green}20`,
              border: `1px solid ${settings.theme.green}`,
              borderRadius: '6px',
              color: settings.theme.green,
              fontSize: '11px',
              fontWeight: 500,
            }}
          >
            <Plus size={12} />
            <span>Drop to open in new window</span>
          </div>
        </div>,
        document.body
      )}
    </div>
  )
}

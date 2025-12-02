import { useCallback, useRef, useState, useEffect, type ReactNode, type MouseEvent } from 'react'
import {
  type PaneNode,
  type SplitPane as SplitPaneType,
  type TerminalPane,
  isTerminalPane,
  isWebViewPane,
  isWidgetPane,
  isEditorPane,
  isSplitPane,
} from '../types/tabs'
import { useTabs } from '../contexts/TabsContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { WebViewPane } from './WebViewPane'
import { WidgetPane } from './WidgetPane'
import { EditorPane } from './EditorPane'

interface SplitPaneProps {
  node: PaneNode
  renderPane: (pane: TerminalPane) => ReactNode
}

interface ResizeHandleProps {
  direction: 'horizontal' | 'vertical'
  onResize: (delta: number) => void
  onResizeEnd: () => void
}

function ResizeHandle({ direction, onResize, onResizeEnd }: ResizeHandleProps) {
  const { settings } = useTerminalSettings()
  const [isDragging, setIsDragging] = useState(false)
  const handleRef = useRef<HTMLDivElement>(null)
  const startPos = useRef(0)

  const handleMouseDown = useCallback((e: MouseEvent) => {
    e.preventDefault()
    setIsDragging(true)
    startPos.current = direction === 'horizontal' ? e.clientY : e.clientX
  }, [direction])

  useEffect(() => {
    if (!isDragging) return

    const handleMouseMove = (e: globalThis.MouseEvent) => {
      const currentPos = direction === 'horizontal' ? e.clientY : e.clientX
      const delta = currentPos - startPos.current
      startPos.current = currentPos
      onResize(delta)
    }

    const handleMouseUp = () => {
      setIsDragging(false)
      onResizeEnd()
    }

    document.addEventListener('mousemove', handleMouseMove)
    document.addEventListener('mouseup', handleMouseUp)

    return () => {
      document.removeEventListener('mousemove', handleMouseMove)
      document.removeEventListener('mouseup', handleMouseUp)
    }
  }, [isDragging, direction, onResize, onResizeEnd])

  return (
    <div
      ref={handleRef}
      onMouseDown={handleMouseDown}
      style={{
        position: 'absolute',
        [direction === 'horizontal' ? 'height' : 'width']: '6px',
        [direction === 'horizontal' ? 'width' : 'height']: '100%',
        [direction === 'horizontal' ? 'left' : 'top']: 0,
        cursor: direction === 'horizontal' ? 'row-resize' : 'col-resize',
        backgroundColor: isDragging ? settings.theme.cyan : 'transparent',
        zIndex: 50,
        transition: 'background-color 0.15s ease',
      }}
      onMouseEnter={(e) => {
        if (!isDragging) {
          e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}80`
        }
      }}
      onMouseLeave={(e) => {
        if (!isDragging) {
          e.currentTarget.style.backgroundColor = 'transparent'
        }
      }}
    >
      <div
        style={{
          position: 'absolute',
          [direction === 'horizontal' ? 'top' : 'left']: '50%',
          [direction === 'horizontal' ? 'left' : 'top']: '50%',
          transform: 'translate(-50%, -50%)',
          [direction === 'horizontal' ? 'width' : 'height']: '30px',
          [direction === 'horizontal' ? 'height' : 'width']: '2px',
          backgroundColor: settings.theme.cyan,
          borderRadius: '1px',
          opacity: isDragging ? 1 : 0,
          transition: 'opacity 0.15s ease, background-color 0.15s ease',
        }}
      />
    </div>
  )
}

function SplitPaneContainer({ split, renderPane }: { split: SplitPaneType; renderPane: (pane: TerminalPane) => ReactNode }) {
  const { resizeSplit } = useTabs()
  const containerRef = useRef<HTMLDivElement>(null)

  const handleResize = useCallback((delta: number) => {
    if (!containerRef.current) return
    const containerSize = split.direction === 'horizontal'
      ? containerRef.current.clientHeight
      : containerRef.current.clientWidth
    const deltaRatio = delta / containerSize
    resizeSplit(split.id, split.ratio + deltaRatio)
  }, [split.id, split.ratio, split.direction, resizeSplit])

  const handleResizeEnd = useCallback(() => {
    // Could save to persistent storage here
  }, [])

  const firstSize = `${split.ratio * 100}%`
  const secondSize = `${(1 - split.ratio) * 100}%`

  return (
    <div
      ref={containerRef}
      style={{
        display: 'flex',
        flexDirection: split.direction === 'horizontal' ? 'column' : 'row',
        width: '100%',
        height: '100%',
        position: 'relative',
      }}
    >
      <div style={{ [split.direction === 'horizontal' ? 'height' : 'width']: firstSize, position: 'relative', overflow: 'hidden' }}>
        <SplitPane node={split.first} renderPane={renderPane} />
      </div>
      <div style={{ position: 'relative', [split.direction === 'horizontal' ? 'height' : 'width']: '1px', zIndex: 50 }}>
        <ResizeHandle
          direction={split.direction}
          onResize={handleResize}
          onResizeEnd={handleResizeEnd}
        />
      </div>
      <div style={{ [split.direction === 'horizontal' ? 'height' : 'width']: secondSize, position: 'relative', overflow: 'hidden' }}>
        <SplitPane node={split.second} renderPane={renderPane} />
      </div>
    </div>
  )
}

export function SplitPane({ node, renderPane }: SplitPaneProps) {
  if (isTerminalPane(node)) {
    return <>{renderPane(node)}</>
  }

  if (isWebViewPane(node)) {
    return <WebViewPane key={node.id} pane={node} />
  }

  if (isWidgetPane(node)) {
    return <WidgetPane key={node.id} pane={node} />
  }

  if (isEditorPane(node)) {
    return <EditorPane key={node.id} pane={node} />
  }

  if (isSplitPane(node)) {
    return <SplitPaneContainer key={node.id} split={node} renderPane={renderPane} />
  }

  return null
}

// Context menu for split operations
interface SplitContextMenuProps {
  x: number
  y: number
  paneId: string
  onClose: () => void
  onSplitLeft: () => void
  onSplitRight: () => void
  onSplitTop: () => void
  onSplitBottom: () => void
  onSplitWithWebview?: (direction: 'horizontal' | 'vertical', url: string) => void
  onClosePane: () => void
  canClose: boolean
}

export function SplitContextMenu({
  x,
  y,
  onClose,
  onSplitLeft,
  onSplitRight,
  onSplitTop,
  onSplitBottom,
  onSplitWithWebview,
  onClosePane,
  canClose,
}: SplitContextMenuProps) {
  const { settings } = useTerminalSettings()
  const [showWebviewInput, setShowWebviewInput] = useState(false)
  const [webviewUrl, setWebviewUrl] = useState('https://')
  const urlInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const handleClickOutside = (e: globalThis.MouseEvent) => {
      // Don't close if clicking inside the menu
      const target = e.target as HTMLElement
      if (target.closest('[data-context-menu]')) return
      onClose()
    }
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (showWebviewInput) {
          setShowWebviewInput(false)
          setWebviewUrl('https://')
        } else {
          onClose()
        }
      }
    }

    document.addEventListener('click', handleClickOutside)
    document.addEventListener('keydown', handleEscape)

    return () => {
      document.removeEventListener('click', handleClickOutside)
      document.removeEventListener('keydown', handleEscape)
    }
  }, [onClose, showWebviewInput])

  // Focus URL input when shown
  useEffect(() => {
    if (showWebviewInput && urlInputRef.current) {
      urlInputRef.current.focus()
      urlInputRef.current.select()
    }
  }, [showWebviewInput])

  const menuItemStyle = {
    padding: '8px 16px',
    cursor: 'pointer',
    fontSize: '13px',
    display: 'flex',
    alignItems: 'center',
    gap: '12px',
    color: settings.theme.foreground,
    transition: 'background-color 0.1s ease',
  }

  const handleSplitWithWebview = (direction: 'horizontal' | 'vertical') => {
    if (webviewUrl && webviewUrl !== 'https://' && onSplitWithWebview) {
      onSplitWithWebview(direction, webviewUrl)
      onClose()
    }
  }

  const isValidUrl = webviewUrl && webviewUrl !== 'https://' && webviewUrl.length > 8

  return (
    <div
      data-context-menu
      style={{
        position: 'fixed',
        left: x,
        top: y,
        backgroundColor: settings.theme.background,
        border: `1px solid ${settings.theme.brightBlack}`,
        borderRadius: '8px',
        padding: '4px 0',
        zIndex: 1000,
        boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
        minWidth: '180px',
      }}
      onClick={(e) => e.stopPropagation()}
    >
      <div
        style={menuItemStyle}
        onClick={onSplitLeft}
        onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40` }}
        onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
      >
        <span style={{ width: '16px' }}>←</span>
        <span>Split Left</span>
        <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>⌘D</span>
      </div>
      <div
        style={menuItemStyle}
        onClick={onSplitRight}
        onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40` }}
        onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
      >
        <span style={{ width: '16px' }}>→</span>
        <span>Split Right</span>
        <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>⌘D</span>
      </div>
      <div
        style={menuItemStyle}
        onClick={onSplitTop}
        onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40` }}
        onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
      >
        <span style={{ width: '16px' }}>↑</span>
        <span>Split Top</span>
        <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>⇧⌘D</span>
      </div>
      <div
        style={menuItemStyle}
        onClick={onSplitBottom}
        onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40` }}
        onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
      >
        <span style={{ width: '16px' }}>↓</span>
        <span>Split Bottom</span>
        <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>⇧⌘D</span>
      </div>

      {onSplitWithWebview && (
        <>
          <div style={{ height: '1px', backgroundColor: settings.theme.brightBlack, margin: '4px 0' }} />
          {!showWebviewInput ? (
            <div
              style={menuItemStyle}
              onClick={() => setShowWebviewInput(true)}
              onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}40` }}
              onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
            >
              <span style={{ width: '16px' }}>🌐</span>
              <span>Split with Webview...</span>
              <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>▶</span>
            </div>
          ) : (
            <div style={{ padding: '8px 12px' }}>
              <input
                ref={urlInputRef}
                type="text"
                value={webviewUrl}
                onChange={(e) => setWebviewUrl(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && isValidUrl) {
                    handleSplitWithWebview('vertical')
                  }
                }}
                placeholder="Enter URL..."
                style={{
                  width: '100%',
                  padding: '6px 8px',
                  borderRadius: '4px',
                  border: `1px solid ${settings.theme.brightBlack}`,
                  backgroundColor: `${settings.theme.background}`,
                  color: settings.theme.foreground,
                  fontSize: '12px',
                  marginBottom: '8px',
                  outline: 'none',
                }}
              />
              <div style={{ display: 'flex', gap: '4px', justifyContent: 'center' }}>
                <button
                  onClick={() => handleSplitWithWebview('vertical')}
                  disabled={!isValidUrl}
                  title="Split Left"
                  style={{
                    padding: '6px 10px',
                    borderRadius: '4px',
                    border: 'none',
                    backgroundColor: isValidUrl ? settings.theme.cyan : settings.theme.brightBlack,
                    color: isValidUrl ? settings.theme.background : settings.theme.foreground,
                    cursor: isValidUrl ? 'pointer' : 'not-allowed',
                    fontSize: '14px',
                    opacity: isValidUrl ? 1 : 0.5,
                  }}
                >
                  ←
                </button>
                <button
                  onClick={() => handleSplitWithWebview('vertical')}
                  disabled={!isValidUrl}
                  title="Split Right"
                  style={{
                    padding: '6px 10px',
                    borderRadius: '4px',
                    border: 'none',
                    backgroundColor: isValidUrl ? settings.theme.cyan : settings.theme.brightBlack,
                    color: isValidUrl ? settings.theme.background : settings.theme.foreground,
                    cursor: isValidUrl ? 'pointer' : 'not-allowed',
                    fontSize: '14px',
                    opacity: isValidUrl ? 1 : 0.5,
                  }}
                >
                  →
                </button>
                <button
                  onClick={() => handleSplitWithWebview('horizontal')}
                  disabled={!isValidUrl}
                  title="Split Top"
                  style={{
                    padding: '6px 10px',
                    borderRadius: '4px',
                    border: 'none',
                    backgroundColor: isValidUrl ? settings.theme.cyan : settings.theme.brightBlack,
                    color: isValidUrl ? settings.theme.background : settings.theme.foreground,
                    cursor: isValidUrl ? 'pointer' : 'not-allowed',
                    fontSize: '14px',
                    opacity: isValidUrl ? 1 : 0.5,
                  }}
                >
                  ↑
                </button>
                <button
                  onClick={() => handleSplitWithWebview('horizontal')}
                  disabled={!isValidUrl}
                  title="Split Bottom"
                  style={{
                    padding: '6px 10px',
                    borderRadius: '4px',
                    border: 'none',
                    backgroundColor: isValidUrl ? settings.theme.cyan : settings.theme.brightBlack,
                    color: isValidUrl ? settings.theme.background : settings.theme.foreground,
                    cursor: isValidUrl ? 'pointer' : 'not-allowed',
                    fontSize: '14px',
                    opacity: isValidUrl ? 1 : 0.5,
                  }}
                >
                  ↓
                </button>
              </div>
            </div>
          )}
        </>
      )}

      {canClose && (
        <>
          <div style={{ height: '1px', backgroundColor: settings.theme.brightBlack, margin: '4px 0' }} />
          <div
            style={{ ...menuItemStyle, color: settings.theme.red }}
            onClick={onClosePane}
            onMouseEnter={(e) => { e.currentTarget.style.backgroundColor = `${settings.theme.red}20` }}
            onMouseLeave={(e) => { e.currentTarget.style.backgroundColor = 'transparent' }}
          >
            <span style={{ width: '16px' }}>✕</span>
            <span>Close Pane</span>
            <span style={{ marginLeft: 'auto', color: settings.theme.brightBlack, fontSize: '12px' }}>⌘W</span>
          </div>
        </>
      )}
    </div>
  )
}

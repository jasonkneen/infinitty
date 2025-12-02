import { useState, useRef, useEffect } from 'react'
import { PanelRightClose } from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'

interface RightPanelProps {
  isOpen: boolean
  onToggle: () => void
}

export function RightPanel({ isOpen, onToggle }: RightPanelProps) {
  const { settings } = useTerminalSettings()
  const [width, setWidth] = useState(320)
  const [isResizing, setIsResizing] = useState(false)
  const panelRef = useRef<HTMLDivElement>(null)
  const minWidth = 280
  const maxWidth = 500

  // Handle resize
  useEffect(() => {
    if (!isResizing) return

    const handleMouseMove = (e: MouseEvent) => {
      if (!panelRef.current) return
      const distanceFromRight = window.innerWidth - e.clientX
      const newWidth = Math.max(minWidth, Math.min(maxWidth, distanceFromRight))
      setWidth(newWidth)
    }

    const handleMouseUp = () => {
      setIsResizing(false)
    }

    document.addEventListener('mousemove', handleMouseMove)
    document.addEventListener('mouseup', handleMouseUp)

    return () => {
      document.removeEventListener('mousemove', handleMouseMove)
      document.removeEventListener('mouseup', handleMouseUp)
    }
  }, [isResizing])

  return (
    <aside
      ref={panelRef}
      style={{
        width: isOpen ? `${width}px` : '0',
        minWidth: isOpen ? `${width}px` : '0',
        opacity: isOpen ? 1 : 0,
        transition: isResizing ? 'none' : 'opacity 0.2s ease',
        backgroundColor: 'transparent',
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        borderLeft: `1px solid ${settings.theme.brightBlack}40`,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        color: settings.theme.foreground,
      } as React.CSSProperties}
    >
      {/* Background layer */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          backgroundColor: settings.theme.background,
          opacity: settings.window.opacity / 100,
          zIndex: 0,
        }}
      />

      {/* Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 12px',
          borderBottom: `1px solid ${settings.theme.brightBlack}40`,
          minHeight: '44px',
          position: 'relative',
          zIndex: 1,
        }}
      >
        <span
          style={{
            fontSize: '12px',
            fontWeight: 600,
            color: settings.theme.brightBlack,
            textTransform: 'uppercase',
            letterSpacing: '0.5px',
          }}
        >
          Panel
        </span>

        <button
          onClick={onToggle}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            cursor: 'pointer',
            color: settings.theme.brightBlack,
            transition: 'all 0.15s ease',
            borderRadius: '4px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = `${settings.theme.brightBlack}20`
            e.currentTarget.style.color = settings.theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.backgroundColor = 'transparent'
            e.currentTarget.style.color = settings.theme.brightBlack
          }}
          title="Close panel"
        >
          <PanelRightClose size={16} />
        </button>
      </div>

      {/* Content area - placeholder for future views */}
      <div
        style={{
          flex: 1,
          overflow: 'auto',
          padding: '12px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: settings.theme.brightBlack,
          fontSize: '13px',
          textAlign: 'center',
          position: 'relative',
          zIndex: 1,
        }}
      >
        <div style={{ padding: '16px', lineHeight: '1.5' }}>
          Ready for your content
        </div>
      </div>

      {/* Left edge resizer */}
      <div
        onMouseDown={() => setIsResizing(true)}
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          bottom: 0,
          width: '4px',
          cursor: 'col-resize',
          transition: 'background-color 0.15s ease',
          backgroundColor: 'transparent',
          zIndex: 2,
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.backgroundColor = `${settings.theme.cyan}40`
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.backgroundColor = 'transparent'
        }}
      />
    </aside>
  )
}

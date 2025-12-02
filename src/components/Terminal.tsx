import { useRef, useEffect, useImperativeHandle, forwardRef, useMemo } from 'react'
import { useTerminal } from '../hooks/useTerminal'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { themeToXterm } from '../config/terminal'
import '@xterm/xterm/css/xterm.css'

// Convert hex color to rgba with alpha
function hexToRgba(hex: string, alpha: number): string {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

interface TerminalProps {
  onData?: (data: string) => void
  onExit?: (code: number) => void
  onLinkClick?: (url: string) => void // Custom handler for link clicks
  onFilePathClick?: (path: string) => void // Handler for cmd+click on file paths
  onPwdChange?: (path: string) => void // Called when current directory changes
  className?: string
  persistKey?: string // Key to persist terminal across React remounts
}

export interface TerminalHandle {
  write: (data: string) => void
  clear: () => void
  focus: () => void
}

export const Terminal = forwardRef<TerminalHandle, TerminalProps>(
  function Terminal({ onData, onExit, onLinkClick, onFilePathClick, onPwdChange, className = '', persistKey }, ref) {
    const containerRef = useRef<HTMLDivElement>(null)
    const { settings } = useTerminalSettings()

    // Calculate window alpha for transparency support
    const windowAlpha = settings.window.opacity / 100

    // Convert settings to xterm options - memoize by theme id to avoid unnecessary recalculations
    const terminalTheme = useMemo(() => {
      const xtermTheme = themeToXterm(settings.theme)
      if (windowAlpha < 1) {
        // Use low-opacity background for window transparency
        // Note: Canvas renderer doesn't support full transparency,
        // but we can use a very low alpha to achieve near-transparency
        return {
          ...xtermTheme,
          background: hexToRgba(settings.theme.background, windowAlpha * 0.3),
        }
      }
      return xtermTheme
    }, [settings.theme, windowAlpha])

    const { isReady, write, clear, focus } = useTerminal(containerRef, {
      onData,
      onExit,
      onLinkClick,
      onFilePathClick,
      onPwdChange,
      persistKey,
      fontSize: settings.fontSize,
      fontFamily: settings.font.family,
      fontWeight: settings.fontThicken ? 'bold' : 'normal',
      // xterm.js requires lineHeight >= 1, clamp for terminal only
      lineHeight: Math.max(1, settings.lineHeight),
      letterSpacing: settings.letterSpacing,
      cursorBlink: settings.cursorBlink,
      cursorStyle: settings.cursorStyle,
      scrollback: settings.scrollback,
      theme: terminalTheme,
    })

    // Expose methods to parent via ref
    useImperativeHandle(ref, () => ({
      write: (data: string) => {
        write(data)
      },
      clear: () => {
        clear()
      },
      focus: () => {
        focus()
      },
    }), [write, clear, focus])

    // Auto-focus terminal when ready
    useEffect(() => {
      if (isReady) {
        focus()
      }
    }, [isReady, focus])

    return (
      <div
        className={`terminal-wrapper ${className}`}
        style={{
          width: '100%',
          height: '100%',
          backgroundColor: 'transparent',
          padding: '10px 10px 12px 10px',
          boxSizing: 'border-box',
        }}
      >
        <div
          ref={containerRef}
          className="terminal-container"
          style={{
            width: '100%',
            height: '100%',
            position: 'relative',
            zIndex: 1,
          }}
        />
      </div>
    )
  }
)

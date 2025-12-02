import { useEffect, useRef, useState, useCallback } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { spawn, type IPty } from 'tauri-pty'
import { Maximize2, Minimize2, X } from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { themeToXterm } from '../config/terminal'
import type { InteractiveBlock as InteractiveBlockType } from '../types/blocks'

interface InteractiveBlockProps {
  block: InteractiveBlockType
  isExpanded: boolean
  onToggleExpand: () => void
  onExit: (exitCode: number) => void
  onDismiss?: () => void
  isFocused?: boolean
}

// Standard terminal height - approximately 48 rows
const STANDARD_TERMINAL_HEIGHT = '640px'
const COLLAPSED_HEIGHT = '44px' // Just the header

export function InteractiveBlock({ block, isExpanded, onToggleExpand, onExit, onDismiss, isFocused }: InteractiveBlockProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const xtermTheme = themeToXterm(theme)

  const terminalRef = useRef<HTMLDivElement>(null)
  const xtermRef = useRef<Terminal | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)
  const webglAddonRef = useRef<WebglAddon | null>(null)
  const ptyRef = useRef<IPty | null>(null)
  const [isReady, setIsReady] = useState(false)
  const [isCollapsed, setIsCollapsed] = useState(false)

  // Use refs for callbacks to avoid useEffect re-runs
  const onExitRef = useRef(onExit)
  onExitRef.current = onExit

  // Initialize terminal and PTY
  useEffect(() => {
    if (!terminalRef.current || xtermRef.current) return

    const term = new Terminal({
      cursorBlink: settings.cursorBlink,
      cursorStyle: settings.cursorStyle,
      fontSize: settings.fontSize,
      fontFamily: settings.font.family,
      convertEol: false, // Don't convert CR to CRLF - let PTY handle it
      lineHeight: settings.lineHeight,
      theme: xtermTheme,
      allowTransparency: true,
      scrollback: settings.scrollback,
    })

    const fitAddon = new FitAddon()
    const webLinksAddon = new WebLinksAddon()

    term.loadAddon(fitAddon)
    term.loadAddon(webLinksAddon)
    term.open(terminalRef.current)

    // Load WebGL addon for GPU-accelerated rendering (much lower CPU)
    try {
      const webglAddon = new WebglAddon()
      term.loadAddon(webglAddon)
      webglAddonRef.current = webglAddon
      webglAddon.onContextLoss(() => {
        webglAddon.dispose()
        webglAddonRef.current = null
      })
    } catch (e) {
      console.warn('WebGL addon not available, using canvas renderer')
    }

    xtermRef.current = term
    fitAddonRef.current = fitAddon

    // Fit after container is rendered, then mark ready
    setTimeout(() => {
      fitAddon.fit()
      // Double-fit to ensure accurate sizing
      requestAnimationFrame(() => {
        fitAddon.fit()
        setIsReady(true)
      })
    }, 100)

    return () => {
      // Kill PTY first to stop any pending writes
      if (ptyRef.current) {
        ptyRef.current.kill()
        ptyRef.current = null
      }
      // Dispose WebGL addon before terminal to prevent context leaks
      if (webglAddonRef.current) {
        webglAddonRef.current.dispose()
        webglAddonRef.current = null
      }
      // Clear scrollback buffer before dispose to free memory
      term.clear()
      term.dispose()
      xtermRef.current = null
      fitAddonRef.current = null
    }
  }, [])

  // Spawn PTY and run command when ready
  useEffect(() => {
    if (!isReady || !xtermRef.current || ptyRef.current) return

    const shell = navigator.platform.includes('Mac') ? '/bin/zsh' : '/bin/bash'

    try {
      const pty = spawn(shell, ['-c', block.command], {
        cols: xtermRef.current.cols,
        rows: xtermRef.current.rows,
        env: {
          TERM: 'xterm-256color',
          COLORTERM: 'truecolor',
        },
      })

      ptyRef.current = pty

      // Ensure PTY size matches terminal after initialization
      requestAnimationFrame(() => {
        if (fitAddonRef.current && xtermRef.current && ptyRef.current) {
          fitAddonRef.current.fit()
          ptyRef.current.resize(xtermRef.current.cols, xtermRef.current.rows)
        }
      })

      // Connect PTY output to terminal
      pty.onData((data: string) => {
        xtermRef.current?.write(data)
      })

      // Handle PTY exit
      pty.onExit((e: { exitCode: number }) => {
        onExitRef.current(e.exitCode)
      })

      // Connect terminal input to PTY
      xtermRef.current.onData((data: string) => {
        pty.write(data)
      })

      // Focus the terminal
      xtermRef.current.focus()
    } catch (error) {
      console.error('Failed to spawn interactive PTY:', error)
      xtermRef.current?.write(`\r\nError: Failed to run command: ${block.command}\r\n`)
    }

    return () => {
      ptyRef.current?.kill()
      ptyRef.current = null
    }
  }, [isReady, block.command])

  // Handle resize - use ResizeObserver for container size changes
  useEffect(() => {
    const handleResize = () => {
      if (fitAddonRef.current && xtermRef.current && ptyRef.current) {
        fitAddonRef.current.fit()
        ptyRef.current.resize(xtermRef.current.cols, xtermRef.current.rows)
      }
    }

    // ResizeObserver catches sidebar open/close and other layout changes
    const resizeObserver = new ResizeObserver(() => {
      handleResize()
    })

    if (terminalRef.current) {
      resizeObserver.observe(terminalRef.current)
    }

    window.addEventListener('resize', handleResize)

    // Also resize when expanded state changes
    setTimeout(handleResize, 100)

    return () => {
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleResize)
    }
  }, [isExpanded])

  // Kill the process and dismiss the block (show minimal status line)
  const handleKill = useCallback(() => {
    if (ptyRef.current) {
      ptyRef.current.kill()
      ptyRef.current = null
    }

    // If onDismiss is provided, use it to show minimal status line
    if (onDismiss) {
      onDismiss()
    } else {
      // Fallback: collapse the block when killed
      setIsCollapsed(true)
      // Force exit callback in case PTY doesn't fire onExit
      onExitRef.current(130) // 130 = killed by signal (128 + SIGINT)
    }
  }, [onDismiss])

  return (
    <div
      style={{
        backgroundColor: isFocused ? `${theme.brightBlack}40` : `${theme.brightBlack}20`,
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        // Explicit borders to ensure left border persists
        borderTop: `1px solid ${isFocused ? `${theme.cyan}40` : `${theme.white}10`}`,
        borderRight: `1px solid ${isFocused ? `${theme.cyan}40` : `${theme.white}10`}`,
        borderBottom: `1px solid ${isFocused ? `${theme.cyan}40` : `${theme.white}10`}`,
        borderLeft: `6px solid ${theme.cyan}`,
        borderRadius: '0 12px 12px 0',
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        height: isCollapsed ? COLLAPSED_HEIGHT : (isExpanded ? STANDARD_TERMINAL_HEIGHT : '200px'),
        minHeight: isCollapsed ? COLLAPSED_HEIGHT : '120px',
        transition: 'height 0.2s ease, background-color 0.2s ease, border-color 0.2s ease',
        boxShadow: isFocused ? `0 4px 12px rgba(0, 0, 0, 0.2)` : 'none',
      }}
    >
      {/* Header - always visible with controls */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '10px 16px',
          borderBottom: `1px solid ${theme.white}10`,
          backgroundColor: 'transparent',
          flexShrink: 0,
          minHeight: '44px',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flex: 1, minWidth: 0, overflow: 'hidden' }}>
          <span
            style={{
              width: '8px',
              height: '8px',
              borderRadius: '50%',
              backgroundColor: block.isRunning ? theme.cyan : theme.white,
              animation: block.isRunning ? 'pulse 1.5s infinite' : 'none',
              flexShrink: 0,
            }}
          />
          <span style={{ fontFamily: settings.font.family, fontSize: '13px', color: theme.white, flexShrink: 0 }}>
            {block.cwd}
          </span>
          <span style={{ fontFamily: settings.font.family, fontSize: '14px', color: theme.blue, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {block.command}
          </span>
        </div>

        {/* Controls - always visible */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '4px', flexShrink: 0, marginLeft: '12px' }}>
          <button
            onClick={(e) => {
              e.stopPropagation()
              if (isCollapsed) {
                setIsCollapsed(false)
              } else {
                onToggleExpand()
              }
            }}
            style={{
              padding: '6px',
              backgroundColor: 'transparent',
              border: 'none',
              cursor: 'pointer',
              color: theme.white,
              borderRadius: '4px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
            title={isCollapsed ? 'Expand' : (isExpanded ? 'Collapse' : 'Expand')}
          >
            {isCollapsed ? <Maximize2 size={14} /> : (isExpanded ? <Minimize2 size={14} /> : <Maximize2 size={14} />)}
          </button>
          <button
            onClick={(e) => { e.stopPropagation(); handleKill(); }}
            style={{
              padding: '6px',
              backgroundColor: block.isRunning ? `${theme.red}26` : 'transparent',
              border: 'none',
              cursor: 'pointer',
              color: theme.red,
              borderRadius: '4px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
            title="Kill process"
          >
            <X size={14} />
          </button>
        </div>
      </div>

      {/* Terminal - hidden when collapsed */}
      {!isCollapsed && (
        <div
          ref={terminalRef}
          style={{
            flex: 1,
            padding: '8px',
            minHeight: 0,
          }}
          onClick={() => xtermRef.current?.focus()}
        />
      )}

    </div>
  )
}

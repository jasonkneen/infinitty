import { useEffect, useRef, useCallback, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { CanvasAddon } from '@xterm/addon-canvas'
import { spawn, type IPty } from 'tauri-pty'
import { getErrorMessage } from '../lib/utils'
import { getEnvWithPath } from '../lib/shellEnv'
import { FONTS_LOADED_EVENT } from '../components/FontLoader'

// Global registry to persist terminals across React remounts
interface TerminalInstance {
  terminal: Terminal
  pty: IPty
  fitAddon: FitAddon
}

const terminalRegistry = new Map<string, TerminalInstance>()

// Clean up a persisted terminal (call when pane is permanently closed)
export function destroyPersistedTerminal(persistKey: string): void {
  const instance = terminalRegistry.get(persistKey)
  if (instance) {
    instance.pty.kill()
    instance.terminal.dispose()
    terminalRegistry.delete(persistKey)
  }
}

// Write to a terminal by its persist key (for external control like file explorer)
export function writeToTerminalByKey(persistKey: string, data: string): boolean {
  const instance = terminalRegistry.get(persistKey)
  if (instance) {
    instance.pty.write(data)
    return true
  }
  return false
}

// Check if a terminal exists in the registry
export function hasTerminal(persistKey: string): boolean {
  return terminalRegistry.has(persistKey)
}

interface UseTerminalOptions {
  shell?: string
  onData?: (data: string) => void
  onExit?: (code: number) => void
  onLinkClick?: (url: string) => void // Custom handler for link clicks
  onFilePathClick?: (path: string) => void // Custom handler for file/directory path clicks
  onPwdChange?: (path: string) => void // Called when current directory changes
  persistKey?: string // Key to persist terminal across remounts
  // Terminal appearance options
  fontSize?: number
  fontFamily?: string
  fontWeight?: 'normal' | 'bold' | '100' | '200' | '300' | '400' | '500' | '600' | '700' | '800' | '900'
  lineHeight?: number
  letterSpacing?: number
  cursorBlink?: boolean
  cursorStyle?: 'block' | 'underline' | 'bar'
  scrollback?: number
  theme?: {
    background?: string
    foreground?: string
    cursor?: string
    cursorAccent?: string
    selectionBackground?: string
    black?: string
    red?: string
    green?: string
    yellow?: string
    blue?: string
    magenta?: string
    cyan?: string
    white?: string
    brightBlack?: string
    brightRed?: string
    brightGreen?: string
    brightYellow?: string
    brightBlue?: string
    brightMagenta?: string
    brightCyan?: string
    brightWhite?: string
  }
}

export function useTerminal(containerRef: React.RefObject<HTMLDivElement | null>, options: UseTerminalOptions = {}) {
  const terminalRef = useRef<Terminal | null>(null)
  const ptyRef = useRef<IPty | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)
  const [isReady, setIsReady] = useState(false)

  // Store options in refs to avoid recreating initTerminal on every render
  const optionsRef = useRef(options)
  optionsRef.current = options

  const getDefaultShell = useCallback(() => {
    // Default shells by platform
    if (navigator.platform.includes('Mac')) return '/bin/zsh'
    if (navigator.platform.includes('Win')) return 'powershell.exe'
    return '/bin/bash'
  }, [])

  const initTerminal = useCallback(async () => {
    if (!containerRef.current) return

    const persistKey = optionsRef.current.persistKey

    // Check if we have a persisted terminal for this key
    if (persistKey && terminalRegistry.has(persistKey)) {
      const existing = terminalRegistry.get(persistKey)!

      // Move the terminal's DOM element to the new container
      // xterm.js creates a .terminal element inside the container
      const terminalElement = existing.terminal.element
      if (terminalElement) {
        // Always try to append - the element may have been detached from its old parent
        containerRef.current.appendChild(terminalElement)

        // Apply current settings to the restored terminal
        // (settings may have changed while terminal was persisted)
        const term = existing.terminal
        const opts = optionsRef.current
        if (opts.fontSize !== undefined) term.options.fontSize = opts.fontSize
        if (opts.fontFamily !== undefined) term.options.fontFamily = opts.fontFamily
        if (opts.fontWeight !== undefined) term.options.fontWeight = opts.fontWeight
        if (opts.lineHeight !== undefined) term.options.lineHeight = opts.lineHeight
        if (opts.letterSpacing !== undefined) term.options.letterSpacing = opts.letterSpacing
        if (opts.cursorBlink !== undefined) term.options.cursorBlink = opts.cursorBlink
        if (opts.cursorStyle !== undefined) term.options.cursorStyle = opts.cursorStyle
        if (opts.scrollback !== undefined) term.options.scrollback = opts.scrollback
        if (opts.theme !== undefined) term.options.theme = opts.theme

        // Force aggressive font cache clear when restoring
        // The CanvasAddon caches font glyphs, so we need to force recalculation
        const currentSize = term.options.fontSize ?? 14
        term.options.fontSize = currentSize + 0.1
        term.refresh(0, term.rows - 1)
        requestAnimationFrame(() => {
          term.options.fontSize = currentSize
          term.refresh(0, term.rows - 1)
          existing.fitAddon.fit()
          existing.pty.resize(term.cols, term.rows)
        })

        terminalRef.current = existing.terminal
        ptyRef.current = existing.pty
        fitAddonRef.current = existing.fitAddon
        setIsReady(true)
        return
      }
      // If terminal element doesn't exist, fall through to create new terminal
      // and clean up the orphaned registry entry
      terminalRegistry.delete(persistKey)
    }

    // Don't reinitialize if already have a terminal
    if (terminalRef.current) return

    // Create terminal instance with options from props (or defaults)
    const terminal = new Terminal({
      cursorBlink: optionsRef.current.cursorBlink ?? true,
      cursorStyle: optionsRef.current.cursorStyle ?? 'bar',
      fontSize: optionsRef.current.fontSize ?? 14,
      fontFamily: optionsRef.current.fontFamily ?? 'JetBrains Mono, Menlo, Monaco, Consolas, monospace',
      fontWeight: optionsRef.current.fontWeight ?? 'normal',
      fontWeightBold: 'bold',
      lineHeight: optionsRef.current.lineHeight ?? 1.2,
      letterSpacing: optionsRef.current.letterSpacing ?? 0,
      scrollback: optionsRef.current.scrollback ?? 1000,
      theme: optionsRef.current.theme ?? {
        background: '#0d1117',
        foreground: '#c9d1d9',
        cursor: '#58a6ff',
        cursorAccent: '#0d1117',
        selectionBackground: 'rgba(88, 166, 255, 0.3)',
        black: '#0d1117',
        red: '#f85149',
        green: '#3fb950',
        yellow: '#d29922',
        blue: '#58a6ff',
        magenta: '#bc8cff',
        cyan: '#39c5cf',
        white: '#8b949e',
        brightBlack: '#6e7681',
        brightRed: '#ffa198',
        brightGreen: '#56d364',
        brightYellow: '#e3b341',
        brightBlue: '#79c0ff',
        brightMagenta: '#d2a8ff',
        brightCyan: '#56d4dd',
        brightWhite: '#f0f6fc',
      },
      allowProposedApi: true,
      allowTransparency: true,  // Enable transparent backgrounds
    })

    // Load addons
    const fitAddon = new FitAddon()

    // WebLinksAddon with custom click handler
    const webLinksAddon = new WebLinksAddon((event, uri) => {
      event.preventDefault()
      // Defensive protocol allowlist.
      if (!/^https?:\/\//i.test(uri)) return
      if (optionsRef.current.onLinkClick) {
        optionsRef.current.onLinkClick(uri)
      } else {
        // Default: open in system browser
        window.open(uri, '_blank')
      }
    })

    terminal.loadAddon(fitAddon)
    terminal.loadAddon(webLinksAddon)

    // File path link provider - detects paths like /Users/... or ~/...
    // Uses cmd+click (meta key) to differentiate from regular text selection
    const filePathRegex = /(?:~\/|\/(?:Users|home|var|tmp|etc|opt|usr|private))[^\s'"`\[\]{}()]+/g
    terminal.registerLinkProvider({
      provideLinks: (bufferLineNumber: number, callback: (links: { text: string; range: { start: { x: number; y: number }; end: { x: number; y: number } }; activate: (event: MouseEvent, text: string) => void; hover?: (event: MouseEvent, text: string) => void }[] | undefined) => void) => {
        const line = terminal.buffer.active.getLine(bufferLineNumber)
        if (!line) {
          callback(undefined)
          return
        }

        const lineText = line.translateToString()
        const links: { text: string; range: { start: { x: number; y: number }; end: { x: number; y: number } }; activate: (event: MouseEvent, text: string) => void; hover?: (event: MouseEvent, text: string) => void }[] = []

        let match
        while ((match = filePathRegex.exec(lineText)) !== null) {
          const startX = match.index + 1 // xterm uses 1-based indexing
          const endX = startX + match[0].length
          links.push({
            text: match[0],
            range: {
              start: { x: startX, y: bufferLineNumber },
              end: { x: endX, y: bufferLineNumber },
            },
            activate: (event: MouseEvent, text: string) => {
              // Only trigger on cmd+click (Mac) or ctrl+click (Windows/Linux)
              if (event.metaKey || event.ctrlKey) {
                event.preventDefault()
                if (optionsRef.current.onFilePathClick) {
                  optionsRef.current.onFilePathClick(text)
                }
              }
            },
            hover: (_event: MouseEvent, _text: string) => {
              // Show tooltip hint on hover
            },
          })
        }

        // Reset regex for next use
        filePathRegex.lastIndex = 0

        callback(links.length > 0 ? links : undefined)
      },
    })

    // Open terminal in container
    terminal.open(containerRef.current)

    // Use Canvas addon for better font rendering quality
    // (WebGL has issues with font rendering on macOS retina displays)
    try {
      const canvasAddon = new CanvasAddon()
      terminal.loadAddon(canvasAddon)
    } catch (error: unknown) {
      console.warn('[Terminal] Canvas addon not available, using default renderer:', getErrorMessage(error))
    }

    // Fit terminal to container
    fitAddon.fit()

    // Store refs
    terminalRef.current = terminal
    fitAddonRef.current = fitAddon

    // Spawn PTY process
    const shell = optionsRef.current.shell || getDefaultShell()
    try {
      // spawn returns synchronously but initializes async internally
      // Use login shell (-l) to source user's shell config (.zshrc, .zprofile)
      // which sets up PATH and other environment variables properly
      const isZsh = shell.includes('zsh')
      const isBash = shell.includes('bash')
      const shellArgs = isZsh || isBash ? ['-l'] : []

      // Get shell environment with proper PATH (fixes GUI app not inheriting shell env)
      const env = await getEnvWithPath()

      const pty = spawn(shell, shellArgs, {
        cols: terminal.cols,
        rows: terminal.rows,
        env,
      })

      ptyRef.current = pty

      // OSC 7 regex for detecting directory change sequences
      // Format: ESC ] 7 ; file://hostname/path ST
      const osc7Regex = /\x1b\]7;file:\/\/[^\/]*([^\x07\x1b]+)(?:\x07|\x1b\\)/g

      // Connect PTY to terminal - events work immediately
      pty.onData((data: string) => {
        terminal.write(data)
        optionsRef.current.onData?.(data)

        // Check for OSC 7 directory change sequences
        if (optionsRef.current.onPwdChange) {
          let match
          while ((match = osc7Regex.exec(data)) !== null) {
            try {
              const path = decodeURIComponent(match[1])
              console.log('[Terminal] OSC 7 detected, path:', path)
              optionsRef.current.onPwdChange(path)
            } catch {
              // Ignore malformed OSC-7 payloads.
            }
          }
          osc7Regex.lastIndex = 0
        }
      })

      pty.onExit((e: { exitCode: number; signal?: number }) => {
        optionsRef.current.onExit?.(e.exitCode)
      })

      // Connect terminal input to PTY
      terminal.onData((data: string) => {
        pty.write(data)
      })

      // Store in registry if persistKey is provided
      if (persistKey) {
        terminalRegistry.set(persistKey, {
          terminal,
          pty,
          fitAddon,
        })
      }

      setIsReady(true)
    } catch (error: unknown) {
      const errorMsg = getErrorMessage(error)
      console.error('[Terminal] Failed to spawn PTY:', errorMsg)
      terminal.write('\r\n\x1b[31mFailed to spawn shell. Make sure you are running in Tauri.\x1b[0m\r\n')
    }
  }, [containerRef, getDefaultShell])

  // Handle resize
  const handleResize = useCallback(() => {
    if (fitAddonRef.current && terminalRef.current && ptyRef.current) {
      fitAddonRef.current.fit()
      ptyRef.current.resize(terminalRef.current.cols, terminalRef.current.rows)
    }
  }, [])

  // Write to terminal
  const write = useCallback((data: string) => {
    ptyRef.current?.write(data)
  }, [])

  // Clear terminal
  const clear = useCallback(() => {
    terminalRef.current?.clear()
  }, [])

  // Focus terminal
  const focus = useCallback(() => {
    terminalRef.current?.focus()
  }, [])

  // Initialize on mount
  useEffect(() => {
    initTerminal()

    return () => {
      const persistKey = optionsRef.current.persistKey

      // If persisted, don't destroy - just detach
      if (persistKey && terminalRegistry.has(persistKey)) {
        // Just clear refs, the terminal lives on in the registry
        terminalRef.current = null
        ptyRef.current = null
        fitAddonRef.current = null
        return
      }

      // Not persisted, clean up fully
      ptyRef.current?.kill()
      terminalRef.current?.dispose()
      terminalRef.current = null
      ptyRef.current = null
    }
  }, [initTerminal])

  // Handle window resize
  useEffect(() => {
    window.addEventListener('resize', handleResize)
    return () => window.removeEventListener('resize', handleResize)
  }, [handleResize])

  // Handle container resize (for split panes) - debounced to prevent flicker
  useEffect(() => {
    if (!containerRef.current) return

    let resizeTimeout: ReturnType<typeof setTimeout> | null = null

    const resizeObserver = new ResizeObserver(() => {
      if (resizeTimeout) clearTimeout(resizeTimeout)
      resizeTimeout = setTimeout(() => {
        handleResize()
      }, 16) // ~60fps debounce
    })

    resizeObserver.observe(containerRef.current)
    return () => {
      if (resizeTimeout) clearTimeout(resizeTimeout)
      resizeObserver.disconnect()
    }
  }, [containerRef, handleResize])

  // Refresh terminal when fonts are loaded (for custom fonts that load async)
  useEffect(() => {
    const handleFontsLoaded = () => {
      if (!terminalRef.current || !fitAddonRef.current) return
      const term = terminalRef.current
      console.log('[Terminal] Fonts loaded, refreshing terminal')
      // Force glyph cache clear by toggling fontSize
      const currentSize = term.options.fontSize ?? 14
      term.options.fontSize = currentSize + 0.1
      requestAnimationFrame(() => {
        term.options.fontSize = currentSize
        term.refresh(0, term.rows - 1)
        fitAddonRef.current?.fit()
        if (ptyRef.current) {
          ptyRef.current.resize(term.cols, term.rows)
        }
      })
    }

    window.addEventListener(FONTS_LOADED_EVENT, handleFontsLoaded)
    return () => window.removeEventListener(FONTS_LOADED_EVENT, handleFontsLoaded)
  }, [])

  // Track previous settings to detect changes
  const prevFontFamilyRef = useRef<string | undefined>(undefined)
  const prevFontSizeRef = useRef<number | undefined>(undefined)
  const prevThemeRef = useRef<typeof options.theme | undefined>(undefined)

  // Update terminal settings when options change
  useEffect(() => {
    if (!terminalRef.current) return
    const term = terminalRef.current

    // Detect if settings actually changed
    const fontFamilyChanged = options.fontFamily !== undefined &&
      options.fontFamily !== prevFontFamilyRef.current
    // Theme is an object, so compare by background color as a simple check
    const themeChanged = options.theme !== undefined &&
      options.theme?.background !== prevThemeRef.current?.background

    // Update tracking refs
    if (options.fontSize !== undefined) prevFontSizeRef.current = options.fontSize
    if (options.fontFamily !== undefined) prevFontFamilyRef.current = options.fontFamily
    if (options.theme !== undefined) prevThemeRef.current = options.theme

    // Update font settings
    if (options.fontSize !== undefined) {
      term.options.fontSize = options.fontSize
    }
    if (options.fontFamily !== undefined) {
      term.options.fontFamily = options.fontFamily
    }
    if (options.fontWeight !== undefined) {
      term.options.fontWeight = options.fontWeight
    }
    if (options.lineHeight !== undefined) {
      term.options.lineHeight = options.lineHeight
    }
    if (options.cursorBlink !== undefined) {
      term.options.cursorBlink = options.cursorBlink
    }
    if (options.cursorStyle !== undefined) {
      term.options.cursorStyle = options.cursorStyle
    }
    if (options.scrollback !== undefined) {
      term.options.scrollback = options.scrollback
    }
    if (options.letterSpacing !== undefined) {
      term.options.letterSpacing = options.letterSpacing
    }
    if (options.theme !== undefined) {
      term.options.theme = options.theme
    }

    // If font family or theme changed, use aggressive refresh to clear caches
    // The CanvasAddon caches font glyphs and colors
    if (fontFamilyChanged || themeChanged) {
      // Force glyph cache clear by temporarily changing fontSize then restoring
      const currentSize = term.options.fontSize ?? 14
      requestAnimationFrame(() => {
        term.options.fontSize = currentSize + 0.1
        requestAnimationFrame(() => {
          term.options.fontSize = currentSize
          term.refresh(0, term.rows - 1)
          if (fitAddonRef.current) {
            fitAddonRef.current.fit()
          }
          if (ptyRef.current) {
            ptyRef.current.resize(term.cols, term.rows)
          }
        })
      })
    } else {
      // Standard refresh for other settings
      term.refresh(0, term.rows - 1)
      if (fitAddonRef.current) {
        fitAddonRef.current.fit()
      }
      if (ptyRef.current) {
        ptyRef.current.resize(term.cols, term.rows)
      }
    }
  }, [
    options.fontSize,
    options.fontFamily,
    options.fontWeight,
    options.lineHeight,
    options.letterSpacing,
    options.cursorBlink,
    options.cursorStyle,
    options.scrollback,
    options.theme,
  ])

  return {
    terminal: terminalRef.current,
    pty: ptyRef.current,
    isReady,
    write,
    clear,
    focus,
    resize: handleResize,
  }
}

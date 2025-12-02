import { useState, useCallback, useRef, useEffect } from 'react'
import { RotateCw, Home, ExternalLink, X, MousePointer2, Check } from 'lucide-react'
import { invoke } from '@tauri-apps/api/core'
import { useTabs } from '../contexts/TabsContext'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { useElementSelector, type ElementContext } from '../hooks/useElementSelector'
import { WEBVIEW_CAPTURE_EVENT, WEBVIEW_RESTORE_EVENT, captureWebviewScreenshot } from '../hooks/useWebviewOverlay'
import type { WebViewPane as WebViewPaneType } from '../types/tabs'

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

interface WebViewPaneProps {
  pane: WebViewPaneType
}

export function WebViewPane({ pane }: WebViewPaneProps) {
  const { activePaneId, setActivePane, closePane } = useTabs()
  const { settings } = useTerminalSettings()
  const [currentUrl, setCurrentUrl] = useState(pane.url)
  const [inputUrl, setInputUrl] = useState(pane.url)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [showCopiedToast, setShowCopiedToast] = useState(false)
  const [showSelectorHint, setShowSelectorHint] = useState(false)
  const [isWebviewCreated, setIsWebviewCreated] = useState(false)
  const [screenshotDataUrl, setScreenshotDataUrl] = useState<string | null>(null)
  const [isHiddenForDialog, setIsHiddenForDialog] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const webviewId = useRef(`webview-${pane.id}`)

  const isActive = pane.id === activePaneId

  // Element selector hook
  const {
    isActive: isSelectorActive,
    toggleSelector,
    copyContextToClipboard,
  } = useElementSelector({
    webviewId: webviewId.current,
    onElementSelected: () => {
      setShowCopiedToast(true)
      setTimeout(() => setShowCopiedToast(false), 2000)
    },
  })

  // Show hint on first activation
  const handleToggleSelector = useCallback(() => {
    if (!isSelectorActive) {
      setShowSelectorHint(true)
      setTimeout(() => setShowSelectorHint(false), 4000)
    }
    toggleSelector()
  }, [isSelectorActive, toggleSelector])

  // Listen for element selection events from the webview
  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      if (event.data?.type === '__INFINITTY_ELEMENT_SELECTED') {
        const context = event.data.context as ElementContext
        copyContextToClipboard(context)
      }
    }
    window.addEventListener('message', handleMessage)
    return () => window.removeEventListener('message', handleMessage)
  }, [copyContextToClipboard])

  const handleFocus = useCallback(() => {
    setActivePane(pane.id)
  }, [pane.id, setActivePane])

  // Create and manage the embedded webview
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    let mounted = true

    const createWebview = async () => {
      const rect = container.getBoundingClientRect()

      console.log('[WebViewPane] Creating webview:', {
        id: webviewId.current,
        url: currentUrl,
        rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      })

      // Check if container has valid dimensions
      if (rect.width === 0 || rect.height === 0) {
        console.warn('[WebViewPane] Container has zero dimensions, retrying...')
        setTimeout(createWebview, 200)
        return
      }

      try {
        const result = await invoke('create_embedded_webview', {
          webviewId: webviewId.current,
          url: currentUrl,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        })
        console.log('[WebViewPane] Webview created successfully:', result)

        if (mounted) {
          setIsWebviewCreated(true)
          setIsLoading(false)
          setError(null)
        }
      } catch (err) {
        console.error('[WebViewPane] Failed to create webview:', err)
        if (mounted) {
          setError(String(err))
          setIsLoading(false)
        }
      }
    }

    // Validate URL before attempting to create webview
    if (!currentUrl || currentUrl === 'https://' || currentUrl === 'http://') {
      console.error('[WebViewPane] Invalid URL:', currentUrl)
      setError('Invalid URL. Please enter a valid URL.')
      setIsLoading(false)
      return
    }

    // Small delay to ensure container is properly rendered
    const timer = setTimeout(createWebview, 100)

    return () => {
      mounted = false
      clearTimeout(timer)
    }
  }, []) // Only run once on mount

  // Update webview position when container resizes or moves
  useEffect(() => {
    const container = containerRef.current
    if (!container || !isWebviewCreated) return

    const updateBounds = async () => {
      const rect = container.getBoundingClientRect()
      try {
        // Keep webview positioned within its container bounds
        // Native webviews are positioned absolutely on the window, so we track container position
        await invoke('update_webview_bounds', {
          webviewId: webviewId.current,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        })
      } catch (err) {
        console.error('Failed to update webview bounds:', err)
      }
    }

    // Use ResizeObserver to track size changes
    const resizeObserver = new ResizeObserver(updateBounds)
    resizeObserver.observe(container)

    // Also update on window resize/scroll
    window.addEventListener('resize', updateBounds)
    window.addEventListener('scroll', updateBounds)

    // Listen for webviews-refresh event (triggered when settings dialog closes)
    const handleRefresh = () => updateBounds()
    window.addEventListener('webviews-refresh', handleRefresh)

    // Initial update
    updateBounds()

    return () => {
      resizeObserver.disconnect()
      window.removeEventListener('resize', updateBounds)
      window.removeEventListener('scroll', updateBounds)
      window.removeEventListener('webviews-refresh', handleRefresh)
    }
  }, [isWebviewCreated])

  // Cleanup webview on unmount
  useEffect(() => {
    const id = webviewId.current

    return () => {
      invoke('destroy_webview', { webviewId: id }).catch(err => {
        console.error('Failed to destroy webview:', err)
      })
    }
  }, [])

  // Handle dialog capture/restore events
  // Sequence: capture screenshot → display it → hide webview (seamless swap)
  useEffect(() => {
    if (!isWebviewCreated) return

    const handleCapture = async () => {
      try {
        // 1. Capture screenshot first
        const dataUrl = await captureWebviewScreenshot(webviewId.current)

        // 2. Display screenshot immediately (seamless - user sees same content)
        if (dataUrl) {
          setScreenshotDataUrl(dataUrl)
        }
        setIsHiddenForDialog(true)

        // 3. Now hide the actual webview (move off-screen)
        const container = containerRef.current
        if (container) {
          await invoke('update_webview_bounds', {
            webviewId: webviewId.current,
            x: -10000,
            y: -10000,
            width: container.getBoundingClientRect().width,
            height: container.getBoundingClientRect().height,
          })
        }

        // 4. Signal that this webview is ready (dialog can now open)
        window.dispatchEvent(new CustomEvent('webview-capture-complete', {
          detail: { webviewId: webviewId.current }
        }))
      } catch (err) {
        console.error('[WebViewPane] Failed to capture screenshot:', err)
        // Still hide webview even if screenshot failed
        setIsHiddenForDialog(true)
        window.dispatchEvent(new CustomEvent('webview-capture-complete', {
          detail: { webviewId: webviewId.current }
        }))
      }
    }

    const handleRestore = async () => {
      // Move webview back to position first
      const container = containerRef.current
      if (container) {
        const rect = container.getBoundingClientRect()
        try {
          await invoke('update_webview_bounds', {
            webviewId: webviewId.current,
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height,
          })
        } catch (err) {
          console.error('[WebViewPane] Failed to restore webview position:', err)
        }
      }

      // Then clear screenshot and state
      setScreenshotDataUrl(null)
      setIsHiddenForDialog(false)
    }

    window.addEventListener(WEBVIEW_CAPTURE_EVENT, handleCapture)
    window.addEventListener(WEBVIEW_RESTORE_EVENT, handleRestore)

    return () => {
      window.removeEventListener(WEBVIEW_CAPTURE_EVENT, handleCapture)
      window.removeEventListener(WEBVIEW_RESTORE_EVENT, handleRestore)
    }
  }, [isWebviewCreated])

  const handleNavigate = useCallback(async (input: string) => {
    const trimmed = input.trim()
    if (!trimmed) return

    let normalizedUrl: string

    // Check if it looks like a URL
    const looksLikeUrl = /^(https?:\/\/)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(\/.*)?$/.test(trimmed) ||
                         trimmed.startsWith('http://') ||
                         trimmed.startsWith('https://') ||
                         trimmed.includes('localhost')

    if (looksLikeUrl) {
      // It's a URL - add https:// if missing
      if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
        normalizedUrl = 'https://' + trimmed
      } else {
        normalizedUrl = trimmed
      }
    } else {
      // It's a search query - use Google
      normalizedUrl = `https://www.google.com/search?q=${encodeURIComponent(trimmed)}`
    }

    // Validate the URL before navigating
    try {
      validateWebViewUrl(normalizedUrl)
    } catch (err) {
      console.error('[WebViewPane] URL validation failed:', err)
      setError(String(err))
      setIsLoading(false)
      return
    }

    setCurrentUrl(normalizedUrl)
    setInputUrl(normalizedUrl)
    setIsLoading(true)
    setError(null)

    try {
      await invoke('navigate_webview', {
        webviewId: webviewId.current,
        url: normalizedUrl,
      })
      setIsLoading(false)
    } catch (err) {
      console.error('Failed to navigate:', err)
      setError(String(err))
      setIsLoading(false)
    }
  }, [])

  const handleSubmit = useCallback((e: React.FormEvent) => {
    e.preventDefault()
    handleNavigate(inputUrl)
  }, [inputUrl, handleNavigate])

  const handleRefresh = useCallback(() => {
    handleNavigate(currentUrl)
  }, [currentUrl, handleNavigate])

  const handleHome = useCallback(() => {
    handleNavigate(pane.url)
  }, [pane.url, handleNavigate])

  const handleOpenExternal = useCallback(async () => {
    const { openUrl } = await import('@tauri-apps/plugin-opener')
    await openUrl(currentUrl)
  }, [currentUrl])

  return (
    <div
      onClick={handleFocus}
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        backgroundColor: settings.theme.background,
        opacity: isActive ? 1 : 0.6,
        transition: 'opacity 0.15s ease',
      }}
    >
      {/* URL Bar */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          padding: '8px 12px',
          backgroundColor: `${settings.theme.brightBlack}20`,
          borderBottom: `1px solid ${settings.theme.brightBlack}40`,
        }}
      >
        {/* Navigation buttons */}
        <button
          onClick={handleRefresh}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: settings.theme.foreground,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          title="Refresh"
        >
          <RotateCw size={16} className={isLoading ? 'animate-spin' : ''} />
        </button>
        <button
          onClick={handleHome}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: settings.theme.foreground,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          title="Home"
        >
          <Home size={16} />
        </button>

        {/* URL input */}
        <form onSubmit={handleSubmit} style={{ flex: 1 }}>
          <input
            type="text"
            value={inputUrl}
            onChange={(e) => setInputUrl(e.target.value)}
            style={{
              width: '100%',
              padding: '6px 12px',
              backgroundColor: settings.theme.background,
              border: `1px solid ${settings.theme.brightBlack}`,
              borderRadius: '6px',
              color: settings.theme.foreground,
              fontSize: '13px',
              outline: 'none',
            }}
            placeholder="Enter URL..."
          />
        </form>

        {/* External link */}
        <button
          onClick={handleOpenExternal}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: settings.theme.foreground,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          title="Open in browser"
        >
          <ExternalLink size={16} />
        </button>

        {/* Element selector toggle */}
        <button
          onClick={handleToggleSelector}
          style={{
            padding: '4px',
            backgroundColor: isSelectorActive ? `${settings.theme.cyan}30` : 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: isSelectorActive ? settings.theme.cyan : settings.theme.foreground,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          title={isSelectorActive ? 'Disable element selector' : 'Enable element selector (React Grab)'}
        >
          <MousePointer2 size={16} />
        </button>

        {/* Close pane */}
        <button
          onClick={() => closePane(pane.id)}
          style={{
            padding: '4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: settings.theme.brightBlack,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.color = settings.theme.red
            e.currentTarget.style.backgroundColor = `${settings.theme.red}20`
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.color = settings.theme.brightBlack
            e.currentTarget.style.backgroundColor = 'transparent'
          }}
        >
          <X size={16} />
        </button>
      </div>

      {/* WebView container - the native webview will be positioned here */}
      <div
        ref={containerRef}
        style={{
          flex: 1,
          position: 'relative',
          backgroundColor: '#fff',
        }}
      >
        {/* Placeholder shown when dialog is open (webview moved off-screen) */}
        {isHiddenForDialog && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              backgroundColor: settings.theme.background,
              overflow: 'hidden',
            }}
          >
            {screenshotDataUrl ? (
              <img
                src={screenshotDataUrl}
                alt="Webview snapshot"
                style={{
                  width: '100%',
                  height: '100%',
                  objectFit: 'fill',
                  display: 'block',
                }}
              />
            ) : (
              <div style={{
                width: '100%',
                height: '100%',
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                justifyContent: 'center',
                gap: '12px',
                color: settings.theme.foreground,
                opacity: 0.5,
              }}>
                <div style={{
                  width: '48px',
                  height: '48px',
                  borderRadius: '12px',
                  backgroundColor: `${settings.theme.brightBlack}30`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}>
                  <ExternalLink size={24} />
                </div>
                <div style={{ fontSize: '14px', fontWeight: 500 }}>
                  {currentUrl}
                </div>
              </div>
            )}
          </div>
        )}

        {isLoading && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              backgroundColor: settings.theme.background,
              color: settings.theme.foreground,
              fontSize: '14px',
            }}
          >
            Loading...
          </div>
        )}

        {error && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              backgroundColor: settings.theme.background,
              color: settings.theme.foreground,
              padding: '40px',
              textAlign: 'center',
              gap: '12px',
            }}
          >
            <div style={{ fontSize: '16px', fontWeight: 600 }}>
              Failed to load webview
            </div>
            <div style={{ fontSize: '13px', color: settings.theme.brightBlack, maxWidth: '400px' }}>
              {error}
            </div>
            <button
              onClick={handleOpenExternal}
              style={{
                padding: '8px 16px',
                backgroundColor: settings.theme.cyan,
                border: 'none',
                borderRadius: '8px',
                color: '#000',
                fontSize: '13px',
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              Open in Browser
            </button>
          </div>
        )}
      </div>

      {/* Selector hint toast */}
      {showSelectorHint && (
        <div
          style={{
            position: 'absolute',
            bottom: '20px',
            left: '50%',
            transform: 'translateX(-50%)',
            backgroundColor: 'rgba(0, 0, 0, 0.9)',
            color: settings.theme.cyan,
            padding: '12px 20px',
            borderRadius: '8px',
            fontSize: '13px',
            fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
            boxShadow: '0 4px 20px rgba(0, 0, 0, 0.4)',
            border: `1px solid ${settings.theme.cyan}30`,
            zIndex: 1000,
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
          }}
        >
          <MousePointer2 size={16} />
          <span>
            <strong>Element Selector Active</strong> — Hover over elements, click to copy context to clipboard. Press ESC to cancel.
          </span>
        </div>
      )}

      {/* Copied toast */}
      {showCopiedToast && (
        <div
          style={{
            position: 'absolute',
            bottom: '20px',
            left: '50%',
            transform: 'translateX(-50%)',
            backgroundColor: settings.theme.green,
            color: '#000',
            padding: '10px 16px',
            borderRadius: '8px',
            fontSize: '13px',
            fontWeight: 500,
            fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
            boxShadow: '0 4px 20px rgba(0, 0, 0, 0.4)',
            zIndex: 1000,
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
          }}
        >
          <Check size={16} />
          Element context copied to clipboard!
        </div>
      )}
    </div>
  )
}

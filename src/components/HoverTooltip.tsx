/**
 * HoverTooltip Component
 * Displays type information, documentation, and code examples on hover
 */

import { useEffect, useRef, useState } from 'react'
import { X } from 'lucide-react'
import type { Hover, MarkupContent } from '../services/lsp'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'

interface HoverTooltipProps {
  data: Hover | null
  position: { x: number; y: number } | null
  isVisible: boolean
  onDismiss: () => void
}

/**
 * Extract text content from LSP hover result
 */
function extractContent(
  contents: string | MarkupContent | Array<string | { kind: string; value: string }>
): string {
  if (typeof contents === 'string') {
    return contents
  }

  if (Array.isArray(contents)) {
    return contents
      .map((item) => (typeof item === 'string' ? item : item.value))
      .join('\n\n')
  }

  if (contents && typeof contents === 'object' && 'value' in contents) {
    return contents.value
  }

  return ''
}

/**
 * Format content with syntax highlighting for code blocks
 */
function FormatContent({ content, theme }: { content: string; theme: { foreground: string; brightBlack: string; yellow: string } }) {
  const parts = content.split(/(`{1,3}[\s\S]*?`{1,3})/g)

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '8px', fontSize: '13px' }}>
      {parts.map((part, idx) => {
        // Single backtick inline code
        if (part.startsWith('`') && part.endsWith('`') && !part.includes('\n')) {
          return (
            <code
              key={idx}
              style={{
                display: 'inline-block',
                backgroundColor: 'rgba(0, 0, 0, 0.4)',
                color: theme.yellow,
                padding: '2px 6px',
                borderRadius: '4px',
                fontFamily: 'monospace',
                fontSize: '12px',
              }}
            >
              {part.slice(1, -1)}
            </code>
          )
        }

        // Code block (triple backticks)
        if (part.startsWith('```') && part.endsWith('```')) {
          const lines = part.slice(3, -3).trim().split('\n')
          const language = lines[0]?.match(/^(\w+)$/) ? lines[0] : null
          const code = language ? lines.slice(1).join('\n') : part.slice(3, -3)

          return (
            <pre
              key={idx}
              style={{
                backgroundColor: 'rgba(0, 0, 0, 0.6)',
                color: theme.yellow,
                padding: '8px',
                borderRadius: '4px',
                overflowX: 'auto',
                fontFamily: 'monospace',
                fontSize: '12px',
                margin: 0,
              }}
            >
              <code>{code}</code>
            </pre>
          )
        }

        // Regular text
        if (part.trim()) {
          return (
            <p key={idx} style={{ color: theme.foreground, margin: 0, opacity: 0.9 }}>
              {part}
            </p>
          )
        }

        return null
      })}
    </div>
  )
}

export function HoverTooltip({ data, position, isVisible, onDismiss }: HoverTooltipProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const tooltipRef = useRef<HTMLDivElement>(null)
  const [tooltipPos, setTooltipPos] = useState<{ top: number; left: number } | null>(null)

  // Position tooltip and handle overflow
  useEffect(() => {
    if (!isVisible || !position || !tooltipRef.current) {
      setTooltipPos(null)
      return
    }

    // Initial position (below cursor)
    const gap = 8
    let top = position.y + gap
    let left = position.x

    // Measure tooltip
    const rect = tooltipRef.current.getBoundingClientRect()
    const tooltipWidth = rect.width || 320
    const tooltipHeight = rect.height || 200

    // Adjust for viewport bounds
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    // Horizontal adjustment
    if (left + tooltipWidth > viewportWidth - 10) {
      left = Math.max(10, viewportWidth - tooltipWidth - 10)
    }

    // Vertical adjustment - show above if no room below
    if (top + tooltipHeight > viewportHeight - 10) {
      top = Math.max(10, position.y - tooltipHeight - gap)
    }

    setTooltipPos({ top, left })
  }, [isVisible, position])

  // Handle Escape key
  useEffect(() => {
    if (!isVisible) return

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onDismiss()
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [isVisible, onDismiss])

  if (!isVisible || !data) {
    return null
  }

  const content = extractContent(data.contents)

  return (
    <div
      ref={tooltipRef}
      style={{
        position: 'fixed',
        top: tooltipPos ? `${tooltipPos.top}px` : '-9999px',
        left: tooltipPos ? `${tooltipPos.left}px` : '-9999px',
        zIndex: 9999,
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '8px',
        boxShadow: '0 8px 32px rgba(0, 0, 0, 0.4)',
        maxWidth: '400px',
        minWidth: '200px',
        visibility: tooltipPos ? 'visible' : 'hidden',
      }}
      onMouseLeave={onDismiss}
    >
      {/* Header with close button */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 12px',
          borderBottom: `1px solid ${theme.brightBlack}50`,
        }}
      >
        <span
          style={{
            fontSize: '11px',
            fontWeight: 600,
            color: theme.brightBlack,
            textTransform: 'uppercase',
            letterSpacing: '0.5px',
          }}
        >
          Type Information
        </span>
        <button
          onClick={onDismiss}
          style={{
            background: 'transparent',
            border: 'none',
            color: theme.brightBlack,
            cursor: 'pointer',
            padding: '4px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            borderRadius: '4px',
            transition: 'color 0.15s ease',
          }}
          onMouseEnter={(e) => { e.currentTarget.style.color = theme.foreground }}
          onMouseLeave={(e) => { e.currentTarget.style.color = theme.brightBlack }}
          aria-label="Close tooltip"
        >
          <X size={14} />
        </button>
      </div>

      {/* Content */}
      <div
        style={{
          padding: '12px',
          maxHeight: '256px',
          overflowY: 'auto',
        }}
      >
        <FormatContent content={content} theme={theme} />
      </div>
    </div>
  )
}

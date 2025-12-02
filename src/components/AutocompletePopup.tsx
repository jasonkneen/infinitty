/**
 * AutocompletePopup Component
 * Displays LSP completion suggestions with keyboard navigation
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ChevronRight, Zap } from 'lucide-react'
import type { CompletionItem } from '../services/lsp'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'

interface AutocompletePopupProps {
  items: CompletionItem[]
  position: { x: number; y: number } | null
  isVisible: boolean
  filterText?: string
  onSelect: (item: CompletionItem) => void
  onDismiss: () => void
}

/**
 * Completion kind to display info mapping
 */
const COMPLETION_KIND_INFO: Record<number, { label: string; colorKey: keyof typeof themeColorMap }> = {
  1: { label: 'Text', colorKey: 'brightBlack' },
  2: { label: 'Method', colorKey: 'blue' },
  3: { label: 'Function', colorKey: 'blue' },
  4: { label: 'Constructor', colorKey: 'green' },
  5: { label: 'Field', colorKey: 'yellow' },
  6: { label: 'Variable', colorKey: 'yellow' },
  7: { label: 'Class', colorKey: 'green' },
  8: { label: 'Interface', colorKey: 'green' },
  9: { label: 'Module', colorKey: 'magenta' },
  10: { label: 'Property', colorKey: 'yellow' },
  11: { label: 'Unit', colorKey: 'brightBlack' },
  12: { label: 'Value', colorKey: 'brightBlack' },
  13: { label: 'Enum', colorKey: 'green' },
  14: { label: 'Keyword', colorKey: 'red' },
  15: { label: 'Snippet', colorKey: 'magenta' },
  16: { label: 'Color', colorKey: 'cyan' },
  17: { label: 'File', colorKey: 'brightBlack' },
  18: { label: 'Reference', colorKey: 'brightBlack' },
  19: { label: 'Folder', colorKey: 'blue' },
  20: { label: 'EnumMember', colorKey: 'green' },
  21: { label: 'Constant', colorKey: 'red' },
  22: { label: 'Struct', colorKey: 'green' },
  23: { label: 'Event', colorKey: 'magenta' },
  24: { label: 'Operator', colorKey: 'red' },
  25: { label: 'TypeParameter', colorKey: 'cyan' },
}

const themeColorMap = {
  brightBlack: 'brightBlack',
  blue: 'blue',
  green: 'green',
  yellow: 'yellow',
  magenta: 'magenta',
  red: 'red',
  cyan: 'cyan',
} as const

/**
 * Filter completion items based on filter text
 */
function filterItems(items: CompletionItem[], filterText: string): CompletionItem[] {
  if (!filterText) return items

  const lowerFilter = filterText.toLowerCase()
  return items.filter((item) => {
    const filterField = item.filterText || item.label
    return filterField.toLowerCase().includes(lowerFilter)
  })
}

/**
 * Highlight matching text in label
 */
function HighlightMatch({
  text,
  match,
  highlightColor,
  defaultColor,
}: {
  text: string
  match: string
  highlightColor: string
  defaultColor: string
}) {
  if (!match) return <>{text}</>

  const lowerMatch = match.toLowerCase()
  const lowerText = text.toLowerCase()
  const index = lowerText.indexOf(lowerMatch)

  if (index === -1) return <>{text}</>

  return (
    <>
      <span style={{ color: defaultColor }}>{text.slice(0, index)}</span>
      <span
        style={{
          backgroundColor: `${highlightColor}30`,
          color: highlightColor,
          fontWeight: 600,
        }}
      >
        {text.slice(index, index + match.length)}
      </span>
      <span style={{ color: defaultColor }}>{text.slice(index + match.length)}</span>
    </>
  )
}

export function AutocompletePopup({
  items,
  position,
  isVisible,
  filterText = '',
  onSelect,
  onDismiss,
}: AutocompletePopupProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const popupRef = useRef<HTMLDivElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const [popupPos, setPopupPos] = useState<{ top: number; left: number } | null>(null)
  const [selectedIndex, setSelectedIndex] = useState(0)

  // Filter items
  const filteredItems = useMemo(() => filterItems(items, filterText), [items, filterText])

  // Update selected index when filter changes
  useEffect(() => {
    setSelectedIndex(0)
  }, [filterText])

  // Position popup
  useEffect(() => {
    if (!isVisible || !position || !popupRef.current) {
      setPopupPos(null)
      return
    }

    const gap = 4
    let top = position.y + gap
    let left = position.x

    // Measure popup
    const rect = popupRef.current.getBoundingClientRect()
    const popupWidth = rect.width || 320
    const popupHeight = rect.height || 300

    // Adjust for viewport bounds
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    // Horizontal adjustment
    if (left + popupWidth > viewportWidth - 10) {
      left = Math.max(10, viewportWidth - popupWidth - 10)
    }

    // Vertical adjustment
    if (top + popupHeight > viewportHeight - 10) {
      top = Math.max(10, position.y - popupHeight - gap)
    }

    setPopupPos({ top, left })
  }, [isVisible, position])

  // Scroll selected item into view
  useEffect(() => {
    if (!listRef.current) return

    const items = listRef.current.querySelectorAll('[data-index]')
    const selectedItem = items[selectedIndex] as HTMLElement
    if (selectedItem) {
      selectedItem.scrollIntoView({ block: 'nearest' })
    }
  }, [selectedIndex])

  // Keyboard navigation
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!isVisible) return

      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault()
          setSelectedIndex((i) => (i < filteredItems.length - 1 ? i + 1 : i))
          break
        case 'ArrowUp':
          e.preventDefault()
          setSelectedIndex((i) => (i > 0 ? i - 1 : i))
          break
        case 'Enter':
        case 'Tab':
          e.preventDefault()
          if (filteredItems[selectedIndex]) {
            onSelect(filteredItems[selectedIndex])
            onDismiss()
          }
          break
        case 'Escape':
          e.preventDefault()
          onDismiss()
          break
      }
    },
    [filteredItems, selectedIndex, onSelect, onDismiss, isVisible]
  )

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeyDown])

  if (!isVisible || filteredItems.length === 0) {
    return null
  }

  const getKindColor = (kind?: number) => {
    if (!kind || !COMPLETION_KIND_INFO[kind]) {
      return theme.brightBlack
    }
    const colorKey = COMPLETION_KIND_INFO[kind].colorKey
    return theme[colorKey]
  }

  return (
    <div
      ref={popupRef}
      style={{
        position: 'fixed',
        top: popupPos ? `${popupPos.top}px` : '-9999px',
        left: popupPos ? `${popupPos.left}px` : '-9999px',
        zIndex: 9999,
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '8px',
        boxShadow: '0 8px 32px rgba(0, 0, 0, 0.4)',
        maxWidth: '400px',
        minWidth: '280px',
        visibility: popupPos ? 'visible' : 'hidden',
      }}
    >
      {/* Header */}
      <div
        style={{
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
          Suggestions ({filteredItems.length})
        </span>
      </div>

      {/* Items list */}
      <div
        ref={listRef}
        style={{
          maxHeight: '256px',
          overflowY: 'auto',
        }}
        role="listbox"
      >
        {filteredItems.map((item, index) => {
          const isSelected = index === selectedIndex
          const kindColor = getKindColor(item.kind)

          return (
            <button
              key={`${item.label}-${index}`}
              data-index={index}
              onClick={() => {
                onSelect(item)
                onDismiss()
              }}
              onMouseEnter={() => setSelectedIndex(index)}
              style={{
                width: '100%',
                textAlign: 'left',
                padding: '8px 12px',
                backgroundColor: isSelected ? `${theme.cyan}20` : 'transparent',
                border: 'none',
                borderLeft: isSelected ? `2px solid ${theme.cyan}` : '2px solid transparent',
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                transition: 'background-color 0.1s ease',
              }}
              role="option"
              aria-selected={isSelected}
            >
              {/* Icon */}
              <span style={{ flexShrink: 0, color: kindColor }}>
                <Zap size={14} />
              </span>

              {/* Label and detail */}
              <div style={{ flex: 1, minWidth: 0, overflow: 'hidden' }}>
                <div
                  style={{
                    fontSize: '13px',
                    fontWeight: 500,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  <HighlightMatch
                    text={item.label}
                    match={filterText}
                    highlightColor={theme.yellow}
                    defaultColor={theme.foreground}
                  />
                </div>
                {item.detail && (
                  <div
                    style={{
                      fontSize: '11px',
                      color: theme.brightBlack,
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {item.detail}
                  </div>
                )}
              </div>

              {/* Hint icon */}
              {isSelected && (
                <ChevronRight size={16} style={{ flexShrink: 0, color: theme.cyan }} />
              )}
            </button>
          )
        })}
      </div>

      {/* Footer hint */}
      <div
        style={{
          padding: '8px 12px',
          borderTop: `1px solid ${theme.brightBlack}50`,
          backgroundColor: `${theme.background}80`,
        }}
      >
        <div
          style={{
            fontSize: '11px',
            color: theme.brightBlack,
            textAlign: 'center',
          }}
        >
          <span>↑↓ Navigate • Enter/Tab Select • Esc Close</span>
        </div>
      </div>
    </div>
  )
}

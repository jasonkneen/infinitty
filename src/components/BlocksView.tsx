import { useEffect, useRef, useState, useCallback, useMemo } from 'react'
import { ArrowDown } from 'lucide-react'
import { CommandBlock } from './CommandBlock'
import { AIResponseBlock } from './AIResponseBlock'
import { InteractiveBlock } from './InteractiveBlock'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import type { Block, ToolCall } from '../types/blocks'

// Get relative time string (e.g., "2 minutes ago")
function getRelativeTime(date: Date): string {
  const now = new Date()
  const seconds = Math.floor((now.getTime() - date.getTime()) / 1000)

  if (seconds < 60) return 'just now'
  if (seconds < 3600) {
    const mins = Math.floor(seconds / 60)
    return `${mins} minute${mins > 1 ? 's' : ''} ago`
  }
  if (seconds < 86400) {
    const hours = Math.floor(seconds / 3600)
    return `${hours} hour${hours > 1 ? 's' : ''} ago`
  }
  const days = Math.floor(seconds / 86400)
  return `${days} day${days > 1 ? 's' : ''} ago`
}

interface BlocksViewProps {
  blocks: Block[]
  onInteractiveExit?: (blockId: string, exitCode: number) => void
  onDismissBlock?: (blockId: string) => void
  onBlockClick?: (blockId: string, blockType: string, label: string) => void
  onBlockDoubleClick?: (blockId: string, blockType: string, label: string) => void
  onLoadMore?: () => Promise<{ loaded: number; hasMore: boolean }>  // Called when scrolling to top
  canLoadMore?: boolean  // Whether more messages are available
}

// Estimate height of blocks based on type and content
const estimateBlockHeight = (block: Block): number => {
  const BASE_PADDING = 0 // gap between blocks

  switch (block.type) {
    case 'command':
      return 45 + BASE_PADDING
    case 'ai-response':
      // Estimate based on response length
      if (!block.response) return 100 + BASE_PADDING
      const charCount = block.response.length
      // Rough estimate: ~80 chars per line at typical width
      const estimatedLines = Math.ceil(charCount / 80)
      return Math.min(600, Math.max(60, estimatedLines * 20)) + BASE_PADDING
    case 'interactive':
      // Dismissed blocks show minimal status line
      if ('dismissed' in block && block.dismissed) {
        return 36 + BASE_PADDING
      }
      return 60 + BASE_PADDING
    case 'error':
      return 50 + BASE_PADDING
    case 'system':
      return 35 + BASE_PADDING
    default:
      return 50 + BASE_PADDING
  }
}

export function BlocksView({ blocks, onInteractiveExit, onDismissBlock, onBlockClick, onBlockDoubleClick, onScrollToEndRef, onLoadMore, canLoadMore }: BlocksViewProps & { onScrollToEndRef?: React.MutableRefObject<(() => void) | null> }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const containerRef = useRef<HTMLDivElement>(null)
  const [focusedBlockId, setFocusedBlockId] = useState<string | null>(null)
  const [expandedBlockId, setExpandedBlockId] = useState<string | null>(null)
  const [expandedToolId, setExpandedToolId] = useState<string | null>(null) // For tool chip expansion
  const [scrollTop, setScrollTop] = useState(0)
  const [containerHeight, setContainerHeight] = useState(0)
  const [isSticky, setIsSticky] = useState(true) // Sticky mode - auto-scroll to bottom
  const [showScrollButton, setShowScrollButton] = useState(false)
  const lastBlockCountRef = useRef(blocks.length)
  const [measuredHeights, setMeasuredHeights] = useState<Record<string, number>>({})
  const blockObserversRef = useRef<Map<string, ResizeObserver>>(new Map())

  // Track block heights for accurate virtualization
  const blockHeights = useMemo(() => {
    return blocks.map((block) => measuredHeights[block.id] ?? estimateBlockHeight(block))
  }, [blocks, measuredHeights])

  // Calculate cumulative heights for fast index lookup
  const cumulativeHeights = useMemo(() => {
    const cumulative: number[] = [0]
    for (const height of blockHeights) {
      cumulative.push(cumulative[cumulative.length - 1] + height)
    }
    return cumulative
  }, [blockHeights])

  // Find visible range based on scroll position
  const visibleRange = useMemo(() => {
    const BUFFER = 500 // Render 500px above and below viewport
    const startY = Math.max(0, scrollTop - BUFFER)
    const endY = scrollTop + containerHeight + BUFFER

    let startIndex = 0
    let endIndex = blocks.length - 1

    // Binary search for start index
    for (let i = 0; i < cumulativeHeights.length - 1; i++) {
      if (cumulativeHeights[i + 1] >= startY) {
        startIndex = Math.max(0, i - 1)
        break
      }
    }

    // Find end index
    for (let i = startIndex; i < cumulativeHeights.length - 1; i++) {
      if (cumulativeHeights[i] >= endY) {
        endIndex = i
        break
      }
    }

    return { startIndex, endIndex }
  }, [scrollTop, containerHeight, blocks.length, cumulativeHeights])

  // Scroll to end function
  const scrollToEnd = useCallback(() => {
    if (containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
      setIsSticky(true)
      setShowScrollButton(false)
    }
  }, [])

  // Expose scrollToEnd to parent via ref
  useEffect(() => {
    if (onScrollToEndRef) {
      onScrollToEndRef.current = scrollToEnd
    }
  }, [onScrollToEndRef, scrollToEnd])

  // Auto-focus the latest running interactive block (but don't auto-expand)
  useEffect(() => {
    const runningInteractive = blocks.find(
      (b) => b.type === 'interactive' && b.isRunning
    )
    if (runningInteractive && focusedBlockId !== runningInteractive.id) {
      setFocusedBlockId(runningInteractive.id)
    }
  }, [blocks, focusedBlockId])

  // Auto-scroll to bottom when new blocks added (only if sticky mode)
  useEffect(() => {
    const blocksAdded = blocks.length > lastBlockCountRef.current
    lastBlockCountRef.current = blocks.length

    if (containerRef.current && isSticky) {
      // Use requestAnimationFrame to ensure DOM has updated
      requestAnimationFrame(() => {
        if (containerRef.current) {
          containerRef.current.scrollTop = containerRef.current.scrollHeight
        }
      })
    } else if (blocksAdded && !isSticky) {
      // New content added while scrolled up - show button
      setShowScrollButton(true)
    }
  }, [blocks, isSticky])

  // Track loading state for backfill
  const [isLoadingMore, setIsLoadingMore] = useState(false)
  const loadMoreThrottleRef = useRef<number | null>(null)

  // Handle scroll events for virtualization and sticky detection
  const handleScroll = useCallback((e: React.UIEvent<HTMLDivElement>) => {
    const target = e.currentTarget
    const currentScrollTop = target.scrollTop
    setScrollTop(currentScrollTop)

    // Check if user is near bottom (within 100px)
    const isNearBottom = target.scrollHeight - target.scrollTop - target.clientHeight < 100

    if (isNearBottom) {
      setIsSticky(true)
      setShowScrollButton(false)
    } else {
      setIsSticky(false)
      setShowScrollButton(true)
    }

    // Check if scrolled to top - trigger load more
    if (currentScrollTop < 100 && canLoadMore && onLoadMore && !isLoadingMore) {
      // Throttle to prevent multiple calls
      if (!loadMoreThrottleRef.current) {
        setIsLoadingMore(true)
        
        // Remember scroll height before loading
        const prevScrollHeight = target.scrollHeight
        
        onLoadMore().then((result) => {
          setIsLoadingMore(false)
          
          // Maintain scroll position after prepending blocks
          if (result.loaded > 0) {
            requestAnimationFrame(() => {
              const newScrollHeight = target.scrollHeight
              const heightDiff = newScrollHeight - prevScrollHeight
              target.scrollTop = currentScrollTop + heightDiff
            })
          }
        }).catch(() => {
          setIsLoadingMore(false)
        })
        
        // Throttle for 1 second
        loadMoreThrottleRef.current = window.setTimeout(() => {
          loadMoreThrottleRef.current = null
        }, 1000)
      }
    }
  }, [canLoadMore, onLoadMore, isLoadingMore])

  // Handle container resize
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const resizeObserver = new ResizeObserver(() => {
      setContainerHeight(container.clientHeight)
    })

    resizeObserver.observe(container)
    setContainerHeight(container.clientHeight)

    return () => resizeObserver.disconnect()
  }, [])

  // Measure each rendered block and store its height for virtualization
  const registerBlock = useCallback((id: string) => (node: HTMLDivElement | null) => {
    const existingObserver = blockObserversRef.current.get(id)
    if (existingObserver) {
      existingObserver.disconnect()
      blockObserversRef.current.delete(id)
    }
    if (!node) return

    const observer = new ResizeObserver((entries) => {
      const entry = entries[0]
      const height = entry?.contentRect?.height ?? node.getBoundingClientRect().height
      setMeasuredHeights((prev) => {
        if (Math.abs((prev[id] ?? 0) - height) < 1) return prev
        return { ...prev, [id]: height }
      })
    })
    observer.observe(node)
    blockObserversRef.current.set(id, observer)
  }, [])

  // Clean up observers on unmount
  useEffect(() => {
    return () => {
      blockObserversRef.current.forEach((observer) => observer.disconnect())
      blockObserversRef.current.clear()
    }
  }, [])

  const handleBlockClick = useCallback((blockId: string, blockType: string, label: string) => {
    setFocusedBlockId(blockId)
    onBlockClick?.(blockId, blockType, label)
  }, [onBlockClick])

  const handleBlockDoubleClick = useCallback((blockId: string, blockType: string, label: string) => {
    onBlockDoubleClick?.(blockId, blockType, label)
  }, [onBlockDoubleClick])

  const handleToggleExpand = useCallback((blockId: string) => {
    setExpandedBlockId((prev) => (prev === blockId ? null : blockId))
  }, [])

  const handleInteractiveExit = useCallback((blockId: string, exitCode: number) => {
    onInteractiveExit?.(blockId, exitCode)
    // Collapse and unfocus on exit
    if (expandedBlockId === blockId) {
      setExpandedBlockId(null)
    }
    setFocusedBlockId(null)
  }, [onInteractiveExit, expandedBlockId])

  // Handle tool chip click - toggle collapsible output (mutually exclusive)
  const handleToolClick = useCallback((tool: ToolCall) => {
    if (!tool.output) return // No output to show
    setExpandedToolId((prev) => (prev === tool.id ? null : tool.id))
  }, [])

  // Render a single block
  const renderBlock = (block: Block, index: number, allBlocks: Block[]) => {
    const isFocused = focusedBlockId === block.id
    const isExpanded = expandedBlockId === block.id
    
    // Check if model changed from previous AI response block
    let showModelInfo = true
    if (block.type === 'ai-response' && index > 0) {
      // Find the previous AI response block
      for (let i = index - 1; i >= 0; i--) {
        const prevBlock = allBlocks[i]
        if (prevBlock.type === 'ai-response') {
          showModelInfo = prevBlock.model !== block.model || prevBlock.provider !== block.provider
          break
        }
      }
    }

    switch (block.type) {
      case 'command':
        return (
          <div
            key={block.id}
            ref={registerBlock(block.id)}
            onClick={() => handleBlockClick(block.id, 'command', block.command)}
            onDoubleClick={() => handleBlockDoubleClick(block.id, 'command', block.command)}
            style={{
              cursor: 'pointer',
              borderRadius: '0 12px 12px 0',
              // Outline handled by component
            }}
          >
            <CommandBlock block={block} isFocused={isFocused} />
          </div>
        )
      case 'ai-response': {
        // Find the expanded tool for this block (if any)
        const expandedTool = block.toolCalls?.find(t => t.id === expandedToolId)
        return (
          <div key={block.id}>
            <div
              ref={registerBlock(block.id)}
              onClick={() => handleBlockClick(block.id, 'ai-response', block.prompt)}
              onDoubleClick={() => handleBlockDoubleClick(block.id, 'ai-response', block.prompt)}
              style={{
                cursor: 'pointer',
                borderRadius: '0 12px 12px 0',
              }}
            >
              <AIResponseBlock block={block} isFocused={isFocused} onToolClick={handleToolClick} showModelInfo={showModelInfo} />
            </div>
            {/* Collapsible tool output */}
            {expandedTool && expandedTool.output && (
              <div
                style={{
                  marginLeft: '24px',
                  marginTop: '-1px',
                  padding: '12px 16px',
                  fontSize: `${settings.fontSize}px`,
                  fontFamily: settings.font.family,
                  lineHeight: settings.lineHeight,
                  backgroundColor: `${theme.brightBlack}10`,
                  borderLeft: `3px solid ${theme.brightBlack}40`,
                  borderRadius: '0 0 8px 0',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                  color: theme.foreground,
                  maxHeight: '400px',
                  overflowY: 'auto',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
                  <span style={{ fontSize: '11px', color: theme.brightBlack, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                    {expandedTool.name} output
                  </span>
                  <button
                    onClick={() => setExpandedToolId(null)}
                    style={{
                      padding: '2px 6px',
                      fontSize: '10px',
                      color: theme.brightBlack,
                      backgroundColor: 'transparent',
                      border: `1px solid ${theme.brightBlack}40`,
                      borderRadius: '4px',
                      cursor: 'pointer',
                    }}
                  >
                    collapse
                  </button>
                </div>
                <code style={{ fontFamily: settings.font.family }}>
                  {expandedTool.output}
                </code>
              </div>
            )}
          </div>
        )
      }
      case 'interactive':
        // Render minimal status line for dismissed blocks
        if (block.dismissed) {
          const relativeTime = getRelativeTime(block.endTime || new Date())
          return (
            <div
              key={block.id}
              ref={registerBlock(block.id)}
              onClick={() => handleBlockClick(block.id, 'interactive', block.command)}
              onDoubleClick={() => handleBlockDoubleClick(block.id, 'interactive', block.command)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                padding: '8px 16px',
                fontSize: '12px',
                color: theme.brightBlack,
                fontFamily: settings.font.family,
                borderLeft: `3px solid ${theme.brightBlack}40`,
                marginLeft: '3px',
                cursor: 'pointer',
              }}
            >
              <span style={{ color: theme.white, opacity: 0.6 }}>Process closed.</span>
              <span style={{ opacity: 0.4 }}>{relativeTime}</span>
            </div>
          )
        }

        return (
          <div
            key={block.id}
            ref={registerBlock(block.id)}
            onClick={() => handleBlockClick(block.id, 'interactive', block.command)}
            onDoubleClick={() => handleBlockDoubleClick(block.id, 'interactive', block.command)}
            style={{
              cursor: 'pointer',
              borderRadius: '0 12px 12px 0',
              transition: 'all 0.15s ease',
              // Outline handled by component
            }}
          >
            <InteractiveBlock
              block={block}
              isExpanded={isExpanded}
              isFocused={isFocused}
              onToggleExpand={() => handleToggleExpand(block.id)}
              onExit={(exitCode) => handleInteractiveExit(block.id, exitCode)}
              onDismiss={() => onDismissBlock?.(block.id)}
            />
          </div>
        )
      case 'error':
        return (
          <div
            key={block.id}
            ref={registerBlock(block.id)}
            style={{
              backgroundColor: `${theme.red}1a`,
              border: `1px solid ${theme.red}33`,
              borderRadius: '0 12px 12px 0',
              borderLeft: `6px solid ${theme.red}`,
              padding: '12px 16px',
              color: theme.red,
              fontSize: `${settings.fontSize}px`,
              fontFamily: settings.font.family,
            }}
          >
            {block.message}
          </div>
        )
      case 'system':
        return (
          <div
            key={block.id}
            ref={registerBlock(block.id)}
            style={{
              textAlign: 'center',
              fontSize: '10px',
              fontFamily: settings.font.family,
              color: theme.white,
              padding: '8px 0',
              opacity: 0.6,
            }}
          >
            {block.message}
          </div>
        )
      default:
        return null
    }
  }

  // Get visible blocks using virtualization
  const visibleBlocks = blocks.slice(visibleRange.startIndex, visibleRange.endIndex + 1)
  const offsetY = cumulativeHeights[visibleRange.startIndex]

  return (
    <div
      style={{
        height: '100%',
        overflow: 'hidden',
        backgroundColor: 'transparent',
        position: 'relative',
      }}
    >
      <div
        ref={containerRef}
        onScroll={handleScroll}
        style={{
          height: '100%',
          overflowY: 'auto',
          scrollBehavior: 'auto',
        }}
      >
        <div style={{ padding: '0 16px 32px 0' }}>

          {blocks.length === 0 ? (
            <div style={{ display: 'flex', height: '60vh', alignItems: 'center', justifyContent: 'center' }}>
              <div style={{ textAlign: 'center' }}>
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    gap: '8px',
                    fontSize: '10px',
                    color: theme.white,
                    textTransform: 'uppercase',
                    letterSpacing: '0.05em',
                    marginBottom: '16px',
                  }}
                >
                  <span style={{ width: '6px', height: '6px', backgroundColor: theme.cyan, borderRadius: '50%' }} />
                  To Infinitty and Beyond
                </div>
                <p style={{ fontSize: '15px', color: theme.white }}>
                  What would you like to work on today?
                </p>
              </div>
            </div>
          ) : (
            <>
              {/* Spinner keyframes */}
              <style>{`@keyframes blocksview-spin { to { transform: rotate(360deg); } }`}</style>
              
              {/* Loading indicator when fetching older messages */}
              {isLoadingMore && (
                <div style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  padding: '16px',
                  color: theme.brightBlack,
                  fontSize: '12px',
                  gap: '8px',
                }}>
                  <span style={{
                    width: '16px',
                    height: '16px',
                    border: `2px solid ${theme.brightBlack}40`,
                    borderTopColor: theme.cyan,
                    borderRadius: '50%',
                    animation: 'blocksview-spin 1s linear infinite',
                  }} />
                  Loading older messages...
                </div>
              )}
              
              {/* "Load more" indicator when more messages available */}
              {canLoadMore && !isLoadingMore && (
                <div style={{
                  textAlign: 'center',
                  padding: '12px',
                  color: theme.brightBlack,
                  fontSize: '11px',
                  opacity: 0.7,
                }}>
                  ↑ Scroll up for older messages
                </div>
              )}

              {/* Spacer for blocks above viewport */}
              <div style={{ height: `${offsetY}px` }} />

              {/* Virtualized block list */}
              <div style={{ display: 'flex', flexDirection: 'column', gap: '0' }}>
                {visibleBlocks.map((block, i) => renderBlock(block, visibleRange.startIndex + i, blocks))}
              </div>

              {/* Spacer for blocks below viewport */}
              <div
                style={{
                  height: `${Math.max(0, cumulativeHeights[cumulativeHeights.length - 1] - (offsetY + visibleBlocks.reduce((sum, _, i) => sum + blockHeights[visibleRange.startIndex + i], 0)))}px`,
                }}
              />
            </>
          )}
        </div>
      </div>

      {/* Scroll to bottom button */}
      {showScrollButton && (
        <button
          onClick={scrollToEnd}
          style={{
            position: 'absolute',
            bottom: '20px',
            right: '20px',
            zIndex: 100,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: '6px',
            padding: '8px 14px',
            backgroundColor: theme.cyan,
            color: theme.background,
            border: 'none',
            borderRadius: '20px',
            fontSize: '12px',
            fontWeight: 600,
            fontFamily: settings.font.family,
            cursor: 'pointer',
            boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
            transition: 'all 0.2s ease',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.transform = 'scale(1.05)'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.transform = 'scale(1)'
          }}
        >
          <ArrowDown size={14} />
          New messages
        </button>
      )}
    </div>
  )
}

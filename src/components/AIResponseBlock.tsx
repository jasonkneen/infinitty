import { useState, useEffect, memo, useMemo } from 'react'
import ReactDiffViewer, { DiffMethod } from 'react-diff-viewer-continued'
import { Check, Copy, Sparkles, Loader2, Wrench, FileText, Search, Code, Terminal, Globe, Database, Settings, X, ChevronDown, ChevronRight, Brain } from 'lucide-react'
import { Streamdown } from 'streamdown'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import type { AIResponseBlock as AIResponseBlockType, ToolCall } from '../types/blocks'
import type { TerminalTheme } from '../config/terminal'

// Tool type colors - subtle shades
const TOOL_COLORS: Record<string, { bg: string; border: string; icon: typeof Wrench }> = {
  read: { bg: '45, 212, 191', border: '45, 212, 191', icon: FileText },      // cyan
  write: { bg: '251, 146, 60', border: '251, 146, 60', icon: FileText },     // orange
  edit: { bg: '251, 191, 36', border: '251, 191, 36', icon: Code },          // yellow
  search: { bg: '168, 85, 247', border: '168, 85, 247', icon: Search },      // purple
  grep: { bg: '168, 85, 247', border: '168, 85, 247', icon: Search },        // purple
  glob: { bg: '168, 85, 247', border: '168, 85, 247', icon: Search },        // purple
  bash: { bg: '34, 197, 94', border: '34, 197, 94', icon: Terminal },        // green
  shell: { bg: '34, 197, 94', border: '34, 197, 94', icon: Terminal },       // green
  web: { bg: '59, 130, 246', border: '59, 130, 246', icon: Globe },          // blue
  fetch: { bg: '59, 130, 246', border: '59, 130, 246', icon: Globe },        // blue
  database: { bg: '236, 72, 153', border: '236, 72, 153', icon: Database },  // pink
  sql: { bg: '236, 72, 153', border: '236, 72, 153', icon: Database },       // pink
  config: { bg: '148, 163, 184', border: '148, 163, 184', icon: Settings },  // slate
  default: { bg: '148, 163, 184', border: '148, 163, 184', icon: Wrench },   // slate
}

function getToolStyle(toolName: string): { bg: string; border: string; icon: typeof Wrench } {
  const lowerName = toolName.toLowerCase()
  for (const [key, style] of Object.entries(TOOL_COLORS)) {
    if (lowerName.includes(key)) return style
  }
  return TOOL_COLORS.default
}

// ASCII spinner animation frames
const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const THINKING_FRAMES = [
  '●○○○○',
  '○●○○○',
  '○○●○○',
  '○○○●○',
  '○○○○●',
  '○○○●○',
  '○○●○○',
  '○●○○○',
]

// Animated loading indicator component
function StreamingIndicator({ color }: { color: string }) {
  const [frame, setFrame] = useState(0)

  useEffect(() => {
    const interval = setInterval(() => {
      setFrame(f => (f + 1) % SPINNER_FRAMES.length)
    }, 80)
    return () => clearInterval(interval)
  }, [])

  return (
    <span style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: '8px',
      color,
      fontFamily: 'monospace',
    }}>
      <span style={{ fontSize: '16px' }}>{SPINNER_FRAMES[frame]}</span>
      <span style={{ opacity: 0.7 }}>Waiting for response...</span>
    </span>
  )
}

// Extended thinking indicator with pulsing animation
function ThinkingIndicator({ color }: { color: string }) {
  const [frame, setFrame] = useState(0)

  useEffect(() => {
    const interval = setInterval(() => {
      setFrame(f => (f + 1) % THINKING_FRAMES.length)
    }, 150)
    return () => clearInterval(interval)
  }, [])

  return (
    <span style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: '10px',
      color,
      fontFamily: 'monospace',
    }}>
      <span style={{
        fontSize: '12px',
        letterSpacing: '2px',
        opacity: 0.9,
      }}>
        {THINKING_FRAMES[frame]}
      </span>
      <span style={{ opacity: 0.7 }}>Deep thinking...</span>
    </span>
  )
}

// Collapsible thinking section
interface ThinkingSectionProps {
  thinking: string
  theme: TerminalTheme
  fontFamily: string
  lineHeight: number
}

function ThinkingSection({ thinking, theme, fontFamily, lineHeight }: ThinkingSectionProps) {
  const [expanded, setExpanded] = useState(false)

  return (
    <div style={{
      borderTop: `1px solid ${theme.magenta}20`,
      backgroundColor: `${theme.magenta}05`,
    }}>
      <button
        onClick={() => setExpanded(!expanded)}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          width: '100%',
          padding: '10px 16px',
          background: 'none',
          border: 'none',
          cursor: 'pointer',
          color: theme.magenta,
          fontSize: '12px',
          fontWeight: 500,
        }}
      >
        {expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
        <Brain size={14} />
        <span>Extended Thinking</span>
        <span style={{ opacity: 0.5, marginLeft: 'auto' }}>
          {thinking.length.toLocaleString()} chars
        </span>
      </button>
      {expanded && (
        <div style={{
          padding: '0 16px 16px',
          fontSize: '12px',
          fontFamily,
          color: theme.foreground,
          opacity: 0.8,
          whiteSpace: 'pre-wrap',
          maxHeight: '300px',
          overflow: 'auto',
          lineHeight,
        }}>
          {thinking}
        </div>
      )}
    </div>
  )
}

// Diff viewer for edit tool calls using react-diff-viewer
interface EditDiffViewerProps {
  oldString: string
  newString: string
  filePath: string
  theme: TerminalTheme
  fontFamily: string
}

function EditDiffViewer({ oldString, newString, filePath, theme, fontFamily }: EditDiffViewerProps) {
  // Extract just the filename from the path
  const fileName = filePath.split('/').pop() || filePath
  
  // Custom styles for the diff viewer
  const diffStyles = useMemo(() => ({
    variables: {
      dark: {
        diffViewerBackground: 'transparent',
        addedBackground: `${theme.green}15`,
        addedColor: theme.green,
        removedBackground: `${theme.red}15`,
        removedColor: theme.red,
        wordAddedBackground: `${theme.green}30`,
        wordRemovedBackground: `${theme.red}30`,
        addedGutterBackground: `${theme.green}20`,
        removedGutterBackground: `${theme.red}20`,
        gutterBackground: 'transparent',
        gutterBackgroundDark: 'transparent',
        codeFoldBackground: `${theme.brightBlack}10`,
        codeFoldGutterBackground: `${theme.brightBlack}10`,
        codeFoldContentColor: theme.brightBlack,
        emptyLineBackground: 'transparent',
      },
    },
    line: {
      padding: '2px 8px',
      fontSize: '11px',
      fontFamily,
    },
    gutter: {
      minWidth: '30px',
      padding: '0 8px',
      fontSize: '10px',
      color: theme.brightBlack,
    },
    content: {
      width: '100%',
    },
    wordDiff: {
      padding: '1px 2px',
      borderRadius: '2px',
    },
  }), [theme, fontFamily])
  
  return (
    <div style={{ fontSize: '11px', fontFamily }}>
      {/* File path header */}
      <div style={{
        padding: '6px 8px',
        backgroundColor: `${theme.brightBlack}15`,
        borderRadius: '4px 4px 0 0',
        color: theme.foreground,
        display: 'flex',
        alignItems: 'center',
        gap: '6px',
        borderBottom: `1px solid ${theme.brightBlack}20`,
      }}>
        <FileText size={12} style={{ color: theme.cyan }} />
        <span style={{ opacity: 0.7 }}>{fileName}</span>
      </div>
      
      {/* Diff content */}
      <div style={{
        backgroundColor: `${theme.brightBlack}08`,
        borderRadius: '0 0 4px 4px',
        overflow: 'auto',
        maxHeight: '400px',
      }}>
        <ReactDiffViewer
          oldValue={oldString}
          newValue={newString}
          splitView={false}
          useDarkTheme={true}
          hideLineNumbers={false}
          showDiffOnly={true}
          extraLinesSurroundingDiff={2}
          compareMethod={DiffMethod.WORDS}
          styles={diffStyles}
        />
      </div>
    </div>
  )
}

// Check if tool input is an edit operation with oldString/newString
function isEditToolInput(input: Record<string, unknown> | undefined): input is { filePath: string; oldString: string; newString: string } {
  return !!(
    input &&
    typeof input.filePath === 'string' &&
    typeof input.oldString === 'string' &&
    typeof input.newString === 'string'
  )
}

interface AIResponseBlockProps {
  block: AIResponseBlockType
  isFocused?: boolean
  onToolClick?: (tool: ToolCall) => void
  showModelInfo?: boolean  // Only show model/provider if different from previous block
}

export const AIResponseBlock = memo(function AIResponseBlock({ block, isFocused, onToolClick, showModelInfo = true }: AIResponseBlockProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [copied, setCopied] = useState(false)
  const [selectedTool, setSelectedTool] = useState<ToolCall | null>(null)
  
  // Memoize code colors to prevent recalculation
  const codeColors = useMemo(() => ({
    keyword: theme.magenta,
    string: theme.green,
    function: theme.blue,
    number: theme.yellow,
    comment: theme.brightBlack,
    variable: theme.cyan,
    punctuation: theme.foreground,
  }), [theme.magenta, theme.green, theme.blue, theme.yellow, theme.brightBlack, theme.cyan, theme.foreground])

  // Memoize the large CSS string to prevent recreation on every render
  const streamdownStyles = useMemo(() => `
    .streamdown-response {
      --shiki-dark-bg: ${theme.background};
      --shiki-light-bg: ${theme.background};
      --shiki-dark: ${theme.foreground};
      --shiki-light: ${theme.foreground};
      --shiki-dark-keyword: ${codeColors.keyword};
      --shiki-light-keyword: ${codeColors.keyword};
      --shiki-dark-string: ${codeColors.string};
      --shiki-light-string: ${codeColors.string};
      --shiki-dark-function: ${codeColors.function};
      --shiki-light-function: ${codeColors.function};
      --shiki-dark-number: ${codeColors.number};
      --shiki-light-number: ${codeColors.number};
      --shiki-dark-comment: ${codeColors.comment};
      --shiki-light-comment: ${codeColors.comment};
      --shiki-dark-variable: ${codeColors.variable};
      --shiki-light-variable: ${codeColors.variable};
      --shiki-dark-punctuation: ${codeColors.punctuation};
      --shiki-light-punctuation: ${codeColors.punctuation};
    }
    .streamdown-response [data-rehype-pretty-code-figure] {
      margin: 20px 0;
      border-radius: 6px;
      overflow: hidden;
      border: 1px solid ${theme.brightBlack}18;
      background: ${theme.background};
      position: relative;
    }
    .streamdown-response [data-streamdown="code-block"] {
      margin: 20px 0 !important;
      border-radius: 6px !important;
      border: 1px solid ${theme.brightBlack}20 !important;
      background: ${theme.background} !important;
    }
    .streamdown-response [data-streamdown="code-block-header"] {
      background: linear-gradient(135deg, #16121c 0%, #1a161f 100%) !important;
      border-bottom: 1px solid ${theme.brightBlack}18 !important;
      padding: 10px 14px !important;
      color: ${theme.foreground}60 !important;
    }
    .streamdown-response [data-streamdown="code-block-body"] {
      background: ${theme.background} !important;
      padding: 14px 20px 14px 12px !important;
    }
    .streamdown-response [data-rehype-pretty-code-title] {
      display: flex;
      align-items: center;
      justify-content: space-between;
      font-size: 12px;
      font-weight: 600;
      font-family: ${settings.font.family};
      color: ${theme.foreground}60;
      background: linear-gradient(135deg, #16121c 0%, #1a161f 100%);
      border: none;
      border-bottom: 1px solid ${theme.brightBlack}18;
      padding: 10px 14px;
      text-transform: lowercase;
      letter-spacing: 0.3px;
    }
    .streamdown-response [data-rehype-pretty-code-title] + pre {
      margin-top: 0;
      border-top-left-radius: 0;
      border-top-right-radius: 0;
    }
    .streamdown-response pre {
      background: ${theme.background} !important;
      border: none;
      border-radius: 6px;
      padding: 14px 16px;
      margin: 20px 0;
      overflow-x: auto;
      position: relative;
    }
    .streamdown-response [data-rehype-pretty-code-figure] pre {
      border-radius: 0;
      margin: 0;
      padding: 20px 16px;
    }
    .streamdown-response pre code {
      background: transparent !important;
      padding: 0;
      font-family: ${settings.font.family};
      font-size: ${settings.fontSize}px;
      line-height: ${settings.lineHeight};
      color: #cdd6f4;
      letter-spacing: 0.2px;
    }
    .streamdown-response code {
      font-family: ${settings.font.family};
      font-size: ${settings.fontSize - 1}px;
    }
    .streamdown-response :not(pre) > code {
      background: ${theme.brightBlack}25;
      color: ${theme.foreground};
      padding: 4px 9px;
      border-radius: 5px;
      font-weight: 450;
      border: 1px solid ${theme.brightBlack}15;
    }
    .streamdown-response p {
      margin: 0 0 ${settings.paragraphSpacing}px 0;
      line-height: ${settings.lineHeight};
      color: ${theme.foreground};
      font-size: inherit;
    }
    .streamdown-response p:last-child { margin-bottom: 0; }
    .streamdown-response h1, .streamdown-response h2, .streamdown-response h3, .streamdown-response h4 {
      font-weight: 700;
      margin: 32px 0 14px 0;
      line-height: 1.25;
      color: ${theme.white};
      letter-spacing: -0.5px;
    }
    .streamdown-response h1:first-child, .streamdown-response h2:first-child, .streamdown-response h3:first-child { margin-top: 0; }
    .streamdown-response h1 { font-size: 28px; margin-bottom: 16px; }
    .streamdown-response h2 {
      font-size: 22px;
      margin-top: 36px;
      margin-bottom: 14px;
      padding-bottom: 8px;
      border-bottom: 1px solid ${theme.brightBlack}20;
    }
    .streamdown-response h3 { font-size: 16px; font-weight: 600; color: ${theme.white}; }
    .streamdown-response h4 { font-size: 14px; font-weight: 600; color: ${theme.foreground}; }
    .streamdown-response ul, .streamdown-response ol { margin: 18px 0; padding-left: 28px; }
    .streamdown-response li {
      margin: 10px 0;
      line-height: ${settings.lineHeight};
      color: ${theme.foreground};
    }
    .streamdown-response li::marker { color: ${theme.brightBlack}60; font-weight: 500; }
    .streamdown-response a {
      color: ${theme.cyan};
      text-decoration: none;
      transition: all 0.2s ease;
      font-weight: 500;
    }
    .streamdown-response a:hover { text-decoration: underline; opacity: 0.8; }
    .streamdown-response strong { color: ${theme.white}; font-weight: 700; }
    .streamdown-response blockquote {
      margin: 24px 0;
      padding: 16px 20px;
      padding-left: 16px;
      background: ${theme.yellow}08;
      border: 1px solid ${theme.yellow}25;
      border-left: 4px solid ${theme.yellow}60;
      border-radius: 8px;
      color: ${theme.foreground};
      font-style: normal;
    }
    .streamdown-response blockquote p { margin: 0; line-height: 1.75; }
    .streamdown-response blockquote strong { color: ${theme.yellow}; }
    .streamdown-response table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      margin: 24px 0;
      font-size: ${settings.fontSize}px;
      border: 1px solid ${theme.brightBlack}30;
      border-radius: 10px;
      overflow: hidden;
      background: ${theme.brightBlack}05;
    }
    .streamdown-response thead {
      background: linear-gradient(135deg, ${theme.brightBlack}20 0%, ${theme.brightBlack}10 100%);
    }
    .streamdown-response th {
      padding: 16px 18px;
      text-align: left;
      color: ${theme.white};
      font-weight: 700;
      border-bottom: 1px solid ${theme.brightBlack}30;
      letter-spacing: 0.1px;
    }
    .streamdown-response td {
      padding: 14px 18px;
      border-bottom: 1px solid ${theme.brightBlack}15;
      color: ${theme.foreground};
    }
    .streamdown-response tbody tr:hover { background: ${theme.brightBlack}08; }
    .streamdown-response tr:last-child td { border-bottom: none; }
    .streamdown-response hr {
      border: none;
      height: 1px;
      background: linear-gradient(90deg, transparent, ${theme.brightBlack}30, transparent);
      margin: 36px 0;
    }
    .streamdown-response .mermaid {
      background: #1e1e2e;
      border-radius: 12px;
      padding: 24px;
      margin: 24px 0;
      border: 1px solid ${theme.brightBlack}30;
    }
    .streamdown-response [data-rehype-pretty-code-figure] button {
      position: absolute;
      top: 12px;
      right: 12px;
      font-size: 11px;
      padding: 6px 10px;
      background: ${theme.brightBlack}40;
      border: 1px solid ${theme.brightBlack}60;
      border-radius: 6px;
      color: ${theme.brightBlack}80;
      cursor: pointer;
      transition: all 0.2s ease;
      display: flex;
      align-items: center;
      gap: 6px;
      font-family: ${settings.font.family};
      z-index: 10;
    }
    .streamdown-response [data-rehype-pretty-code-figure] button:hover {
      background: ${theme.brightBlack}60;
      border-color: ${theme.brightBlack}80;
      color: ${theme.foreground};
    }
    .streamdown-response [data-rehype-pretty-code-figure] button:active { transform: scale(0.95); }
    .streamdown-response input[type="range"],
    .streamdown-response progress,
    .streamdown-response .progress-bar,
    .streamdown-response [role="progressbar"] { display: none !important; }
    .streamdown-response *::-webkit-scrollbar,
    .streamdown-response::-webkit-scrollbar { height: 3px !important; width: 3px !important; background: transparent !important; }
    .streamdown-response *::-webkit-scrollbar-track,
    .streamdown-response::-webkit-scrollbar-track { background: transparent !important; }
    .streamdown-response *::-webkit-scrollbar-thumb,
    .streamdown-response::-webkit-scrollbar-thumb { background: ${theme.brightBlack}30 !important; border-radius: 2px !important; }
    .streamdown-response *::-webkit-scrollbar-thumb:hover,
    .streamdown-response::-webkit-scrollbar-thumb:hover { background: ${theme.brightBlack}50 !important; }
    .streamdown-response *::-webkit-scrollbar-corner,
    .streamdown-response::-webkit-scrollbar-corner { background: transparent !important; }
    .streamdown-response .streamdown-toolbar,
    .streamdown-response .streamdown-actions,
    .streamdown-response [class*="toolbar"],
    .streamdown-response [class*="actions"],
    .streamdown-response [class*="progress"],
    .streamdown-response [class*="slider"] { display: none !important; }
  `, [theme, codeColors, settings.font.family, settings.fontSize, settings.lineHeight, settings.paragraphSpacing])

  const copyResponse = async () => {
    await navigator.clipboard.writeText(block.response)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div
      style={{
        backgroundColor: isFocused ? 'rgba(0, 0, 0, 0.4)' : 'transparent',
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        borderTop: `1px solid ${isFocused ? `${theme.magenta}40` : `${theme.white}10`}`,
        borderRight: 'none',
        borderBottom: `1px solid ${isFocused ? `${theme.magenta}40` : `${theme.white}10`}`,
        borderLeft: `6px solid ${theme.magenta}`,
        borderRadius: 0,
        overflow: 'hidden',
        transition: 'all 0.2s ease',
      }}
    >
      {/* Header - only show if there's a prompt */}
      {block.prompt && block.prompt.trim() && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '10px 16px',
            borderBottom: `1px solid ${theme.white}20`,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', fontSize: '14px' }}>
            <Sparkles size={14} style={{ color: theme.magenta }} />
            <span style={{ color: theme.white, fontSize: '13px', fontWeight: 600 }}>{block.prompt}</span>
          </div>
          <button
            onClick={copyResponse}
            title={copied ? 'Copied' : 'Copy'}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '4px',
              fontSize: '11px',
              color: copied ? theme.cyan : theme.white,
              backgroundColor: 'transparent',
              border: 'none',
              cursor: 'pointer',
              borderRadius: '4px',
              transition: 'all 0.15s ease',
            }}
          >
            {copied ? (
              <Check size={14} />
            ) : (
              <Copy size={14} />
            )}
          </button>
        </div>
      )}

      {/* Response content - using Streamdown for AI responses */}
      {/* Only show if streaming or has response content */}
      {(block.isStreaming || (block.response && block.response.trim())) && (
        <>
          <style>{streamdownStyles}</style>
          <div
            className="streamdown-response"
            style={{
              padding: '16px',
              fontSize: `${settings.fontSize}px`,
              fontFamily: settings.font.family,
              lineHeight: settings.lineHeight,
              color: theme.foreground,
            }}
          >
            {block.isStreaming && !block.response ? (
              block.thinking ? (
                <ThinkingIndicator color={theme.magenta} />
              ) : (
                <StreamingIndicator color={theme.magenta} />
              )
            ) : (
              <Streamdown parseIncompleteMarkdown={block.isStreaming}>
                {block.response}
              </Streamdown>
            )}
          </div>
        </>
      )}

      {/* Thinking content - collapsible section for extended thinking */}
      {block.thinking && (
        <ThinkingSection thinking={block.thinking} theme={theme} fontFamily={settings.font.family} lineHeight={settings.lineHeight} />
      )}

      {/* Tool chips - displayed when tools were used */}
      {block.toolCalls && block.toolCalls.length > 0 && (
        <div
          style={{
            display: 'flex',
            flexWrap: 'wrap',
            gap: '6px',
            padding: '8px 16px',
            borderTop: `1px solid ${theme.white}10`,
          }}
        >
          {block.toolCalls.map((tool) => {
            const style = getToolStyle(tool.name)
            const Icon = style.icon
            const isCompleted = tool.status === 'completed'
            const isError = tool.status === 'error'
            const isPending = tool.status === 'pending' || tool.status === 'running'
            const isSelected = selectedTool?.id === tool.id

            return (
              <div key={tool.id} style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                <button
                  onClick={() => {
                    setSelectedTool(isSelected ? null : tool)
                    onToolClick?.(tool)
                  }}
                  title={`${tool.name} - Click to ${isSelected ? 'hide' : 'view'} details`}
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '5px',
                    padding: '3px 10px',
                    fontSize: '11px',
                    fontFamily: settings.font.family,
                    fontWeight: 500,
                    color: isError ? theme.red : `rgb(${style.bg})`,
                    backgroundColor: isSelected ? `rgba(${style.bg}, 0.2)` : `rgba(${style.bg}, 0.1)`,
                    border: `1px solid rgba(${style.border}, ${isSelected ? '0.5' : '0.3'})`,
                    borderRadius: '4px',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                    opacity: isPending ? 0.7 : 1,
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.backgroundColor = `rgba(${style.bg}, 0.2)`
                    e.currentTarget.style.borderColor = `rgba(${style.border}, 0.5)`
                  }}
                  onMouseLeave={(e) => {
                    if (!isSelected) {
                      e.currentTarget.style.backgroundColor = `rgba(${style.bg}, 0.1)`
                      e.currentTarget.style.borderColor = `rgba(${style.border}, 0.3)`
                    }
                  }}
                >
                  {isPending ? (
                    <Loader2 size={10} style={{ animation: 'spin 1s linear infinite' }} />
                  ) : isCompleted ? (
                    <Check size={10} />
                  ) : isError ? (
                    <X size={10} />
                  ) : (
                    <Icon size={10} />
                  )}
                  <span>{tool.name}</span>
                </button>
              </div>
            )
          })}
        </div>
      )}

      {/* Expanded tool details - inline below chips */}
      {selectedTool && (
        <div
          style={{
            padding: '12px 16px',
            borderTop: `1px solid ${theme.white}10`,
            backgroundColor: `${theme.brightBlack}10`,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '8px' }}>
            <span style={{ fontSize: '12px', color: theme.white, fontWeight: 600 }}>
              {selectedTool.name}
            </span>
            <button
              onClick={() => setSelectedTool(null)}
              style={{
                background: 'none',
                border: 'none',
                color: theme.brightBlack,
                cursor: 'pointer',
                padding: '2px',
              }}
            >
              <X size={14} />
            </button>
          </div>
          {selectedTool.input && Object.keys(selectedTool.input).length > 0 && (
            <div style={{ marginBottom: '8px' }}>
              <div style={{ fontSize: '10px', color: theme.brightBlack, marginBottom: '4px', textTransform: 'uppercase' }}>Input</div>
              {isEditToolInput(selectedTool.input) ? (
                <EditDiffViewer
                  oldString={selectedTool.input.oldString}
                  newString={selectedTool.input.newString}
                  filePath={selectedTool.input.filePath}
                  theme={theme}
                  fontFamily={settings.font.family}
                />
              ) : (
                <pre style={{
                  margin: 0,
                  padding: '8px',
                  backgroundColor: `${theme.brightBlack}20`,
                  borderRadius: '6px',
                  fontSize: '11px',
                  color: theme.foreground,
                  overflow: 'auto',
                  maxHeight: '150px',
                  fontFamily: settings.font.family,
                }}>
                  {JSON.stringify(selectedTool.input, null, 2)}
                </pre>
              )}
            </div>
          )}
          {selectedTool.output && (
            <div>
              <div style={{ fontSize: '10px', color: theme.brightBlack, marginBottom: '4px', textTransform: 'uppercase' }}>Output</div>
              <pre style={{
                margin: 0,
                padding: '8px',
                backgroundColor: `${theme.brightBlack}20`,
                borderRadius: '6px',
                fontSize: '11px',
                color: theme.foreground,
                overflow: 'auto',
                maxHeight: '200px',
                fontFamily: settings.font.family,
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
              }}>
                {selectedTool.output}
              </pre>
            </div>
          )}
          {!selectedTool.input && !selectedTool.output && (
            <div style={{ color: theme.brightBlack, fontSize: '11px' }}>
              No details available
            </div>
          )}
        </div>
      )}

      {/* Footer with model info and stats - only show if showModelInfo or has stats */}
      {(showModelInfo || block.tokens || block.cost !== undefined || block.duration) && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '8px 16px 12px',
            fontSize: '12px',
            color: theme.brightBlack,
            borderTop: `1px solid ${theme.white}10`,
          }}
        >
          {showModelInfo ? (
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <span style={{ color: theme.magenta, fontWeight: 500 }}>
                {block.provider || 'opencode'}
              </span>
              <span style={{ color: theme.foreground }}>
                {block.model}
              </span>
            </div>
          ) : (
            <div />
          )}

          {(block.tokens || block.cost !== undefined || block.duration) && (
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              {block.tokens && (block.tokens.input || block.tokens.output) && (
                <span title="Input / Output tokens" style={{ display: 'inline-flex', alignItems: 'center', gap: '6px' }}>
                  {block.tokens.input !== undefined && block.tokens.input > 0 && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: '2px' }}>
                      <span style={{ color: theme.green, opacity: 0.7 }}>↑</span>
                      <span style={{ color: theme.green }}>{block.tokens.input.toLocaleString()}</span>
                    </span>
                  )}
                  {block.tokens.output !== undefined && block.tokens.output > 0 && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: '2px' }}>
                      <span style={{ color: theme.blue, opacity: 0.7 }}>↓</span>
                      <span style={{ color: theme.blue }}>{block.tokens.output.toLocaleString()}</span>
                    </span>
                  )}
                </span>
              )}
              {block.cost !== undefined && block.cost > 0 && (
                <span style={{ color: theme.yellow }}>
                  ${block.cost.toFixed(4)}
                </span>
              )}
              {block.duration && (
                <span style={{ color: theme.brightBlack }}>
                  {(block.duration / 1000).toFixed(2)}s
                </span>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
})

import { useState, useEffect, useCallback, memo, useMemo, lazy, Suspense, useRef } from 'react'
import { createPortal } from 'react-dom'
import { readTextFile, writeTextFile } from '@tauri-apps/plugin-fs'
import { convertFileSrc } from '@tauri-apps/api/core'
import { Save, X, Eye, Edit2, FileCode, Image as ImageIcon, FileText, File, BookOpen, Palette, ChevronDown, Check, Loader2, Code } from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { type EditorPane as EditorPaneType } from '../types/tabs'
import { SYNTAX_THEMES, type SyntaxTheme } from '../config/terminal'
import { useLSP } from '../hooks/useLSP'
import Prism from 'prismjs'
import ReactMarkdown from 'react-markdown'

// Lazy load editor components to reduce initial bundle size
const CodeMirrorEditor = lazy(() => import('./editors/CodeMirrorEditor').then(m => ({ default: m.CodeMirrorEditor })))
const MonacoEditor = lazy(() => import('./editors/MonacoEditor').then(m => ({ default: m.MonacoEditor })))
const AceEditor = lazy(() => import('./editors/AceEditor').then(m => ({ default: m.AceEditor })))

// Import Prism languages
import 'prismjs/components/prism-typescript'
import 'prismjs/components/prism-javascript'
import 'prismjs/components/prism-jsx'
import 'prismjs/components/prism-tsx'
import 'prismjs/components/prism-css'
import 'prismjs/components/prism-scss'
import 'prismjs/components/prism-json'
import 'prismjs/components/prism-yaml'
import 'prismjs/components/prism-markdown'
import 'prismjs/components/prism-bash'
import 'prismjs/components/prism-python'
import 'prismjs/components/prism-rust'
import 'prismjs/components/prism-go'
import 'prismjs/components/prism-sql'
import 'prismjs/components/prism-toml'
import 'prismjs/components/prism-docker'
import 'prismjs/components/prism-graphql'

// Markdown preview is rendered via `react-markdown` to avoid XSS.

// Check if file is markdown
function isMarkdownFile(filePath: string): boolean {
  const ext = filePath.split('.').pop()?.toLowerCase()
  return ['md', 'mdx', 'markdown'].includes(ext || '')
}

interface EditorPaneProps {
  pane: EditorPaneType
  onClose?: () => void
}

// Detect language from file extension
function detectLanguage(filePath: string): string {
  const ext = filePath.split('.').pop()?.toLowerCase()
  const languageMap: Record<string, string> = {
    ts: 'typescript',
    tsx: 'tsx',
    js: 'javascript',
    jsx: 'jsx',
    py: 'python',
    rs: 'rust',
    go: 'go',
    rb: 'ruby',
    java: 'java',
    c: 'c',
    cpp: 'cpp',
    h: 'c',
    hpp: 'cpp',
    cs: 'csharp',
    php: 'php',
    swift: 'swift',
    kt: 'kotlin',
    scala: 'scala',
    r: 'r',
    sql: 'sql',
    sh: 'bash',
    bash: 'bash',
    zsh: 'bash',
    ps1: 'powershell',
    yaml: 'yaml',
    yml: 'yaml',
    json: 'json',
    xml: 'xml',
    html: 'html',
    htm: 'html',
    css: 'css',
    scss: 'scss',
    sass: 'sass',
    less: 'less',
    md: 'markdown',
    mdx: 'markdown',
    txt: 'plaintext',
    toml: 'toml',
    ini: 'ini',
    cfg: 'ini',
    conf: 'ini',
    dockerfile: 'docker',
    makefile: 'makefile',
    cmake: 'cmake',
    graphql: 'graphql',
    gql: 'graphql',
    vue: 'vue',
    svelte: 'svelte',
  }
  return languageMap[ext || ''] || 'plaintext'
}

// Map language names to Prism grammar keys
function getPrismLanguage(language: string): string {
  const prismMap: Record<string, string> = {
    typescript: 'typescript',
    tsx: 'tsx',
    javascript: 'javascript',
    jsx: 'jsx',
    python: 'python',
    rust: 'rust',
    go: 'go',
    bash: 'bash',
    shell: 'bash',
    sql: 'sql',
    yaml: 'yaml',
    json: 'json',
    css: 'css',
    scss: 'scss',
    markdown: 'markdown',
    toml: 'toml',
    docker: 'docker',
    dockerfile: 'docker',
    graphql: 'graphql',
  }
  return prismMap[language] || 'plaintext'
}

// Syntax highlight code using Prism
function highlightCode(code: string, language: string): string {
  const prismLang = getPrismLanguage(language)
  const grammar = Prism.languages[prismLang]

  if (grammar) {
    return Prism.highlight(code, grammar, prismLang)
  }

  // Fallback: escape HTML for plain text
  return code
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

// Check if file is an image
function isImageFile(filePath: string): boolean {
  const ext = filePath.split('.').pop()?.toLowerCase()
  return ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico'].includes(ext || '')
}

// Check if file is a video
function isVideoFile(filePath: string): boolean {
  const ext = filePath.split('.').pop()?.toLowerCase()
  return ['mp4', 'webm', 'mov', 'avi', 'mkv'].includes(ext || '')
}

// Check if file is audio
function isAudioFile(filePath: string): boolean {
  const ext = filePath.split('.').pop()?.toLowerCase()
  return ['mp3', 'wav', 'ogg', 'flac', 'aac', 'm4a'].includes(ext || '')
}

// Get file icon based on type
function getFileIcon(filePath: string): typeof FileCode {
  if (isImageFile(filePath)) return ImageIcon
  if (isVideoFile(filePath) || isAudioFile(filePath)) return File
  const lang = detectLanguage(filePath)
  if (lang === 'markdown') return FileText
  return FileCode
}

export const EditorPane = memo(function EditorPane({ pane, onClose }: EditorPaneProps) {
  const { settings, setSyntaxTheme } = useTerminalSettings()
  const theme = settings.theme
  const lsp = useLSP()

  const [content, setContent] = useState<string>('')
  const [originalContent, setOriginalContent] = useState<string>('')
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [isEditing, setIsEditing] = useState(!pane.isReadOnly)
  const [isSaving, setIsSaving] = useState(false)
  const [showPreview, setShowPreview] = useState(false)

  const hasChanges = content !== originalContent
  const fileName = pane.filePath.split('/').pop() || pane.filePath
  const language = pane.language || detectLanguage(pane.filePath)
  const FileIcon = getFileIcon(pane.filePath)
  const isMarkdown = isMarkdownFile(pane.filePath)

  // Memoize syntax-highlighted code for read-only view
  const highlightedCode = useMemo(() => {
    if (!isEditing && !showPreview && content) {
      return highlightCode(content, language)
    }
    return ''
  }, [content, language, isEditing, showPreview])

  // Load file content
  useEffect(() => {
    const loadFile = async () => {
      setIsLoading(true)
      setError(null)
      try {
        // For images/videos, we don't load text content
        if (isImageFile(pane.filePath) || isVideoFile(pane.filePath) || isAudioFile(pane.filePath)) {
          setIsLoading(false)
          return
        }
        const text = await readTextFile(pane.filePath)
        setContent(text)
        setOriginalContent(text)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load file')
      } finally {
        setIsLoading(false)
      }
    }
    loadFile()
  }, [pane.filePath])

  // Initialize LSP for the current workspace when enabled
  useEffect(() => {
    if (!settings.lsp?.enabled) return
    const projectPath = pane.filePath.substring(0, pane.filePath.lastIndexOf('/')) || '/'
    let cancelled = false
    ;(async () => {
      const ok = await lsp.init(projectPath)
      if (!ok && !cancelled) {
        console.warn('[EditorPane] LSP init failed for', projectPath)
      }
    })()
    return () => {
      cancelled = true
      void lsp.shutdown()
    }
  }, [lsp, pane.filePath, settings.lsp?.enabled])

  // Save file
  const handleSave = useCallback(async () => {
    if (!hasChanges || pane.isReadOnly) return
    setIsSaving(true)
    try {
      await writeTextFile(pane.filePath, content)
      setOriginalContent(content)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save file')
    } finally {
      setIsSaving(false)
    }
  }, [content, hasChanges, pane.filePath, pane.isReadOnly])

  // Keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault()
        handleSave()
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleSave])

  // Render image preview
  if (isImageFile(pane.filePath)) {
    return (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          backgroundColor: theme.background,
        }}
      >
        <EditorHeader
          fileName={fileName}
          FileIcon={FileIcon}
          isReadOnly
          onClose={onClose}
        />
        <div
          style={{
            flex: 1,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            overflow: 'auto',
          }}
        >
          <img
            src={convertFileSrc(pane.filePath)}
            alt={fileName}
            style={{
              maxWidth: '100%',
              maxHeight: '100%',
              objectFit: 'contain',
              borderRadius: '8px',
              boxShadow: '0 4px 24px rgba(0,0,0,0.3)',
            }}
          />
        </div>
      </div>
    )
  }

  // Render video preview
  if (isVideoFile(pane.filePath)) {
    return (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          backgroundColor: theme.background,
        }}
      >
        <EditorHeader
          fileName={fileName}
          FileIcon={FileIcon}
          isReadOnly
          onClose={onClose}
        />
        <div
          style={{
            flex: 1,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <video
            src={convertFileSrc(pane.filePath)}
            controls
            style={{
              maxWidth: '100%',
              maxHeight: '100%',
              borderRadius: '8px',
              boxShadow: '0 4px 24px rgba(0,0,0,0.3)',
            }}
          />
        </div>
      </div>
    )
  }

  // Render audio preview
  if (isAudioFile(pane.filePath)) {
    return (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          backgroundColor: theme.background,
        }}
      >
        <EditorHeader
          fileName={fileName}
          FileIcon={FileIcon}
          isReadOnly
          onClose={onClose}
        />
        <div
          style={{
            flex: 1,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <audio
            src={convertFileSrc(pane.filePath)}
            controls
            style={{ width: '100%', maxWidth: '500px' }}
          />
        </div>
      </div>
    )
  }

  // Loading state
  if (isLoading) {
    return (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: theme.background,
          color: theme.brightBlack,
        }}
      >
        Loading...
      </div>
    )
  }

  // Error state
  if (error) {
    return (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: theme.background,
          color: theme.red,
          gap: '8px',
        }}
      >
        <span>Error loading file</span>
        <span style={{ fontSize: '12px', color: theme.brightBlack }}>{error}</span>
      </div>
    )
  }

  // Text editor view
  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        backgroundColor: theme.background,
      }}
    >
      <EditorHeader
        fileName={fileName}
        FileIcon={FileIcon}
        hasChanges={hasChanges}
        isReadOnly={pane.isReadOnly}
        isEditing={isEditing}
        isSaving={isSaving}
        language={language}
        isMarkdown={isMarkdown}
        showPreview={showPreview}
        syntaxTheme={settings.editor.syntaxTheme}
        onSave={handleSave}
        onToggleEdit={() => setIsEditing(!isEditing)}
        onTogglePreview={() => setShowPreview(!showPreview)}
        onSyntaxThemeChange={setSyntaxTheme}
        onClose={onClose}
      />
      <div
        style={{
          flex: 1,
          overflow: 'hidden',
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        {showPreview && isMarkdown ? (
          <div
            className="markdown-preview"
            style={{
              color: theme.foreground,
              fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif',
              fontSize: '15px',
              lineHeight: 1.6,
              overflow: 'auto',
              padding: '12px 16px',
            }}
          >
            <ReactMarkdown>
              {content}
            </ReactMarkdown>
          </div>
        ) : settings.editor.editor === 'basic' ? (
          // Basic editor - simple textarea or syntax-highlighted view
          isEditing ? (
            <textarea
              value={content}
              onChange={(e) => setContent(e.target.value)}
              spellCheck={false}
              style={{
                width: '100%',
                height: '100%',
                backgroundColor: 'transparent',
                color: theme.foreground,
                fontFamily: settings.font.family,
                fontSize: `${settings.fontSize}px`,
                lineHeight: settings.lineHeight,
                border: 'none',
                outline: 'none',
                resize: 'none',
                tabSize: 2,
              }}
            />
          ) : (
            <pre
              style={{
                margin: 0,
                fontFamily: settings.font.family,
                fontSize: `${settings.fontSize}px`,
                lineHeight: settings.lineHeight,
                color: theme.foreground,
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
              }}
            >
              <code
                className={`language-${language}`}
                dangerouslySetInnerHTML={{ __html: highlightedCode }}
              />
            </pre>
          )
        ) : (
          // Advanced editors (CodeMirror, Monaco, Ace)
          <Suspense fallback={<div style={{ padding: '16px', color: theme.brightBlack }}>Loading editor...</div>}>
            {settings.editor.editor === 'codemirror' && (
              <CodeMirrorEditor
                value={content}
                onChange={setContent}
                language={language}
                filePath={pane.filePath}
                lspEnabled={settings.lsp?.enabled}
                readOnly={pane.isReadOnly || !isEditing}
                fontSize={settings.fontSize}
                fontFamily={settings.font.family}
                lineHeight={settings.lineHeight}
                wordWrap={settings.editor.wordWrap}
                syntaxTheme={settings.editor.syntaxTheme.id}
              />
            )}
            {settings.editor.editor === 'monaco' && (
              <MonacoEditor
                value={content}
                onChange={setContent}
                language={language}
                readOnly={pane.isReadOnly || !isEditing}
                fontSize={settings.fontSize}
                fontFamily={settings.font.family}
                lineHeight={settings.lineHeight}
                wordWrap={settings.editor.wordWrap}
                minimap={settings.editor.minimap}
              />
            )}
            {settings.editor.editor === 'ace' && (
              <AceEditor
                value={content}
                onChange={setContent}
                language={language}
                readOnly={pane.isReadOnly || !isEditing}
                fontSize={settings.fontSize}
                fontFamily={settings.font.family}
                wordWrap={settings.editor.wordWrap}
              />
            )}
          </Suspense>
        )}
      </div>
    </div>
  )
})

interface EditorHeaderProps {
  fileName: string
  FileIcon: typeof FileCode
  hasChanges?: boolean
  isReadOnly?: boolean
  isEditing?: boolean
  isSaving?: boolean
  language?: string
  isMarkdown?: boolean
  showPreview?: boolean
  syntaxTheme?: SyntaxTheme
  onSave?: () => void
  onToggleEdit?: () => void
  onTogglePreview?: () => void
  onSyntaxThemeChange?: (themeId: string) => void
  onClose?: () => void
}

function EditorHeader({
  fileName,
  FileIcon,
  hasChanges,
  isReadOnly,
  isEditing,
  isSaving,
  language,
  isMarkdown,
  showPreview,
  syntaxTheme,
  onSave,
  onToggleEdit,
  onTogglePreview,
  onSyntaxThemeChange,
  onClose,
}: EditorHeaderProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [showThemeDropdown, setShowThemeDropdown] = useState(false)
  const [dropdownPos, setDropdownPos] = useState({ top: 0, left: 0 })
  const buttonRef = useRef<HTMLButtonElement>(null)

  const handleToggleDropdown = useCallback(() => {
    if (!showThemeDropdown && buttonRef.current) {
      const rect = buttonRef.current.getBoundingClientRect()
      setDropdownPos({ top: rect.bottom + 4, left: rect.right - 200 })
    }
    setShowThemeDropdown(!showThemeDropdown)
  }, [showThemeDropdown])

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '8px 16px',
        borderBottom: `1px solid ${theme.white}20`,
        backgroundColor: `${theme.brightBlack}20`,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
        <FileIcon size={16} style={{ color: theme.brightBlack }} />
        <span style={{ fontSize: '14px', color: theme.foreground }}>
          {fileName}
          {hasChanges && <span style={{ color: theme.yellow, marginLeft: '4px' }}>•</span>}
        </span>
        {language && (
          <span
            style={{
              fontSize: '11px',
              color: theme.brightBlack,
              backgroundColor: `${theme.white}10`,
              padding: '2px 6px',
              borderRadius: '4px',
            }}
          >
            {language}
          </span>
        )}
        {isReadOnly && (
          <span
            style={{
              fontSize: '11px',
              color: theme.yellow,
              backgroundColor: `${theme.yellow}20`,
              padding: '2px 6px',
              borderRadius: '4px',
            }}
          >
            read-only
          </span>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
        {/* Syntax Theme dropdown */}
        {onSyntaxThemeChange && syntaxTheme && (
          <div style={{ position: 'relative' }}>
            <button
              ref={buttonRef}
              onClick={handleToggleDropdown}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '4px',
                padding: '4px 8px',
                backgroundColor: showThemeDropdown ? `${theme.magenta}30` : 'transparent',
                border: 'none',
                borderRadius: '4px',
                color: showThemeDropdown ? theme.magenta : theme.brightBlack,
                cursor: 'pointer',
                fontSize: '12px',
              }}
              title="Syntax theme"
            >
              <Palette size={14} />
              <span style={{ maxWidth: '80px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {syntaxTheme.name}
              </span>
              <ChevronDown size={12} />
            </button>
            {showThemeDropdown && createPortal(
              <div
                style={{
                  position: 'fixed',
                  top: dropdownPos.top,
                  left: dropdownPos.left,
                  width: '200px',
                  maxHeight: '300px',
                  overflowY: 'auto',
                  backgroundColor: theme.background,
                  border: `1px solid ${theme.brightBlack}`,
                  borderRadius: '8px',
                  boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
                  zIndex: 999999,
                }}
              >
                <div style={{ padding: '4px', fontSize: '11px', color: theme.brightBlack, borderBottom: `1px solid ${theme.brightBlack}30` }}>
                  Dark Themes
                </div>
                {SYNTAX_THEMES.filter(t => t.category === 'dark').map(t => (
                  <button
                    key={t.id}
                    onClick={() => {
                      onSyntaxThemeChange(t.id)
                      setShowThemeDropdown(false)
                    }}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      width: '100%',
                      padding: '8px 12px',
                      backgroundColor: t.id === syntaxTheme.id ? `${theme.cyan}20` : 'transparent',
                      border: 'none',
                      color: theme.foreground,
                      cursor: 'pointer',
                      fontSize: '13px',
                      textAlign: 'left',
                    }}
                  >
                    {t.name}
                    {t.id === syntaxTheme.id && <Check size={14} style={{ color: theme.cyan }} />}
                  </button>
                ))}
                <div style={{ padding: '4px', fontSize: '11px', color: theme.brightBlack, borderTop: `1px solid ${theme.brightBlack}30`, borderBottom: `1px solid ${theme.brightBlack}30` }}>
                  Light Themes
                </div>
                {SYNTAX_THEMES.filter(t => t.category === 'light').map(t => (
                  <button
                    key={t.id}
                    onClick={() => {
                      onSyntaxThemeChange(t.id)
                      setShowThemeDropdown(false)
                    }}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      width: '100%',
                      padding: '8px 12px',
                      backgroundColor: t.id === syntaxTheme.id ? `${theme.cyan}20` : 'transparent',
                      border: 'none',
                      color: theme.foreground,
                      cursor: 'pointer',
                      fontSize: '13px',
                      textAlign: 'left',
                    }}
                  >
                    {t.name}
                    {t.id === syntaxTheme.id && <Check size={14} style={{ color: theme.cyan }} />}
                  </button>
                ))}
              </div>,
              document.body
            )}
          </div>
        )}
        {/* Markdown preview toggle */}
        {isMarkdown && onTogglePreview && (
          <button
            onClick={onTogglePreview}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '4px',
              backgroundColor: showPreview ? `${theme.magenta}30` : 'transparent',
              border: 'none',
              borderRadius: '4px',
              color: showPreview ? theme.magenta : theme.brightBlack,
              cursor: 'pointer',
            }}
            title={showPreview ? 'Show source' : 'Preview markdown'}
          >
            {showPreview ? <Code size={14} /> : <BookOpen size={14} />}
          </button>
        )}
        {onToggleEdit && !isReadOnly && !showPreview && (
          <button
            onClick={onToggleEdit}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '4px',
              backgroundColor: isEditing ? `${theme.cyan}30` : 'transparent',
              border: 'none',
              borderRadius: '4px',
              color: isEditing ? theme.cyan : theme.brightBlack,
              cursor: 'pointer',
            }}
            title={isEditing ? 'View mode' : 'Edit mode'}
          >
            {isEditing ? <Eye size={14} /> : <Edit2 size={14} />}
          </button>
        )}
        {onSave && hasChanges && !isReadOnly && (
          <button
            onClick={onSave}
            disabled={isSaving}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '4px',
              backgroundColor: theme.green,
              border: 'none',
              borderRadius: '4px',
              color: theme.background,
              cursor: isSaving ? 'wait' : 'pointer',
              opacity: isSaving ? 0.7 : 1,
            }}
            title={isSaving ? 'Saving...' : 'Save (⌘S)'}
          >
            {isSaving ? (
              <Loader2 size={14} style={{ animation: 'spin 1s linear infinite' }} />
            ) : (
              <Save size={14} />
            )}
          </button>
        )}
        {onClose && (
          <button
            onClick={onClose}
            style={{
              display: 'flex',
              alignItems: 'center',
              padding: '4px',
              backgroundColor: 'transparent',
              border: 'none',
              borderRadius: '4px',
              color: theme.brightBlack,
              cursor: 'pointer',
            }}
            title="Close"
          >
            <X size={16} />
          </button>
        )}
      </div>
    </div>
  )
}

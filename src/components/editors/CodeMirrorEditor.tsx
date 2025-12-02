import { useEffect, useRef } from 'react'
import { EditorState, Extension } from '@codemirror/state'
import { EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars, drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightActiveLine, hoverTooltip } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { syntaxHighlighting, defaultHighlightStyle, bracketMatching, foldGutter, indentOnInput } from '@codemirror/language'
import { autocompletion, completionKeymap, closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete'
import { lspService, type Hover } from '../../services/lsp'
import { oneDark } from '@codemirror/theme-one-dark'
import { dracula } from '@uiw/codemirror-theme-dracula'
import { githubDark, githubLight } from '@uiw/codemirror-theme-github'
import { nord } from '@uiw/codemirror-theme-nord'
import { tokyoNight } from '@uiw/codemirror-theme-tokyo-night'

// Language imports
import { javascript } from '@codemirror/lang-javascript'
import { python } from '@codemirror/lang-python'
import { rust } from '@codemirror/lang-rust'
import { css } from '@codemirror/lang-css'
import { html } from '@codemirror/lang-html'
import { json } from '@codemirror/lang-json'
import { markdown } from '@codemirror/lang-markdown'
import { sql } from '@codemirror/lang-sql'
import { xml } from '@codemirror/lang-xml'
import { yaml } from '@codemirror/lang-yaml'

interface CodeMirrorEditorProps {
  value: string
  onChange: (value: string) => void
  language: string
  filePath?: string
  lspEnabled?: boolean
  readOnly?: boolean
  fontSize?: number
  fontFamily?: string
  lineHeight?: number
  wordWrap?: boolean
  syntaxTheme?: string
}

/**
 * Extract text content from LSP hover result
 */
function extractHoverContent(contents: Hover['contents']): string {
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
 * Create LSP hover tooltip extension for CodeMirror
 */
function createLSPHoverExtension(filePath: string): Extension {
  return hoverTooltip(async (view, pos) => {
    // Get line and character position
    const line = view.state.doc.lineAt(pos)
    const lineNumber = line.number - 1 // LSP uses 0-based lines
    const character = pos - line.from

    try {
      const result = await lspService.hover(filePath, lineNumber, character)
      if (!result.success || !result.data) {
        return null
      }

      const content = extractHoverContent(result.data.contents)
      if (!content) return null

      return {
        pos,
        end: pos,
        above: true,
        create() {
          const dom = document.createElement('div')
          dom.className = 'cm-lsp-tooltip'
          dom.style.cssText = `
            background: #1e1e2e;
            border: 1px solid #45475a;
            border-radius: 6px;
            padding: 8px 12px;
            max-width: 500px;
            font-size: 12px;
            font-family: JetBrains Mono, monospace;
            color: #cdd6f4;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
            white-space: pre-wrap;
            overflow: auto;
            max-height: 300px;
          `
          // Simple markdown-like rendering for code blocks
          const formattedContent = content
            .replace(/```(\w*)\n?([\s\S]*?)```/g, '<pre style="background: #11111b; padding: 8px; border-radius: 4px; margin: 4px 0; color: #f9e2af;">$2</pre>')
            .replace(/`([^`]+)`/g, '<code style="background: #11111b; padding: 2px 6px; border-radius: 3px; color: #f9e2af;">$1</code>')
            .replace(/\n/g, '<br>')

          dom.innerHTML = formattedContent
          return { dom }
        },
      }
    } catch (error) {
      console.error('[LSP] Hover error:', error)
      return null
    }
  }, { hideOnChange: true })
}

// Map theme IDs to CodeMirror theme extensions
function getThemeExtension(themeId: string): Extension {
  switch (themeId) {
    case 'dracula':
      return dracula
    case 'githubDark':
      return githubDark
    case 'githubLight':
      return githubLight
    case 'nord':
      return nord
    case 'tokyoNight':
      return tokyoNight
    case 'oneDark':
    default:
      return oneDark
  }
}

function getLanguageExtension(language: string) {
  switch (language) {
    case 'javascript':
    case 'jsx':
      return javascript({ jsx: true })
    case 'typescript':
    case 'tsx':
      return javascript({ jsx: true, typescript: true })
    case 'python':
      return python()
    case 'rust':
      return rust()
    case 'css':
    case 'scss':
    case 'sass':
    case 'less':
      return css()
    case 'html':
      return html()
    case 'json':
      return json()
    case 'markdown':
      return markdown()
    case 'sql':
      return sql()
    case 'xml':
      return xml()
    case 'yaml':
      return yaml()
    default:
      return []
  }
}

export function CodeMirrorEditor({
  value,
  onChange,
  language,
  filePath,
  lspEnabled = false,
  readOnly = false,
  fontSize = 14,
  fontFamily = 'JetBrains Mono, monospace',
  lineHeight = 1.5,
  wordWrap = true,
  syntaxTheme = 'oneDark',
}: CodeMirrorEditorProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const viewRef = useRef<EditorView | null>(null)

  useEffect(() => {
    if (!containerRef.current) return

    console.log('[CodeMirrorEditor] Creating editor with theme:', syntaxTheme)

    const extensions = [
      lineNumbers(),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      history(),
      foldGutter(),
      drawSelection(),
      dropCursor(),
      EditorState.allowMultipleSelections.of(true),
      indentOnInput(),
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      bracketMatching(),
      closeBrackets(),
      autocompletion(),
      rectangularSelection(),
      crosshairCursor(),
      highlightActiveLine(),
      keymap.of([
        ...closeBracketsKeymap,
        ...defaultKeymap,
        ...historyKeymap,
        ...completionKeymap,
      ]),
      getThemeExtension(syntaxTheme),
      getLanguageExtension(language),
      EditorView.updateListener.of((update) => {
        if (update.docChanged) {
          onChange(update.state.doc.toString())
        }
      }),
      EditorView.theme({
        '&': {
          height: '100%',
          fontSize: `${fontSize}px`,
        },
        '.cm-scroller': {
          fontFamily,
          lineHeight: `${lineHeight}`,
          overflow: 'auto',
        },
        '.cm-content': {
          caretColor: '#528bff',
        },
        '.cm-gutters': {
          backgroundColor: 'transparent',
          borderRight: 'none',
        },
      }),
    ]

    if (wordWrap) {
      extensions.push(EditorView.lineWrapping)
    }

    if (readOnly) {
      extensions.push(EditorState.readOnly.of(true))
    }

    // Add LSP hover extension if enabled and file path is provided
    if (lspEnabled && filePath) {
      extensions.push(createLSPHoverExtension(filePath))
    }

    const state = EditorState.create({
      doc: value,
      extensions,
    })

    const view = new EditorView({
      state,
      parent: containerRef.current,
    })

    viewRef.current = view

    return () => {
      view.destroy()
      viewRef.current = null
    }
  }, [language, filePath, lspEnabled, readOnly, fontSize, fontFamily, lineHeight, wordWrap, syntaxTheme])

  // Update content when value changes externally
  useEffect(() => {
    if (viewRef.current) {
      const currentValue = viewRef.current.state.doc.toString()
      if (currentValue !== value) {
        viewRef.current.dispatch({
          changes: {
            from: 0,
            to: currentValue.length,
            insert: value,
          },
        })
      }
    }
  }, [value])

  return (
    <div
      ref={containerRef}
      style={{
        width: '100%',
        height: '100%',
        overflow: 'hidden',
      }}
    />
  )
}

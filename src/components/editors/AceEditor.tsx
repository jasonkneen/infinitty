import { useEffect, useRef } from 'react'
import ace from 'ace-builds'
import 'ace-builds/src-noconflict/theme-one_dark'
import 'ace-builds/src-noconflict/ext-language_tools'

// Import modes
import 'ace-builds/src-noconflict/mode-javascript'
import 'ace-builds/src-noconflict/mode-typescript'
import 'ace-builds/src-noconflict/mode-python'
import 'ace-builds/src-noconflict/mode-rust'
import 'ace-builds/src-noconflict/mode-css'
import 'ace-builds/src-noconflict/mode-scss'
import 'ace-builds/src-noconflict/mode-html'
import 'ace-builds/src-noconflict/mode-json'
import 'ace-builds/src-noconflict/mode-markdown'
import 'ace-builds/src-noconflict/mode-sql'
import 'ace-builds/src-noconflict/mode-xml'
import 'ace-builds/src-noconflict/mode-yaml'
import 'ace-builds/src-noconflict/mode-golang'
import 'ace-builds/src-noconflict/mode-java'
import 'ace-builds/src-noconflict/mode-c_cpp'
import 'ace-builds/src-noconflict/mode-csharp'
import 'ace-builds/src-noconflict/mode-php'
import 'ace-builds/src-noconflict/mode-ruby'
import 'ace-builds/src-noconflict/mode-swift'
import 'ace-builds/src-noconflict/mode-kotlin'
import 'ace-builds/src-noconflict/mode-scala'
import 'ace-builds/src-noconflict/mode-sh'
import 'ace-builds/src-noconflict/mode-powershell'
import 'ace-builds/src-noconflict/mode-dockerfile'
import 'ace-builds/src-noconflict/mode-graphqlschema'
import 'ace-builds/src-noconflict/mode-toml'

interface AceEditorProps {
  value: string
  onChange: (value: string) => void
  language: string
  readOnly?: boolean
  fontSize?: number
  fontFamily?: string
  lineHeight?: number
  wordWrap?: boolean
  minimap?: boolean
}

function mapLanguageToAceMode(language: string): string {
  const modeMap: Record<string, string> = {
    javascript: 'javascript',
    jsx: 'javascript',
    typescript: 'typescript',
    tsx: 'typescript',
    python: 'python',
    rust: 'rust',
    css: 'css',
    scss: 'scss',
    sass: 'scss',
    less: 'css',
    html: 'html',
    json: 'json',
    markdown: 'markdown',
    sql: 'sql',
    xml: 'xml',
    yaml: 'yaml',
    go: 'golang',
    java: 'java',
    c: 'c_cpp',
    cpp: 'c_cpp',
    csharp: 'csharp',
    php: 'php',
    ruby: 'ruby',
    swift: 'swift',
    kotlin: 'kotlin',
    scala: 'scala',
    bash: 'sh',
    shell: 'sh',
    powershell: 'powershell',
    dockerfile: 'dockerfile',
    docker: 'dockerfile',
    graphql: 'graphqlschema',
    toml: 'toml',
    plaintext: 'text',
  }
  return modeMap[language] || 'text'
}

export function AceEditor({
  value,
  onChange,
  language,
  readOnly = false,
  fontSize = 14,
  fontFamily = 'JetBrains Mono, monospace',
  wordWrap = true,
}: AceEditorProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const editorRef = useRef<ace.Ace.Editor | null>(null)
  const isUpdatingRef = useRef(false)

  useEffect(() => {
    if (!containerRef.current) return

    // Enable autocomplete
    ace.require('ace/ext/language_tools')

    const editor = ace.edit(containerRef.current, {
      theme: 'ace/theme/one_dark',
      mode: `ace/mode/${mapLanguageToAceMode(language)}`,
      value,
      fontSize,
      fontFamily,
      readOnly,
      wrap: wordWrap,
      showPrintMargin: false,
      highlightActiveLine: true,
      highlightSelectedWord: true,
      showGutter: true,
      enableBasicAutocompletion: true,
      enableLiveAutocompletion: true,
      enableSnippets: true,
      tabSize: 2,
      useSoftTabs: true,
      scrollPastEnd: 0.5,
    })

    editor.on('change', () => {
      if (!isUpdatingRef.current) {
        onChange(editor.getValue())
      }
    })

    editorRef.current = editor

    return () => {
      editor.destroy()
      editorRef.current = null
    }
  }, [])

  // Update options when props change
  useEffect(() => {
    if (editorRef.current) {
      editorRef.current.setFontSize(fontSize)
      editorRef.current.setOption('fontFamily', fontFamily)
      editorRef.current.setReadOnly(readOnly)
      editorRef.current.session.setUseWrapMode(wordWrap)
      editorRef.current.session.setMode(`ace/mode/${mapLanguageToAceMode(language)}`)
    }
  }, [fontSize, fontFamily, readOnly, wordWrap, language])

  // Update value when it changes externally
  useEffect(() => {
    if (editorRef.current && editorRef.current.getValue() !== value) {
      isUpdatingRef.current = true
      const cursor = editorRef.current.getCursorPosition()
      editorRef.current.setValue(value, -1)
      editorRef.current.moveCursorToPosition(cursor)
      isUpdatingRef.current = false
    }
  }, [value])

  return (
    <div
      ref={containerRef}
      style={{
        width: '100%',
        height: '100%',
      }}
    />
  )
}

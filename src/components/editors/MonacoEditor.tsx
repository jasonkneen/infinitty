import Editor, { loader } from '@monaco-editor/react'
import { useRef } from 'react'

// Configure Monaco to use local assets instead of CDN
loader.config({
  paths: {
    vs: 'https://cdn.jsdelivr.net/npm/monaco-editor@0.45.0/min/vs'
  }
})

interface MonacoEditorProps {
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

function mapLanguage(language: string): string {
  const languageMap: Record<string, string> = {
    js: 'javascript',
    jsx: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    go: 'go',
    java: 'java',
    c: 'c',
    cpp: 'cpp',
    cs: 'csharp',
    php: 'php',
    swift: 'swift',
    kt: 'kotlin',
    scala: 'scala',
    sh: 'shell',
    bash: 'shell',
    zsh: 'shell',
    ps1: 'powershell',
    yml: 'yaml',
    md: 'markdown',
    mdx: 'markdown',
    dockerfile: 'dockerfile',
    graphql: 'graphql',
    gql: 'graphql',
  }
  return languageMap[language] || language
}

export function MonacoEditor({
  value,
  onChange,
  language,
  readOnly = false,
  fontSize = 14,
  fontFamily = 'JetBrains Mono, monospace',
  lineHeight = 1.5,
  wordWrap = true,
  minimap = false,
}: MonacoEditorProps) {
  const editorRef = useRef<unknown>(null)

  const handleEditorDidMount = (editor: unknown) => {
    editorRef.current = editor
  }

  const handleChange = (value: string | undefined) => {
    if (value !== undefined) {
      onChange(value)
    }
  }

  return (
    <Editor
      height="100%"
      language={mapLanguage(language)}
      value={value}
      onChange={handleChange}
      onMount={handleEditorDidMount}
      theme="vs-dark"
      options={{
        readOnly,
        fontSize,
        fontFamily,
        lineHeight,
        wordWrap: wordWrap ? 'on' : 'off',
        minimap: { enabled: minimap },
        scrollBeyondLastLine: false,
        automaticLayout: true,
        padding: { top: 16 },
        scrollbar: {
          verticalScrollbarSize: 10,
          horizontalScrollbarSize: 10,
        },
        renderLineHighlight: 'line',
        cursorBlinking: 'smooth',
        cursorSmoothCaretAnimation: 'on',
        smoothScrolling: true,
        bracketPairColorization: { enabled: true },
        guides: {
          bracketPairs: true,
          indentation: true,
        },
        suggest: {
          showMethods: true,
          showFunctions: true,
          showConstructors: true,
          showFields: true,
          showVariables: true,
          showClasses: true,
          showStructs: true,
          showInterfaces: true,
          showModules: true,
          showProperties: true,
          showEvents: true,
          showOperators: true,
          showUnits: true,
          showValues: true,
          showConstants: true,
          showEnums: true,
          showEnumMembers: true,
          showKeywords: true,
          showWords: true,
          showColors: true,
          showFiles: true,
          showReferences: true,
          showFolders: true,
          showTypeParameters: true,
          showSnippets: true,
        },
      }}
    />
  )
}

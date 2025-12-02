import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
import { TERMINAL_THEMES, TERMINAL_FONTS, UI_FONTS, SYNTAX_THEMES, type TerminalTheme, type TerminalFont, type UIFont, type SyntaxTheme } from '../config/terminal'
import { useGhosttyConfig, type GhosttyConfig } from '../hooks/useGhosttyConfig'
import { getErrorMessage } from '../lib/utils'

export interface BackgroundSettings {
  enabled: boolean
  type: 'image' | 'video'
  imagePath: string | null
  videoPath: string | null
  opacity: number // 0-100
  blur: number // 0-20px
  position: 'cover' | 'contain' | 'tile' | 'center'
  videoMuted: boolean
  videoLoop: boolean
}

export interface WindowSettings {
  opacity: number // 0-100 (window transparency)
  blur: number // blur amount in pixels (0-20), applied when opacity < 100
  nativeTabs: boolean // use native macOS tab styling (requires restart)
  nativeContextMenus: boolean // use native context menus (requires restart)
  tabStyle: 'compact' | 'fill' // compact = fixed size, fill = expand to fill bar
}

export type LinkClickBehavior = 'webview' | 'browser' | 'disabled'

export type CodeEditorType = 'codemirror' | 'monaco' | 'ace' | 'basic'

export interface EditorSettings {
  editor: CodeEditorType // which code editor to use
  minimap: boolean // show minimap (monaco/ace)
  wordWrap: boolean // wrap long lines
  syntaxTheme: SyntaxTheme // syntax highlighting theme
}

export interface BehaviorSettings {
  linkClickBehavior: LinkClickBehavior // what happens when clicking links in terminal
}

export interface LSPSettings {
  enabled: boolean // Master toggle for LSP features
  servers: Record<string, boolean> // Per-server enable/disable
}

export interface TerminalSettings {
  theme: TerminalTheme
  font: TerminalFont           // Monospace font for terminal/code
  uiFont: UIFont               // Sans font for app UI
  fontSize: number             // Terminal font size
  uiFontSize: number           // UI font size
  lineHeight: number
  paragraphSpacing: number     // Spacing between paragraphs in AI responses (in pixels)
  letterSpacing: number        // Terminal letter spacing in pixels
  uiLineHeight: number         // UI line height for app interface
  fontThicken: boolean         // Use subpixel antialiasing for bolder fonts on retina
  cursorBlink: boolean
  cursorStyle: 'block' | 'underline' | 'bar'
  scrollback: number
  background: BackgroundSettings
  window: WindowSettings
  behavior: BehaviorSettings
  editor: EditorSettings
  lsp: LSPSettings
}

interface TerminalSettingsContextType {
  settings: TerminalSettings
  setTheme: (themeId: string) => void
  setFont: (fontId: string) => void
  setUIFont: (fontId: string) => void
  setFontSize: (size: number) => void
  setUIFontSize: (size: number) => void
  setLineHeight: (height: number) => void
  setParagraphSpacing: (spacing: number) => void
  setLetterSpacing: (spacing: number) => void
  setUILineHeight: (height: number) => void
  setCursorBlink: (blink: boolean) => void
  setCursorStyle: (style: 'block' | 'underline' | 'bar') => void
  setScrollback: (lines: number) => void
  setBackgroundEnabled: (enabled: boolean) => void
  setBackgroundType: (type: BackgroundSettings['type']) => void
  setBackgroundImage: (path: string | null) => void
  setBackgroundVideo: (path: string | null) => void
  setBackgroundOpacity: (opacity: number) => void
  setBackgroundBlur: (blur: number) => void
  setBackgroundPosition: (position: BackgroundSettings['position']) => void
  setVideoMuted: (muted: boolean) => void
  setVideoLoop: (loop: boolean) => void
  setWindowOpacity: (opacity: number) => void
  setWindowBlur: (blur: number) => void
  setNativeTabs: (enabled: boolean) => void
  setNativeContextMenus: (enabled: boolean) => void
  setTabStyle: (style: WindowSettings['tabStyle']) => void
  setFontThicken: (enabled: boolean) => void
  setLinkClickBehavior: (behavior: LinkClickBehavior) => void
  setCodeEditor: (editor: CodeEditorType) => void
  setEditorMinimap: (enabled: boolean) => void
  setEditorWordWrap: (enabled: boolean) => void
  setSyntaxTheme: (themeId: string) => void
  setLSPEnabled: (enabled: boolean) => void
  setLSPServerEnabled: (serverId: string, enabled: boolean) => void
  resetToDefaults: () => void
  // Ghostty config integration
  ghosttyConfig: GhosttyConfig | null
  ghosttyConfigLoading: boolean
}

const defaultSettings: TerminalSettings = {
  theme: TERMINAL_THEMES.find((t: TerminalTheme) => t.id === 'tokyo-night') || TERMINAL_THEMES[0],
  font: TERMINAL_FONTS.find((f: TerminalFont) => f.id === 'jetbrains-mono') || TERMINAL_FONTS[0],
  uiFont: UI_FONTS.find((f: UIFont) => f.id === 'inter') || UI_FONTS[0],
  fontSize: 14,
  uiFontSize: 14,
  lineHeight: 1.2,
  paragraphSpacing: 18,
  letterSpacing: 0,
  uiLineHeight: 1.5,
  fontThicken: false,
  cursorBlink: true,
  cursorStyle: 'block',
  scrollback: 1000,
  background: {
    enabled: false,
    type: 'image',
    imagePath: null,
    videoPath: null,
    opacity: 30,
    blur: 0,
    position: 'cover',
    videoMuted: true,
    videoLoop: true,
  },
  window: {
    opacity: 30,
    blur: 10,
    nativeTabs: true,
    nativeContextMenus: true,
    tabStyle: 'compact',
  },
  behavior: {
    linkClickBehavior: 'webview',
  },
  editor: {
    editor: 'codemirror',
    minimap: false,
    wordWrap: true,
    syntaxTheme: SYNTAX_THEMES.find((t) => t.id === 'oneDark') || SYNTAX_THEMES[0],
  },
  lsp: {
    enabled: true,
    servers: {
      'typescript-language-server': true,
      'pyright': true,
      'gopls': true,
      'rust-analyzer': true,
      'vscode-css-language-server': true,
      'vscode-html-language-server': true,
      'vscode-json-language-server': true,
      'yaml-language-server': true,
      'bash-language-server': true,
      'tailwindcss-language-server': true,
    },
  },
}

const STORAGE_KEY = 'terminal-settings'

function loadSettings(): TerminalSettings {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored) {
      const parsed = JSON.parse(stored)
      // Resolve theme and fonts by ID
      return {
        ...defaultSettings,
        ...parsed,
        theme: TERMINAL_THEMES.find((t: TerminalTheme) => t.id === parsed.themeId) || defaultSettings.theme,
        font: TERMINAL_FONTS.find((f: TerminalFont) => f.id === parsed.fontId) || defaultSettings.font,
        uiFont: UI_FONTS.find((f: UIFont) => f.id === parsed.uiFontId) || defaultSettings.uiFont,
        uiLineHeight: parsed.uiLineHeight ?? defaultSettings.uiLineHeight,
        paragraphSpacing: parsed.paragraphSpacing ?? defaultSettings.paragraphSpacing,
        letterSpacing: parsed.letterSpacing ?? defaultSettings.letterSpacing,
        fontThicken: parsed.fontThicken ?? defaultSettings.fontThicken,
        behavior: parsed.behavior ?? defaultSettings.behavior,
        editor: {
          ...(parsed.editor ?? defaultSettings.editor),
          syntaxTheme: parsed.editor?.syntaxThemeId
            ? SYNTAX_THEMES.find((t) => t.id === parsed.editor.syntaxThemeId) || defaultSettings.editor.syntaxTheme
            : parsed.editor?.syntaxTheme || defaultSettings.editor.syntaxTheme,
        },
        lsp: {
          enabled: parsed.lsp?.enabled ?? defaultSettings.lsp.enabled,
          servers: { ...defaultSettings.lsp.servers, ...(parsed.lsp?.servers ?? {}) },
        },
      }
    }
  } catch (error: unknown) {
    console.warn('[TerminalSettings] Failed to load settings:', getErrorMessage(error))
  }
  return defaultSettings
}

function saveSettings(settings: TerminalSettings): void {
  try {
    // Store IDs instead of full objects
    const toStore = {
      themeId: settings.theme.id,
      fontId: settings.font.id,
      uiFontId: settings.uiFont.id,
      fontSize: settings.fontSize,
      uiFontSize: settings.uiFontSize,
      lineHeight: settings.lineHeight,
      paragraphSpacing: settings.paragraphSpacing,
      letterSpacing: settings.letterSpacing,
      uiLineHeight: settings.uiLineHeight,
      fontThicken: settings.fontThicken,
      cursorBlink: settings.cursorBlink,
      cursorStyle: settings.cursorStyle,
      scrollback: settings.scrollback,
      background: settings.background,
      window: settings.window,
      behavior: settings.behavior,
      editor: {
        ...settings.editor,
        syntaxThemeId: settings.editor.syntaxTheme.id,
      },
      lsp: settings.lsp,
    }
    localStorage.setItem(STORAGE_KEY, JSON.stringify(toStore))
  } catch (error: unknown) {
    console.warn('[TerminalSettings] Failed to save settings:', getErrorMessage(error))
  }
}

const TerminalSettingsContext = createContext<TerminalSettingsContextType | null>(null)

export function TerminalSettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<TerminalSettings>(loadSettings)
  const { config: ghosttyConfig, loading: ghosttyConfigLoading } = useGhosttyConfig()

  // Apply Ghostty config on first load if no saved settings exist
  useEffect(() => {
    if (ghosttyConfigLoading || !ghosttyConfig) return

    // Only apply Ghostty config if user hasn't customized settings
    const hasCustomSettings = localStorage.getItem(STORAGE_KEY) !== null
    if (hasCustomSettings) return

    // Apply Ghostty settings
    const updates: Partial<TerminalSettings> = {}

    if (ghosttyConfig.fontSize) {
      updates.fontSize = ghosttyConfig.fontSize
    }

    if (ghosttyConfig.cursorStyle) {
      updates.cursorStyle = ghosttyConfig.cursorStyle
    }

    if (ghosttyConfig.cursorBlink !== undefined) {
      updates.cursorBlink = ghosttyConfig.cursorBlink
    }

    if (ghosttyConfig.scrollbackLines) {
      updates.scrollback = ghosttyConfig.scrollbackLines
    }

    if (Object.keys(updates).length > 0) {
      setSettings(prev => ({ ...prev, ...updates }))
    }
  }, [ghosttyConfig, ghosttyConfigLoading])

  const updateSettings = useCallback((updates: Partial<TerminalSettings>) => {
    setSettings(prev => {
      const next = { ...prev, ...updates }
      saveSettings(next)
      return next
    })
  }, [])

  const setTheme = useCallback((themeId: string) => {
    const theme = TERMINAL_THEMES.find((t: TerminalTheme) => t.id === themeId)
    if (theme) updateSettings({ theme })
  }, [updateSettings])

  const setFont = useCallback((fontId: string) => {
    const font = TERMINAL_FONTS.find((f: TerminalFont) => f.id === fontId)
    if (font) updateSettings({ font })
  }, [updateSettings])

  const setUIFont = useCallback((fontId: string) => {
    const uiFont = UI_FONTS.find((f: UIFont) => f.id === fontId)
    if (uiFont) updateSettings({ uiFont })
  }, [updateSettings])

  const setFontSize = useCallback((fontSize: number) => {
    updateSettings({ fontSize: Math.max(8, Math.min(32, fontSize)) })
  }, [updateSettings])

  const setUIFontSize = useCallback((uiFontSize: number) => {
    updateSettings({ uiFontSize: Math.max(10, Math.min(24, uiFontSize)) })
  }, [updateSettings])

  const setLineHeight = useCallback((lineHeight: number) => {
    updateSettings({ lineHeight: Math.max(0.8, Math.min(2.5, lineHeight)) })
  }, [updateSettings])

  const setParagraphSpacing = useCallback((paragraphSpacing: number) => {
    updateSettings({ paragraphSpacing: Math.max(0, Math.min(48, paragraphSpacing)) })
  }, [updateSettings])

  const setLetterSpacing = useCallback((letterSpacing: number) => {
    updateSettings({ letterSpacing: Math.max(-2, Math.min(5, letterSpacing)) })
  }, [updateSettings])

  const setUILineHeight = useCallback((uiLineHeight: number) => {
    updateSettings({ uiLineHeight: Math.max(1, Math.min(2, uiLineHeight)) })
  }, [updateSettings])

  const setCursorBlink = useCallback((cursorBlink: boolean) => {
    updateSettings({ cursorBlink })
  }, [updateSettings])

  const setCursorStyle = useCallback((cursorStyle: 'block' | 'underline' | 'bar') => {
    updateSettings({ cursorStyle })
  }, [updateSettings])

  const setScrollback = useCallback((scrollback: number) => {
    updateSettings({ scrollback: Math.max(100, Math.min(10000, scrollback)) })
  }, [updateSettings])

  const setBackgroundEnabled = useCallback((enabled: boolean) => {
    updateSettings({ background: { ...settings.background, enabled } })
  }, [updateSettings, settings.background])

  const setBackgroundType = useCallback((type: BackgroundSettings['type']) => {
    updateSettings({ background: { ...settings.background, type } })
  }, [updateSettings, settings.background])

  const setBackgroundImage = useCallback((imagePath: string | null) => {
    updateSettings({ background: { ...settings.background, imagePath } })
  }, [updateSettings, settings.background])

  const setBackgroundVideo = useCallback((videoPath: string | null) => {
    updateSettings({ background: { ...settings.background, videoPath } })
  }, [updateSettings, settings.background])

  const setBackgroundOpacity = useCallback((opacity: number) => {
    updateSettings({ background: { ...settings.background, opacity: Math.max(0, Math.min(100, opacity)) } })
  }, [updateSettings, settings.background])

  const setBackgroundBlur = useCallback((blur: number) => {
    updateSettings({ background: { ...settings.background, blur: Math.max(0, Math.min(20, blur)) } })
  }, [updateSettings, settings.background])

  const setBackgroundPosition = useCallback((position: BackgroundSettings['position']) => {
    updateSettings({ background: { ...settings.background, position } })
  }, [updateSettings, settings.background])

  const setVideoMuted = useCallback((videoMuted: boolean) => {
    updateSettings({ background: { ...settings.background, videoMuted } })
  }, [updateSettings, settings.background])

  const setVideoLoop = useCallback((videoLoop: boolean) => {
    updateSettings({ background: { ...settings.background, videoLoop } })
  }, [updateSettings, settings.background])

  const setWindowOpacity = useCallback((opacity: number) => {
    updateSettings({ window: { ...settings.window, opacity: Math.max(10, Math.min(100, opacity)) } })
  }, [updateSettings, settings.window])

  const setWindowBlur = useCallback((blur: number) => {
    updateSettings({ window: { ...settings.window, blur: Math.max(0, Math.min(20, blur)) } })
  }, [updateSettings, settings.window])

  const setNativeTabs = useCallback((nativeTabs: boolean) => {
    updateSettings({ window: { ...settings.window, nativeTabs } })
  }, [updateSettings, settings.window])

  const setNativeContextMenus = useCallback((nativeContextMenus: boolean) => {
    updateSettings({ window: { ...settings.window, nativeContextMenus } })
  }, [updateSettings, settings.window])

  const setTabStyle = useCallback((tabStyle: WindowSettings['tabStyle']) => {
    updateSettings({ window: { ...settings.window, tabStyle } })
  }, [updateSettings, settings.window])

  const setFontThicken = useCallback((fontThicken: boolean) => {
    updateSettings({ fontThicken })
  }, [updateSettings])

  const setLinkClickBehavior = useCallback((linkClickBehavior: LinkClickBehavior) => {
    updateSettings({ behavior: { ...settings.behavior, linkClickBehavior } })
  }, [updateSettings, settings.behavior])

  const setCodeEditor = useCallback((editor: CodeEditorType) => {
    updateSettings({ editor: { ...settings.editor, editor } })
  }, [updateSettings, settings.editor])

  const setEditorMinimap = useCallback((minimap: boolean) => {
    updateSettings({ editor: { ...settings.editor, minimap } })
  }, [updateSettings, settings.editor])

  const setEditorWordWrap = useCallback((wordWrap: boolean) => {
    updateSettings({ editor: { ...settings.editor, wordWrap } })
  }, [updateSettings, settings.editor])

  const setSyntaxTheme = useCallback((themeId: string) => {
    console.log('[TerminalSettings] setSyntaxTheme called with:', themeId)
    const theme = SYNTAX_THEMES.find((t) => t.id === themeId) || SYNTAX_THEMES[0]
    console.log('[TerminalSettings] Found theme:', theme)
    updateSettings({ editor: { ...settings.editor, syntaxTheme: theme } })
  }, [updateSettings, settings.editor])

  const setLSPEnabled = useCallback((enabled: boolean) => {
    updateSettings({ lsp: { ...settings.lsp, enabled } })
  }, [updateSettings, settings.lsp])

  const setLSPServerEnabled = useCallback((serverId: string, enabled: boolean) => {
    updateSettings({
      lsp: {
        ...settings.lsp,
        servers: { ...settings.lsp.servers, [serverId]: enabled },
      },
    })
  }, [updateSettings, settings.lsp])

  const resetToDefaults = useCallback(() => {
    setSettings(defaultSettings)
    saveSettings(defaultSettings)
  }, [])

  return (
    <TerminalSettingsContext.Provider
      value={{
        settings,
        setTheme,
        setFont,
        setUIFont,
        setFontSize,
        setUIFontSize,
        setLineHeight,
        setParagraphSpacing,
        setLetterSpacing,
        setUILineHeight,
        setCursorBlink,
        setCursorStyle,
        setScrollback,
        setBackgroundEnabled,
        setBackgroundType,
        setBackgroundImage,
        setBackgroundVideo,
        setBackgroundOpacity,
        setBackgroundBlur,
        setBackgroundPosition,
        setVideoMuted,
        setVideoLoop,
        setWindowOpacity,
        setWindowBlur,
        setNativeTabs,
        setNativeContextMenus,
        setTabStyle,
        setFontThicken,
        setLinkClickBehavior,
        setCodeEditor,
        setEditorMinimap,
        setEditorWordWrap,
        setSyntaxTheme,
        setLSPEnabled,
        setLSPServerEnabled,
        resetToDefaults,
        ghosttyConfig,
        ghosttyConfigLoading,
      }}
    >
      {children}
    </TerminalSettingsContext.Provider>
  )
}

export function useTerminalSettings() {
  const context = useContext(TerminalSettingsContext)
  if (!context) {
    throw new Error('useTerminalSettings must be used within a TerminalSettingsProvider')
  }
  return context
}

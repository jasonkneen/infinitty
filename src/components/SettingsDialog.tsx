import { useState, useCallback, useRef, useEffect, useMemo, useLayoutEffect } from 'react'
import { createPortal } from 'react-dom'
import { X, Settings, Palette, Terminal, Image, Monitor, Code, RotateCcw, Check, ChevronDown, Search, Key } from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { open } from '@tauri-apps/plugin-dialog'
import { triggerWebviewRestore } from '../hooks/useWebviewOverlay'
import { TERMINAL_THEMES, TERMINAL_FONTS, UI_FONTS, SYNTAX_THEMES, themeToXterm, type TerminalFont, type UIFont, type SyntaxTheme } from '../config/terminal'
import { FontLoader } from './FontLoader'

type TabId = 'general' | 'themes' | 'background' | 'application' | 'terminal' | 'coding' | 'providers'

interface Tab {
  id: TabId
  label: string
  icon: typeof Palette
}

const tabs: Tab[] = [
  { id: 'general', label: 'General', icon: Settings },
  { id: 'providers', label: 'Providers', icon: Key },
  { id: 'themes', label: 'Theme', icon: Palette },
  { id: 'background', label: 'Background', icon: Image },
  { id: 'application', label: 'Application', icon: Monitor },
  { id: 'terminal', label: 'Terminal', icon: Terminal },
  { id: 'coding', label: 'Coding', icon: Code },
]

interface SettingsDialogProps {
  isOpen: boolean
  onClose: () => void
}

export function SettingsDialog({ isOpen, onClose }: SettingsDialogProps) {
  const [activeTab, setActiveTab] = useState<TabId>('general')
  const settings = useTerminalSettings()

  // Restore webviews when dialog closes
  // (Hiding is done before dialog opens in App.tsx openSettings())
  useEffect(() => {
    if (!isOpen) {
      triggerWebviewRestore()
    }
  }, [isOpen])

  if (!isOpen) return null

  return (
    <>
      <FontLoader />

    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.6)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 9999,
        backdropFilter: 'blur(4px)',
      }}
      onClick={onClose}
    >
      <div
        style={{
          width: '720px',
          maxWidth: '90vw',
          height: '600px',
          maxHeight: '85vh',
          backgroundColor: '#0d1117',
          borderRadius: '16px',
          border: '1px solid #30363d',
          display: 'flex',
          overflow: 'hidden',
          boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Sidebar with tabs */}
        <div
          style={{
            width: '180px',
            flexShrink: 0,
            backgroundColor: '#161b22',
            borderRight: '1px solid #30363d',
            display: 'flex',
            flexDirection: 'column',
            padding: '16px 0',
          }}
        >
          <h2
            style={{
              color: '#e6edf3',
              fontSize: '18px',
              fontWeight: 600,
              padding: '0 20px 20px',
              margin: 0,
              borderBottom: '1px solid #30363d',
            }}
          >
            Settings
          </h2>

          <nav style={{ flex: 1, padding: '16px 12px' }}>
            {tabs.map((tab) => {
              const Icon = tab.icon
              const isActive = activeTab === tab.id
              return (
                <button
                  key={tab.id}
                  onClick={() => setActiveTab(tab.id)}
                  style={{
                    width: '100%',
                    display: 'flex',
                    alignItems: 'center',
                    gap: '12px',
                    padding: '12px 16px',
                    backgroundColor: isActive ? '#21262d' : 'transparent',
                    border: 'none',
                    borderRadius: '8px',
                    color: isActive ? '#e6edf3' : '#8b949e',
                    fontSize: '14px',
                    fontWeight: isActive ? 500 : 400,
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                    marginBottom: '4px',
                  }}
                  onMouseEnter={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.backgroundColor = '#1c2128'
                      e.currentTarget.style.color = '#c9d1d9'
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.backgroundColor = 'transparent'
                      e.currentTarget.style.color = '#8b949e'
                    }
                  }}
                >
                  <Icon size={18} />
                  {tab.label}
                </button>
              )
            })}
          </nav>

          {/* Reset button */}
          <div style={{ padding: '16px 12px', borderTop: '1px solid #30363d' }}>
            <button
              onClick={settings.resetToDefaults}
              style={{
                width: '100%',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: '8px',
                padding: '10px 16px',
                backgroundColor: 'transparent',
                border: '1px solid #30363d',
                borderRadius: '8px',
                color: '#8b949e',
                fontSize: '13px',
                cursor: 'pointer',
                transition: 'all 0.15s ease',
              }}
              onMouseEnter={(e) => {
                e.currentTarget.style.borderColor = '#f85149'
                e.currentTarget.style.color = '#f85149'
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.borderColor = '#30363d'
                e.currentTarget.style.color = '#8b949e'
              }}
            >
              <RotateCcw size={14} />
              Reset to Defaults
            </button>
          </div>
        </div>

        {/* Main content */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          {/* Header */}
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '12px 20px',
              borderBottom: '1px solid #30363d',
            }}
          >
            <h3
              style={{
                color: '#e6edf3',
                fontSize: '16px',
                fontWeight: 500,
                margin: 0,
              }}
            >
              {tabs.find((t) => t.id === activeTab)?.label}
            </h3>
            <button
              onClick={onClose}
              style={{
                padding: '8px',
                backgroundColor: 'transparent',
                border: 'none',
                borderRadius: '6px',
                color: '#8b949e',
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
              onMouseEnter={(e) => {
                e.currentTarget.style.backgroundColor = '#21262d'
                e.currentTarget.style.color = '#e6edf3'
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.backgroundColor = 'transparent'
                e.currentTarget.style.color = '#8b949e'
              }}
            >
              <X size={18} />
            </button>
          </div>

          {/* Content */}
          <div
            style={{
              flex: 1,
              padding: '16px 20px',
              overflowY: 'auto',
              overflowX: 'hidden',
            }}
          >
            {activeTab === 'general' && <GeneralPanel />}
            {activeTab === 'providers' && <ProvidersPanel />}
            {activeTab === 'themes' && <ThemesPanel />}
            {activeTab === 'background' && <BackgroundPanel />}
            {activeTab === 'application' && <ApplicationPanel />}
            {activeTab === 'terminal' && <TerminalPanel />}
            {activeTab === 'coding' && <CodingPanel />}
          </div>
        </div>
      </div>
    </div>
    </>
  )
}

// ============================================
// Reusable Components
// ============================================

// Searchable Font Dropdown
interface FontDropdownProps {
  fonts: (TerminalFont | UIFont)[]
  selectedId: string
  onChange: (id: string) => void
  placeholder?: string
}

function FontDropdown({ fonts, selectedId, onChange, placeholder = 'Select font...' }: FontDropdownProps) {
  const [isOpen, setIsOpen] = useState(false)
  const [search, setSearch] = useState('')
  const buttonRef = useRef<HTMLButtonElement>(null)
  const dropdownRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const [dropdownPos, setDropdownPos] = useState({ top: 0, left: 0, width: 0 })

  const selectedFont = fonts.find(f => f.id === selectedId)

  const filteredFonts = useMemo(() => {
    if (!search) return fonts
    const lower = search.toLowerCase()
    return fonts.filter(f => f.name.toLowerCase().includes(lower))
  }, [fonts, search])

  // Update dropdown position when opening
  useLayoutEffect(() => {
    if (isOpen && buttonRef.current) {
      const rect = buttonRef.current.getBoundingClientRect()
      setDropdownPos({
        top: rect.bottom + 4,
        left: rect.left,
        width: rect.width,
      })
    }
  }, [isOpen])

  // Close on outside click
  useEffect(() => {
    if (!isOpen) return
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        buttonRef.current && !buttonRef.current.contains(target) &&
        dropdownRef.current && !dropdownRef.current.contains(target)
      ) {
        setIsOpen(false)
        setSearch('')
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [isOpen])

  // Focus input when opening
  useEffect(() => {
    if (isOpen && inputRef.current) {
      inputRef.current.focus()
    }
  }, [isOpen])

  return (
    <div style={{ position: 'relative', width: '100%' }}>
      <button
        ref={buttonRef}
        onClick={() => setIsOpen(!isOpen)}
        style={{
          width: '100%',
          padding: '6px 10px',
          backgroundColor: '#161b22',
          border: '1px solid #30363d',
          borderRadius: '6px',
          color: '#e6edf3',
          fontSize: '12px',
          fontFamily: selectedFont?.family || 'inherit',
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          transition: 'border-color 0.15s ease',
        }}
        onMouseEnter={(e) => { e.currentTarget.style.borderColor = '#484f58' }}
        onMouseLeave={(e) => { e.currentTarget.style.borderColor = '#30363d' }}
      >
        <span>{selectedFont?.name || placeholder}</span>
        <ChevronDown size={14} style={{ color: '#8b949e', transform: isOpen ? 'rotate(180deg)' : 'rotate(0)', transition: 'transform 0.15s' }} />
      </button>

      {isOpen && createPortal(
        <div
          ref={dropdownRef}
          style={{
            position: 'fixed',
            top: dropdownPos.top,
            left: dropdownPos.left,
            width: dropdownPos.width,
            backgroundColor: '#161b22',
            border: '1px solid #30363d',
            borderRadius: '8px',
            boxShadow: '0 8px 24px rgba(0, 0, 0, 0.4)',
            zIndex: 999999,
            maxHeight: '300px',
            overflow: 'hidden',
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          {/* Search input */}
          <div style={{ padding: '8px', borderBottom: '1px solid #30363d' }}>
            <div style={{ position: 'relative' }}>
              <Search size={14} style={{ position: 'absolute', left: '10px', top: '50%', transform: 'translateY(-50%)', color: '#8b949e' }} />
              <input
                ref={inputRef}
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Search fonts..."
                style={{
                  width: '100%',
                  padding: '8px 12px 8px 32px',
                  backgroundColor: '#0d1117',
                  border: '1px solid #30363d',
                  borderRadius: '6px',
                  color: '#e6edf3',
                  fontSize: '13px',
                  outline: 'none',
                }}
              />
            </div>
          </div>

          {/* Font list */}
          <div style={{ flex: 1, overflowY: 'auto', padding: '4px' }}>
            {filteredFonts.map((font) => {
              const isSelected = font.id === selectedId
              return (
                <button
                  key={font.id}
                  onClick={() => {
                    onChange(font.id)
                    setIsOpen(false)
                    setSearch('')
                  }}
                  style={{
                    width: '100%',
                    padding: '10px 12px',
                    backgroundColor: isSelected ? '#21262d' : 'transparent',
                    border: 'none',
                    borderRadius: '6px',
                    color: isSelected ? '#e6edf3' : '#c9d1d9',
                    fontSize: '13px',
                    fontFamily: font.family,
                    cursor: 'pointer',
                    textAlign: 'left',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    marginBottom: '2px',
                  }}
                  onMouseEnter={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = '#1c2128' }}
                  onMouseLeave={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent' }}
                >
                  <span>{font.name}</span>
                  {isSelected && <Check size={14} style={{ color: '#58a6ff' }} />}
                </button>
              )
            })}
            {filteredFonts.length === 0 && (
              <div style={{ padding: '12px', color: '#8b949e', fontSize: '13px', textAlign: 'center' }}>
                No fonts found
              </div>
            )}
          </div>
        </div>,
        document.body
      )}
    </div>
  )
}

// Syntax Theme Dropdown
interface SyntaxThemeDropdownProps {
  themes: SyntaxTheme[]
  selectedId: string
  onChange: (id: string) => void
}

function SyntaxThemeDropdown({ themes, selectedId, onChange }: SyntaxThemeDropdownProps) {
  const [isOpen, setIsOpen] = useState(false)
  const [search, setSearch] = useState('')
  const buttonRef = useRef<HTMLButtonElement>(null)
  const dropdownRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const [dropdownPos, setDropdownPos] = useState({ top: 0, left: 0, width: 0 })

  const selectedTheme = themes.find(t => t.id === selectedId)

  const filteredThemes = useMemo(() => {
    if (!search) return themes
    const lower = search.toLowerCase()
    return themes.filter(t => t.name.toLowerCase().includes(lower))
  }, [themes, search])

  // Group themes by category
  const groupedThemes = useMemo(() => {
    const dark = filteredThemes.filter(t => t.category === 'dark')
    const light = filteredThemes.filter(t => t.category === 'light')
    return { dark, light }
  }, [filteredThemes])

  // Update dropdown position when opening
  useLayoutEffect(() => {
    if (isOpen && buttonRef.current) {
      const rect = buttonRef.current.getBoundingClientRect()
      setDropdownPos({
        top: rect.bottom + 4,
        left: rect.left,
        width: rect.width,
      })
    }
  }, [isOpen])

  // Close on outside click
  useEffect(() => {
    if (!isOpen) return
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        buttonRef.current && !buttonRef.current.contains(target) &&
        dropdownRef.current && !dropdownRef.current.contains(target)
      ) {
        setIsOpen(false)
        setSearch('')
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [isOpen])

  // Focus input when opening
  useEffect(() => {
    if (isOpen && inputRef.current) {
      inputRef.current.focus()
    }
  }, [isOpen])

  return (
    <div style={{ position: 'relative', width: '100%' }}>
      <button
        ref={buttonRef}
        onClick={() => setIsOpen(!isOpen)}
        style={{
          width: '100%',
          padding: '6px 10px',
          backgroundColor: '#161b22',
          border: '1px solid #30363d',
          borderRadius: '6px',
          color: '#e6edf3',
          fontSize: '12px',
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          transition: 'border-color 0.15s ease',
        }}
        onMouseEnter={(e) => { e.currentTarget.style.borderColor = '#484f58' }}
        onMouseLeave={(e) => { e.currentTarget.style.borderColor = '#30363d' }}
      >
        <span>{selectedTheme?.name || 'Select theme...'}</span>
        <ChevronDown size={14} style={{ color: '#8b949e', transform: isOpen ? 'rotate(180deg)' : 'rotate(0)', transition: 'transform 0.15s' }} />
      </button>

      {isOpen && createPortal(
        <div
          ref={dropdownRef}
          style={{
            position: 'fixed',
            top: dropdownPos.top,
            left: dropdownPos.left,
            width: dropdownPos.width,
            backgroundColor: '#161b22',
            border: '1px solid #30363d',
            borderRadius: '8px',
            boxShadow: '0 8px 24px rgba(0, 0, 0, 0.4)',
            zIndex: 999999,
            maxHeight: '350px',
            overflow: 'hidden',
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          {/* Search input */}
          <div style={{ padding: '8px', borderBottom: '1px solid #30363d' }}>
            <div style={{ position: 'relative' }}>
              <Search size={14} style={{ position: 'absolute', left: '10px', top: '50%', transform: 'translateY(-50%)', color: '#8b949e' }} />
              <input
                ref={inputRef}
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Search themes..."
                style={{
                  width: '100%',
                  padding: '8px 12px 8px 32px',
                  backgroundColor: '#0d1117',
                  border: '1px solid #30363d',
                  borderRadius: '6px',
                  color: '#e6edf3',
                  fontSize: '13px',
                  outline: 'none',
                }}
              />
            </div>
          </div>

          {/* Theme list */}
          <div style={{ flex: 1, overflowY: 'auto', padding: '4px' }}>
            {/* Dark themes */}
            {groupedThemes.dark.length > 0 && (
              <>
                <div style={{ padding: '8px 12px 4px', color: '#8b949e', fontSize: '11px', fontWeight: 600, textTransform: 'uppercase' }}>
                  Dark
                </div>
                {groupedThemes.dark.map((theme) => {
                  const isSelected = theme.id === selectedId
                  return (
                    <button
                      key={theme.id}
                      onClick={() => {
                        onChange(theme.id)
                        setIsOpen(false)
                        setSearch('')
                      }}
                      style={{
                        width: '100%',
                        padding: '10px 12px',
                        backgroundColor: isSelected ? '#21262d' : 'transparent',
                        border: 'none',
                        borderRadius: '6px',
                        color: isSelected ? '#e6edf3' : '#c9d1d9',
                        fontSize: '13px',
                        cursor: 'pointer',
                        textAlign: 'left',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        marginBottom: '2px',
                      }}
                      onMouseEnter={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = '#1c2128' }}
                      onMouseLeave={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent' }}
                    >
                      <span>{theme.name}</span>
                      {isSelected && <Check size={14} style={{ color: '#58a6ff' }} />}
                    </button>
                  )
                })}
              </>
            )}

            {/* Light themes */}
            {groupedThemes.light.length > 0 && (
              <>
                <div style={{ padding: '12px 12px 4px', color: '#8b949e', fontSize: '11px', fontWeight: 600, textTransform: 'uppercase' }}>
                  Light
                </div>
                {groupedThemes.light.map((theme) => {
                  const isSelected = theme.id === selectedId
                  return (
                    <button
                      key={theme.id}
                      onClick={() => {
                        onChange(theme.id)
                        setIsOpen(false)
                        setSearch('')
                      }}
                      style={{
                        width: '100%',
                        padding: '10px 12px',
                        backgroundColor: isSelected ? '#21262d' : 'transparent',
                        border: 'none',
                        borderRadius: '6px',
                        color: isSelected ? '#e6edf3' : '#c9d1d9',
                        fontSize: '13px',
                        cursor: 'pointer',
                        textAlign: 'left',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        marginBottom: '2px',
                      }}
                      onMouseEnter={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = '#1c2128' }}
                      onMouseLeave={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent' }}
                    >
                      <span>{theme.name}</span>
                      {isSelected && <Check size={14} style={{ color: '#58a6ff' }} />}
                    </button>
                  )
                })}
              </>
            )}

            {filteredThemes.length === 0 && (
              <div style={{ padding: '12px', color: '#8b949e', fontSize: '13px', textAlign: 'center' }}>
                No themes found
              </div>
            )}
          </div>
        </div>,
        document.body
      )}
    </div>
  )
}

// Size Selector (editable dropdown list)
interface SizeSelectorProps {
  value: number
  onChange: (size: number) => void
  sizes: number[]
  min?: number
  max?: number
  suffix?: string
}

function SizeSelector({ value, onChange, sizes, min = 8, max = 32, suffix = 'px' }: SizeSelectorProps) {
  const [isOpen, setIsOpen] = useState(false)
  const [inputValue, setInputValue] = useState(String(value))
  const containerRef = useRef<HTMLDivElement>(null)
  const dropdownRef = useRef<HTMLDivElement>(null)
  const [dropdownPos, setDropdownPos] = useState({ top: 0, left: 0, width: 0 })

  // Sync input value with prop
  useEffect(() => {
    setInputValue(String(value))
  }, [value])

  // Update dropdown position when opening
  useLayoutEffect(() => {
    if (isOpen && containerRef.current) {
      const rect = containerRef.current.getBoundingClientRect()
      setDropdownPos({
        top: rect.bottom + 4,
        left: rect.left,
        width: rect.width,
      })
    }
  }, [isOpen])

  // Close on outside click
  useEffect(() => {
    if (!isOpen) return
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        containerRef.current && !containerRef.current.contains(target) &&
        dropdownRef.current && !dropdownRef.current.contains(target)
      ) {
        setIsOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [isOpen])

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setInputValue(e.target.value)
  }

  const handleInputBlur = () => {
    const num = parseFloat(inputValue)
    if (!isNaN(num)) {
      onChange(Math.max(min, Math.min(max, num)))
    } else {
      setInputValue(String(value))
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      handleInputBlur()
      setIsOpen(false)
    }
  }

  return (
    <div ref={containerRef} style={{ position: 'relative', width: '80px' }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          backgroundColor: '#161b22',
          border: '1px solid #30363d',
          borderRadius: '6px',
          overflow: 'hidden',
        }}
      >
        <input
          type="text"
          value={inputValue}
          onChange={handleInputChange}
          onBlur={handleInputBlur}
          onKeyDown={handleKeyDown}
          style={{
            flex: 1,
            padding: '6px 4px 6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            color: '#e6edf3',
            fontSize: '12px',
            fontFamily: 'monospace',
            outline: 'none',
            width: '40px',
          }}
        />
        <span style={{ color: '#8b949e', fontSize: '11px', paddingRight: '4px' }}>{suffix}</span>
        <button
          onClick={() => setIsOpen(!isOpen)}
          style={{
            padding: '6px 4px',
            backgroundColor: 'transparent',
            border: 'none',
            borderLeft: '1px solid #30363d',
            color: '#8b949e',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
          }}
        >
          <ChevronDown size={12} style={{ transform: isOpen ? 'rotate(180deg)' : 'rotate(0)', transition: 'transform 0.15s' }} />
        </button>
      </div>

      {isOpen && createPortal(
        <div
          ref={dropdownRef}
          style={{
            position: 'fixed',
            top: dropdownPos.top,
            left: dropdownPos.left,
            width: dropdownPos.width,
            backgroundColor: '#161b22',
            border: '1px solid #30363d',
            borderRadius: '8px',
            boxShadow: '0 8px 24px rgba(0, 0, 0, 0.4)',
            zIndex: 999999,
            maxHeight: '200px',
            overflowY: 'auto',
            padding: '4px',
          }}
        >
          {sizes.map((size) => {
            const isSelected = size === value
            return (
              <button
                key={size}
                onClick={() => {
                  onChange(size)
                  setIsOpen(false)
                }}
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  backgroundColor: isSelected ? '#21262d' : 'transparent',
                  border: 'none',
                  borderRadius: '6px',
                  color: isSelected ? '#e6edf3' : '#c9d1d9',
                  fontSize: '13px',
                  fontFamily: 'monospace',
                  cursor: 'pointer',
                  textAlign: 'left',
                  marginBottom: '2px',
                }}
                onMouseEnter={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = '#1c2128' }}
                onMouseLeave={(e) => { if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent' }}
              >
                {size}{suffix}
              </button>
            )
          })}
        </div>,
        document.body
      )}
    </div>
  )
}

// Spacing Input (for line height and letter spacing)
interface SpacingInputProps {
  label: string
  value: number
  onChange: (value: number) => void
  min: number
  max: number
  step?: number
  suffix?: string
}

function SpacingInput({ label, value, onChange, min, max, step = 0.1, suffix = '' }: SpacingInputProps) {
  const [inputValue, setInputValue] = useState(String(value))

  useEffect(() => {
    setInputValue(String(value))
  }, [value])

  const handleBlur = () => {
    const num = parseFloat(inputValue)
    if (!isNaN(num)) {
      onChange(Math.max(min, Math.min(max, num)))
    } else {
      setInputValue(String(value))
    }
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
      <span style={{ color: '#8b949e', fontSize: '11px' }}>{label}</span>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          backgroundColor: '#161b22',
          border: '1px solid #30363d',
          borderRadius: '6px',
          overflow: 'hidden',
        }}
      >
        <button
          onClick={() => onChange(Math.max(min, value - step))}
          style={{
            padding: '4px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            color: '#8b949e',
            cursor: 'pointer',
            fontSize: '14px',
            fontWeight: 'bold',
          }}
        >
          −
        </button>
        <input
          type="text"
          value={inputValue}
          onChange={(e) => setInputValue(e.target.value)}
          onBlur={handleBlur}
          style={{
            width: '50px',
            padding: '4px 2px',
            backgroundColor: 'transparent',
            border: 'none',
            borderLeft: '1px solid #30363d',
            borderRight: '1px solid #30363d',
            color: '#e6edf3',
            fontSize: '12px',
            fontFamily: 'monospace',
            textAlign: 'center',
            outline: 'none',
          }}
        />
        <button
          onClick={() => onChange(Math.min(max, value + step))}
          style={{
            padding: '4px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            color: '#8b949e',
            cursor: 'pointer',
            fontSize: '14px',
            fontWeight: 'bold',
          }}
        >
          +
        </button>
      </div>
      {suffix && <span style={{ color: '#6e7681', fontSize: '11px' }}>{suffix}</span>}
    </div>
  )
}

// Toggle Switch Component
function Toggle({
  checked,
  onChange,
  disabled = false,
}: {
  checked: boolean
  onChange: (value: boolean) => void
  disabled?: boolean
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => !disabled && onChange(!checked)}
      style={{
        width: '36px',
        height: '20px',
        backgroundColor: checked ? '#238636' : '#30363d',
        borderRadius: '10px',
        border: 'none',
        cursor: disabled ? 'not-allowed' : 'pointer',
        position: 'relative',
        transition: 'background-color 0.2s ease',
        opacity: disabled ? 0.5 : 1,
        flexShrink: 0,
      }}
    >
      <div
        style={{
          width: '14px',
          height: '14px',
          backgroundColor: '#e6edf3',
          borderRadius: '50%',
          position: 'absolute',
          top: '3px',
          left: checked ? '19px' : '3px',
          transition: 'left 0.2s ease',
          boxShadow: '0 1px 3px rgba(0, 0, 0, 0.3)',
        }}
      />
    </button>
  )
}

// ============================================
// Panel Components
// ============================================

// General Panel - Basic app preferences
function GeneralPanel() {
  const {
    settings,
    setLinkClickBehavior,
  } = useTerminalSettings()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <p style={{ color: '#8b949e', fontSize: '13px', margin: 0 }}>
        Configure general application preferences.
      </p>

      {/* Link Click Behavior */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Link Click Behavior
        </h4>
        <p style={{ color: '#8b949e', fontSize: '12px', marginBottom: '12px', marginTop: 0 }}>
          What happens when you click links in the terminal
        </p>
        <div style={{ display: 'flex', gap: '12px' }}>
          {([
            { id: 'webview', label: 'Open in Webview', description: 'Open links in a new tab' },
            { id: 'browser', label: 'Open in Browser', description: 'Open in system browser' },
            { id: 'disabled', label: 'Disabled', description: 'Do nothing' },
          ] as const).map((option) => {
            const isSelected = settings.behavior.linkClickBehavior === option.id
            return (
              <button
                key={option.id}
                onClick={() => setLinkClickBehavior(option.id)}
                style={{
                  flex: 1,
                  padding: '12px 16px',
                  backgroundColor: isSelected ? '#21262d' : '#161b22',
                  border: isSelected ? '2px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '8px',
                  cursor: 'pointer',
                  textAlign: 'left',
                  transition: 'all 0.15s ease',
                }}
              >
                <span style={{ color: isSelected ? '#e6edf3' : '#8b949e', fontSize: '13px', fontWeight: 500, display: 'block' }}>
                  {option.label}
                </span>
                <span style={{ color: '#6e7681', fontSize: '11px', display: 'block', marginTop: '4px' }}>
                  {option.description}
                </span>
              </button>
            )
          })}
        </div>
      </section>
    </div>
  )
}

// Themes Panel - Glassy theme selection
function ThemesPanel() {
  const { settings, setTheme } = useTerminalSettings()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>
      <p style={{ color: '#8b949e', fontSize: '13px', margin: 0 }}>
        Choose a color theme for your terminal.
      </p>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
          gap: '16px',
        }}
      >
        {TERMINAL_THEMES.map((theme) => {
          const isSelected = settings.theme.id === theme.id
          const xtermTheme = themeToXterm(theme)
          return (
            <button
              key={theme.id}
              onClick={() => setTheme(theme.id)}
              style={{
                padding: '16px',
                background: isSelected
                  ? 'linear-gradient(135deg, rgba(88, 166, 255, 0.15), rgba(88, 166, 255, 0.05))'
                  : 'linear-gradient(135deg, rgba(255, 255, 255, 0.05), rgba(255, 255, 255, 0.02))',
                border: isSelected ? '2px solid #58a6ff' : '1px solid rgba(255, 255, 255, 0.1)',
                borderRadius: '12px',
                cursor: 'pointer',
                transition: 'all 0.2s ease',
                textAlign: 'left',
                backdropFilter: 'blur(10px)',
                boxShadow: isSelected
                  ? '0 8px 32px rgba(88, 166, 255, 0.2), inset 0 1px 1px rgba(255, 255, 255, 0.1)'
                  : '0 4px 20px rgba(0, 0, 0, 0.2), inset 0 1px 1px rgba(255, 255, 255, 0.05)',
              }}
              onMouseEnter={(e) => {
                if (!isSelected) {
                  e.currentTarget.style.border = '1px solid rgba(255, 255, 255, 0.2)'
                  e.currentTarget.style.transform = 'translateY(-2px)'
                }
              }}
              onMouseLeave={(e) => {
                if (!isSelected) {
                  e.currentTarget.style.border = '1px solid rgba(255, 255, 255, 0.1)'
                  e.currentTarget.style.transform = 'translateY(0)'
                }
              }}
            >
              {/* Terminal preview */}
              <div
                style={{
                  height: '70px',
                  borderRadius: '8px',
                  backgroundColor: xtermTheme.background,
                  marginBottom: '12px',
                  padding: '10px',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '4px',
                  overflow: 'hidden',
                  boxShadow: 'inset 0 2px 4px rgba(0, 0, 0, 0.3)',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                  <span style={{ color: xtermTheme.green, fontSize: '10px', fontFamily: 'monospace' }}>➜</span>
                  <span style={{ color: xtermTheme.cyan, fontSize: '10px', fontFamily: 'monospace' }}>~/projects</span>
                </div>
                <div style={{ color: xtermTheme.yellow, fontSize: '9px', fontFamily: 'monospace' }}>On branch main</div>
                <div style={{ color: xtermTheme.green, fontSize: '9px', fontFamily: 'monospace' }}>✓ Clean</div>
              </div>

              {/* Color dots */}
              <div style={{ display: 'flex', gap: '6px', marginBottom: '10px' }}>
                {[xtermTheme.red, xtermTheme.green, xtermTheme.yellow, xtermTheme.blue, xtermTheme.magenta, xtermTheme.cyan].map((color, i) => (
                  <div key={i} style={{ width: '14px', height: '14px', borderRadius: '50%', backgroundColor: color, boxShadow: `0 2px 8px ${color}40` }} />
                ))}
              </div>

              {/* Theme name */}
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <span style={{ color: '#e6edf3', fontSize: '13px', fontWeight: 500 }}>{theme.name}</span>
                {isSelected && <Check size={16} style={{ color: '#58a6ff' }} />}
              </div>
            </button>
          )
        })}
      </div>
    </div>
  )
}

// Application Panel - Window settings + App font
function ApplicationPanel() {
  const {
    settings,
    setUIFont,
    setUIFontSize,
    setUILineHeight,
    setWindowOpacity,
    setWindowBlur,
    setNativeTabs,
    setNativeContextMenus,
    setTabStyle,
  } = useTerminalSettings()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <p style={{ color: '#8b949e', fontSize: '13px', margin: 0 }}>
        Configure the application appearance and typography.
      </p>

      {/* App Font Section */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Application Font
        </h4>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: '16px', alignItems: 'end' }}>
          <div>
            <label style={{ color: '#8b949e', fontSize: '12px', display: 'block', marginBottom: '8px' }}>Font Family</label>
            <FontDropdown
              fonts={UI_FONTS}
              selectedId={settings.uiFont.id}
              onChange={setUIFont}
            />
          </div>
          <div>
            <label style={{ color: '#8b949e', fontSize: '12px', display: 'block', marginBottom: '8px' }}>Size</label>
            <SizeSelector
              value={settings.uiFontSize}
              onChange={setUIFontSize}
              sizes={[10, 11, 12, 13, 14, 15, 16, 18, 20]}
              min={10}
              max={24}
            />
          </div>
          <div>
            <label style={{ color: '#8b949e', fontSize: '12px', display: 'block', marginBottom: '8px' }}>Line Height</label>
            <SizeSelector
              value={settings.uiLineHeight}
              onChange={setUILineHeight}
              sizes={[1.0, 1.2, 1.4, 1.5, 1.6, 1.8, 2.0]}
              min={1}
              max={2}
              suffix=""
            />
          </div>
        </div>

        {/* Preview */}
        <div
          style={{
            marginTop: '16px',
            padding: '16px',
            backgroundColor: '#161b22',
            borderRadius: '8px',
            border: '1px solid #30363d',
          }}
        >
          <p style={{ fontFamily: settings.uiFont.family, fontSize: `${settings.uiFontSize}px`, lineHeight: settings.uiLineHeight, color: '#e6edf3', margin: 0 }}>
            The quick brown fox jumps over the lazy dog.
          </p>
          <p style={{ fontFamily: settings.uiFont.family, fontSize: `${settings.uiFontSize - 2}px`, lineHeight: settings.uiLineHeight, color: '#8b949e', margin: '8px 0 0' }}>
            Settings • Terminal • Themes • Window
          </p>
        </div>
      </section>

      <div style={{ borderTop: '1px solid #30363d' }} />

      {/* Window Transparency */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Window Transparency
        </h4>
        <div style={{ display: 'flex', gap: '24px' }}>
          <SpacingInput
            label="Opacity"
            value={settings.window.opacity}
            onChange={setWindowOpacity}
            min={10}
            max={100}
            step={5}
            suffix="%"
          />
          <SpacingInput
            label="Blur"
            value={settings.window.blur}
            onChange={setWindowBlur}
            min={0}
            max={20}
            step={1}
            suffix="px"
          />
        </div>
        <p style={{ color: '#6e7681', fontSize: '11px', marginTop: '8px' }}>
          Blur applies when opacity is less than 100%
        </p>
      </section>

      {/* Tab Style */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '12px' }}>Tab Style</h4>
        <div style={{ display: 'flex', gap: '12px' }}>
          {[
            { value: 'compact' as const, label: 'Compact', description: 'Fixed width tabs' },
            { value: 'fill' as const, label: 'Fill', description: 'Tabs expand to fill bar' },
          ].map((option) => {
            const isSelected = settings.window.tabStyle === option.value
            return (
              <button
                key={option.value}
                onClick={() => setTabStyle(option.value)}
                style={{
                  flex: 1,
                  padding: '12px',
                  backgroundColor: isSelected ? '#21262d' : '#161b22',
                  border: isSelected ? '2px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '8px',
                  cursor: 'pointer',
                  textAlign: 'left',
                }}
              >
                <div style={{ color: '#e6edf3', fontSize: '13px', fontWeight: 500 }}>{option.label}</div>
                <div style={{ color: '#8b949e', fontSize: '11px', marginTop: '4px' }}>{option.description}</div>
              </button>
            )
          })}
        </div>
      </section>

      {/* Native Options */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>Native Integration</h4>
        <p style={{ color: '#8b949e', fontSize: '12px', margin: '0 0 16px' }}>Requires app restart</p>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div>
              <span style={{ color: '#e6edf3', fontSize: '13px' }}>Native Tabs</span>
              <p style={{ color: '#8b949e', fontSize: '11px', margin: '2px 0 0' }}>Use macOS native window tabs</p>
            </div>
            <Toggle checked={settings.window.nativeTabs} onChange={setNativeTabs} />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div>
              <span style={{ color: '#e6edf3', fontSize: '13px' }}>Native Context Menus</span>
              <p style={{ color: '#8b949e', fontSize: '11px', margin: '2px 0 0' }}>Use native macOS context menus</p>
            </div>
            <Toggle checked={settings.window.nativeContextMenus} onChange={setNativeContextMenus} />
          </div>
        </div>
      </section>
    </div>
  )
}

// Terminal Panel - Terminal-specific settings
function TerminalPanel() {
  const {
    settings,
    setFont,
    setFontSize,
    setFontThicken,
    setLineHeight,
    setParagraphSpacing,
    setLetterSpacing,
    setCursorBlink,
    setCursorStyle,
    setScrollback,
  } = useTerminalSettings()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <p style={{ color: '#8b949e', fontSize: '13px', margin: 0 }}>
        Configure terminal appearance and behavior.
      </p>

      {/* Terminal Font Section */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Terminal Font
        </h4>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr auto', gap: '16px', alignItems: 'end' }}>
          <div>
            <label style={{ color: '#8b949e', fontSize: '12px', display: 'block', marginBottom: '8px' }}>Font Family</label>
            <FontDropdown
              fonts={TERMINAL_FONTS}
              selectedId={settings.font.id}
              onChange={setFont}
            />
          </div>
          <div>
            <label style={{ color: '#8b949e', fontSize: '12px', display: 'block', marginBottom: '8px' }}>Size</label>
            <SizeSelector
              value={settings.fontSize}
              onChange={setFontSize}
              sizes={[10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24]}
              min={8}
              max={32}
            />
          </div>
        </div>

        <div style={{ marginTop: '16px', display: 'flex', gap: '24px' }}>
          <SpacingInput label="Line Height" value={settings.lineHeight} onChange={setLineHeight} min={0.8} max={2.5} step={0.1} />
          <SpacingInput label="Letter Spacing" value={settings.letterSpacing} onChange={setLetterSpacing} min={-2} max={5} step={0.5} suffix="px" />
          <SpacingInput label="Paragraph Spacing" value={settings.paragraphSpacing} onChange={setParagraphSpacing} min={0} max={48} step={2} suffix="px" />
        </div>
        {settings.lineHeight < 1 && (
          <p style={{ color: '#d29922', fontSize: '11px', margin: '4px 0 0' }}>
            Note: Terminal enforces minimum line height of 1. Values below 1 only apply to AI responses.
          </p>
        )}

        <div style={{ marginTop: '16px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <span style={{ color: '#e6edf3', fontSize: '13px' }}>Thicken Font (Retina)</span>
            <p style={{ color: '#8b949e', fontSize: '11px', margin: '2px 0 0' }}>Use subpixel antialiasing for bolder fonts</p>
          </div>
          <Toggle checked={settings.fontThicken} onChange={setFontThicken} />
        </div>

        {/* Preview */}
        <div
          style={{
            marginTop: '16px',
            padding: '16px',
            backgroundColor: settings.theme.background,
            borderRadius: '8px',
            border: '1px solid #30363d',
          }}
        >
          <code style={{ fontFamily: settings.font.family, fontSize: `${settings.fontSize}px`, lineHeight: settings.lineHeight, letterSpacing: `${settings.letterSpacing}px`, color: settings.theme.foreground }}>
            $ echo &quot;Hello, Terminal!&quot;
            <br />
            <span style={{ color: settings.theme.green }}>Hello, Terminal!</span>
          </code>
        </div>
      </section>

      <div style={{ borderTop: '1px solid #30363d' }} />

      {/* Cursor Style */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>Cursor Style</h4>
        <div style={{ display: 'flex', gap: '12px' }}>
          {(['block', 'underline', 'bar'] as const).map((style) => {
            const isSelected = settings.cursorStyle === style
            return (
              <button
                key={style}
                onClick={() => setCursorStyle(style)}
                style={{
                  padding: '16px 24px',
                  backgroundColor: isSelected ? '#21262d' : '#161b22',
                  border: isSelected ? '2px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '8px',
                  cursor: 'pointer',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: '10px',
                }}
              >
                <div style={{ width: '24px', height: '28px', backgroundColor: '#0d1117', borderRadius: '4px', display: 'flex', alignItems: 'flex-end', justifyContent: 'center', padding: '4px' }}>
                  <div style={{ width: style === 'bar' ? '2px' : '12px', height: style === 'underline' ? '2px' : '16px', backgroundColor: '#58a6ff', borderRadius: '1px' }} />
                </div>
                <span style={{ color: isSelected ? '#e6edf3' : '#8b949e', fontSize: '12px', fontWeight: 500, textTransform: 'capitalize' }}>{style}</span>
              </button>
            )
          })}
        </div>
      </section>

      {/* Cursor Blink */}
      <section>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, margin: 0 }}>Cursor Blink</h4>
            <p style={{ color: '#8b949e', fontSize: '12px', margin: '4px 0 0' }}>Enable blinking cursor animation</p>
          </div>
          <Toggle checked={settings.cursorBlink} onChange={setCursorBlink} />
        </div>
      </section>

      {/* Scrollback */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>Scrollback Lines</h4>
        <SpacingInput label="Lines" value={settings.scrollback} onChange={setScrollback} min={100} max={10000} step={100} />
        <p style={{ color: '#8b949e', fontSize: '11px', marginTop: '8px' }}>Higher values use more memory. Recommended: 1000-5000</p>
      </section>
    </div>
  )
}

// Coding Panel - Code editor settings
function CodingPanel() {
  const {
    settings,
    setFont,
    setFontSize,
    setLineHeight,
    setParagraphSpacing,
    setLetterSpacing,
    setCodeEditor,
    setEditorMinimap,
    setEditorWordWrap,
    setSyntaxTheme,
  } = useTerminalSettings()

  const editorOptions = [
    { value: 'codemirror' as const, label: 'CodeMirror', description: 'Lightweight and fast' },
    { value: 'monaco' as const, label: 'Monaco (VS Code)', description: 'Full IDE features' },
    { value: 'ace' as const, label: 'Ace Editor', description: 'Cloud9 editor' },
    { value: 'basic' as const, label: 'Basic', description: 'Simple syntax highlighting' },
  ]

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      <p style={{ color: '#8b949e', fontSize: '12px', margin: 0 }}>
        Configure code editor appearance.
      </p>

      {/* Code Editor Selection */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '12px', fontWeight: 500, marginBottom: '8px' }}>
          Code Editor
        </h4>
        <div style={{ display: 'flex', gap: '6px', flexWrap: 'wrap' }}>
          {editorOptions.map((option) => {
            const isSelected = settings.editor.editor === option.value
            return (
              <button
                key={option.value}
                onClick={() => setCodeEditor(option.value)}
                title={option.description}
                style={{
                  padding: '6px 12px',
                  backgroundColor: isSelected ? '#21262d' : '#161b22',
                  border: isSelected ? '2px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '6px',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                }}
                onMouseEnter={(e) => {
                  if (!isSelected) {
                    e.currentTarget.style.borderColor = '#484f58'
                  }
                }}
                onMouseLeave={(e) => {
                  if (!isSelected) {
                    e.currentTarget.style.borderColor = '#30363d'
                  }
                }}
              >
                <span style={{ color: isSelected ? '#e6edf3' : '#c9d1d9', fontSize: '11px', fontWeight: 500 }}>
                  {option.label}
                </span>
              </button>
            )
          })}
        </div>
      </section>

      {/* Syntax Theme Selection */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '12px', fontWeight: 500, marginBottom: '8px' }}>
          Syntax Theme
        </h4>
        <div style={{ maxWidth: '240px' }}>
          <SyntaxThemeDropdown
            themes={SYNTAX_THEMES}
            selectedId={settings.editor.syntaxTheme.id}
            onChange={setSyntaxTheme}
          />
        </div>
      </section>

      {/* Editor Options */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '12px', fontWeight: 500, marginBottom: '8px' }}>
          Options
        </h4>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ color: '#e6edf3', fontSize: '12px' }}>Word Wrap</span>
            <Toggle checked={settings.editor.wordWrap} onChange={setEditorWordWrap} />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ color: '#e6edf3', fontSize: '12px' }}>Minimap (Monaco only)</span>
            <Toggle
              checked={settings.editor.minimap}
              onChange={setEditorMinimap}
              disabled={settings.editor.editor !== 'monaco'}
            />
          </div>
        </div>
      </section>

      {/* Code Font Section */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '12px', fontWeight: 500, marginBottom: '8px' }}>
          Code Font
        </h4>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr auto', gap: '12px', alignItems: 'end' }}>
          <div>
            <label style={{ color: '#8b949e', fontSize: '11px', display: 'block', marginBottom: '4px' }}>Font Family</label>
            <FontDropdown
              fonts={TERMINAL_FONTS}
              selectedId={settings.font.id}
              onChange={setFont}
            />
          </div>
          <div>
            <label style={{ color: '#8b949e', fontSize: '11px', display: 'block', marginBottom: '4px' }}>Size</label>
            <SizeSelector
              value={settings.fontSize}
              onChange={setFontSize}
              sizes={[10, 11, 12, 13, 14, 15, 16, 18, 20]}
              min={8}
              max={24}
            />
          </div>
        </div>

        <div style={{ marginTop: '12px', display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px' }}>
          <SpacingInput label="Line Ht" value={settings.lineHeight} onChange={setLineHeight} min={0.8} max={2.5} step={0.1} />
          <SpacingInput label="Letter" value={settings.letterSpacing} onChange={setLetterSpacing} min={-2} max={5} step={0.5} suffix="px" />
          <SpacingInput label="Para" value={settings.paragraphSpacing} onChange={setParagraphSpacing} min={0} max={48} step={2} suffix="px" />
        </div>
        {settings.lineHeight < 1 && (
          <p style={{ color: '#d29922', fontSize: '11px', margin: '4px 0 0' }}>
            Note: Terminal enforces minimum line height of 1. Values below 1 only apply to AI responses.
          </p>
        )}

        {/* Code Preview */}
        <div
          style={{
            marginTop: '10px',
            padding: '10px',
            backgroundColor: '#0d1117',
            borderRadius: '6px',
            border: '1px solid #30363d',
          }}
        >
          <pre style={{ fontFamily: settings.font.family, fontSize: `${Math.min(settings.fontSize, 13)}px`, lineHeight: settings.lineHeight, letterSpacing: `${settings.letterSpacing}px`, margin: 0, color: '#c9d1d9' }}>
            <span style={{ color: '#ff7b72' }}>function</span>{' '}
            <span style={{ color: '#d2a8ff' }}>greet</span>
            <span style={{ color: '#c9d1d9' }}>(</span>
            <span style={{ color: '#ffa657' }}>name</span>
            <span style={{ color: '#c9d1d9' }}>)</span>
            {' { '}
            <span style={{ color: '#ff7b72' }}>return</span>
            {' `Hello, '}
            <span style={{ color: '#79c0ff' }}>{'${name}'}</span>
            {'!` }'}
          </pre>
        </div>
      </section>

      {/* LSP Section */}
      <LSPSettingsSection />
    </div>
  )
}

// Providers Panel - Dedicated tab for API keys and provider configuration
function ProvidersPanel() {
  const { settings, setProviderSettings } = useTerminalSettings()
  const [showKeys, setShowKeys] = useState<Record<string, boolean>>({})

  const toggleShowKey = (key: string) => {
    setShowKeys(prev => ({ ...prev, [key]: !prev[key] }))
  }

  const apiKeyProviders = [
    {
      id: 'anthropic',
      name: 'Anthropic',
      key: 'anthropicKey' as const,
      placeholder: 'sk-ant-api03-...',
      description: 'Claude models (Opus, Sonnet, Haiku)',
      docsUrl: 'https://console.anthropic.com/settings/keys'
    },
    {
      id: 'openai',
      name: 'OpenAI',
      key: 'openaiKey' as const,
      placeholder: 'sk-proj-...',
      description: 'GPT-4, GPT-4o, o1, o3 models',
      docsUrl: 'https://platform.openai.com/api-keys'
    },
    {
      id: 'openrouter',
      name: 'OpenRouter',
      key: 'openrouterKey' as const,
      placeholder: 'sk-or-v1-...',
      description: 'Access to 100+ models via single API',
      docsUrl: 'https://openrouter.ai/keys'
    },
    {
      id: 'google',
      name: 'Google AI',
      key: 'googleKey' as const,
      placeholder: 'AIza...',
      description: 'Gemini 2.0, Gemini 1.5 models',
      docsUrl: 'https://aistudio.google.com/apikey'
    },
    {
      id: 'groq',
      name: 'Groq',
      key: 'groqKey' as const,
      placeholder: 'gsk_...',
      description: 'Ultra-fast inference (Llama, Mixtral)',
      docsUrl: 'https://console.groq.com/keys'
    },
    {
      id: 'grok',
      name: 'xAI (Grok)',
      key: 'grokKey' as const,
      placeholder: 'xai-...',
      description: 'Grok models from xAI',
      docsUrl: 'https://console.x.ai/'
    },
    {
      id: 'mistral',
      name: 'Mistral AI',
      key: 'mistralKey' as const,
      placeholder: '...',
      description: 'Mistral Large, Codestral, Mixtral',
      docsUrl: 'https://console.mistral.ai/api-keys/'
    },
    {
      id: 'cohere',
      name: 'Cohere',
      key: 'cohereKey' as const,
      placeholder: '...',
      description: 'Command R, Command R+ models',
      docsUrl: 'https://dashboard.cohere.com/api-keys'
    },
    {
      id: 'together',
      name: 'Together AI',
      key: 'togetherKey' as const,
      placeholder: '...',
      description: 'Open source models (Llama, Qwen)',
      docsUrl: 'https://api.together.xyz/settings/api-keys'
    },
    {
      id: 'deepseek',
      name: 'DeepSeek',
      key: 'deepseekKey' as const,
      placeholder: 'sk-...',
      description: 'DeepSeek Coder, DeepSeek Chat',
      docsUrl: 'https://platform.deepseek.com/api_keys'
    },
  ]

  const localProviders = [
    {
      id: 'ollama',
      name: 'Ollama',
      key: 'ollamaUrl' as const,
      placeholder: 'http://localhost:11434',
      description: 'Run models locally with Ollama',
      isUrl: true
    },
    {
      id: 'lmstudio',
      name: 'LM Studio',
      key: 'lmStudioUrl' as const,
      placeholder: 'http://localhost:1234',
      description: 'Local inference with LM Studio',
      isUrl: true
    },
  ]

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>
      <p style={{ color: '#8b949e', fontSize: '13px', margin: 0 }}>
        Configure API keys for cloud providers and URLs for local inference servers.
      </p>

      {/* Cloud Providers */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Cloud Providers
        </h4>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          {apiKeyProviders.map((provider) => {
            const value = settings.providers[provider.key] || ''
            const isVisible = showKeys[provider.id]
            return (
              <div
                key={provider.id}
                style={{
                  padding: '12px 14px',
                  backgroundColor: '#161b22',
                  borderRadius: '8px',
                  border: value ? '1px solid #238636' : '1px solid #30363d',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
                  <div>
                    <span style={{ color: '#e6edf3', fontSize: '13px', fontWeight: 500 }}>{provider.name}</span>
                    {value && <span style={{ marginLeft: '8px', color: '#238636', fontSize: '11px' }}>●</span>}
                  </div>
                  <a
                    href={provider.docsUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    style={{
                      fontSize: '11px',
                      color: '#58a6ff',
                      textDecoration: 'none',
                    }}
                    onClick={(e) => e.stopPropagation()}
                  >
                    Get API key →
                  </a>
                </div>
                <p style={{ color: '#8b949e', fontSize: '11px', margin: '0 0 8px 0' }}>{provider.description}</p>
                <div style={{ display: 'flex', gap: '8px' }}>
                  <input
                    type={isVisible ? 'text' : 'password'}
                    value={value}
                    onChange={(e) => setProviderSettings({ [provider.key]: e.target.value })}
                    placeholder={provider.placeholder}
                    style={{
                      flex: 1,
                      padding: '8px 10px',
                      backgroundColor: '#0d1117',
                      border: '1px solid #30363d',
                      borderRadius: '6px',
                      color: '#e6edf3',
                      fontSize: '12px',
                      fontFamily: 'monospace',
                    }}
                  />
                  <button
                    onClick={() => toggleShowKey(provider.id)}
                    style={{
                      padding: '8px 12px',
                      backgroundColor: '#21262d',
                      border: '1px solid #30363d',
                      borderRadius: '6px',
                      color: '#8b949e',
                      fontSize: '11px',
                      cursor: 'pointer',
                    }}
                  >
                    {isVisible ? 'Hide' : 'Show'}
                  </button>
                </div>
              </div>
            )
          })}
        </div>
      </section>

      {/* Local Providers */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '16px' }}>
          Local Providers
        </h4>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          {localProviders.map((provider) => {
            const value = settings.providers[provider.key] || ''
            return (
              <div
                key={provider.id}
                style={{
                  padding: '12px 14px',
                  backgroundColor: '#161b22',
                  borderRadius: '8px',
                  border: '1px solid #30363d',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
                  <span style={{ color: '#e6edf3', fontSize: '13px', fontWeight: 500 }}>{provider.name}</span>
                </div>
                <p style={{ color: '#8b949e', fontSize: '11px', margin: '0 0 8px 0' }}>{provider.description}</p>
                <input
                  type="text"
                  value={value}
                  onChange={(e) => setProviderSettings({ [provider.key]: e.target.value })}
                  placeholder={provider.placeholder}
                  style={{
                    width: '100%',
                    padding: '8px 10px',
                    backgroundColor: '#0d1117',
                    border: '1px solid #30363d',
                    borderRadius: '6px',
                    color: '#e6edf3',
                    fontSize: '12px',
                    fontFamily: 'monospace',
                  }}
                />
              </div>
            )
          })}
        </div>
      </section>
    </div>
  )
}

// LSP Settings Section
function LSPSettingsSection() {
  const { settings, setLSPEnabled, setLSPServerEnabled } = useTerminalSettings()

  // Get available servers from the LSP service
  const servers = [
    { id: 'typescript-language-server', name: 'TypeScript/JS', ext: '.ts/.js' },
    { id: 'pyright', name: 'Python', ext: '.py' },
    { id: 'gopls', name: 'Go', ext: '.go' },
    { id: 'rust-analyzer', name: 'Rust', ext: '.rs' },
    { id: 'vscode-json-language-server', name: 'JSON', ext: '.json' },
    { id: 'vscode-css-language-server', name: 'CSS', ext: '.css' },
    { id: 'vscode-html-language-server', name: 'HTML', ext: '.html' },
    { id: 'yaml-language-server', name: 'YAML', ext: '.yaml' },
    { id: 'tailwindcss-language-server', name: 'Tailwind', ext: 'tw' },
    { id: 'bash-language-server', name: 'Bash', ext: '.sh' },
  ]

  return (
    <section>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '12px' }}>
        <div>
          <h4 style={{ color: '#e6edf3', fontSize: '12px', fontWeight: 500, margin: 0 }}>
            Language Server Protocol (LSP)
          </h4>
          <p style={{ color: '#6e7681', fontSize: '11px', margin: '2px 0 0' }}>
            Hover info, autocomplete, go-to-definition
          </p>
        </div>
        <Toggle checked={settings.lsp?.enabled ?? false} onChange={setLSPEnabled} />
      </div>

      {/* Server Grid */}
      {settings.lsp?.enabled && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: '6px' }}>
          {servers.map((server) => {
            const isEnabled = settings.lsp?.servers?.[server.id] ?? true
            return (
              <div
                key={server.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '6px 8px',
                  backgroundColor: '#161b22',
                  borderRadius: '4px',
                  border: '1px solid #30363d',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                  <span style={{ color: '#e6edf3', fontSize: '11px' }}>{server.name}</span>
                  <span style={{ color: '#6e7681', fontSize: '10px' }}>{server.ext}</span>
                </div>
                <Toggle
                  checked={isEnabled}
                  onChange={(enabled) => setLSPServerEnabled(server.id, enabled)}
                />
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}


// Background Panel - Keep existing implementation but simplified
function BackgroundPanel() {
  const {
    settings,
    setBackgroundEnabled,
    setBackgroundType,
    setBackgroundImage,
    setBackgroundVideo,
    setBackgroundOpacity,
    setBackgroundBlur,
    setBackgroundPosition,
    setVideoMuted,
    setVideoLoop,
  } = useTerminalSettings()

  const imageInputRef = useRef<HTMLInputElement>(null)
  const videoInputRef = useRef<HTMLInputElement>(null)

  const handleImageSelect = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0]
      if (!file) return

      // Web fallback: use blob URL
      const url = URL.createObjectURL(file)
      setBackgroundImage(url)
      setBackgroundType('image')
      setBackgroundEnabled(true)
    },
    [setBackgroundEnabled, setBackgroundImage, setBackgroundType]
  )

  const handleVideoSelect = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0]
      if (!file) return

      // Web fallback: use blob URL
      const url = URL.createObjectURL(file)
      setBackgroundVideo(url)
      setBackgroundType('video')
      setBackgroundEnabled(true)
    },
    [setBackgroundEnabled, setBackgroundType, setBackgroundVideo]
  )

  const handleChooseBackground = useCallback(async () => {
    const isVideo = settings.background.type === 'video'

    // Prefer native Tauri dialog when available (persists across restarts).
    if (typeof window !== 'undefined' && '__TAURI__' in window) {
      try {
        const result = await open({
          multiple: false,
          directory: false,
          filters: isVideo
            ? [{ name: 'Video', extensions: ['mp4', 'webm', 'mov', 'm4v', 'avi', 'mkv'] }]
            : [{ name: 'Image', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif', 'tiff'] }],
        })

        if (!result) return

        const path = Array.isArray(result) ? result[0] : result
        if (!path) return

        if (isVideo) {
          setBackgroundVideo(path)
          setBackgroundType('video')
        } else {
          setBackgroundImage(path)
          setBackgroundType('image')
        }

        setBackgroundEnabled(true)
        return
      } catch (error) {
        // If capabilities/plugin are misconfigured, fall back to HTML picker.
        console.error('[BackgroundPanel] Native dialog failed, falling back to file input:', error)
      }
    }

    // Web fallback (and desktop fallback if native dialog fails).
    if (isVideo) {
      videoInputRef.current?.click()
    } else {
      imageInputRef.current?.click()
    }
  }, [
    settings.background.type,
    setBackgroundEnabled,
    setBackgroundImage,
    setBackgroundType,
    setBackgroundVideo,
  ])

  const handleRemoveBackground = useCallback(() => {
    setBackgroundImage(null)
    setBackgroundVideo(null)
    setBackgroundEnabled(false)
  }, [setBackgroundImage, setBackgroundVideo, setBackgroundEnabled])

  const hasBackground = settings.background.imagePath || settings.background.videoPath

  const positionOptions = [
    { value: 'cover' as const, label: 'Cover' },
    { value: 'contain' as const, label: 'Contain' },
    { value: 'tile' as const, label: 'Tile' },
    { value: 'center' as const, label: 'Center' },
  ]

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      {/* Enable Toggle */}
      <section>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, margin: 0 }}>Background Media</h4>
            <p style={{ color: '#8b949e', fontSize: '12px', margin: '4px 0 0' }}>Display image or video behind terminal</p>
          </div>
          <Toggle checked={settings.background.enabled} onChange={setBackgroundEnabled} disabled={!hasBackground} />
        </div>
      </section>

      {/* Type Selector */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '12px' }}>Type</h4>
        <div style={{ display: 'flex', gap: '12px' }}>
          {[{ value: 'image' as const, label: 'Image' }, { value: 'video' as const, label: 'Video' }].map((option) => {
            const isSelected = settings.background.type === option.value
            return (
              <button
                key={option.value}
                onClick={() => setBackgroundType(option.value)}
                style={{
                  flex: 1,
                  padding: '12px',
                  backgroundColor: isSelected ? '#21262d' : '#161b22',
                  border: isSelected ? '2px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '8px',
                  color: isSelected ? '#e6edf3' : '#8b949e',
                  fontSize: '13px',
                  cursor: 'pointer',
                }}
              >
                {option.label}
              </button>
            )
          })}
        </div>
      </section>

      {/* File Selection */}
      <section>
        <input ref={imageInputRef} type="file" accept="image/*" onChange={handleImageSelect} style={{ display: 'none' }} />
        <input ref={videoInputRef} type="file" accept="video/*" onChange={handleVideoSelect} style={{ display: 'none' }} />

        <div style={{ display: 'flex', gap: '12px' }}>
          <button
            onClick={handleChooseBackground}
            style={{
              padding: '10px 20px',
              backgroundColor: '#21262d',
              border: '1px solid #30363d',
              borderRadius: '6px',
              color: '#e6edf3',
              fontSize: '13px',
              cursor: 'pointer',
            }}
          >
            Choose {settings.background.type === 'image' ? 'Image' : 'Video'}
          </button>
          {hasBackground && (
            <button
              onClick={handleRemoveBackground}
              style={{
                padding: '10px 20px',
                backgroundColor: 'transparent',
                border: '1px solid #f85149',
                borderRadius: '6px',
                color: '#f85149',
                fontSize: '13px',
                cursor: 'pointer',
              }}
            >
              Remove
            </button>
          )}
        </div>
      </section>

      {/* Video Options */}
      {settings.background.type === 'video' && settings.background.videoPath && (
        <section>
          <div style={{ display: 'flex', gap: '24px' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '8px', cursor: 'pointer' }}>
              <input type="checkbox" checked={settings.background.videoMuted} onChange={(e) => setVideoMuted(e.target.checked)} style={{ accentColor: '#58a6ff' }} />
              <span style={{ color: '#e6edf3', fontSize: '13px' }}>Muted</span>
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '8px', cursor: 'pointer' }}>
              <input type="checkbox" checked={settings.background.videoLoop} onChange={(e) => setVideoLoop(e.target.checked)} style={{ accentColor: '#58a6ff' }} />
              <span style={{ color: '#e6edf3', fontSize: '13px' }}>Loop</span>
            </label>
          </div>
        </section>
      )}

      {/* Position */}
      <section>
        <h4 style={{ color: '#e6edf3', fontSize: '14px', fontWeight: 500, marginBottom: '12px' }}>Position</h4>
        <div style={{ display: 'flex', gap: '8px' }}>
          {positionOptions.map((option) => {
            const isSelected = settings.background.position === option.value
            return (
              <button
                key={option.value}
                onClick={() => setBackgroundPosition(option.value)}
                style={{
                  padding: '8px 16px',
                  backgroundColor: isSelected ? '#21262d' : 'transparent',
                  border: isSelected ? '1px solid #58a6ff' : '1px solid #30363d',
                  borderRadius: '6px',
                  color: isSelected ? '#e6edf3' : '#8b949e',
                  fontSize: '13px',
                  cursor: 'pointer',
                }}
              >
                {option.label}
              </button>
            )
          })}
        </div>
      </section>

      {/* Opacity & Blur */}
      <section>
        <SpacingInput label="Opacity" value={settings.background.opacity} onChange={setBackgroundOpacity} min={0} max={100} step={5} suffix="%" />
      </section>

      <section>
        <SpacingInput label="Blur" value={settings.background.blur} onChange={setBackgroundBlur} min={0} max={20} step={1} suffix="px" />
      </section>
    </div>
  )
}

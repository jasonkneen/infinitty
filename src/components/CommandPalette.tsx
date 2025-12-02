import { useState, useEffect, useCallback } from 'react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { triggerWebviewRestore } from '../hooks/useWebviewOverlay'

interface Command {
  id: string
  label: string
  shortcut?: string
  action: () => void
}

interface CommandPaletteProps {
  isOpen: boolean
  onClose: () => void
  commands: Command[]
}

export function CommandPalette({ isOpen, onClose, commands }: CommandPaletteProps) {
  const contextValue = useTerminalSettings()
  const settings = contextValue.settings
  const [search, setSearch] = useState('')
  const [selectedIndex, setSelectedIndex] = useState(0)

  const filteredCommands = commands.filter((cmd) =>
    cmd.label.toLowerCase().includes(search.toLowerCase())
  )

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!isOpen) return

      switch (e.key) {
        case 'Escape':
          onClose()
          break
        case 'ArrowDown':
          e.preventDefault()
          setSelectedIndex((i) => Math.min(i + 1, filteredCommands.length - 1))
          break
        case 'ArrowUp':
          e.preventDefault()
          setSelectedIndex((i) => Math.max(i - 1, 0))
          break
        case 'Enter':
          e.preventDefault()
          if (filteredCommands[selectedIndex]) {
            filteredCommands[selectedIndex].action()
            onClose()
          }
          break
      }
    },
    [isOpen, onClose, filteredCommands, selectedIndex]
  )

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeyDown])

  useEffect(() => {
    setSelectedIndex(0)
  }, [search])

  useEffect(() => {
    if (isOpen) {
      setSearch('')
      setSelectedIndex(0)
    }
  }, [isOpen])

  // Restore webviews when palette closes
  // (Hiding is done before palette opens in App.tsx openCommandPalette())
  useEffect(() => {
    if (!isOpen) {
      triggerWebviewRestore()
    }
  }, [isOpen])

  if (!isOpen) return null

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.5)',
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'center',
        paddingTop: '100px',
        zIndex: 999999,
      }}
      onClick={onClose}
    >
      <div
        style={{
          width: '90%',
          maxWidth: '480px',
          backgroundColor: settings.theme.background,
          border: `1px solid ${settings.theme.brightBlack}`,
          borderRadius: '10px',
          boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
          overflow: 'hidden',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ padding: '8px 12px', borderBottom: `1px solid ${settings.theme.brightBlack}` }}>
          <input
            type="text"
            placeholder="Type a command..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            autoFocus
            style={{
              width: '100%',
              padding: '8px',
              backgroundColor: 'transparent',
              border: 'none',
              color: settings.theme.foreground,
              fontSize: '14px',
              outline: 'none',
              boxSizing: 'border-box',
            }}
          />
        </div>

        <div style={{ maxHeight: '280px', overflowY: 'auto' }}>
          {filteredCommands.length === 0 ? (
            <div style={{ padding: '16px', textAlign: 'center', color: settings.theme.white, fontSize: '13px' }}>
              No commands found
            </div>
          ) : (
            filteredCommands.map((cmd, index) => (
              <div
                key={cmd.id}
                onClick={() => {
                  cmd.action()
                  onClose()
                }}
                style={{
                  padding: '8px 12px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  cursor: 'pointer',
                  backgroundColor: index === selectedIndex ? `${settings.theme.brightBlack}66` : 'transparent',
                }}
              >
                <span style={{ color: settings.theme.foreground, fontSize: '13px' }}>{cmd.label}</span>
                {cmd.shortcut && (
                  <span style={{ color: settings.theme.white, fontSize: '11px', opacity: 0.5 }}>{cmd.shortcut}</span>
                )}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  )
}

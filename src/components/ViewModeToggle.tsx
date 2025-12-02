import { Ghost, Infinity } from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { type TerminalViewMode } from '../types/tabs'

interface ViewModeToggleProps {
  viewMode: TerminalViewMode
  onChange: (mode: TerminalViewMode) => void
}

export function ViewModeToggle({ viewMode, onChange }: ViewModeToggleProps) {
  const { settings } = useTerminalSettings()
  
  return (
    <div
      style={{
        display: 'flex',
        backgroundColor: `${settings.theme.brightBlack}40`,
        borderRadius: '5px',
        padding: '2px',
        border: `1px solid ${settings.theme.brightBlack}`,
        transform: 'scale(0.9)',
      }}
    >
      <button
        onClick={() => onChange('classic')}
        title="Classic View"
        style={{
          padding: '4px 8px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          transition: 'all 0.15s ease',
          background: viewMode === 'classic' ? settings.theme.foreground : 'transparent',
          color: viewMode === 'classic' ? settings.theme.background : settings.theme.white,
        }}
      >
        <Ghost size={14} />
      </button>
      <button
        onClick={() => onChange('blocks')}
        title="Blocks View"
        style={{
          padding: '4px 8px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          transition: 'all 0.15s ease',
          background: viewMode === 'blocks' ? settings.theme.foreground : 'transparent',
          color: viewMode === 'blocks' ? settings.theme.background : settings.theme.white,
        }}
      >
        <Infinity size={14} />
      </button>
    </div>
  )
}

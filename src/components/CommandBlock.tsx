import { useMemo } from 'react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import type { CommandBlock as CommandBlockType } from '../types/blocks'

interface CommandBlockProps {
  block: CommandBlockType
  isFocused?: boolean
}

export function CommandBlock({ block, isFocused }: CommandBlockProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  const durationLabel = useMemo(() => {
    const end = block.endTime ? block.endTime.getTime() : Date.now()
    const seconds = (end - block.startTime.getTime()) / 1000
    return `${seconds.toFixed(3)}s`
  }, [block.endTime, block.startTime])

  // Determine if command had an error
  const hasError = block.exitCode !== null && block.exitCode !== 0
  const borderColor = hasError ? theme.red : theme.blue
  const commandColor = hasError ? theme.red : theme.blue

  return (
    <div
      style={{
        backgroundColor: isFocused ? `${theme.brightBlack}40` : `${theme.brightBlack}20`,
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        borderTop: `1px solid ${isFocused ? `${borderColor}40` : `${theme.white}10`}`,
        borderRight: 'none',
        borderBottom: `1px solid ${isFocused ? `${borderColor}40` : `${theme.white}10`}`,
        borderLeft: `6px solid ${borderColor}`,
        borderRadius: 0,
        overflow: 'hidden',
        transition: 'all 0.2s ease',
      }}
    >
      {/* Path and time row */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          padding: '10px 16px 6px',
          fontSize: '12px',
          fontFamily: settings.font.family,
          color: theme.white,
          opacity: 0.5,
        }}
      >
        <span>{block.cwd}</span>
        <span>({durationLabel})</span>
      </div>

      {/* Command */}
      <div style={{ padding: '0 16px 12px' }}>
        <div style={{
          color: commandColor,
          fontFamily: settings.font.family,
          fontSize: `${settings.fontSize}px`,
          fontWeight: 600,
          textDecoration: 'underline',
          textDecorationColor: `${commandColor}60`,
          textUnderlineOffset: '3px',
        }}>
          {block.command}
        </div>
      </div>

      {/* Output */}
      {block.output && (
        <div style={{ padding: '0 16px 16px' }}>
          <pre
            style={{
              fontFamily: settings.font.family,
              fontSize: `${settings.fontSize - 1}px`,
              color: theme.foreground,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
              lineHeight: settings.lineHeight,
              margin: 0,
            }}
          >
            {block.output}
          </pre>
        </div>
      )}

      {/* Running indicator */}
      {block.isRunning && (
        <div
          style={{
            padding: '8px 16px 12px',
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            fontSize: '10px',
            color: theme.white,
          }}
        >
          <span
            style={{
              width: '6px',
              height: '6px',
              backgroundColor: theme.cyan,
              borderRadius: '50%',
              animation: 'pulse 1.5s infinite',
            }}
          />
          Running...
        </div>
      )}
    </div>
  )
}

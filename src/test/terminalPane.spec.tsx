import { render, cleanup } from '@testing-library/react'
import React from 'react'
import { vi, describe, it, expect, beforeEach, afterEach } from 'vitest'
import { TerminalPane } from '../components/TerminalPane'
import { type TerminalPane as TerminalPaneType } from '../types/tabs'

// Mutable flag so we can flip modes per test
let ghosttyMode = true

vi.mock('../config', () => ({
  isGhosttyMode: () => ghosttyMode,
  isOpenWarpMode: () => !ghosttyMode,
}))

// Capture the props passed to the Terminal component
const terminalProps: any[] = []
vi.mock('../components/Terminal', () => ({
  Terminal: React.forwardRef((props: any, _ref) => {
    terminalProps[0] = props
    return <div data-testid="terminal-mock" />
  }),
}))

// Provide stable defaults for settings and tabs context
vi.mock('../contexts/TerminalSettingsContext', () => ({
  useTerminalSettings: () => ({
    settings: {
      theme: {
        background: '#000000',
        foreground: '#ffffff',
        brightBlack: '#333333',
        cyan: '#00ffff',
        red: '#ff0000',
        green: '#00ff00',
        yellow: '#ffff00',
        magenta: '#ff00ff',
        blue: '#0000ff',
        white: '#ffffff',
      },
      window: { opacity: 100, nativeContextMenus: false, tabStyle: 'compact' },
      behavior: { linkClickBehavior: 'browser' },
      uiFont: { family: 'Inter' },
      uiFontSize: 14,
    },
  }),
}))

vi.mock('../contexts/TabsContext', () => ({
  useTabs: () => ({
    activePaneId: 'pane-1',
    activeTabId: 'tab-1',
    setActivePane: vi.fn(),
    splitPane: vi.fn(),
    splitPaneWithWebview: vi.fn(),
    closePane: vi.fn(),
    getActiveTab: () => ({
      id: 'tab-1',
      root: { id: 'pane-1', type: 'terminal', title: 'Terminal', isActive: true },
    }),
    createWebViewTab: vi.fn(),
  }),
}))

vi.mock('../hooks/useBlockTerminal', () => ({
  useBlockTerminal: () => ({
    blocks: [],
    executeCommand: vi.fn(),
    executeAIQuery: vi.fn(),
    completeInteractiveBlock: vi.fn(),
    dismissBlock: vi.fn(),
  }),
}))

const explorerMocks = vi.hoisted(() => ({
  emitPwdChanged: vi.fn(),
}))
vi.mock('../hooks/useFileExplorer', () => explorerMocks)

describe('TerminalPane PWD propagation', () => {
  const basePane: TerminalPaneType = { id: 'pane-1', type: 'terminal', title: 'Terminal', isActive: true, viewMode: 'classic' }

  beforeEach(() => {
    ghosttyMode = true
    terminalProps.length = 0
  })

  afterEach(() => {
    cleanup()
  })

  it('does not emit pwd changes in Ghostty (classic) mode', () => {
    render(<TerminalPane pane={basePane} />)
    const handler = terminalProps[0]?.onPwdChange
    expect(typeof handler).toBe('function')
    explorerMocks.emitPwdChanged.mockClear()
    handler?.('/tmp')
    expect(explorerMocks.emitPwdChanged).not.toHaveBeenCalled()
  })

  it('provides onPwdChange when in OpenWarp/Infinitty mode', () => {
    ghosttyMode = false
    render(<TerminalPane pane={basePane} />)
    const handler = terminalProps[0]?.onPwdChange
    expect(typeof handler).toBe('function')
    explorerMocks.emitPwdChanged.mockClear()
    handler?.('/tmp')
    expect(explorerMocks.emitPwdChanged).toHaveBeenCalledWith('/tmp')
  })
})

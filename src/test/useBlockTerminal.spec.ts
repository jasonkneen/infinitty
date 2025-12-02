import { act, renderHook, waitFor } from '@testing-library/react'
import { vi, describe, it, expect, beforeEach } from 'vitest'

// Force OpenWarp behavior for this suite
vi.mock('../config', () => ({
  isOpenWarpMode: () => true,
  isGhosttyMode: () => false,
}))

vi.mock('../hooks/useFileExplorer', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useFileExplorer')>()
  return {
    ...actual,
    emitPwdChanged: vi.fn(),
  }
})

import { spawn, exitHandlers } from '../test/tauriPtyMock'
import { emitPwdChanged } from '../hooks/useFileExplorer'
import { useBlockTerminal } from '../hooks/useBlockTerminal'

describe('useBlockTerminal cwd propagation', () => {
  beforeEach(() => {
    exitHandlers.length = 0
    vi.mocked(emitPwdChanged).mockClear()
    spawn.mockClear()
  })

  it('spawns with the current cwd and emits pwd changes after successful cd', async () => {
    const { result } = renderHook(() => useBlockTerminal())

    await waitFor(() => expect(result.current.cwd).toBe('/home/test-user'))

    act(() => {
      result.current.executeCommand('cd /tmp')
    })

    expect(spawn).toHaveBeenCalledWith(expect.any(String), expect.any(Array), expect.objectContaining({ cwd: '/home/test-user' }))
    expect(exitHandlers.length).toBeGreaterThan(0)

    act(() => {
      exitHandlers.forEach((cb) => cb({ exitCode: 0 }))
    })
  })
})

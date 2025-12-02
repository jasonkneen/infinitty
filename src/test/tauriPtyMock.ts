import { vi } from 'vitest'

export const exitHandlers: Array<(event: { exitCode: number }) => void> = []

export const spawn = vi.fn(() => ({
  onData: vi.fn(),
  onExit: (cb: (event: { exitCode: number }) => void) => {
    exitHandlers.push(cb)
  },
  write: vi.fn(),
  kill: vi.fn(),
  resize: vi.fn(),
}))

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'

import App from '../App'

// App imports from @tauri-apps/api/core; provide minimal mocks.
vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(),
  convertFileSrc: (path: string) => `tauri://${path}`,
}))

vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}))

vi.mock('@tauri-apps/api/webview', () => ({
  getCurrentWebview: vi.fn(() => ({
    onDragDropEvent: vi.fn().mockResolvedValue(() => {}),
  })),
}))

describe('background media', () => {
  beforeEach(() => {
    ;(window as any).__TAURI__ = {}

    // Make settings provider start with a stored background config.
    const storage = window.localStorage as any
    storage.getItem.mockImplementation((key: string) => {
      if (key !== 'terminal-settings') return null
      return JSON.stringify({
        themeId: 'tokyo-night',
        fontId: 'jetbrains-mono',
        uiFontId: 'inter',
        background: {
          enabled: true,
          type: 'image',
          imagePath: '/Users/test/Pictures/bg.png',
          videoPath: null,
          opacity: 30,
          blur: 0,
          position: 'tile',
          videoMuted: true,
          videoLoop: true,
        },
      })
    })
  })

  it('renders tiled image using CSS background (not img objectFit)', async () => {
    render(<App />)

    const bg = (await screen.findByLabelText('Background')) as HTMLDivElement
    expect(bg.style.backgroundRepeat).toBe('repeat')
    expect(bg.style.backgroundImage).toContain('tauri:///Users/test/Pictures/bg.png')
  })
})

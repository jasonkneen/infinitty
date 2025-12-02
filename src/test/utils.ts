import { ReactElement } from 'react'
import { render, RenderOptions } from '@testing-library/react'
import { vi } from 'vitest'

/**
 * Custom render function that wraps React Testing Library render
 * Can be extended to include providers (Context, Redux, etc.)
 */
export function renderWithProviders(
  ui: ReactElement,
  options?: Omit<RenderOptions, 'wrapper'>
) {
  return render(ui, { ...options })
}

// Re-export everything from React Testing Library
export * from '@testing-library/react'
export { default as userEvent } from '@testing-library/user-event'

/**
 * Mock API response helper
 */
export function createMockFetch(responses: Record<string, unknown>) {
  return vi.fn((url: string) => {
    const response = responses[url]
    if (response instanceof Error) {
      return Promise.reject(response)
    }
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve(response),
      text: () => Promise.resolve(JSON.stringify(response)),
    })
  })
}

/**
 * Wait for async operations to complete
 */
export async function waitForAsync() {
  return new Promise(resolve => setTimeout(resolve, 0))
}

/**
 * Create a mock Tauri command result
 */
export function createMockTauriResult<T>(data: T) {
  return Promise.resolve(data)
}

/**
 * Create a mock Tauri error
 */
export function createMockTauriError(message: string) {
  return Promise.reject(new Error(message))
}

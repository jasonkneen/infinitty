/**
 * Global webview overlay management
 *
 * When a dialog opens, we:
 * 1. Trigger capture event (WebViewPane components listen)
 * 2. WebViewPane shows a placeholder and hides the native webview
 * 3. Dialog opens over the placeholder
 *
 * When the dialog closes, we restore the webview position and remove placeholder.
 *
 * Note: Screenshot capture from external webviews is not currently possible
 * due to Tauri's security model. The placeholder shows the URL instead.
 */

import { invoke } from '@tauri-apps/api/core'

// Event names for React components
export const WEBVIEW_CAPTURE_EVENT = 'webview-capture-start'
export const WEBVIEW_RESTORE_EVENT = 'webview-restore-start'

/**
 * Capture screenshot from a specific webview
 * Returns a promise that resolves with the data URL
 *
 * Note: For external URLs, this will return null quickly since we can't inject scripts
 * that communicate back to the main window. The webview will be hidden and a
 * placeholder shown instead.
 */
export async function captureWebviewScreenshot(_webviewId: string): Promise<string | null> {
  // For now, return null immediately
  // External webviews can't send data back to the main window due to Tauri's security model
  // The webview will be hidden and a placeholder shown
  //
  // Future improvement: Use Tauri's native screenshot APIs when available
  // or implement a custom protocol handler for IPC
  return null
}

/**
 * Trigger capture for all webviews - components listen to this
 */
export function triggerWebviewCapture(): void {
  window.dispatchEvent(new CustomEvent(WEBVIEW_CAPTURE_EVENT))
}

/**
 * Trigger restore for all webviews - dialogs should call this when closing
 */
export function triggerWebviewRestore(): void {
  window.dispatchEvent(new CustomEvent(WEBVIEW_RESTORE_EVENT))
}

/**
 * Hide all webviews (move off-screen) via Tauri command
 */
export async function hideAllWebviews(): Promise<void> {
  try {
    await invoke('hide_all_webviews')
  } catch (err) {
    console.error('[useWebviewOverlay] Failed to hide webviews:', err)
  }
}

/**
 * Show all webviews (refresh positions)
 */
export function showAllWebviews(): void {
  window.dispatchEvent(new CustomEvent('webviews-refresh'))
}

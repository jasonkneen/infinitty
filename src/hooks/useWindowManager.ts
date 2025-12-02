import { useCallback } from 'react'
import { invoke } from '@tauri-apps/api/core'

export function useWindowManager() {
  const createNewWindow = useCallback(async (): Promise<string> => {
    try {
      return await invoke<string>('create_new_window')
    } catch (error) {
      console.error('Failed to create new window:', error)
      throw error
    }
  }, [])

  const mergeWindowsToTabs = useCallback(async (): Promise<void> => {
    try {
      await invoke('merge_windows_to_tabs')
    } catch (error) {
      console.error('Failed to merge windows:', error)
      throw error
    }
  }, [])

  const moveTabToNewWindow = useCallback(async (windowLabel: string): Promise<void> => {
    try {
      await invoke('move_tab_to_new_window', { windowLabel })
    } catch (error) {
      console.error('Failed to move tab to new window:', error)
      throw error
    }
  }, [])

  const getWindowCount = useCallback(async (): Promise<number> => {
    try {
      return await invoke<number>('get_window_count')
    } catch (error) {
      console.error('Failed to get window count:', error)
      return 1
    }
  }, [])

  return {
    createNewWindow,
    mergeWindowsToTabs,
    moveTabToNewWindow,
    getWindowCount,
  }
}

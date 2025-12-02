import { useState, useCallback, useEffect } from 'react'
import { readDir, stat } from '@tauri-apps/plugin-fs'
import { join } from '@tauri-apps/api/path'

// Custom event for pwd changes (terminal -> file explorer)
export const PWD_CHANGED_EVENT = 'terminal-pwd-changed'

export function emitPwdChanged(path: string) {
  console.log('[FileExplorer] PWD changed event:', path)
  window.dispatchEvent(new CustomEvent(PWD_CHANGED_EVENT, { detail: { path } }))
}

// Custom event for changing terminal CWD (file explorer -> terminal)
export const CHANGE_TERMINAL_CWD_EVENT = 'change-terminal-cwd'

export function emitChangeTerminalCwd(path: string) {
  console.log('[FileExplorer] Requesting terminal cd to:', path)
  window.dispatchEvent(new CustomEvent(CHANGE_TERMINAL_CWD_EVENT, { detail: { path } }))
}

export interface FileNode {
  name: string
  path: string
  isFolder: boolean
  children?: FileNode[]
  isLoading?: boolean
  error?: string
}

interface UseFileExplorerState {
  root: FileNode | null
  currentPath: string
  isLoading: boolean
  error: string | null
  favorites: string[]
  autoFollowPwd: boolean
  history: string[]
  historyIndex: number
}

interface UseFileExplorerActions {
  initializeExplorer: (startPath?: string) => Promise<void>
  expandFolder: (path: string) => Promise<void>
  toggleFolder: (path: string) => Promise<void>
  addFavorite: (path: string) => void
  removeFavorite: (path: string) => void
  navigateTo: (path: string) => Promise<void>
  refresh: () => Promise<void>
  setAutoFollowPwd: (enabled: boolean) => void
  goBack: () => Promise<void>
  goForward: () => Promise<void>
  canGoBack: boolean
  canGoForward: boolean
}

export function useFileExplorer(): UseFileExplorerState & UseFileExplorerActions {
  const [state, setState] = useState<UseFileExplorerState>({
    root: null,
    currentPath: '',
    isLoading: false,
    error: null,
    favorites: JSON.parse(localStorage.getItem('fileExplorerFavorites') || '[]'),
    autoFollowPwd: localStorage.getItem('fileExplorerAutoFollow') !== 'false', // default true
    history: [],
    historyIndex: -1,
  })

  const loadDirectory = useCallback(
    async (path: string): Promise<FileNode | null> => {
      try {
        const entries = await readDir(path)
        const children: FileNode[] = []

        for (const entry of entries) {
          try {
            const entryPath = await join(path, entry.name)
            const fileInfo = await stat(entryPath)

            children.push({
              name: entry.name,
              path: entryPath,
              isFolder: fileInfo.isDirectory,
              children: fileInfo.isDirectory ? [] : undefined,
              error: undefined,
            })
          } catch (err) {
            continue
          }
        }

        children.sort((a, b) => {
          if (a.isFolder !== b.isFolder) {
            return b.isFolder ? 1 : -1
          }
          return a.name.localeCompare(b.name)
        })

        return {
          name: path.split('/').pop() || path,
          path,
          isFolder: true,
          children,
        }
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : 'Failed to read directory'
        return {
          name: path.split('/').pop() || path,
          path,
          isFolder: true,
          children: [],
          error: errorMsg,
        }
      }
    },
    []
  )

  const initializeExplorer = useCallback(
    async (startPath?: string) => {
      setState((prev) => ({ ...prev, isLoading: true, error: null }))

      try {
        // Always start in home directory (startPath can override)
        const homePath = startPath || (await getHomeDirectory())
        const rootNode = await loadDirectory(homePath)

        // Initialize history with the starting path
        setState((prev) => ({
          ...prev,
          root: rootNode,
          currentPath: homePath,
          isLoading: false,
          history: [homePath],
          historyIndex: 0,
        }))

        // Save the path
        localStorage.setItem('fileExplorerLastPath', homePath)
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : 'Failed to initialize explorer'
        setState((prev) => ({
          ...prev,
          isLoading: false,
          error: errorMsg,
        }))
      }
    },
    [loadDirectory]
  )

  const findNodeByPath = useCallback(
    (node: FileNode | null, targetPath: string): FileNode | null => {
      if (!node) return null
      if (node.path === targetPath) return node

      if (node.children) {
        for (const child of node.children) {
          const found = findNodeByPath(child, targetPath)
          if (found) return found
        }
      }

      return null
    },
    []
  )

  const expandFolder = useCallback(
    async (path: string) => {
      setState((prev) => {
        if (!prev.root) return prev

        const updateNode = (node: FileNode): FileNode => {
          if (node.path === path) {
            return { ...node, isLoading: true }
          }
          if (node.children) {
            return {
              ...node,
              children: node.children.map(updateNode),
            }
          }
          return node
        }

        return { ...prev, root: prev.root ? updateNode(prev.root) : null }
      })

      try {
        const loadedNode = await loadDirectory(path)

        setState((prev) => {
          if (!prev.root) return prev

          const updateNode = (node: FileNode): FileNode => {
            if (node.path === path) {
              return {
                ...node,
                children: loadedNode?.children || [],
                isLoading: false,
                error: loadedNode?.error,
              }
            }
            if (node.children) {
              return {
                ...node,
                children: node.children.map(updateNode),
              }
            }
            return node
          }

          return { ...prev, root: prev.root ? updateNode(prev.root) : null }
        })
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : 'Failed to expand folder'
        setState((prev) => {
          if (!prev.root) return prev

          const updateNode = (node: FileNode): FileNode => {
            if (node.path === path) {
              return { ...node, isLoading: false, error: errorMsg }
            }
            if (node.children) {
              return {
                ...node,
                children: node.children.map(updateNode),
              }
            }
            return node
          }

          return { ...prev, root: prev.root ? updateNode(prev.root) : null }
        })
      }
    },
    [loadDirectory]
  )

  const toggleFolder = useCallback(
    async (path: string) => {
      const node = findNodeByPath(state.root, path)

      if (!node) return
      if (!node.isFolder) return

      if ((!node.children || node.children.length === 0) && !node.isLoading) {
        await expandFolder(path)
      } else {
        setState((prev) => {
          if (!prev.root) return prev

          const updateNode = (n: FileNode): FileNode => {
            if (n.path === path) {
              return {
                ...n,
                children: n.children && n.children.length > 0 ? [] : n.children,
              }
            }
            if (n.children) {
              return {
                ...n,
                children: n.children.map(updateNode),
              }
            }
            return n
          }

          return { ...prev, root: prev.root ? updateNode(prev.root) : null }
        })
      }
    },
    [state.root, findNodeByPath, expandFolder]
  )

  const addFavorite = useCallback((path: string) => {
    setState((prev) => {
      const updated = Array.from(new Set([...prev.favorites, path]))
      localStorage.setItem('fileExplorerFavorites', JSON.stringify(updated))
      return { ...prev, favorites: updated }
    })
  }, [])

  const removeFavorite = useCallback((path: string) => {
    setState((prev) => {
      const updated = prev.favorites.filter((fav) => fav !== path)
      localStorage.setItem('fileExplorerFavorites', JSON.stringify(updated))
      return { ...prev, favorites: updated }
    })
  }, [])

  const navigateTo = useCallback(
    async (path: string, addToHistory = true) => {
      console.log('[FileExplorer] Navigating to:', path)
      setState((prev) => ({ ...prev, isLoading: true, error: null }))

      try {
        const node = await loadDirectory(path)
        setState((prev) => {
          // If adding to history, truncate forward history and add new path
          let newHistory = prev.history
          let newIndex = prev.historyIndex

          if (addToHistory && path !== prev.currentPath) {
            // Truncate any forward history if we navigated from a back state
            newHistory = prev.history.slice(0, prev.historyIndex + 1)
            newHistory.push(path)
            newIndex = newHistory.length - 1
          }

          return {
            ...prev,
            currentPath: path,
            root: node,
            isLoading: false,
            history: newHistory,
            historyIndex: newIndex,
          }
        })

        // Save the path for persistence
        localStorage.setItem('fileExplorerLastPath', path)
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : 'Failed to navigate'
        setState((prev) => ({
          ...prev,
          isLoading: false,
          error: errorMsg,
        }))
      }
    },
    [loadDirectory]
  )

  const goBack = useCallback(async () => {
    if (state.historyIndex > 0) {
      const prevPath = state.history[state.historyIndex - 1]
      setState((prev) => ({ ...prev, historyIndex: prev.historyIndex - 1 }))
      await navigateTo(prevPath, false)
    }
  }, [state.history, state.historyIndex, navigateTo])

  const goForward = useCallback(async () => {
    if (state.historyIndex < state.history.length - 1) {
      const nextPath = state.history[state.historyIndex + 1]
      setState((prev) => ({ ...prev, historyIndex: prev.historyIndex + 1 }))
      await navigateTo(nextPath, false)
    }
  }, [state.history, state.historyIndex, navigateTo])

  const canGoBack = state.historyIndex > 0
  const canGoForward = state.historyIndex < state.history.length - 1

  const refresh = useCallback(
    async () => {
      if (state.root) {
        await navigateTo(state.root.path)
      }
    },
    [state.root, navigateTo]
  )

  const setAutoFollowPwd = useCallback((enabled: boolean) => {
    setState((prev) => ({ ...prev, autoFollowPwd: enabled }))
    localStorage.setItem('fileExplorerAutoFollow', enabled.toString())
  }, [])

  // Listen for pwd changes from terminals
  useEffect(() => {
    if (!state.autoFollowPwd) {
      console.log('[FileExplorer] Auto-follow disabled')
      return
    }

    console.log('[FileExplorer] Setting up pwd change listener, autoFollowPwd:', state.autoFollowPwd)

    const handlePwdChange = (event: CustomEvent<{ path: string }>) => {
      const newPath = event.detail.path
      console.log('[FileExplorer] Received pwd change:', newPath, 'current:', state.currentPath)
      if (newPath && newPath !== state.currentPath) {
        console.log('[FileExplorer] Navigating to new path')
        navigateTo(newPath)
      }
    }

    window.addEventListener(PWD_CHANGED_EVENT, handlePwdChange as EventListener)
    return () => {
      window.removeEventListener(PWD_CHANGED_EVENT, handlePwdChange as EventListener)
    }
  }, [state.autoFollowPwd, state.currentPath, navigateTo])

  return {
    ...state,
    initializeExplorer,
    expandFolder,
    toggleFolder,
    addFavorite,
    removeFavorite,
    navigateTo,
    refresh,
    setAutoFollowPwd,
    goBack,
    goForward,
    canGoBack,
    canGoForward,
  }
}

async function getHomeDirectory(): Promise<string> {
  try {
    const { homeDir } = await import('@tauri-apps/api/path')
    return await homeDir()
  } catch {
    return '~'
  }
}

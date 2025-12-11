import { useState, useRef, useCallback, useEffect } from 'react'
import { createPortal } from 'react-dom'
import { invoke } from '@tauri-apps/api/core'
import {
  ChevronDown,
  ChevronRight,
  File,
  FileCode,
  Folder,
  Search,
  Server,
  Plus,
  PanelLeftClose,
  Star,
  RefreshCw,
  Navigation2,
  Cpu,
  LayoutGrid,
  GitBranch,
  GitCommit,
  Check,
  Circle,
  Minus,
  Upload,
  FolderPlus,
  FilePlus,
  Pencil,
  Copy,
  Scissors,
  Clipboard,
  Trash2,
  Terminal,
} from 'lucide-react'
import { useFileExplorer, emitChangeTerminalCwd, type FileNode } from '../hooks/useFileExplorer'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import type { TerminalTheme } from '../config/terminal'
import { useTabs } from '../contexts/TabsContext'
import { MCPPanel } from './MCPPanel'

type ViewMode = 'widgets' | 'workspace' | 'git' | 'mcp'

// File explorer action buttons (refresh, follow pwd) - shown in header when workspace view is active
function FileExplorerActions() {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const { refresh, autoFollowPwd, setAutoFollowPwd } = useFileExplorer()

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '2px' }}>
      <button
        onClick={() => refresh()}
        style={{
          padding: '6px',
          backgroundColor: 'transparent',
          border: 'none',
          borderRadius: '4px',
          color: theme.brightBlack,
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          transition: 'color 0.15s ease, background-color 0.15s ease',
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.color = theme.foreground
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.color = theme.brightBlack
        }}
        title="Refresh"
      >
        <RefreshCw size={16} />
      </button>
      <button
        onClick={() => setAutoFollowPwd(!autoFollowPwd)}
        style={{
          padding: '6px',
          backgroundColor: autoFollowPwd ? `${theme.cyan}20` : 'transparent',
          border: 'none',
          borderRadius: '4px',
          color: autoFollowPwd ? theme.cyan : theme.brightBlack,
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          transition: 'color 0.15s ease, background-color 0.15s ease',
        }}
        onMouseEnter={(e) => {
          if (!autoFollowPwd) e.currentTarget.style.color = theme.foreground
        }}
        onMouseLeave={(e) => {
          if (!autoFollowPwd) e.currentTarget.style.color = theme.brightBlack
        }}
        title={autoFollowPwd ? 'Auto-follow terminal pwd (on)' : 'Auto-follow terminal pwd (off)'}
      >
        <Navigation2 size={16} />
      </button>
    </div>
  )
}

interface SidebarProps {
  isOpen: boolean
  onToggle: () => void
}

export function Sidebar({ isOpen, onToggle }: SidebarProps) {
  const [view, setView] = useState<ViewMode>('workspace')
  const [width, setWidth] = useState(360)
  const [isResizing, setIsResizing] = useState(false)
  const sidebarRef = useRef<HTMLElement>(null)
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  const startResizing = useCallback(() => {
    setIsResizing(true)
  }, [])

  const stopResizing = useCallback(() => {
    setIsResizing(false)
  }, [])

  const resize = useCallback(
    (e: MouseEvent) => {
      if (isResizing && sidebarRef.current) {
        const newWidth = e.clientX - sidebarRef.current.getBoundingClientRect().left
        if (newWidth >= 360 && newWidth <= 600) {
          setWidth(newWidth)
        }
      }
    },
    [isResizing]
  )

  useEffect(() => {
    window.addEventListener('mousemove', resize)
    window.addEventListener('mouseup', stopResizing)
    return () => {
      window.removeEventListener('mousemove', resize)
      window.removeEventListener('mouseup', stopResizing)
    }
  }, [resize, stopResizing])

  return (
    <aside
      ref={sidebarRef}
      style={{
        position: 'relative',
        width: isOpen ? `${width}px` : '0',
        minWidth: isOpen ? `${width}px` : '0',
        opacity: isOpen ? 1 : 0,
        backgroundColor: 'transparent',
        backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
        color: theme.foreground,
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        transition: isResizing ? 'none' : 'opacity 0.2s ease',
        borderRight: `1px solid ${theme.white}30`,
      } as React.CSSProperties}
    >
      {/* Traffic lights spacer and collapse button */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'flex-end',
          padding: '10px 12px',
          height: '38px',
          WebkitAppRegion: 'drag',
        } as React.CSSProperties}
      >
        {/* Collapse Button */}
        <button
          onClick={onToggle}
          style={{
            padding: '6px',
            backgroundColor: 'transparent',
            border: 'none',
            cursor: 'pointer',
            color: theme.white,
            transition: 'color 0.15s ease',
            WebkitAppRegion: 'no-drag',
          } as React.CSSProperties}
          onMouseEnter={(e) => {
            e.currentTarget.style.color = theme.foreground
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.color = theme.white
          }}
          title="Collapse sidebar"
        >
          <PanelLeftClose size={16} />
        </button>
      </div>

      {/* View Icons - below traffic lights, left aligned with file explorer actions on right */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '2px', padding: '0 18px 0 11px' }}>
        <button
          onClick={() => setView('workspace')}
          style={{
            padding: '6px',
            backgroundColor: view === 'workspace' ? `${theme.white}15` : 'transparent',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
            color: view === 'workspace' ? theme.foreground : theme.brightBlack,
            transition: 'color 0.15s ease, background-color 0.15s ease',
          }}
          title="Files"
        >
          <Folder size={16} />
        </button>
        <button
          onClick={() => setView('git')}
          style={{
            padding: '6px',
            backgroundColor: view === 'git' ? `${theme.white}15` : 'transparent',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
            color: view === 'git' ? theme.foreground : theme.brightBlack,
            transition: 'color 0.15s ease, background-color 0.15s ease',
          }}
          title="Git"
        >
          <GitBranch size={16} />
        </button>
        <button
          onClick={() => setView('mcp')}
          style={{
            padding: '6px',
            backgroundColor: view === 'mcp' ? `${theme.white}15` : 'transparent',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
            color: view === 'mcp' ? theme.foreground : theme.brightBlack,
            transition: 'color 0.15s ease, background-color 0.15s ease',
          }}
          title="MCP Servers"
        >
          <Server size={16} />
        </button>
        <button
          onClick={() => setView('widgets')}
          style={{
            padding: '6px',
            backgroundColor: view === 'widgets' ? `${theme.white}15` : 'transparent',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
            color: view === 'widgets' ? theme.foreground : theme.brightBlack,
            transition: 'color 0.15s ease, background-color 0.15s ease',
          }}
          title="Widgets"
        >
          <LayoutGrid size={16} />
        </button>

        {/* Spacer */}
        <div style={{ flex: 1 }} />

        {/* File explorer actions - only visible in workspace view */}
        {view === 'workspace' && <FileExplorerActions />}
      </div>

      <div style={{ flex: 1, overflowY: 'auto' }}>
        {view === 'widgets' && <WidgetsPanel />}
        {view === 'workspace' && <ExplorerPanel />}
        {view === 'git' && <GitPanel />}
        {view === 'mcp' && <MCPViewPanel />}
      </div>

      <div
        onMouseDown={startResizing}
        style={{
          position: 'absolute',
          right: 0,
          top: 0,
          bottom: 0,
          width: '4px',
          cursor: 'col-resize',
          backgroundColor: isResizing ? theme.cyan : 'transparent',
          transition: 'background-color 0.15s ease',
        }}
        onMouseEnter={(e) => {
          if (!isResizing) {
            e.currentTarget.style.backgroundColor = `${theme.cyan}4d`
          }
        }}
        onMouseLeave={(e) => {
          if (!isResizing) {
            e.currentTarget.style.backgroundColor = 'transparent'
          }
        }}
      />
    </aside>
  )
}

function WidgetsPanel() {
  const { createWidgetTab } = useTabs()

  return (
    <div style={{ padding: '8px 12px', display: 'flex', flexDirection: 'column', gap: '2px' }}>
      <MenuItem
        icon={Cpu}
        label="Nodes Editor"
        onClick={() => createWidgetTab('nodes', 'Nodes')}
      />
      <MenuItem
        icon={LayoutGrid}
        label="Chart"
        onClick={() => createWidgetTab('chart', 'Chart')}
      />
    </div>
  )
}

function MCPViewPanel() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
        <MCPPanel />
      </div>
    </div>
  )
}

function MenuItem({
  icon: Icon,
  label,
  highlight,
  onClick,
}: {
  icon: typeof Server
  label: string
  highlight?: boolean
  onClick?: () => void
}) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        width: '100%',
        alignItems: 'center',
        gap: '12px',
        padding: '8px 12px',
        fontSize: '14px',
        color: highlight ? theme.blue : theme.white,
        backgroundColor: 'transparent',
        border: 'none',
        cursor: 'pointer',
        textAlign: 'left',
        borderRadius: '6px',
        transition: 'all 0.15s ease',
      }}
    >
      <Icon size={16} style={{ color: highlight ? theme.blue : theme.white }} />
      <span>{label}</span>
    </button>
  )
}

// Git Panel - Shows git status, changes, staging, etc.
interface GitFileChange {
  path: string
  status: 'modified' | 'added' | 'deleted' | 'untracked' | 'renamed'
}

interface GitStatus {
  current_branch: string
  branches: string[]
  staged: { path: string; status: string }[]
  unstaged: { path: string; status: string }[]
}

function GitPanel() {
  const [currentBranch, setCurrentBranch] = useState<string>('main')
  const [branches, setBranches] = useState<string[]>([])
  const [changes, setChanges] = useState<GitFileChange[]>([])
  const [stagedChanges, setStagedChanges] = useState<GitFileChange[]>([])
  const [commitMessage, setCommitMessage] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [showBranchPicker, setShowBranchPicker] = useState(false)
  const [repoPath, setRepoPath] = useState<string>('')
  const { settings } = useTerminalSettings()
  const { createEditorTab } = useTabs()
  const theme = settings.theme

  // Get current directory on mount
  useEffect(() => {
    const getCwd = async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const cwd = await invoke<string>('get_current_directory')
        setRepoPath(cwd)
      } catch (err) {
        console.error('Failed to get cwd:', err)
      }
    }
    getCwd()
  }, [])

  // Load git status when repoPath changes
  useEffect(() => {
    if (repoPath) {
      loadGitStatus()
    }
  }, [repoPath])

  const loadGitStatus = useCallback(async () => {
    if (!repoPath) return
    setIsLoading(true)
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      const status = await invoke<GitStatus>('get_git_status', { path: repoPath })

      setCurrentBranch(status.current_branch)
      setBranches(status.branches)

      // Map status strings to our status type
      const mapStatus = (s: string): GitFileChange['status'] => {
        switch (s) {
          case 'modified': return 'modified'
          case 'added': return 'added'
          case 'deleted': return 'deleted'
          case 'renamed': return 'renamed'
          case 'untracked': return 'untracked'
          default: return 'modified'
        }
      }

      setChanges(status.unstaged.map(f => ({ path: f.path, status: mapStatus(f.status) })))
      setStagedChanges(status.staged.map(f => ({ path: f.path, status: mapStatus(f.status) })))
    } catch (err) {
      console.error('Failed to load git status:', err)
      // Not a git repo or git not available
      setChanges([])
      setStagedChanges([])
    } finally {
      setIsLoading(false)
    }
  }, [repoPath])

  const stageFile = useCallback(async (path: string) => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('git_stage_file', { path: repoPath, file: path })
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to stage file:', err)
    }
  }, [repoPath, loadGitStatus])

  const unstageFile = useCallback(async (path: string) => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('git_unstage_file', { path: repoPath, file: path })
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to unstage file:', err)
    }
  }, [repoPath, loadGitStatus])

  const stageAll = useCallback(async () => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      for (const file of changes) {
        await invoke('git_stage_file', { path: repoPath, file: file.path })
      }
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to stage all:', err)
    }
  }, [repoPath, changes, loadGitStatus])

  const unstageAll = useCallback(async () => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      for (const file of stagedChanges) {
        await invoke('git_unstage_file', { path: repoPath, file: file.path })
      }
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to unstage all:', err)
    }
  }, [repoPath, stagedChanges, loadGitStatus])

  const commit = useCallback(async () => {
    if (!commitMessage.trim() || stagedChanges.length === 0 || !repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('git_commit', { path: repoPath, message: commitMessage })
      setCommitMessage('')
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to commit:', err)
    }
  }, [commitMessage, stagedChanges, repoPath, loadGitStatus])

  const push = useCallback(async () => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('git_push', { path: repoPath })
    } catch (err) {
      console.error('Failed to push:', err)
    }
  }, [repoPath])

  const switchBranch = useCallback(async (branch: string) => {
    if (!repoPath) return
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      await invoke('git_checkout_branch', { path: repoPath, branch })
      setShowBranchPicker(false)
      await loadGitStatus()
    } catch (err) {
      console.error('Failed to switch branch:', err)
    }
  }, [repoPath, loadGitStatus])

  const openFile = useCallback((filePath: string) => {
    // Build full path
    const fullPath = repoPath ? `${repoPath}/${filePath}` : filePath
    createEditorTab(fullPath)
  }, [repoPath, createEditorTab])

  const getStatusIcon = (status: GitFileChange['status']) => {
    switch (status) {
      case 'modified': return <Circle size={10} style={{ color: theme.yellow }} />
      case 'added': return <Plus size={10} style={{ color: theme.green }} />
      case 'deleted': return <Minus size={10} style={{ color: theme.red }} />
      case 'untracked': return <Circle size={10} style={{ color: theme.brightBlack }} />
      case 'renamed': return <ChevronRight size={10} style={{ color: theme.blue }} />
    }
  }

  const getStatusColor = (status: GitFileChange['status']) => {
    switch (status) {
      case 'modified': return theme.yellow
      case 'added': return theme.green
      case 'deleted': return theme.red
      case 'untracked': return theme.brightBlack
      case 'renamed': return theme.blue
    }
  }

  return (
    <div style={{ padding: '8px 12px', display: 'flex', flexDirection: 'column', height: '100%', gap: '12px' }}>
      {/* Branch Selector */}
      <div style={{ position: 'relative' }}>
        <button
          onClick={() => setShowBranchPicker(!showBranchPicker)}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            padding: '8px 12px',
            backgroundColor: `${theme.brightBlack}20`,
            border: `1px solid ${theme.brightBlack}40`,
            borderRadius: '6px',
            color: theme.foreground,
            fontSize: '13px',
            cursor: 'pointer',
            width: '100%',
          }}
        >
          <GitBranch size={14} />
          <span style={{ flex: 1, textAlign: 'left' }}>{currentBranch}</span>
          <ChevronDown size={14} style={{ color: theme.brightBlack }} />
        </button>

        {showBranchPicker && (
          <div
            style={{
              position: 'absolute',
              top: '100%',
              left: 0,
              right: 0,
              marginTop: '4px',
              backgroundColor: theme.background,
              border: `1px solid ${theme.brightBlack}40`,
              borderRadius: '6px',
              boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
              zIndex: 10,
              maxHeight: '200px',
              overflowY: 'auto',
            }}
          >
            {branches.map(branch => (
              <button
                key={branch}
                onClick={() => switchBranch(branch)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  padding: '8px 12px',
                  backgroundColor: branch === currentBranch ? `${theme.cyan}20` : 'transparent',
                  border: 'none',
                  color: branch === currentBranch ? theme.cyan : theme.foreground,
                  fontSize: '13px',
                  cursor: 'pointer',
                  width: '100%',
                  textAlign: 'left',
                }}
              >
                <GitBranch size={12} />
                {branch}
                {branch === currentBranch && <Check size={12} style={{ marginLeft: 'auto' }} />}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Staged Changes */}
      {stagedChanges.length > 0 && (
        <div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
            <span style={{ fontSize: '11px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: theme.green }}>
              Staged ({stagedChanges.length})
            </span>
            <button
              onClick={unstageAll}
              style={{
                padding: '2px 6px',
                backgroundColor: 'transparent',
                border: 'none',
                color: theme.brightBlack,
                fontSize: '11px',
                cursor: 'pointer',
              }}
            >
              Unstage All
            </button>
          </div>
          {stagedChanges.map(file => (
            <div
              key={file.path}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                padding: '4px 8px',
                borderRadius: '4px',
                fontSize: '12px',
                color: theme.foreground,
              }}
            >
              {getStatusIcon(file.status)}
              <button
                onClick={() => openFile(file.path)}
                style={{
                  flex: 1,
                  textAlign: 'left',
                  backgroundColor: 'transparent',
                  border: 'none',
                  color: getStatusColor(file.status),
                  fontSize: '12px',
                  cursor: 'pointer',
                  padding: 0,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
                title={file.path}
              >
                {file.path.split('/').pop()}
              </button>
              <button
                onClick={() => unstageFile(file.path)}
                style={{
                  padding: '2px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  color: theme.brightBlack,
                  cursor: 'pointer',
                }}
                title="Unstage"
              >
                <Minus size={12} />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Unstaged Changes */}
      {changes.length > 0 && (
        <div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '8px' }}>
            <span style={{ fontSize: '11px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: theme.brightBlack }}>
              Changes ({changes.length})
            </span>
            <button
              onClick={stageAll}
              style={{
                padding: '2px 6px',
                backgroundColor: 'transparent',
                border: 'none',
                color: theme.brightBlack,
                fontSize: '11px',
                cursor: 'pointer',
              }}
            >
              Stage All
            </button>
          </div>
          {changes.map(file => (
            <div
              key={file.path}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                padding: '4px 8px',
                borderRadius: '4px',
                fontSize: '12px',
                color: theme.foreground,
              }}
            >
              {getStatusIcon(file.status)}
              <button
                onClick={() => openFile(file.path)}
                style={{
                  flex: 1,
                  textAlign: 'left',
                  backgroundColor: 'transparent',
                  border: 'none',
                  color: getStatusColor(file.status),
                  fontSize: '12px',
                  cursor: 'pointer',
                  padding: 0,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
                title={file.path}
              >
                {file.path.split('/').pop()}
              </button>
              <button
                onClick={() => stageFile(file.path)}
                style={{
                  padding: '2px',
                  backgroundColor: 'transparent',
                  border: 'none',
                  color: theme.brightBlack,
                  cursor: 'pointer',
                }}
                title="Stage"
              >
                <Plus size={12} />
              </button>
            </div>
          ))}
        </div>
      )}

      {changes.length === 0 && stagedChanges.length === 0 && !isLoading && (
        <div style={{ padding: '20px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
          <Check size={24} style={{ marginBottom: '8px', opacity: 0.5 }} />
          <div>No changes</div>
        </div>
      )}

      {isLoading && (
        <div style={{ padding: '20px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
          Loading...
        </div>
      )}

      {/* Commit Box */}
      {stagedChanges.length > 0 && (
        <div style={{ marginTop: 'auto', display: 'flex', flexDirection: 'column', gap: '8px' }}>
          <textarea
            value={commitMessage}
            onChange={(e) => setCommitMessage(e.target.value)}
            placeholder="Commit message..."
            style={{
              padding: '8px 12px',
              backgroundColor: `${theme.brightBlack}20`,
              border: `1px solid ${theme.brightBlack}40`,
              borderRadius: '6px',
              color: theme.foreground,
              fontSize: '13px',
              resize: 'none',
              height: '60px',
              outline: 'none',
            }}
          />
          <div style={{ display: 'flex', gap: '8px' }}>
            <button
              onClick={commit}
              disabled={!commitMessage.trim()}
              style={{
                flex: 1,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: '6px',
                padding: '8px 12px',
                backgroundColor: commitMessage.trim() ? theme.green : `${theme.brightBlack}40`,
                border: 'none',
                borderRadius: '6px',
                color: commitMessage.trim() ? '#fff' : theme.brightBlack,
                fontSize: '13px',
                fontWeight: 500,
                cursor: commitMessage.trim() ? 'pointer' : 'not-allowed',
              }}
            >
              <GitCommit size={14} />
              Commit
            </button>
            <button
              onClick={push}
              style={{
                padding: '8px 12px',
                backgroundColor: `${theme.brightBlack}20`,
                border: `1px solid ${theme.brightBlack}40`,
                borderRadius: '6px',
                color: theme.foreground,
                fontSize: '13px',
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                gap: '6px',
              }}
              title="Push"
            >
              <Upload size={14} />
            </button>
          </div>
        </div>
      )}

      {/* Refresh button */}
      <button
        onClick={loadGitStatus}
        style={{
          padding: '8px',
          backgroundColor: 'transparent',
          border: 'none',
          color: theme.brightBlack,
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          gap: '6px',
          fontSize: '12px',
        }}
      >
        <RefreshCw size={12} />
        Refresh
      </button>
    </div>
  )
}

// Context menu state interface
interface ContextMenuState {
  x: number
  y: number
  path: string
  isFolder: boolean
  name: string
}

// Clipboard state for copy/cut operations
interface ClipboardState {
  path: string
  isFolder: boolean
  operation: 'copy' | 'cut'
}

function ExplorerPanel() {
  const {
    root,
    favorites,
    isLoading,
    error,
    initializeExplorer,
    toggleFolder,
    addFavorite,
    removeFavorite,
    refresh,
  } = useFileExplorer()
  const { settings } = useTerminalSettings()
  const { createEditorTab } = useTabs()
  const theme = settings.theme

  const [searchQuery, setSearchQuery] = useState('')
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null)
  const [clipboard, setClipboard] = useState<ClipboardState | null>(null)
  const [renameState, setRenameState] = useState<{ path: string; name: string } | null>(null)
  const [newItemState, setNewItemState] = useState<{ parentPath: string; type: 'file' | 'folder' } | null>(null)

  // Handle file selection - open in editor tab
  // Folders are handled by expansion toggle, not navigation
  const handleFileSelect = useCallback((path: string, isFolder: boolean) => {
    if (!isFolder) {
      createEditorTab(path)
    }
    // Folder clicks only expand/collapse - don't navigate or change pwd
  }, [createEditorTab])

  // Context menu handler
  const handleContextMenu = useCallback((e: React.MouseEvent, path: string, isFolder: boolean, name: string) => {
    e.preventDefault()
    e.stopPropagation()
    setContextMenu({ x: e.clientX, y: e.clientY, path, isFolder, name })
  }, [])

  // Close context menu
  const closeContextMenu = useCallback(() => {
    setContextMenu(null)
  }, [])

  // Context menu actions
  const handleNewFile = useCallback(async (parentPath: string) => {
    setNewItemState({ parentPath, type: 'file' })
    closeContextMenu()
  }, [closeContextMenu])

  const handleNewFolder = useCallback(async (parentPath: string) => {
    setNewItemState({ parentPath, type: 'folder' })
    closeContextMenu()
  }, [closeContextMenu])

  const handleRename = useCallback((path: string, name: string) => {
    setRenameState({ path, name })
    closeContextMenu()
  }, [closeContextMenu])

  const handleCopy = useCallback((path: string, isFolder: boolean) => {
    setClipboard({ path, isFolder, operation: 'copy' })
    closeContextMenu()
  }, [closeContextMenu])

  const handleCut = useCallback((path: string, isFolder: boolean) => {
    setClipboard({ path, isFolder, operation: 'cut' })
    closeContextMenu()
  }, [closeContextMenu])

  const handlePaste = useCallback(async (targetPath: string, isFolder: boolean) => {
    if (!clipboard) return

    const destinationDir = isFolder ? targetPath : targetPath.substring(0, targetPath.lastIndexOf('/'))
    const fileName = clipboard.path.split('/').pop() || 'file'
    const destination = `${destinationDir}/${fileName}`

    try {
      if (clipboard.operation === 'copy') {
        await invoke('fs_copy', { source: clipboard.path, destination, isDirectory: clipboard.isFolder })
      } else {
        await invoke('fs_move', { source: clipboard.path, destination })
        setClipboard(null)
      }
      refresh()
    } catch (err) {
      console.error('Paste failed:', err)
    }
    closeContextMenu()
  }, [clipboard, refresh, closeContextMenu])

  const handleDelete = useCallback(async (path: string, isFolder: boolean) => {
    if (!confirm(`Are you sure you want to delete "${path.split('/').pop()}"?`)) return

    try {
      await invoke('fs_delete', { path, isDirectory: isFolder })
      refresh()
    } catch (err) {
      console.error('Delete failed:', err)
    }
    closeContextMenu()
  }, [refresh, closeContextMenu])

  // Set folder as terminal workspace (cd to folder)
  const handleSetWorkspace = useCallback((path: string) => {
    emitChangeTerminalCwd(path)
    closeContextMenu()
  }, [closeContextMenu])

  // Submit new file/folder
  const handleNewItemSubmit = useCallback(async (name: string) => {
    if (!newItemState || !name.trim()) {
      setNewItemState(null)
      return
    }

    const fullPath = `${newItemState.parentPath}/${name.trim()}`
    try {
      if (newItemState.type === 'file') {
        await invoke('fs_create_file', { path: fullPath })
      } else {
        await invoke('fs_create_directory', { path: fullPath })
      }
      refresh()
    } catch (err) {
      console.error('Create failed:', err)
    }
    setNewItemState(null)
  }, [newItemState, refresh])

  // Submit rename
  const handleRenameSubmit = useCallback(async (newName: string) => {
    if (!renameState || !newName.trim()) {
      setRenameState(null)
      return
    }

    const parentPath = renameState.path.substring(0, renameState.path.lastIndexOf('/'))
    const newPath = `${parentPath}/${newName.trim()}`

    try {
      await invoke('fs_rename', { oldPath: renameState.path, newPath })
      refresh()
    } catch (err) {
      console.error('Rename failed:', err)
    }
    setRenameState(null)
  }, [renameState, refresh])

  useEffect(() => {
    initializeExplorer()
  }, [initializeExplorer])

  // Close context menu on click outside
  useEffect(() => {
    if (contextMenu) {
      const handleClick = () => setContextMenu(null)
      document.addEventListener('click', handleClick)
      return () => document.removeEventListener('click', handleClick)
    }
  }, [contextMenu])

  const getFileIcon = (name: string) => {
    const ext = name.split('.').pop()?.toLowerCase()

    if (ext === 'tsx' || ext === 'ts' || ext === 'jsx' || ext === 'js') {
      return <FileCode size={14} style={{ color: theme.blue }} />
    }
    if (ext === 'json') {
      return <FileCode size={14} style={{ color: theme.yellow }} />
    }
    if (ext === 'md' || ext === 'txt') {
      return <File size={14} style={{ color: theme.brightBlack }} />
    }
    if (ext === 'css' || ext === 'scss') {
      return <File size={14} style={{ color: theme.magenta }} />
    }
    return <File size={14} style={{ color: theme.brightBlack }} />
  }

  const filteredRoot = root ? filterFileTree(root, searchQuery) : null

  return (
    <div style={{ padding: '0 12px 24px', display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* Search bar */}
      <div style={{ padding: '6px 0 0', display: 'flex', gap: '8px' }}>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '12px',
            backgroundColor: `${theme.brightBlack}33`,
            padding: '10px 14px',
            borderRadius: '8px',
            fontSize: '14px',
            color: theme.white,
            flex: 1,
          }}
        >
          <Search size={16} />
          <input
            type="text"
            placeholder="Search files..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            style={{
              flex: 1,
              backgroundColor: 'transparent',
              fontSize: '14px',
              color: theme.foreground,
              border: 'none',
              outline: 'none',
            }}
          />
        </div>
      </div>

      {error && (
        <div
          style={{
            padding: '8px 12px',
            marginBottom: '12px',
            backgroundColor: `${theme.red}1a`,
            border: `1px solid ${theme.red}`,
            borderRadius: '6px',
            fontSize: '13px',
            color: theme.red,
          }}
        >
          {error}
        </div>
      )}


      {favorites.length > 0 && (
        <SidebarSection title="Favorites">
          {favorites.map((fav) => {
            // Heuristic: paths without extensions or ending with / are folders
            const name = fav.split('/').pop() || ''
            const isLikelyFolder = !name.includes('.') || fav.endsWith('/')
            return (
              <FavoriteItem
                key={fav}
                path={fav}
                isFolder={isLikelyFolder}
                onSelect={() => {
                  if (isLikelyFolder) {
                    // Navigate to folder
                    emitChangeTerminalCwd(fav)
                  } else {
                    // Open file in editor
                    handleFileSelect(fav, false)
                  }
                }}
                onRemove={() => removeFavorite(fav)}
              />
            )
          })}
        </SidebarSection>
      )}

      <SidebarSection title={root ? (root.path === '/' ? 'Root' : root.path) : 'Loading...'}>
        {isLoading && !root ? (
          <div style={{ padding: '8px 12px', color: theme.brightBlack, fontSize: '13px' }}>Loading files...</div>
        ) : filteredRoot ? (
          <FileTreeRenderer
            node={filteredRoot}
            onToggle={toggleFolder}
            onSelect={handleFileSelect}
            onAddFavorite={addFavorite}
            onRemoveFavorite={removeFavorite}
            favorites={favorites}
            onContextMenu={handleContextMenu}
            getIcon={getFileIcon}
            renameState={renameState}
            onRenameSubmit={handleRenameSubmit}
            newItemState={newItemState}
            onNewItemSubmit={handleNewItemSubmit}
          />
        ) : (
          <div style={{ padding: '8px 12px', color: theme.brightBlack, fontSize: '13px' }}>No files found</div>
        )}
      </SidebarSection>

      {/* Context Menu Portal */}
      {contextMenu && createPortal(
        <div
          style={{
            position: 'fixed',
            top: contextMenu.y,
            left: contextMenu.x,
            backgroundColor: theme.background,
            border: `1px solid ${theme.brightBlack}40`,
            borderRadius: '8px',
            boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
            zIndex: 999999,
            minWidth: '180px',
            padding: '4px 0',
          }}
          onClick={(e) => e.stopPropagation()}
        >
          {/* Set as Workspace - only for folders */}
          {contextMenu.isFolder && (
            <ContextMenuItem
              icon={Terminal}
              label="Set as Workspace"
              onClick={() => handleSetWorkspace(contextMenu.path)}
              theme={theme}
            />
          )}

          {contextMenu.isFolder && <ContextMenuDivider theme={theme} />}

          {/* New File - only for folders */}
          {contextMenu.isFolder && (
            <ContextMenuItem
              icon={FilePlus}
              label="New File"
              onClick={() => handleNewFile(contextMenu.path)}
              theme={theme}
            />
          )}

          {/* New Folder - only for folders */}
          {contextMenu.isFolder && (
            <ContextMenuItem
              icon={FolderPlus}
              label="New Folder"
              onClick={() => handleNewFolder(contextMenu.path)}
              theme={theme}
            />
          )}

          {contextMenu.isFolder && <ContextMenuDivider theme={theme} />}

          {/* Rename */}
          <ContextMenuItem
            icon={Pencil}
            label="Rename"
            onClick={() => handleRename(contextMenu.path, contextMenu.name)}
            theme={theme}
          />

          <ContextMenuDivider theme={theme} />

          {/* Copy */}
          <ContextMenuItem
            icon={Copy}
            label="Copy"
            onClick={() => handleCopy(contextMenu.path, contextMenu.isFolder)}
            theme={theme}
          />

          {/* Cut */}
          <ContextMenuItem
            icon={Scissors}
            label="Cut"
            onClick={() => handleCut(contextMenu.path, contextMenu.isFolder)}
            theme={theme}
          />

          {/* Paste - only if clipboard has content */}
          {clipboard && (
            <ContextMenuItem
              icon={Clipboard}
              label={`Paste${clipboard.operation === 'cut' ? ' (Move)' : ''}`}
              onClick={() => handlePaste(contextMenu.path, contextMenu.isFolder)}
              theme={theme}
            />
          )}

          <ContextMenuDivider theme={theme} />

          {/* Delete */}
          <ContextMenuItem
            icon={Trash2}
            label="Delete"
            onClick={() => handleDelete(contextMenu.path, contextMenu.isFolder)}
            theme={theme}
            danger
          />
        </div>,
        document.body
      )}
    </div>
  )
}

interface FileTreeRendererProps {
  node: FileNode
  onToggle: (path: string) => Promise<void>
  onSelect: (path: string, isFolder: boolean) => void
  onAddFavorite: (path: string) => void
  onRemoveFavorite: (path: string) => void
  favorites: string[]
  onContextMenu: (e: React.MouseEvent, path: string, isFolder: boolean, name: string) => void
  getIcon: (name: string) => React.ReactNode
  renameState?: { path: string; name: string } | null
  onRenameSubmit?: (newName: string) => void
  newItemState?: { parentPath: string; type: 'file' | 'folder' } | null
  onNewItemSubmit?: (name: string) => void
  depth?: number
}

function FileTreeRenderer({
  node,
  onToggle,
  onSelect,
  onAddFavorite,
  onRemoveFavorite,
  favorites,
  onContextMenu,
  getIcon,
  renameState,
  onRenameSubmit,
  newItemState,
  onNewItemSubmit,
  depth = 0,
}: FileTreeRendererProps) {
  const [isExpanded, setIsExpanded] = useState(depth === 0)
  const [renameValue, setRenameValue] = useState('')
  const [newItemValue, setNewItemValue] = useState('')
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const isLoading = node.isLoading
  const isRenaming = renameState?.path === node.path
  const isFavorite = favorites.includes(node.path)

  // Auto-expand root folder when path changes
  useEffect(() => {
    if (depth === 0) {
      setIsExpanded(true)
    }
  }, [node.path, depth])

  // Initialize rename value when renaming starts
  useEffect(() => {
    if (isRenaming && renameState) {
      setRenameValue(renameState.name)
    }
  }, [isRenaming, renameState])

  // Check if new item input should be shown in this folder
  const showNewItemInput = newItemState && node.isFolder && newItemState.parentPath === node.path

  const handleClick = async () => {
    if (node.isFolder) {
      setIsExpanded(!isExpanded)
      if (!isExpanded && (!node.children || node.children.length === 0)) {
        await onToggle(node.path)
      }
    }
    onSelect(node.path, node.isFolder)
  }

  const handleRenameKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      onRenameSubmit?.(renameValue)
    } else if (e.key === 'Escape') {
      onRenameSubmit?.('')
    }
  }

  const handleNewItemKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      onNewItemSubmit?.(newItemValue)
      setNewItemValue('')
    } else if (e.key === 'Escape') {
      onNewItemSubmit?.('')
      setNewItemValue('')
    }
  }

  return (
    <div>
      <div
        role="button"
        tabIndex={0}
        onClick={handleClick}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            handleClick()
          }
        }}
        onContextMenu={(e) => onContextMenu(e, node.path, node.isFolder, node.name)}
        style={{
          display: 'flex',
          width: '100%',
          alignItems: 'center',
          gap: '10px',
          padding: '2px 12px',
          textAlign: 'left',
          backgroundColor: 'transparent',
          border: 'none',
          cursor: 'pointer',
          borderRadius: '6px',
          transition: 'all 0.15s ease',
          color: theme.white,
          fontSize: '14px',
          marginLeft: depth > 0 ? `${(depth - 1) * 16}px` : undefined,
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.backgroundColor = `${theme.brightBlack}1a`
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.backgroundColor = 'transparent'
        }}
      >
        {node.isFolder ? (
          <ChevronRight
            size={12}
            style={{
              flexShrink: 0,
              color: theme.brightBlack,
              transition: 'transform 0.15s ease',
              transform: isExpanded ? 'rotate(90deg)' : 'rotate(0deg)',
            }}
          />
        ) : (
          <span style={{ width: '12px', flexShrink: 0 }} />
        )}

        {node.isFolder ? (
          <Folder size={14} style={{ color: theme.brightBlack, flexShrink: 0 }} />
        ) : (
          getIcon(node.name)
        )}

        {isRenaming ? (
          <input
            type="text"
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onKeyDown={handleRenameKeyDown}
            onBlur={() => onRenameSubmit?.(renameValue)}
            autoFocus
            onClick={(e) => e.stopPropagation()}
            style={{
              flex: 1,
              backgroundColor: theme.background,
              border: `1px solid ${theme.cyan}`,
              borderRadius: '4px',
              padding: '2px 6px',
              color: theme.foreground,
              fontSize: '13px',
              outline: 'none',
            }}
          />
        ) : (
          <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
            {node.name}
          </span>
        )}

        {!isRenaming && (
          <button
            onClick={(e) => {
              e.stopPropagation()
              if (isFavorite) {
                onRemoveFavorite(node.path)
              } else {
                onAddFavorite(node.path)
              }
            }}
            style={{
              padding: '4px',
              backgroundColor: 'transparent',
              border: 'none',
              color: isFavorite ? theme.yellow : theme.brightBlack,
              cursor: 'pointer',
              flexShrink: 0,
              display: 'flex',
              alignItems: 'center',
              opacity: isFavorite ? 1 : 0.4,
              transition: 'opacity 0.15s ease, color 0.15s ease',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.opacity = '1'
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.opacity = isFavorite ? '1' : '0.4'
            }}
            title={isFavorite ? "Remove from favorites" : "Add to favorites"}
          >
            <Star size={12} style={isFavorite ? { fill: theme.yellow } : undefined} />
          </button>
        )}
      </div>

      {isLoading && (
        <div style={{ padding: '8px 12px', color: theme.brightBlack, fontSize: '12px', marginLeft: '20px' }}>
          Loading...
        </div>
      )}

      {node.error && (
        <div
          style={{
            padding: '8px 12px',
            color: theme.red,
            fontSize: '12px',
            marginLeft: '20px',
          }}
        >
          Error: {node.error}
        </div>
      )}

      {isExpanded && (
        <div style={{ marginLeft: '12px' }}>
          {/* New file/folder input */}
          {showNewItemInput && (
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '10px',
                padding: '2px 12px',
                marginLeft: depth > 0 ? `${(depth - 1) * 16}px` : undefined,
              }}
            >
              <span style={{ width: '12px', flexShrink: 0 }} />
              {newItemState.type === 'folder' ? (
                <FolderPlus size={14} style={{ color: theme.cyan, flexShrink: 0 }} />
              ) : (
                <FilePlus size={14} style={{ color: theme.cyan, flexShrink: 0 }} />
              )}
              <input
                type="text"
                value={newItemValue}
                onChange={(e) => setNewItemValue(e.target.value)}
                onKeyDown={handleNewItemKeyDown}
                onBlur={() => {
                  if (newItemValue.trim()) {
                    onNewItemSubmit?.(newItemValue)
                  } else {
                    onNewItemSubmit?.('')
                  }
                  setNewItemValue('')
                }}
                autoFocus
                placeholder={newItemState.type === 'folder' ? 'New folder name...' : 'New file name...'}
                style={{
                  flex: 1,
                  backgroundColor: theme.background,
                  border: `1px solid ${theme.cyan}`,
                  borderRadius: '4px',
                  padding: '2px 6px',
                  color: theme.foreground,
                  fontSize: '13px',
                  outline: 'none',
                }}
              />
            </div>
          )}

          {node.children && node.children.length > 0 && node.children.map((child) => (
            <FileTreeRenderer
              key={child.path}
              node={child}
              onToggle={onToggle}
              onSelect={onSelect}
              onAddFavorite={onAddFavorite}
              onRemoveFavorite={onRemoveFavorite}
              favorites={favorites}
              onContextMenu={onContextMenu}
              getIcon={getIcon}
              renameState={renameState}
              onRenameSubmit={onRenameSubmit}
              newItemState={newItemState}
              onNewItemSubmit={onNewItemSubmit}
              depth={depth + 1}
            />
          ))}
        </div>
      )}
    </div>
  )
}

interface FavoriteItemProps {
  path: string
  isFolder?: boolean
  onSelect: () => void
  onRemove: () => void
}

function FavoriteItem({ path, isFolder, onSelect, onRemove }: FavoriteItemProps) {
  const name = path.split('/').pop() || path
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onSelect()
        }
      }}
      style={{
        display: 'flex',
        width: '100%',
        alignItems: 'center',
        gap: '10px',
        padding: '2px 12px',
        textAlign: 'left',
        backgroundColor: 'transparent',
        border: 'none',
        cursor: 'pointer',
        borderRadius: '6px',
        transition: 'all 0.15s ease',
        color: theme.white,
        fontSize: '14px',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.backgroundColor = `${theme.brightBlack}1a`
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.backgroundColor = 'transparent'
      }}
    >
      {isFolder ? (
        <Folder size={14} style={{ color: theme.yellow, flexShrink: 0 }} />
      ) : (
        <Star size={12} style={{ color: theme.yellow, flexShrink: 0, fill: theme.yellow }} />
      )}
      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
        {name}
      </span>
      <button
        onClick={(e) => {
          e.stopPropagation()
          onRemove()
        }}
        style={{
          padding: '4px',
          backgroundColor: 'transparent',
          border: 'none',
          color: theme.brightBlack,
          cursor: 'pointer',
          fontSize: '12px',
          opacity: 0.6,
          transition: 'opacity 0.15s ease',
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.opacity = '1'
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.opacity = '0.6'
        }}
        title="Remove favorite"
      >
        ×
      </button>
    </div>
  )
}

function SidebarSection({ title, children }: { title: string; children: React.ReactNode }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  return (
    <div style={{ marginTop: '8px' }}>
      <div style={{ padding: '0 12px 8px', fontSize: '10px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: theme.brightBlack }}>
        {title}
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '2px' }}>{children}</div>
    </div>
  )
}

// Context menu item component
interface ContextMenuItemProps {
  icon: typeof File
  label: string
  onClick: () => void
  theme: TerminalTheme
  danger?: boolean
}

function ContextMenuItem({ icon: Icon, label, onClick, theme, danger }: ContextMenuItemProps) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '10px',
        padding: '8px 12px',
        width: '100%',
        backgroundColor: 'transparent',
        border: 'none',
        color: danger ? theme.red : theme.foreground,
        fontSize: '13px',
        cursor: 'pointer',
        textAlign: 'left',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.backgroundColor = 'transparent'
      }}
    >
      <Icon size={14} style={{ color: danger ? theme.red : theme.brightBlack, flexShrink: 0 }} />
      {label}
    </button>
  )
}

function ContextMenuDivider({ theme }: { theme: TerminalTheme }) {
  return (
    <div
      style={{
        height: '1px',
        backgroundColor: `${theme.brightBlack}30`,
        margin: '4px 8px',
      }}
    />
  )
}

function filterFileTree(node: FileNode, query: string): FileNode | null {
  if (!query.trim()) {
    return node
  }

  const lowerQuery = query.toLowerCase()
  const nameMatches = node.name.toLowerCase().includes(lowerQuery)

  let filteredChildren: FileNode[] | undefined

  if (node.children) {
    filteredChildren = node.children
      .map((child) => filterFileTree(child, query))
      .filter((child): child is FileNode => child !== null)
  }

  if (nameMatches || (filteredChildren && filteredChildren.length > 0)) {
    return {
      ...node,
      children: filteredChildren,
    }
  }

  return null
}

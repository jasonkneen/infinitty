---
sidebar_position: 4
---

# Storage Widget Example

Working with instance and global storage.

## Complete Storage Example

### src/Component.tsx

```typescript
import { useEffect, useState } from 'react'
import {
  useWidgetSDK,
  useTheme,
  useStorage,
  useGlobalState,
  useLogger,
} from '@infinitty/widget-sdk'

interface Note {
  id: string
  title: string
  content: string
  created: Date
  updated: Date
}

export function Component() {
  const { api, context } = useWidgetSDK()
  const theme = useTheme()
  const logger = useLogger()

  // Instance storage - unique to this widget instance
  const [notes, setNotes] = useStorage<Note[]>('notes', [])
  const [selectedId, setSelectedId] = useStorage<string | null>('selectedId', null)

  // Global state - shared across all instances
  const [defaultTitle, setDefaultTitle] = useGlobalState('defaultTitle', 'Untitled')

  // Temporary state - not persisted
  const [newTitle, setNewTitle] = useState('')
  const [newContent, setNewContent] = useState('')
  const [editingId, setEditingId] = useState<string | null>(null)

  const selectedNote = notes?.find(n => n.id === selectedId)

  // Create new note
  const handleCreate = async () => {
    const title = newTitle || (defaultTitle ?? 'Untitled')
    const note: Note = {
      id: Date.now().toString(),
      title,
      content: newContent,
      created: new Date(),
      updated: new Date(),
    }

    const updated = [...(notes ?? []), note]
    await setNotes(updated)
    await setSelectedId(note.id)

    setNewTitle('')
    setNewContent('')

    logger.info(`Note created: ${title}`)
    api.showMessage(`Created note: "${title}"`, 'info')
  }

  // Update note
  const handleSave = async () => {
    if (!editingId || !selectedNote) return

    const updated = (notes ?? []).map(n =>
      n.id === editingId
        ? { ...n, title: newTitle, content: newContent, updated: new Date() }
        : n
    )

    await setNotes(updated)
    setEditingId(null)
    setNewTitle('')
    setNewContent('')

    logger.info(`Note updated: ${newTitle}`)
    api.showMessage('Note saved', 'info')
  }

  // Delete note
  const handleDelete = async (id: string) => {
    const updated = (notes ?? []).filter(n => n.id !== id)
    await setNotes(updated)

    if (selectedId === id) {
      await setSelectedId(updated.length > 0 ? updated[0].id : null)
    }

    logger.info(`Note deleted: ${id}`)
    api.showMessage('Note deleted', 'info')
  }

  // Start editing
  const handleEdit = (note: Note) => {
    setEditingId(note.id)
    setNewTitle(note.title)
    setNewContent(note.content)
  }

  // Export all notes
  const handleExport = async () => {
    try {
      const data = {
        notes: notes ?? [],
        exported: new Date().toISOString(),
        widgetInstance: context.instanceId,
      }

      await api.writeClipboard(JSON.stringify(data, null, 2))
      api.showMessage('Notes exported to clipboard', 'info')
    } catch (error) {
      api.showMessage('Failed to export', 'error')
      logger.error('Export failed:', error)
    }
  }

  // Clear all notes
  const handleClearAll = async () => {
    const confirm = await api.showQuickPick([
      { label: 'Clear All', description: 'Delete all notes permanently' },
      { label: 'Cancel', description: 'Keep notes' },
    ], { title: 'Clear all notes?' })

    if (confirm?.label === 'Clear All') {
      await setNotes([])
      await setSelectedId(null)
      api.showMessage('All notes cleared', 'info')
      logger.info('All notes cleared')
    }
  }

  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: '300px 1fr',
      height: '100vh',
      backgroundColor: theme.background,
      color: theme.foreground,
      fontFamily: 'system-ui, -apple-system, sans-serif',
    }}>
      {/* Sidebar - Note List */}
      <div style={{
        borderRight: `1px solid ${theme.brightBlack}40`,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}>
        {/* Header */}
        <div style={{
          padding: '16px',
          borderBottom: `1px solid ${theme.brightBlack}40`,
        }}>
          <h2 style={{ margin: '0 0 12px 0', fontSize: '18px' }}>Notes</h2>
          <p style={{
            margin: 0,
            fontSize: '12px',
            color: theme.brightBlack,
          }}>
            Instance: {context.instanceId.slice(-6)}
          </p>
        </div>

        {/* Note List */}
        <div style={{
          flex: 1,
          overflow: 'auto',
          padding: '12px',
        }}>
          {!notes || notes.length === 0 ? (
            <p style={{
              color: theme.brightBlack,
              fontSize: '13px',
              textAlign: 'center',
              paddingTop: '20px',
            }}>
              No notes yet
            </p>
          ) : (
            notes.map(note => (
              <div
                key={note.id}
                onClick={() => {
                  setSelectedId(note.id)
                  setEditingId(null)
                }}
                style={{
                  padding: '12px',
                  marginBottom: '8px',
                  backgroundColor: selectedId === note.id
                    ? theme.cyan + '20'
                    : theme.brightBlack + '10',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  borderLeft: selectedId === note.id
                    ? `3px solid ${theme.cyan}`
                    : 'transparent',
                  transition: 'all 0.2s',
                }}
              >
                <div style={{ fontWeight: 'bold', fontSize: '13px' }}>
                  {note.title}
                </div>
                <div style={{
                  fontSize: '11px',
                  color: theme.brightBlack,
                  marginTop: '4px',
                }}>
                  {new Date(note.updated).toLocaleDateString()}
                </div>
              </div>
            ))
          )}
        </div>

        {/* Actions */}
        <div style={{
          padding: '12px',
          borderTop: `1px solid ${theme.brightBlack}40`,
          display: 'flex',
          gap: '8px',
          fontSize: '12px',
        }}>
          <button
            onClick={handleExport}
            style={{
              flex: 1,
              padding: '6px',
              backgroundColor: theme.green + '40',
              border: `1px solid ${theme.green}`,
              color: theme.foreground,
              borderRadius: '4px',
              cursor: 'pointer',
            }}
          >
            Export
          </button>
          <button
            onClick={handleClearAll}
            style={{
              flex: 1,
              padding: '6px',
              backgroundColor: theme.red + '40',
              border: `1px solid ${theme.red}`,
              color: theme.foreground,
              borderRadius: '4px',
              cursor: 'pointer',
            }}
          >
            Clear
          </button>
        </div>
      </div>

      {/* Main Area */}
      <div style={{
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        padding: '20px',
      }}>
        {editingId || !selectedNote ? (
          // Create/Edit form
          <div>
            <h2>
              {editingId ? 'Edit Note' : 'New Note'}
            </h2>

            <div style={{ marginBottom: '16px' }}>
              <label style={{
                display: 'block',
                marginBottom: '4px',
                fontSize: '12px',
                color: theme.brightBlack,
              }}>
                Title
              </label>
              <input
                type="text"
                placeholder={defaultTitle ?? 'Untitled'}
                value={newTitle}
                onChange={(e) => setNewTitle(e.target.value)}
                style={{
                  width: '100%',
                  padding: '8px',
                  backgroundColor: theme.brightBlack + '20',
                  border: `1px solid ${theme.brightBlack}40`,
                  color: theme.foreground,
                  borderRadius: '4px',
                  fontSize: '14px',
                }}
              />
            </div>

            <div style={{ marginBottom: '16px', flex: 1 }}>
              <label style={{
                display: 'block',
                marginBottom: '4px',
                fontSize: '12px',
                color: theme.brightBlack,
              }}>
                Content
              </label>
              <textarea
                placeholder="Write something..."
                value={newContent}
                onChange={(e) => setNewContent(e.target.value)}
                style={{
                  width: '100%',
                  height: '300px',
                  padding: '8px',
                  backgroundColor: theme.brightBlack + '20',
                  border: `1px solid ${theme.brightBlack}40`,
                  color: theme.foreground,
                  borderRadius: '4px',
                  fontSize: '14px',
                  resize: 'none',
                }}
              />
            </div>

            <div style={{ display: 'flex', gap: '8px' }}>
              <button
                onClick={editingId ? handleSave : handleCreate}
                style={{
                  padding: '8px 16px',
                  backgroundColor: theme.cyan,
                  color: theme.background,
                  border: 'none',
                  borderRadius: '4px',
                  cursor: 'pointer',
                }}
              >
                {editingId ? 'Save' : 'Create'}
              </button>
              {editingId && (
                <button
                  onClick={() => {
                    setEditingId(null)
                    setNewTitle('')
                    setNewContent('')
                  }}
                  style={{
                    padding: '8px 16px',
                    backgroundColor: theme.brightBlack + '30',
                    color: theme.foreground,
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                  }}
                >
                  Cancel
                </button>
              )}
            </div>
          </div>
        ) : (
          // View note
          <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
            <h2 style={{ margin: '0 0 12px 0' }}>
              {selectedNote.title}
            </h2>

            <p style={{
              fontSize: '12px',
              color: theme.brightBlack,
              marginBottom: '16px',
            }}>
              Created: {new Date(selectedNote.created).toLocaleString()}
              <br />
              Updated: {new Date(selectedNote.updated).toLocaleString()}
            </p>

            <div style={{
              flex: 1,
              overflow: 'auto',
              padding: '12px',
              backgroundColor: theme.brightBlack + '10',
              borderRadius: '4px',
              marginBottom: '16px',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}>
              {selectedNote.content}
            </div>

            <div style={{ display: 'flex', gap: '8px' }}>
              <button
                onClick={() => handleEdit(selectedNote)}
                style={{
                  padding: '8px 16px',
                  backgroundColor: theme.blue,
                  color: theme.background,
                  border: 'none',
                  borderRadius: '4px',
                  cursor: 'pointer',
                }}
              >
                Edit
              </button>
              <button
                onClick={() => handleDelete(selectedNote.id)}
                style={{
                  padding: '8px 16px',
                  backgroundColor: theme.red,
                  color: theme.background,
                  border: 'none',
                  borderRadius: '4px',
                  cursor: 'pointer',
                }}
              >
                Delete
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
```

### src/index.tsx

```typescript
import { defineWidget } from '@infinitty/widget-sdk'
import { Component } from './Component'

export default defineWidget({
  id: 'com.example.notes-widget',
  name: 'Notes Widget',
  version: '1.0.0',
  description: 'A notes app with persistent storage',

  activate(context, api, events) {
    context.log.info('Notes widget activated')
  },

  Component,
})
```

## Storage Patterns

### Instance vs Global Storage

```typescript
// Instance storage - unique per widget instance
const [count, setCount] = useStorage('count', 0)

// Global storage - shared across instances
const [defaultTheme, setDefaultTheme] = useGlobalState('defaultTheme', 'light')

// When to use each:
// - Instance: User-specific data, widget state
// - Global: Settings, preferences, shared config
```

### Complex Data

```typescript
interface UserProfile {
  name: string
  email: string
  settings: {
    theme: 'light' | 'dark'
    notifications: boolean
  }
}

const [profile, setProfile] = useStorage<UserProfile>('profile', {
  name: 'User',
  email: '',
  settings: {
    theme: 'dark',
    notifications: true,
  },
})

// Update nested property
const updateEmail = async (newEmail: string) => {
  await setProfile({
    ...profile!,
    email: newEmail,
  })
}
```

### Arrays

```typescript
interface Item {
  id: string
  name: string
  done: boolean
}

const [items, setItems] = useStorage<Item[]>('items', [])

// Add item
const addItem = async (name: string) => {
  await setItems([
    ...(items ?? []),
    { id: Date.now().toString(), name, done: false },
  ])
}

// Update item
const updateItem = async (id: string, updates: Partial<Item>) => {
  await setItems(
    (items ?? []).map(item =>
      item.id === id ? { ...item, ...updates } : item
    )
  )
}

// Remove item
const removeItem = async (id: string) => {
  await setItems((items ?? []).filter(item => item.id !== id))
}
```

## Testing Storage

```typescript
test('should persist data', async () => {
  const { result } = renderHook(() => useStorage('key', 'default'))

  expect(result.current[0]).toBe('default')

  act(() => {
    result.current[1]('new value')
  })

  expect(result.current[0]).toBe('new value')
})
```

## Next Steps

- [Hello World Example](hello-world)
- [Counter Widget Example](counter-widget)
- [Storage Hook Reference](../sdk-reference/hooks)

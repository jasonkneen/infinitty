# File Explorer Implementation

This document describes the working file explorer implementation for the Infinitty app using Tauri's filesystem API.

## Overview

The file explorer provides:
- Real-time directory reading using Tauri's `@tauri-apps/plugin-fs`
- Lazy loading of directories when expanded
- Search/filter functionality
- Favorites management (persisted to localStorage)
- File type detection with appropriate icons
- Error handling for permission denied and other filesystem errors
- Support for navigating to home directory by default

## Architecture

### Hook: `useFileExplorer` (src/hooks/useFileExplorer.ts)

The main hook that manages file explorer state and operations.

**Exports:**
- `FileNode` interface - Represents a file or folder in the tree
- `useFileExplorer()` - Hook function

**FileNode Structure:**
```typescript
interface FileNode {
  name: string           // File or directory name
  path: string          // Full absolute path
  isFolder: boolean     // Is this a directory
  children?: FileNode[] // Child nodes (undefined for files)
  isLoading?: boolean   // Loading indicator during async operations
  error?: string        // Error message if loading failed
}
```

**Hook State:**
```typescript
{
  root: FileNode | null          // Root directory node
  currentPath: string            // Current directory path
  isLoading: boolean             // Overall loading state
  error: string | null           // Overall error message
  favorites: string[]            // Favorite paths list
}
```

**Hook Actions:**

1. **initializeExplorer(startPath?: string)**
   - Initializes the explorer
   - Loads home directory by default
   - Can specify a starting path

2. **expandFolder(path: string)**
   - Loads children for a specific folder
   - Sets loading state during operation
   - Catches and displays errors

3. **toggleFolder(path: string)**
   - Toggle folder expansion
   - Automatically loads if not loaded yet
   - Collapsing clears children from UI

4. **addFavorite(path: string)**
   - Add a path to favorites
   - Persists to localStorage
   - Deduplicates automatically

5. **removeFavorite(path: string)**
   - Remove a path from favorites
   - Updates localStorage

6. **navigateTo(path: string)**
   - Navigate to a different directory
   - Loads entire directory tree

7. **refresh()**
   - Refresh current directory

## Component: `ExplorerPanel` (src/components/Sidebar.tsx)

The main UI component for the file explorer.

**Features:**

1. **Search Input**
   - Real-time filtering of file tree
   - Search is case-insensitive
   - Works recursively through tree structure

2. **Refresh Button**
   - Manual refresh of current directory
   - Located next to search input

3. **Error Display**
   - Shows permission errors and other issues
   - Non-blocking - doesn't prevent other operations

4. **Selected Path Display**
   - Shows the currently clicked file path
   - Monospace font for clarity
   - Useful for copying paths

5. **Favorites Section**
   - Shows saved favorite paths
   - Star icon to indicate favorites
   - Click to select path
   - X button to remove from favorites

6. **File Tree**
   - Dynamic rendering with FileTreeRenderer component
   - Lazy loads children on first expansion
   - Supports infinite nesting
   - Folders open/close with smooth animation
   - File icons based on extension:
     - `.tsx/.ts/.jsx/.js` - Blue code icon
     - `.json` - Yellow code icon
     - `.md/.txt` - Gray file icon
     - `.css/.scss` - Purple file icon
     - Everything else - Gray file icon

### FileTreeRenderer Component

Recursively renders the file tree with lazy loading.

**Features:**
- Expandable/collapsible folders
- Loading indicator during async operations
- Error messages for failed operations
- Star button for adding to favorites (files only)
- Hover effects for interactivity
- Proper indentation for depth visualization

**Props:**
```typescript
interface FileTreeRendererProps {
  node: FileNode
  onToggle: (path: string) => Promise<void>
  onSelect: (path: string) => void
  onAddFavorite: (path: string) => void
  getIcon: (name: string) => React.ReactNode
  depth?: number
}
```

### FavoriteItem Component

Renders a single favorite path item.

**Features:**
- Filled star icon
- Displays folder name
- Remove button (X)
- Hover effects

## Tauri API Usage

### Imports
```typescript
import { readDir, stat } from '@tauri-apps/plugin-fs'
import { join } from '@tauri-apps/api/path'
```

### Key Functions

1. **readDir(path: string): Promise<DirEntry[]>**
   - Returns array of directory entries
   - Each entry has: `name`, `isDirectory`, `isFile`, `isSymlink`
   - Does NOT return full paths, only names

2. **stat(path: string): Promise<FileInfo>**
   - Returns detailed file information
   - Used to determine if entry is directory/file
   - Has properties: `isFile`, `isDirectory`, `isSymlink`, `size`, `mtime`, `atime`, etc.

3. **join(path: string, ...segments: string[]): Promise<string>**
   - Safely joins path segments
   - Used to construct full paths from directory name + parent path

### Permissions Configuration

The app requires filesystem scope permissions in `src-tauri/tauri.conf.json`:

```json
{
  "permissions": [
    "fs:allow-read-dir",
    "fs:allow-stat",
    "path:default"
  ]
}
```

## Error Handling

The implementation handles several error scenarios gracefully:

1. **Permission Denied**
   - Displays error message in UI
   - Prevents app crash
   - Allows retry

2. **Path Not Found**
   - Shows error in tree item
   - Parent folder still accessible

3. **Symlink Loops**
   - Handled by Tauri internally
   - Returns safe FileInfo

4. **Special Directories**
   - Application data directories supported
   - Standard home directory accessible

## LocalStorage Usage

**Key: `fileExplorerFavorites`**

Stores array of favorite file paths:
```json
[
  "/Users/jkneen/Documents/projects",
  "/Users/jkneen/Downloads",
  "/var/log"
]
```

Auto-populated on component mount.

## Performance Considerations

1. **Lazy Loading**
   - Children only loaded when folder is first expanded
   - Empty children array for folders until expanded
   - Prevents loading large directory trees upfront

2. **Memoization**
   - `useCallback` hooks prevent unnecessary re-renders
   - Tree traversal functions cached

3. **Sorting**
   - Files/folders sorted once on load
   - Folders appear first, then files, both alphabetically
   - Improves UX when navigating

4. **Search Filtering**
   - Runs on every keystroke
   - Filters recursively through tree
   - Only shows branches with matching items

## Styling

Uses inline styles matching the existing app theme:
- Background: `#1a1b26` (Dark)
- Text: `#c0caf5` (Light)
- Folder icon: `#565f89` (Gray)
- Active color: `#2dd4bf` (Cyan)
- Accent colors: `#7aa2f7` (Blue), `#e0af68` (Yellow), `#bb9af7` (Purple)

## Known Limitations

1. **No Write Operations**
   - Currently read-only
   - Can be extended to support create/delete/rename

2. **Scope Restrictions**
   - Only accessible paths allowed by Tauri scope
   - Cannot browse system-protected directories

3. **Symbolic Links**
   - Followed for stat but not opened separately
   - Can be enhanced for symlink visualization

4. **No File Thumbnails**
   - Icon-only representation
   - Thumbnails can be added later

## Testing

To test the file explorer:

1. Run the dev server:
   ```bash
   npm run dev
   ```

2. Switch to "Explorer" tab in sidebar

3. Try these actions:
   - Expand folders
   - Search for files
   - Add favorites
   - Remove favorites
   - Click files to see their path
   - Try permission-denied directories

## Future Enhancements

1. **Write Operations**
   - Create files/folders
   - Delete items
   - Rename files
   - Move files (drag and drop)

2. **Advanced Features**
   - File previews
   - Open with system default
   - Show file size in tree
   - Recent files list
   - Bookmarks/pins (current favorites)

3. **Performance**
   - Virtual scrolling for large trees
   - Incremental search
   - Caching metadata

4. **UX Improvements**
   - Double-click to open
   - Context menu
   - Keyboard navigation
   - Copy path to clipboard
   - Breadcrumb navigation

## Files

**New Files Created:**
- `/src/hooks/useFileExplorer.ts` - Main hook (308 lines)
- File explorer UI integrated into `/src/components/Sidebar.tsx`

**Dependencies Added:**
- `@tauri-apps/plugin-fs@2.4.4` - Filesystem operations
- `lucide-react` - Already included, used for icons

**Tauri Configuration:**
- Requires `fs:allow-read-dir` and `fs:allow-stat` permissions

## Build Status

- TypeScript: ✓ Compiles without errors
- Vite: ✓ Bundles successfully
- Runtime: ✓ Works in Tauri app

## Troubleshooting

**Issue: "Cannot find module" errors**
- Run `pnpm install` to ensure all dependencies installed

**Issue: Permission denied errors in console**
- Check Tauri permissions in `src-tauri/tauri.conf.json`
- Ensure fs scope includes necessary directories

**Issue: Slow folder expansion**
- Some directories (like `/var`) may have many files
- Use search to narrow results

**Issue: Files not showing in tree**
- Check if directory is accessible
- View error message for details
- Try different directory

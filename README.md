# Infinitty

A hybrid terminal application combining the power of native terminals with AI-powered workflows. Features two modes: **Ghostty Mode** (native terminal) and **OpenWarp Mode** (AI-powered block-based interface).

![Status](https://img.shields.io/badge/status-alpha-orange)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)

## Features

- **Dual Mode Interface** - Switch between Ghostty (native terminal) and OpenWarp (AI blocks) modes
- **AI Integration** - Built-in support for Claude, OpenAI, and local models via MCP
- **Split Panes** - Flexible terminal splits (horizontal/vertical)
- **Tab Management** - Multiple tabs with session persistence
- **Widget System** - Extensible widget SDK for custom functionality
- **File Explorer** - Built-in file browser with editor integration
- **Code Editor** - Monaco/CodeMirror powered editor with syntax highlighting
- **MCP Support** - Model Context Protocol for AI tool integration
- **Cross-Platform** - Runs on macOS, Windows, and Linux via Tauri

## Screenshots

*Coming soon*

## Quick Start

### Prerequisites

- Node.js 18+
- Rust (for native builds)
- pnpm or npm

### Installation

```bash
# Clone the repository
git clone https://github.com/jasonkneen/infinitty.git
cd infinitty

# Install dependencies
pnpm install

# Run in development mode
npm run tauri dev
```

### Platform Commands

| Platform | Command | Description |
|----------|---------|-------------|
| Tauri (Native) | `npm run tauri dev` | macOS/Windows/Linux desktop app |
| Web (PWA) | `npm run dev` | Browser at http://localhost:1420 |
| Build | `npm run build` | Production build |
| Test | `npm run test` | Run test suite |

## Project Status

### Core Features

| Feature | Status | Notes |
|---------|--------|-------|
| Terminal Emulation | ✅ Complete | xterm.js with WebGL renderer |
| Ghostty Mode | ✅ Complete | Native terminal with tabs/splits |
| OpenWarp Mode | ✅ Complete | AI block-based interface |
| Tab Management | ✅ Complete | Create, close, rename, reorder |
| Split Panes | ✅ Complete | Horizontal/vertical splits |
| Settings Dialog | ✅ Complete | Theme, font, behavior settings |
| Command Palette | ✅ Complete | Quick actions via keyboard |
| Error Boundaries | ✅ Complete | Graceful error handling |

### AI Integration

| Feature | Status | Notes |
|---------|--------|-------|
| AI Response Blocks | ✅ Complete | Markdown rendering, code blocks |
| Model Selection | ✅ Complete | Switch between AI providers |
| MCP Servers | ✅ Complete | Connect to MCP tool servers |
| MCP Tools | ✅ Complete | Execute tools from AI responses |
| Streaming Responses | ✅ Complete | Real-time AI output |
| Context Management | 🟡 Partial | Basic context, needs improvement |
| Conversation History | 🟡 Partial | In-memory only |

### Widget System

| Feature | Status | Notes |
|---------|--------|-------|
| Widget SDK | ✅ Complete | React-based widget development |
| Widget Host | ✅ Complete | Sandboxed widget runtime |
| Widget Loading | ✅ Complete | Load external widgets |
| Theme Integration | ✅ Complete | Widgets follow app theme |
| Widget Storage | ✅ Complete | Persistent widget data |
| Widget Tools | 🟡 Partial | Register AI tools from widgets |
| Widget Marketplace | ❌ Not Started | Discovery and installation |

### Editor & File System

| Feature | Status | Notes |
|---------|--------|-------|
| File Explorer | ✅ Complete | Tree view with icons |
| Code Editor | ✅ Complete | Monaco/CodeMirror support |
| Syntax Highlighting | ✅ Complete | 20+ languages |
| File Operations | ✅ Complete | Open, save, create, delete |
| Search in Files | 🟡 Partial | Basic search implemented |
| Git Integration | ❌ Not Started | Branch/status display |

### Platform & Infrastructure

| Feature | Status | Notes |
|---------|--------|-------|
| macOS Support | ✅ Complete | Native Tauri app |
| Windows Support | 🟡 Partial | Builds, needs testing |
| Linux Support | 🟡 Partial | Builds, needs testing |
| Web/PWA | ✅ Complete | Browser-based version |
| Auto Updates | ❌ Not Started | Tauri updater integration |
| Telemetry | ❌ Not Started | Optional usage analytics |

### Documentation

| Feature | Status | Notes |
|---------|--------|-------|
| Widget SDK Docs | ✅ Complete | Docusaurus site |
| API Reference | 🟡 Partial | Needs expansion |
| User Guide | ❌ Not Started | End-user documentation |
| Video Tutorials | ❌ Not Started | Getting started videos |

## Help Wanted

We welcome contributions! Here are areas where help is especially needed:

### High Priority

| Area | Description | Skills Needed |
|------|-------------|---------------|
| **Windows Testing** | Test and fix Windows-specific issues | Windows, Tauri |
| **Linux Testing** | Test and fix Linux-specific issues | Linux, Tauri |
| **Test Coverage** | Improve unit/integration tests | React Testing Library, Vitest |
| **Accessibility** | WCAG compliance, screen readers | a11y, ARIA |
| **Performance** | Optimize rendering, reduce memory | React, profiling |

### Medium Priority

| Area | Description | Skills Needed |
|------|-------------|---------------|
| **Git Integration** | Show branch, status, diff in UI | Git, React |
| **Search Enhancement** | Fuzzy search, regex support | Algorithms, UI |
| **Keyboard Shortcuts** | Vim mode, customizable bindings | React, keyboard events |
| **Themes** | More built-in themes | CSS, design |
| **Internationalization** | Multi-language support | i18n, translation |

### Good First Issues

| Issue | Description |
|-------|-------------|
| Add more syntax highlighting languages | Extend CodeMirror/Monaco language support |
| Improve error messages | Make error dialogs more user-friendly |
| Add tooltips | Add helpful tooltips to UI elements |
| Documentation typos | Fix typos and improve clarity |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Infinitty App                           │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Ghostty     │  │ OpenWarp    │  │ Widget Host         │  │
│  │ Mode        │  │ Mode        │  │ (Sandboxed)         │  │
│  │             │  │             │  │                     │  │
│  │ • Native    │  │ • AI Blocks │  │ • External Widgets  │  │
│  │   Terminal  │  │ • Commands  │  │ • SDK Integration   │  │
│  │ • Splits    │  │ • Streaming │  │ • Theme Sync        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    Core Services                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ MCP      │  │ OpenCode │  │ Claude   │  │ File     │    │
│  │ Client   │  │ Client   │  │ Client   │  │ System   │    │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │
├─────────────────────────────────────────────────────────────┤
│                    Platform Layer                           │
│  ┌─────────────────────┐  ┌─────────────────────────────┐  │
│  │ Tauri (Native)      │  │ Web (Browser/PWA)           │  │
│  │ • File System       │  │ • IndexedDB Storage         │  │
│  │ • Shell/PTY         │  │ • Service Workers           │  │
│  │ • Native Menus      │  │ • Web APIs                  │  │
│  └─────────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Tech Stack

- **Frontend**: React 19, TypeScript, Tailwind CSS
- **Terminal**: xterm.js with WebGL renderer
- **Editor**: Monaco Editor, CodeMirror
- **Build**: Vite, Tauri 2.0
- **Testing**: Vitest, React Testing Library
- **Docs**: Docusaurus

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

## License

This project uses a dual-licensing model:

- **AGPL-3.0 + Commons Clause** for open-source use
- **Commercial License** available for proprietary use

See [LICENSING.md](./LICENSING.md) for details.

## Acknowledgments

- [Ghostty](https://ghostty.org/) - Terminal inspiration
- [Warp](https://www.warp.dev/) - Block-based terminal concepts
- [xterm.js](https://xtermjs.org/) - Terminal emulation
- [Tauri](https://tauri.app/) - Native app framework

---

**Note**: This project is in active development. APIs may change. Not recommended for production use yet.

Jason Kneen
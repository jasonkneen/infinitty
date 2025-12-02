# Contributing to Infinitty

Thank you for your interest in contributing to Infinitty! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Making Changes](#making-changes)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Areas Needing Help](#areas-needing-help)

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Focus on the code, not the person
- Help others learn and grow

## Getting Started

### Prerequisites

- **Node.js** 18+ (recommend using [nvm](https://github.com/nvm-sh/nvm))
- **pnpm** or **npm** for package management
- **Rust** (for Tauri development) - [Install Rust](https://rustup.rs/)
- **Tauri CLI** - `cargo install tauri-cli`

### Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/jasonkneen/infinitty.git
   cd infinitty
   ```

2. **Install dependencies**
   ```bash
   pnpm install
   # or
   npm install
   ```

3. **Run in development mode**

   **Tauri (native macOS/Windows/Linux):**
   ```bash
   npm run tauri dev
   ```

   **Web (browser PWA):**
   ```bash
   npm run dev
   # Open http://localhost:1420
   ```

4. **Run tests**
   ```bash
   npm run test
   ```

## Project Structure

```
infinitty/
├── src/                    # React frontend
│   ├── components/         # UI components
│   ├── contexts/           # React Context providers
│   ├── hooks/              # Custom React hooks
│   ├── services/           # API clients (OpenCode, Claude, MCP)
│   ├── widget-sdk/         # Widget SDK for extensions
│   ├── widget-host/        # Widget runtime environment
│   └── types/              # TypeScript type definitions
├── src-tauri/              # Tauri (Rust) backend
│   ├── src/                # Rust source code
│   └── capabilities/       # Tauri permissions
├── docs/                   # Documentation (Docusaurus)
├── website/                # Marketing website (Astro)
└── public/                 # Static assets
```

## Making Changes

### Branch Naming

- `feature/` - New features (e.g., `feature/split-panes`)
- `fix/` - Bug fixes (e.g., `fix/terminal-resize`)
- `docs/` - Documentation updates
- `refactor/` - Code refactoring
- `test/` - Test additions/updates

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add split pane support
fix: resolve terminal resize issue
docs: update installation guide
refactor: extract terminal hook logic
test: add BlocksView unit tests
```

## Pull Request Process

1. **Create a feature branch** from `main`
2. **Make your changes** with clear, focused commits
3. **Run tests** - `npm run test`
4. **Run linting** - `npm run lint`
5. **Update documentation** if needed
6. **Submit PR** with clear description

### PR Requirements

- [ ] Tests pass (`npm run test`)
- [ ] TypeScript compiles (`npm run build`)
- [ ] No lint errors (`npm run lint`)
- [ ] Documentation updated (if applicable)
- [ ] PR description explains changes

## Coding Standards

### TypeScript

- Use explicit return types on functions
- Avoid `any` - use proper types or `unknown`
- Use interfaces for object shapes
- Document complex logic with comments

### React

- Functional components with hooks
- Keep components under 500 lines
- Extract reusable logic to custom hooks
- Use React Context for shared state

### Styling

- Tailwind CSS for styling
- Use existing design tokens
- Follow existing component patterns

### File Organization

```typescript
// 1. External imports
import React, { useState, useEffect } from 'react'

// 2. Internal imports
import { useTerminalSettings } from '@/contexts/TerminalSettings'

// 3. Type definitions
interface Props {
  // ...
}

// 4. Component
export function MyComponent({ ...props }: Props) {
  // ...
}
```

## Testing

### Running Tests

```bash
# Run all tests
npm run test

# Run with coverage
npm run test:coverage

# Run specific test file
npx vitest run src/components/MyComponent.test.tsx
```

### Writing Tests

```typescript
import { render, screen } from '@testing-library/react'
import { MyComponent } from './MyComponent'

describe('MyComponent', () => {
  it('renders correctly', () => {
    render(<MyComponent />)
    expect(screen.getByText('Expected Text')).toBeInTheDocument()
  })
})
```

## Areas Needing Help

See the [README.md](./README.md) for the current project status and areas where contributions are especially welcome.

### High Priority

- **Testing** - Improve test coverage
- **Documentation** - Improve inline docs and guides
- **Accessibility** - WCAG compliance improvements
- **Performance** - Optimize rendering and memory usage

### Good First Issues

Look for issues labeled `good-first-issue` in the GitHub issue tracker. These are specifically selected for new contributors.

## Questions?

- **GitHub Issues** - For bugs and feature requests
- **Discussions** - For questions and ideas

## License

By contributing, you agree that your contributions will be licensed under the project's [AGPL-3.0 + Commons Clause](./LICENSE) license.

---

Thank you for contributing to Infinitty!

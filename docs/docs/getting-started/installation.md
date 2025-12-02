---
sidebar_position: 1
---

# Installation

Set up your development environment for building Infinitty widgets.

## Prerequisites

Before you begin, make sure you have the following installed:

- **Node.js** (v18 or later) - [Download](https://nodejs.org/)
- **npm** or **pnpm** - Included with Node.js or [install pnpm](https://pnpm.io/)
- **TypeScript** - Install globally: `npm install -g typescript`
- **Git** - [Download](https://git-scm.com/)

## Create a New Widget Project

### Using a Template (Recommended)

Create a new widget project from the official template:

```bash
# Create a new directory
mkdir my-widget
cd my-widget

# Initialize with template
npm init @infinitty/widget@latest
# or with pnpm
pnpm create @infinitty/widget
```

This will scaffold a complete widget project with:
- TypeScript configuration
- Vite build setup
- Development simulator
- Example widget code
- Test setup

### Manual Setup

If you prefer to set up manually:

```bash
# Create project structure
mkdir -p my-widget/src

# Initialize npm
npm init -y

# Install dependencies
npm install @infinitty/widget-sdk react react-dom
npm install -D typescript vite @vitejs/plugin-react tsconfig.json
```

## Project Structure

A typical widget project looks like:

```
my-widget/
├── src/
│   ├── index.tsx          # Widget component
│   ├── types.ts           # TypeScript types
│   └── utils.ts           # Helper functions
├── manifest.json          # Widget metadata
├── package.json           # Project config
├── tsconfig.json          # TypeScript config
├── vite.config.ts         # Build config
└── README.md              # Documentation
```

## Configuration Files

### manifest.json

Describes your widget to Infinitty:

```json
{
  "id": "com.example.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "description": "My awesome widget",
  "author": "Your Name",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "contributes": {
    "commands": [],
    "tools": []
  }
}
```

### tsconfig.json

TypeScript configuration:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "esModuleInterop": true,
    "strict": true,
    "jsx": "react-jsx",
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist"
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.app.json" }]
}
```

### package.json Scripts

Essential npm scripts:

```json
{
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "test": "vitest",
    "lint": "eslint src",
    "type-check": "tsc --noEmit"
  }
}
```

## Verify Installation

Test your setup:

```bash
# Check TypeScript
tsc --version

# Check Node version
node --version

# Build your widget
npm run build

# Start dev server
npm run dev
```

You should see:
- No TypeScript compilation errors
- A dev server running (typically on http://localhost:5173)
- The development simulator loading

## Next Steps

- [Create Your First Widget](first-widget)
- [Test Your Widget](testing)
- [Widget SDK Overview](../widget-sdk/overview)

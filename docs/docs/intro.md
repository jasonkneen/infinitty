---
sidebar_position: 1
slug: /
---

# Infinitty Widget SDK

Welcome to the Infinitty Widget SDK documentation! This guide will help you build powerful widgets and extensions for the Infinitty terminal application.

## What is Infinitty?

Infinitty is a hybrid terminal application that combines the power of a modern terminal with AI capabilities, file exploration, and an extensible widget system. The Widget SDK allows developers to create custom widgets that integrate seamlessly with Infinitty.

## What can you build?

With the Infinitty Widget SDK, you can create:

- **UI Widgets** - Interactive React components that run within Infinitty
- **AI Tools** - Tools that integrate with Claude and other AI models
- **Automation Utilities** - Scripts and automations for terminal workflows
- **Data Visualization** - Charts, dashboards, and visualization widgets
- **Custom Commands** - Terminal commands that extend Infinitty's functionality
- **Storage Solutions** - Persistent data storage per widget instance

## Key Features

- **React-based** - Build widgets using modern React patterns
- **TypeScript Support** - Full TypeScript support with strict typing
- **Hot Reloading** - Development simulator with live updates
- **Host API** - Access to clipboard, file dialogs, commands, and more
- **Inter-widget Communication** - Send messages between widgets
- **Storage** - Instance and global storage, encrypted secrets
- **Tool Integration** - Register AI tools for Claude integration
- **Event System** - Lifecycle and custom event handling

## Quick Start

Get started in just a few minutes:

1. **Install** the SDK and create a new widget project
2. **Write** your first widget component
3. **Test** using the development simulator
4. **Package** and distribute your widget

## Next Steps

- [Installation Guide](getting-started/installation)
- [Create Your First Widget](getting-started/first-widget)
- [Widget SDK Overview](widget-sdk/overview)
- [SDK Reference](sdk-reference/hooks)

## Resources

- **GitHub**: [flows/hybrid-terminal](https://github.com/flows/hybrid-terminal)
- **Issues**: Report bugs or request features
- **Examples**: See working widget examples in the documentation

## Architecture Overview

```
┌─────────────────────────────────────────┐
│         Infinitty Terminal App          │
├─────────────────────────────────────────┤
│  Widget Host Layer                      │
│  ├── Widget Manager                     │
│  ├── Host API (Clipboard, Files, etc)   │
│  └── Event System                       │
├─────────────────────────────────────────┤
│  Your Widget                            │
│  ├── React Component                    │
│  ├── Lifecycle Handlers                 │
│  └── SDK Hooks & APIs                   │
└─────────────────────────────────────────┘
```

## Widget Manifest

Every widget includes a `manifest.json` that describes its capabilities:

```json
{
  "id": "com.example.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "description": "An example widget",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "contributes": {
    "tools": [
      {
        "name": "my_tool",
        "description": "A tool provided by this widget"
      }
    ],
    "commands": [
      {
        "id": "my-widget.action",
        "title": "Do Something"
      }
    ]
  }
}
```

## Getting Help

- Check the [Troubleshooting Guide](troubleshooting)
- Review [Examples](examples/hello-world)
- Explore the [SDK Reference](sdk-reference/hooks)
- Visit the GitHub Issues page

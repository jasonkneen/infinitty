# Infinitty Widget SDK Documentation

Complete documentation for building widgets for the Infinitty terminal application.

## Quick Start

### Installation

```bash
npm install
```

### Development

```bash
npm run start
```

Starts the documentation site on `http://localhost:3000`

### Building

```bash
npm run build
```

Creates a static site in the `build/` directory.

## Documentation Structure

```
docs/
├── docs/
│   ├── intro.md                          # Overview
│   ├── getting-started/
│   │   ├── installation.md               # Setup instructions
│   │   ├── first-widget.md               # Create first widget
│   │   └── testing.md                    # Testing widgets
│   ├── widget-sdk/
│   │   ├── overview.md                   # SDK architecture
│   │   ├── manifest.md                   # Widget manifest reference
│   │   └── lifecycle.md                  # Widget lifecycle
│   ├── sdk-reference/
│   │   ├── hooks.md                      # React hooks API
│   │   ├── host-api.md                   # Host API methods
│   │   ├── types.md                      # TypeScript types
│   │   └── utilities.md                  # Helper functions
│   ├── widget-development/
│   │   ├── dev-simulator.md              # Development simulator
│   │   ├── testing-widgets.md            # Testing guide
│   │   ├── packaging-distribution.md     # Publishing widgets
│   │   └── best-practices.md             # Best practices
│   ├── examples/
│   │   ├── hello-world.md                # Hello World example
│   │   ├── counter-widget.md             # Counter widget
│   │   ├── tool-widget.md                # AI tool widget
│   │   └── storage-widget.md             # Storage/persistence
│   └── troubleshooting.md                # Common issues & fixes
├── src/
│   └── css/
│       └── custom.css                    # Custom styling
├── docusaurus.config.js                  # Docusaurus config
├── sidebars.js                           # Navigation sidebar
└── package.json                          # Dependencies
```

## Sections

### Getting Started
- Installation and setup
- Creating your first widget
- Running tests

### Widget SDK
- Overview of the SDK architecture
- Widget manifest configuration
- Widget lifecycle and events

### SDK Reference
- Complete hook reference (useTheme, useStorage, etc.)
- Host API methods (showMessage, registerTool, etc.)
- Type definitions
- Utility functions

### Widget Development
- Development simulator usage
- Testing strategies
- Packaging and distribution
- Best practices and patterns

### Examples
- Hello World widget
- Counter with storage
- AI tools for Claude
- Storage and persistence

### Troubleshooting
- Common issues and solutions
- Debug tips
- Performance optimization

## Building a Widget

Follow this path through the documentation:

1. **[Installation](docs/getting-started/installation.md)** - Set up your environment
2. **[First Widget](docs/getting-started/first-widget.md)** - Build a simple widget
3. **[SDK Overview](docs/widget-sdk/overview.md)** - Understand the architecture
4. **[Hook Reference](docs/sdk-reference/hooks.md)** - Learn available hooks
5. **[Examples](docs/examples/hello-world.md)** - See working code
6. **[Best Practices](docs/widget-development/best-practices.md)** - Write better code
7. **[Publishing](docs/widget-development/packaging-distribution.md)** - Share your widget

## Development

### Run Locally

```bash
# Install dependencies
npm install

# Start dev server
npm run start

# Open http://localhost:3000
```

### Build for Production

```bash
# Build static site
npm run build

# Test production build
npm run serve
```

### Edit Documentation

- Add new pages in `docs/`
- Update sidebars in `sidebars.js`
- Modify config in `docusaurus.config.js`
- Style with `src/css/custom.css`

### Markdown Features

- **Code blocks** with syntax highlighting
- **Callouts** (note, info, warning, danger)
- **Tables** and lists
- **Links** between pages
- **Embedded code** from files

Example callout:

```markdown
:::info
This is an info callout
:::

:::warning
This is a warning
:::

:::danger
This is a danger callout
:::
```

## Technology Stack

- **Docusaurus 3** - Static site generator
- **React 18** - Component framework
- **Markdown** - Content format
- **TypeScript** - Type safety
- **CSS** - Styling with dark mode support

## Deployment

### GitHub Pages

```bash
# Build and deploy to GitHub Pages
npm run deploy
```

Update `docusaurus.config.js` with your repository details:

```javascript
{
  url: 'https://yourusername.github.io',
  baseUrl: '/docs/',
  organizationName: 'yourusername',
  projectName: 'infinitty',
}
```

### Other Platforms

The `build/` directory contains a static site that can be deployed to:
- Vercel
- Netlify
- AWS S3
- Any static hosting service

## Contributing

When adding documentation:

1. Follow the existing structure
2. Use clear, concise language
3. Include code examples
4. Add to appropriate sidebar section
5. Link related pages
6. Test locally before pushing

## License

Documentation is part of the Infinitty project.

## See Also

- [Infinitty Repository](https://github.com/flows/hybrid-terminal)
- [Widget SDK Source](../src/widget-sdk)
- [Examples](docs/examples/hello-world.md)

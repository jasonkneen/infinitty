---
sidebar_position: 3
---

# Packaging & Distribution

Guide to packaging and distributing Infinitty widgets.

## Project Structure

Ensure your widget has the correct structure:

```
my-widget/
├── src/
│   ├── index.tsx              # Main entry
│   ├── Component.tsx          # React component
│   ├── types.ts               # Type definitions
│   └── utils.ts               # Helpers
├── manifest.json              # Widget metadata
├── package.json               # Project config
├── tsconfig.json              # TypeScript config
├── vite.config.ts             # Build config
├── README.md                  # Documentation
└── LICENSE                    # License file
```

## Building for Distribution

### 1. Update Package.json

```json
{
  "name": "@mycompany/infinitty-my-widget",
  "version": "1.0.0",
  "description": "A useful widget for Infinitty",
  "author": "Your Name <you@example.com>",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/yourname/infinitty-my-widget"
  },
  "keywords": [
    "infinitty",
    "widget",
    "extension"
  ],
  "files": [
    "dist/",
    "manifest.json",
    "README.md",
    "LICENSE"
  ],
  "main": "dist/index.js",
  "types": "dist/index.d.ts"
}
```

### 2. Update Manifest.json

```json
{
  "id": "com.mycompany.my-widget",
  "name": "My Widget",
  "version": "1.0.0",
  "description": "Clear, searchable description",
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://example.com"
  },
  "license": "MIT",
  "icon": "icon.png",
  "repository": "https://github.com/yourname/infinitty-my-widget",
  "main": "dist/index.js",
  "ui": "dist/index.tsx",
  "engines": {
    "infinitty": ">=0.1.0"
  }
}
```

### 3. Build the Widget

```bash
# Production build
npm run build

# Verify dist/ was created
ls -la dist/
```

Check that `dist/` contains:
- `index.js` - Compiled JavaScript
- `index.d.ts` - Type definitions
- `index.tsx` - React component (if applicable)
- `styles.css` - Styles (if applicable)

### 4. Create Documentation

Create comprehensive `README.md`:

```markdown
# My Widget

A brief description of what your widget does.

## Features

- Feature 1
- Feature 2
- Feature 3

## Installation

Install from the Infinitty registry:

\`\`\`
infinitty widget install @mycompany/my-widget
\`\`\`

## Usage

How to use your widget...

## Configuration

Widget settings:

- \`my-widget.enabled\` (boolean) - Enable/disable
- \`my-widget.timeout\` (number) - Timeout in ms

## Tools

This widget provides the following tools for Claude:

- \`my_tool\` - Description of what it does

## Examples

Code examples of how to use...

## Contributing

How to contribute...

## License

MIT
```

## Version Management

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., 1.2.3)
- **MAJOR** - Breaking changes
- **MINOR** - New features (backward compatible)
- **PATCH** - Bug fixes

Update version in:
1. `package.json`
2. `manifest.json`

## Creating a Release

### Using Git

```bash
# Create version tag
git tag v1.0.0

# Push tags
git push --tags

# Create GitHub release from tag
# (Include changelog in release notes)
```

### Changelog

Create `CHANGELOG.md`:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2024-01-15

### Added
- Initial widget release
- Support for CLI commands
- Tool integration with Claude

### Fixed
- Theme color handling
- Storage persistence

## [0.9.0] - 2024-01-10

### Added
- Beta version

[1.0.0]: https://github.com/yourname/widget/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/yourname/widget/releases/tag/v0.9.0
```

## Publishing to Registry

### npm Registry

If publishing as npm package:

```bash
# Login to npm
npm login

# Verify package name is available
npm search @mycompany/my-widget

# Publish
npm publish

# Verify
npm view @mycompany/my-widget
```

Update `package.json`:

```json
{
  "publishConfig": {
    "access": "public"
  }
}
```

### Infinitty Registry

(Once official registry is available)

```bash
# Login
infinitty login

# Publish
infinitty widget publish

# List your widgets
infinitty widget list --published
```

## Security Checklist

Before publishing:

- [ ] No hardcoded secrets
- [ ] No unintended debug code
- [ ] Dependencies audited
- [ ] Input validation in place
- [ ] Error handling implemented
- [ ] Permissions documented
- [ ] Privacy policy if needed
- [ ] Code reviewed

Check for issues:

```bash
# Audit dependencies
npm audit

# Check for secrets
npm install -g detect-secrets
detect-secrets scan

# Lint code
npm run lint
```

## Distribution Methods

### 1. npm Package

```bash
npm install @mycompany/infinitty-my-widget
```

### 2. GitHub Release

```bash
# Download from GitHub
git clone https://github.com/yourname/infinitty-my-widget.git
cd infinitty-my-widget
npm install
npm run build
infinitty widget install ./
```

### 3. Direct Installation

```bash
# From local directory
infinitty widget install /path/to/my-widget

# From URL
infinitty widget install https://github.com/yourname/my-widget/archive/main.zip
```

## Licensing

Choose an appropriate license:

- **MIT** - Permissive, very popular
- **Apache 2.0** - Permissive with patent clause
- **GPL** - Copyleft, requires derivatives to be GPL
- **ISC** - Permissive, simple

Add to repository:

```bash
# Add license file
cp LICENSE-MIT LICENSE

# Include in package.json
{
  "license": "MIT"
}
```

## Updating Your Widget

### Patch Update (Bug Fix)

```bash
# Fix bug
# Update version 1.0.0 -> 1.0.1
npm version patch

# Build
npm run build

# Publish
npm publish

# Tag
git push --tags
```

### Minor Update (New Feature)

```bash
# Add feature
# Update version 1.0.0 -> 1.1.0
npm version minor

npm run build
npm publish
git push --tags
```

### Major Update (Breaking Change)

```bash
# Major refactor
# Update version 1.0.0 -> 2.0.0
npm version major

npm run build
npm publish
git push --tags
```

## Distribution File Sizes

Keep your widget small:

| Metric | Target |
|--------|--------|
| Total size | < 500KB |
| JS bundle | < 300KB |
| Dependencies | < 10 MB |
| Install time | < 5 seconds |

Check size:

```bash
# Check dist size
du -sh dist/

# Analyze bundle
npm install -g webpack-bundle-analyzer
# (or use vite equivalent)
```

## Best Practices

1. **Include documentation** - README, inline comments, examples
2. **Version consistently** - Follow semver
3. **Test before release** - Run full test suite
4. **Update changelog** - Document all changes
5. **Keep small** - Minimize bundle size
6. **Maintain backward compatibility** - Don't break users
7. **Respond to issues** - Be responsive to bug reports
8. **Include license** - Choose and include one

## Example Widget Package

Complete example structure:

```
my-widget/
├── .github/
│   └── workflows/
│       └── publish.yml          # Auto-publish on release
├── src/
│   ├── __tests__/
│   │   └── Component.test.tsx
│   ├── index.tsx
│   ├── Component.tsx
│   └── types.ts
├── manifest.json
├── package.json
├── tsconfig.json
├── vite.config.ts
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
```

## GitHub Actions CI/CD

Auto-publish on release:

```yaml
# .github/workflows/publish.yml
name: Publish Widget

on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
          registry-url: 'https://registry.npmjs.org'
      - run: npm install
      - run: npm run build
      - run: npm publish
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

## Next Steps

- [Best Practices](best-practices)
- [Widget Examples](../examples/hello-world)
- [Troubleshooting](../troubleshooting)

# Infinitty Terminal Website

Marketing and documentation website for Infinitty Terminal - the hybrid terminal with AI assistance, widgets, and MCP integration.

## Setup

```bash
cd website
pnpm install
pnpm dev
```

Visit `http://localhost:3000` to see the website.

## Build

```bash
pnpm build
```

Output in `dist/` directory.

## Structure

```
website/
├── src/
│   ├── components/           # Reusable Astro components
│   │   ├── Navigation.astro  # Header navigation
│   │   ├── Hero.astro        # Hero section
│   │   ├── Features.astro    # Features grid
│   │   ├── Capabilities.astro # Capabilities section
│   │   ├── Documentation.astro # Docs links
│   │   ├── CTA.astro         # Call-to-action
│   │   └── Footer.astro      # Footer
│   ├── layouts/              # Page layouts
│   │   ├── Layout.astro      # Main layout
│   │   └── DocLayout.astro   # Documentation layout
│   ├── pages/                # Website pages
│   │   ├── index.astro       # Home page
│   │   └── docs/             # Documentation pages
│   │       ├── installation.mdx
│   │       ├── quick-start.mdx
│   │       ├── features.mdx
│   │       ├── widgets.mdx
│   │       └── mcp.mdx
│   └── styles/
│       └── global.css        # Global styles & animations
├── astro.config.mjs
├── tailwind.config.js
├── postcss.config.js
└── package.json
```

## Design Features

### Dark Theme
- Slate-based color palette (slate-950 background)
- Cyan (#22d3ee) and Amber (#fbbf24) accent colors
- Terminal-inspired aesthetics

### Animations
- Fade-in animations on page load
- Slide-up effects for content
- Glow effects on interactive elements
- Smooth transitions and hover states

### Typography
- Geist Sans for body text
- JetBrains Mono for code/technical text
- Distinctive gradient text for headings

### Responsive
- Mobile-first design
- Tablet and desktop optimizations
- Touch-friendly navigation

## Content

### Pages

- **Home** - Hero section, features, and CTA
- **Installation** - Setup guide for all platforms
- **Quick Start** - 5-minute getting started guide
- **Features & Usage** - Complete feature documentation
- **Widgets** - Building and using custom widgets
- **MCP Integration** - Model Context Protocol guide

### Components

- Navigation with logo and CTA button
- Hero with terminal mockup and feature pills
- 6-feature grid with hover effects
- Capabilities section with use cases
- Documentation cards linking to guides
- CTA section for downloads
- Footer with links and social

## Customization

### Colors

Edit `tailwind.config.js` to change colors:

```javascript
colors: {
  cyan: {
    400: '#22d3ee',  // Primary accent
    500: '#06b6d4',
  },
  amber: {
    400: '#fbbf24',  // Secondary accent
    500: '#f59e0b',
  },
}
```

### Fonts

Change fonts in `tailwind.config.js`:

```javascript
fontFamily: {
  sans: ['Geist Sans', 'system-ui', 'sans-serif'],
  mono: ['JetBrains Mono', 'Menlo', 'monospace'],
}
```

### Content

Edit Astro components and `.mdx` pages directly. Content is stored in source files, not a CMS.

## Development

### Adding Pages

1. Create file in `src/pages/` (`.astro` or `.mdx`)
2. Import layout and add content
3. Navigation updates automatically

### Adding Components

1. Create component in `src/components/`
2. Use in pages with `import` and `<ComponentName />`

### Styling

- Use Tailwind classes in `.astro` files
- Global styles in `src/styles/global.css`
- Custom animations defined in `tailwind.config.js`

## Deployment

### Vercel

```bash
vercel
```

### Netlify

```bash
netlify deploy
```

### GitHub Pages

```bash
pnpm build
# Push dist/ to gh-pages branch
```

### Self-Hosted

```bash
pnpm build
# Serve dist/ directory with any static host
```

## Performance

- Static site generation (Astro)
- Zero JavaScript by default (components are pre-rendered)
- Optimized images
- Fast page loads
- SEO-friendly

## License

Part of Infinitty Terminal project.

## Support

- [GitHub Issues](https://github.com/flows-ai/hybrid-terminal/issues)
- [GitHub Discussions](https://github.com/flows-ai/hybrid-terminal/discussions)

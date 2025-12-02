# Infinitty Terminal Website - Deployment Guide

Complete guide to building and deploying the Infinitty Terminal marketing website.

## Quick Start

```bash
cd /Users/jkneen/Documents/GitHub/flows/hybrid-terminal/website

# Install dependencies
pnpm install

# Development server
pnpm dev
# Open http://localhost:3000

# Production build
pnpm build
# Output: dist/
```

## Prerequisites

- Node.js 18+ (recommended: 20.x LTS)
- pnpm (install with: `npm install -g pnpm`)
- Git (for version control)

## Project Structure

```
website/
├── src/
│   ├── components/          # Reusable Astro components
│   ├── layouts/             # Page templates
│   ├── pages/               # Routes
│   │   ├── index.astro      # Home
│   │   └── docs/            # Documentation
│   └── styles/              # Global CSS
├── public/                  # Static files
├── dist/                    # Built output (after build)
├── astro.config.mjs
├── tailwind.config.js
├── package.json
└── tsconfig.json
```

## Configuration

### Environment Variables

Create `.env.local` (optional):

```bash
# Not required for this static site
# But useful for future API integrations
SITE_URL=https://infinitty.dev
```

### Astro Configuration

File: `astro.config.mjs`

```javascript
export default defineConfig({
  integrations: [react()],
  output: 'static',
  // Add other config as needed
})
```

## Development

### Start Dev Server

```bash
pnpm dev
```

- Hot module reloading
- Live CSS updates
- Local at http://localhost:3000

### File Changes Auto-Reload

- Modify `.astro` files → page reloads
- Update `.mdx` files → content updates
- Change `tailwind.config.js` → styles rebuild
- Edit `src/styles/global.css` → styles refresh

### Development Tips

1. **Inspector** - Right-click → Inspect (standard DevTools)
2. **Console** - Check for errors/warnings
3. **Network** - Monitor asset loading
4. **Device Emulation** - Test mobile view

## Building for Production

### Build Command

```bash
pnpm build
```

This:
1. Compiles all TypeScript
2. Bundles CSS with Tailwind purging
3. Optimizes images
4. Generates static HTML
5. Outputs to `dist/`

### Build Output

```
dist/
├── index.html
├── docs/
│   ├── installation/index.html
│   ├── quick-start/index.html
│   ├── features/index.html
│   ├── widgets/index.html
│   ├── mcp/index.html
│   └── workflows/index.html
├── _astro/
│   └── [compiled CSS and JS]
└── [static assets]
```

### Build Size

- HTML: ~50KB (compressed)
- CSS: ~30KB (tailwind-optimized)
- JS: ~5KB (minimal)
- Total: ~85KB gzipped

## Deployment Options

### 1. Vercel (Recommended)

Easiest deployment with zero config.

**Setup:**

```bash
# Install Vercel CLI
npm i -g vercel

# Deploy
cd website
vercel

# Follow prompts
```

**Via GitHub:**

1. Push to GitHub
2. Go to vercel.com
3. Connect GitHub repo
4. Vercel auto-deploys on git push

**Custom Domain:**

```bash
vercel --prod
# Then configure DNS
```

### 2. Netlify

**Via CLI:**

```bash
# Install Netlify CLI
npm install -g netlify-cli

# Deploy
netlify deploy --prod --dir=dist
```

**Via GitHub:**

1. Push to GitHub
2. Go to netlify.com
3. Connect repo
4. Set build command: `pnpm build`
5. Set publish directory: `dist`

### 3. GitHub Pages

```bash
# Build locally
pnpm build

# Create gh-pages branch
git branch -D gh-pages
git checkout -b gh-pages
git add dist -f
git commit -m "Deploy website"
git push origin gh-pages -f

# Configure in GitHub:
# Settings → Pages → Source: gh-pages
```

### 4. AWS S3 + CloudFront

```bash
# Build
pnpm build

# Upload to S3
aws s3 sync dist/ s3://infinitty.dev

# Invalidate CloudFront
aws cloudfront create-invalidation \
  --distribution-id XXXXX \
  --paths "/*"
```

### 5. Self-Hosted

```bash
# Build
pnpm build

# Copy dist/ to server
scp -r dist/* user@server:/var/www/infinitty/

# Configure web server (nginx)
server {
  server_name infinitty.dev;
  root /var/www/infinitty;
  index index.html;
  error_page 404 /404.html;
}
```

## Domain Setup

### Point Domain to Vercel

1. Add domain in Vercel dashboard
2. Update DNS:

```
CNAME  www  cname.vercel-dns.com
A      @   76.76.19.165
```

### Point Domain to Netlify

1. Add domain in Netlify dashboard
2. Update DNS to Netlify nameservers

### Point Domain to Custom Server

```
A      @    YOUR_IP
CNAME  www  YOUR_DOMAIN
```

## SSL/TLS Certificate

- **Vercel** - Automatic free certificate
- **Netlify** - Automatic free certificate
- **Self-hosted** - Use Let's Encrypt (certbot)

```bash
# Let's Encrypt with certbot
sudo certbot certonly -d infinitty.dev -d www.infinitty.dev
```

## SEO & Meta Tags

The site includes:

- `<meta name="description">` on all pages
- Open Graph tags for social sharing
- Semantic HTML structure
- Proper heading hierarchy
- Mobile-friendly viewport

## Analytics (Optional)

Add to `Layout.astro`:

```html
<!-- Google Analytics -->
<script async src="https://www.googletagmanager.com/gtag/js?id=GA_ID"></script>
<script>
  window.dataLayer = window.dataLayer || []
  function gtag(){dataLayer.push(arguments)}
  gtag('js', new Date())
  gtag('config', 'GA_ID')
</script>
```

## Monitoring

### Vercel

- Dashboard shows deployments
- Analytics: Page views, Edge Network data
- Real-time logs

### Netlify

- Deploy logs and history
- Analytics built-in
- Deployment status checks

## Updating Content

### Home Page

Edit: `/src/pages/index.astro`

Sections:
- Hero
- Features
- Capabilities
- Documentation links
- CTA
- Footer

### Documentation Pages

Edit `.mdx` files in `/src/pages/docs/`:

```
/docs/installation.mdx
/docs/quick-start.mdx
/docs/features.mdx
/docs/widgets.mdx
/docs/mcp.mdx
/docs/workflows.mdx
```

### Styling

Edit `/src/styles/global.css` or `tailwind.config.js`

### Components

Edit files in `/src/components/`

## Performance Optimization

### Image Optimization

```html
<!-- Use Astro image component -->
<Image src={import('../path/to/image.png')} alt="Description" />
```

### CSS Purging

Tailwind automatically purges unused CSS in production.

### Lazy Loading

```html
<!-- Lazy load iframes -->
<iframe loading="lazy" src="..."></iframe>
```

### Caching Headers

Set on your host:

```
# CSS and JS
Cache-Control: max-age=31536000

# HTML
Cache-Control: max-age=3600
```

## Troubleshooting

### Build Fails

```bash
# Clear cache
rm -rf .astro
rm -rf node_modules
pnpm install

# Try again
pnpm build
```

### Styles Not Loading

```bash
# Rebuild tailwind
pnpm build
# Clear browser cache (Cmd+Shift+Delete)
```

### Pages Not Found After Deploy

Ensure:
1. All files built to `dist/`
2. Server configured for SPA (redirects 404 to index.html)
3. No URL path issues

### Slow Loading

- Check Network tab (DevTools)
- Verify CSS/JS are gzipped
- Check image sizes
- Enable caching headers

## Continuous Deployment

### GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: 20
      - run: npm i -g pnpm
      - run: pnpm install
      - run: pnpm build
      - uses: actions/upload-artifact@v3
        with:
          name: dist
          path: dist/
      - name: Deploy to Vercel
        run: npx vercel --prod --token=${{ secrets.VERCEL_TOKEN }}
```

## Maintenance Checklist

- [ ] Test all links work
- [ ] Check mobile responsiveness
- [ ] Verify search engines can crawl
- [ ] Update documentation when features change
- [ ] Monitor performance metrics
- [ ] Check error logs regularly
- [ ] Update dependencies monthly

## Support & Issues

For issues during deployment:

1. Check deployment logs
2. Verify build output: `ls dist/`
3. Test locally: `pnpm build && pnpm preview`
4. Check GitHub for similar issues

## Next Steps

1. **Set up domain** - Point DNS to your host
2. **Configure SSL** - Get HTTPS certificate
3. **Enable analytics** - Track visitors
4. **Monitor performance** - Use Vercel/Netlify dashboard
5. **Backup regularly** - Keep git repo safe

## Resources

- [Astro Docs](https://docs.astro.build)
- [Tailwind CSS](https://tailwindcss.com)
- [Vercel Docs](https://vercel.com/docs)
- [Netlify Docs](https://docs.netlify.com)

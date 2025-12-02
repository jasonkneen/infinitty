import { defineConfig } from 'astro/config'
import react from '@astrojs/react'
import mdx from '@astrojs/mdx'
import tailwindcss from '@tailwindcss/postcss'

export default defineConfig({
  integrations: [react(), mdx()],
  output: 'static',
  vite: {
    css: {
      postcss: true,
    }
  }
})

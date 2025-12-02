/**
 * Vite config for development mode (standalone simulator)
 */

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'

export default defineConfig({
  plugins: [react()],

  // Dev server entry is src/dev.tsx
  root: '.',

  resolve: {
    alias: {
      // Point to local widget-sdk during development
      '@infinitty/widget-sdk': resolve(__dirname, '../../..'),
      '@infinitty/widget-sdk/dev-simulator': resolve(__dirname, '../../../dev-simulator'),
    },
  },

  server: {
    port: 3100,
    open: true,
  },

  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
      },
    },
  },
})

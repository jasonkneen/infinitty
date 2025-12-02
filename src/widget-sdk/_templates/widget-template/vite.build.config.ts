/**
 * Vite config for production build (Infinitty package)
 */

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'

export default defineConfig({
  plugins: [react()],

  resolve: {
    alias: {
      // In production, widget-sdk is provided by Infinitty host
      '@infinitty/widget-sdk': resolve(__dirname, '../../..'),
    },
  },

  build: {
    // Output to dist/ folder
    outDir: 'dist',

    // Library mode - exports the widget module
    lib: {
      entry: resolve(__dirname, 'src/index.tsx'),
      name: 'Widget',
      fileName: 'index',
      formats: ['es'],
    },

    rollupOptions: {
      // External dependencies provided by host
      external: ['react', 'react-dom', '@infinitty/widget-sdk'],

      output: {
        // Global variables for externals when building UMD
        globals: {
          react: 'React',
          'react-dom': 'ReactDOM',
        },

        // Single file output
        entryFileNames: 'index.js',
        chunkFileNames: '[name].js',
        assetFileNames: '[name][extname]',
      },
    },

    // Generate sourcemaps for debugging
    sourcemap: true,

    // Don't minify in dev mode
    minify: process.env.NODE_ENV === 'production',
  },
})

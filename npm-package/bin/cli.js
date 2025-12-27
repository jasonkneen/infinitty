#!/usr/bin/env node

const { spawn } = require('child_process')
const path = require('path')
const fs = require('fs')

const binDir = path.join(__dirname, '..', '.binary')
const platform = process.platform
const arch = process.arch

// Tauri produces different structures per platform
const binaryMap = {
  darwin: {
    x64: 'Infinitty.app/Contents/MacOS/Infinitty',
    arm64: 'Infinitty.app/Contents/MacOS/Infinitty'
  },
  win32: {
    x64: 'Infinitty.exe'
  },
  linux: {
    x64: 'infinitty.AppImage'
  }
}

const relativePath = binaryMap[platform]?.[arch]

if (!relativePath) {
  console.error(`Platform ${platform}-${arch} not supported`)
  console.error('Supported platforms: macOS (x64, arm64), Windows (x64), Linux (x64)')
  process.exit(1)
}

const binaryPath = path.join(binDir, relativePath)

if (!fs.existsSync(binaryPath)) {
  console.error('Binary not found. Running postinstall...')
  console.error(`Expected: ${binaryPath}`)

  // Try to run postinstall
  try {
    require('../scripts/postinstall')
  } catch (e) {
    console.error('Failed to install binary:', e.message)
    console.error('Try reinstalling: npm install -g infinitty')
    process.exit(1)
  }
}

// Make executable on Unix (AppImage needs this)
if (platform !== 'win32') {
  try {
    fs.chmodSync(binaryPath, 0o755)
  } catch (e) {
    // Ignore if already executable
  }
}

const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: 'inherit',
  env: process.env
})

child.on('error', (err) => {
  console.error('Failed to start Infinitty:', err.message)
  process.exit(1)
})

child.on('close', (code) => process.exit(code || 0))

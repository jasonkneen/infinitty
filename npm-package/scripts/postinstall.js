const https = require('https')
const fs = require('fs')
const path = require('path')
const { execSync } = require('child_process')

const pkg = require('../package.json')
const version = pkg.version
const platform = process.platform
const arch = process.arch

// Map Node platform/arch to Tauri target names
const targetMap = {
  darwin: {
    x64: 'x86_64-apple-darwin',
    arm64: 'aarch64-apple-darwin'
  },
  win32: {
    x64: 'x86_64-pc-windows-msvc'
  },
  linux: {
    x64: 'x86_64-unknown-linux-gnu'
  }
}

const target = targetMap[platform]?.[arch]

if (!target) {
  console.log(`Platform ${platform}-${arch} not supported`)
  console.log('Supported: macOS (x64, arm64), Windows (x64), Linux (x64)')
  process.exit(0)
}

const binDir = path.join(__dirname, '..', '.binary')
const appName = 'Infinitty'

// GitHub releases URL pattern
const baseUrl = `https://github.com/jasonkneen/infinitty/releases/download/v${version}`

// Tauri artifact naming varies by platform
function getDownloadUrl() {
  if (platform === 'linux') {
    return `${baseUrl}/infinitty_${version}_amd64.AppImage`
  } else if (platform === 'darwin') {
    // macOS - compressed .app bundle
    if (arch === 'arm64') {
      return `${baseUrl}/${appName}_aarch64-apple-darwin.app.tar.gz`
    }
    return `${baseUrl}/${appName}_x86_64-apple-darwin.app.tar.gz`
  } else if (platform === 'win32') {
    // Windows - portable exe or NSIS installer
    return `${baseUrl}/${appName}_${version}_x64-setup.exe`
  }
  return null
}

const downloadUrl = getDownloadUrl()

if (!downloadUrl) {
  console.error('Could not determine download URL')
  process.exit(1)
}

console.log(`Downloading Infinitty for ${platform}-${arch}...`)
console.log(`Version: ${version}`)
console.log(`URL: ${downloadUrl}`)

if (!fs.existsSync(binDir)) {
  fs.mkdirSync(binDir, { recursive: true })
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest)

    const request = (url) => {
      https.get(url, (response) => {
        if (response.statusCode === 302 || response.statusCode === 301) {
          // Follow redirect
          request(response.headers.location)
          return
        }
        if (response.statusCode === 404) {
          reject(new Error(`Release not found: v${version}\nMake sure GitHub release v${version} exists with the binary assets.`))
          return
        }
        if (response.statusCode !== 200) {
          reject(new Error(`HTTP ${response.statusCode}: ${url}`))
          return
        }

        const totalBytes = parseInt(response.headers['content-length'], 10)
        let downloadedBytes = 0

        response.on('data', (chunk) => {
          downloadedBytes += chunk.length
          if (totalBytes) {
            const percent = Math.round((downloadedBytes / totalBytes) * 100)
            process.stdout.write(`\rDownloading... ${percent}%`)
          }
        })

        response.pipe(file)
        file.on('finish', () => {
          file.close()
          console.log('\nDownload complete!')
          resolve()
        })
      }).on('error', reject)
    }

    request(url)
  })
}

async function install() {
  try {
    if (platform === 'linux') {
      // AppImage is a single file
      const appImagePath = path.join(binDir, 'infinitty.AppImage')
      await download(downloadUrl, appImagePath)
      fs.chmodSync(appImagePath, 0o755)
      console.log('AppImage installed successfully!')

    } else if (platform === 'darwin') {
      // Download and extract .tar.gz
      const archiveFile = path.join(binDir, 'download.tar.gz')
      await download(downloadUrl, archiveFile)

      console.log('Extracting app bundle...')
      execSync(`tar -xzf "${archiveFile}" -C "${binDir}"`, { stdio: 'inherit' })
      fs.unlinkSync(archiveFile)
      console.log('macOS app installed successfully!')

    } else if (platform === 'win32') {
      // Download exe
      const exePath = path.join(binDir, 'Infinitty.exe')
      await download(downloadUrl, exePath)
      console.log('Windows executable installed successfully!')
    }

    console.log(`\nInfinitty v${version} installed!`)
    console.log('Run with: infinitty')

  } catch (error) {
    console.error('\nFailed to install binary:', error.message)
    console.error('\nTroubleshooting:')
    console.error(`1. Check if release v${version} exists: https://github.com/jasonkneen/infinitty/releases`)
    console.error('2. Ensure the release has binary assets for your platform')
    console.error('3. Try installing again: npm install -g infinitty')
    process.exit(1)
  }
}

install()

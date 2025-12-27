const https = require('https')
const fs = require('fs')
const path = require('path')
const { execSync } = require('child_process')

const pkg = require('../package.json')
const version = pkg.version
const platform = process.platform
const arch = process.arch

// Map Node platform/arch to Tauri target names
// NOTE: Currently only macOS is supported. Linux/Windows coming soon.
const targetMap = {
  darwin: {
    x64: 'x86_64-apple-darwin',
    arm64: 'aarch64-apple-darwin'
  }
  // TODO: Add when builds are fixed
  // win32: { x64: 'x86_64-pc-windows-msvc' },
  // linux: { x64: 'x86_64-unknown-linux-gnu' }
}

const target = targetMap[platform]?.[arch]

if (!target) {
  console.log(`Platform ${platform}-${arch} not yet supported`)
  console.log('Currently supported: macOS (x64, arm64)')
  console.log('Linux and Windows coming soon!')
  process.exit(0)
}

const binDir = path.join(__dirname, '..', '.binary')
const appName = 'Infinitty'

// GitHub releases URL pattern
const baseUrl = `https://github.com/jasonkneen/infinitty/releases/download/v${version}`

// Tauri artifact naming varies by platform
function getDownloadUrl() {
  if (platform === 'darwin') {
    // macOS - compressed .app bundle (Tauri uses short arch names)
    if (arch === 'arm64') {
      return `${baseUrl}/${appName}_aarch64.app.tar.gz`
    }
    return `${baseUrl}/${appName}_x64.app.tar.gz`
  }
  // TODO: Add Linux/Windows when builds are fixed
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
    // macOS: Download and extract .tar.gz
    const archiveFile = path.join(binDir, 'download.tar.gz')
    await download(downloadUrl, archiveFile)

    console.log('Extracting app bundle...')
    execSync(`tar -xzf "${archiveFile}" -C "${binDir}"`, { stdio: 'inherit' })
    fs.unlinkSync(archiveFile)

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

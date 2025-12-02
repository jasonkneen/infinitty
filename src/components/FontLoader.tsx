import { useEffect } from 'react'
import { TERMINAL_FONTS, UI_FONTS } from '../config/terminal'

// Map of Google Fonts that need to be loaded
const GOOGLE_FONTS_MAP: Record<string, string> = {
  // Modern monospace fonts
  'jetbrains-mono': 'JetBrains+Mono',
  'fira-code': 'Fira+Code',
  'cascadia-code': 'Cascadia+Code',
  'source-code-pro': 'Source+Code+Pro',
  'ibm-plex-mono': 'IBM+Plex+Mono',
  'hack': 'Hack',
  'victor-mono': 'Victor+Mono',
  'iosevka': 'Iosevka',
  'monaspace-neon': 'Monaspace+Neon',
  'monaspace-argon': 'Monaspace+Argon',
  'geist-mono': 'Geist+Mono',
  'commit-mono': 'Commit+Mono',
  'recursive-mono': 'Recursive+Mono',
  'intel-one-mono': 'Intel+One+Mono',
  'julia-mono': 'JuliaMono',
  'fantasque-sans-mono': 'Fantasque+Sans+Mono',
  'anonymous-pro': 'Anonymous+Pro',
  'inconsolata': 'Inconsolata',
  'comic-mono': 'Comic+Mono',
  // Retro/CRT fonts
  'vt323': 'VT323',
  'glass-tty-vt220': 'VT323', // Fallback to VT323
  'ibm-3270': 'IBM+Plex+Mono', // Fallback
  'terminus': 'IBM+Plex+Mono', // Fallback
  'cozette': 'IBM+Plex+Mono', // Fallback
  'scientifica': 'IBM+Plex+Mono', // Fallback
  'creep': 'IBM+Plex+Mono', // Fallback
  'tamsyn': 'IBM+Plex+Mono', // Fallback
  'unscii': 'IBM+Plex+Mono', // Fallback
  // UI Fonts
  'inter': 'Inter',
  'geist': 'Geist',
  'plus-jakarta': 'Plus+Jakarta+Sans',
  'dm-sans': 'DM+Sans',
  'space-grotesk': 'Space+Grotesk',
  'manrope': 'Manrope',
  'work-sans': 'Work+Sans',
  'nunito': 'Nunito',
  'poppins': 'Poppins',
  'outfit': 'Outfit',
  'sora': 'Sora',
  'albert-sans': 'Albert+Sans',
  'figtree': 'Figtree',
  'satoshi': 'Satoshi',
  'cabinet-grotesk': 'Cabinet+Grotesk',
  'general-sans': 'General+Sans',
  'clash-display': 'Clash+Display',
  'roboto': 'Roboto',
  'lato': 'Lato',
  'open-sans': 'Open+Sans',
  'montserrat': 'Montserrat',
  'raleway': 'Raleway',
  'source-sans': 'Source+Sans+Pro',
  'ibm-plex-sans': 'IBM+Plex+Sans',
  'fira-sans': 'Fira+Sans',
  'ubuntu': 'Ubuntu',
  'karla': 'Karla',
  'rubik': 'Rubik',
  'quicksand': 'Quicksand',
  'playfair': 'Playfair+Display',
  'merriweather': 'Merriweather',
  'lora': 'Lora',
  'libre-baskerville': 'Libre+Baskerville',
  'source-serif': 'Source+Serif+Pro',
  'fraunces': 'Fraunces',
  'orbitron': 'Orbitron',
  'audiowide': 'Audiowide',
  'exo-2': 'Exo',
  'rajdhani': 'Rajdhani',
  'chakra-petch': 'Chakra+Petch',
  'oxanium': 'Oxanium',
  'share-tech': 'Share+Tech',
}

// System fonts that are already installed locally, no need to load from web
const SYSTEM_FONTS = new Set([
  // macOS system fonts
  'sf-mono',
  'menlo',
  'monaco',
  // Windows system fonts
  'consolas',
  'segoe-ui',
  // Cross-platform
  'courier-new',
  'andale-mono',
  'dejavu-sans-mono',
  'ubuntu-mono',
  'droid-sans-mono',
  'liberation-mono',
  // Retro/pixel fonts (typically installed locally)
  'profont',
  'fixedsys-excelsior',
  'px437-ibm-vga',
  'dos-v',
  'perfect-dos',
  'commodore-64',
  'apple-ii',
  'envy-code-r',
  'spleen',
  'monocraft',
  // Premium/local fonts (user must install)
  'berkeley-mono',
  'maple-mono',
  '0xproto',
  'meslo',
  // Serif
  'georgia',
  // System UI
  'system-ui',
  'sf-pro',
])

// Event to notify when fonts are loaded
export const FONTS_LOADED_EVENT = 'fonts-loaded'

/**
 * FontLoader component loads Google Fonts and notifies when they're ready.
 * This ensures all font options are available for preview and selection.
 */
export function FontLoader() {
  useEffect(() => {
    // Collect all unique Google Fonts that need to be loaded
    const fontsToLoad = new Set<string>()

    // Add terminal fonts
    TERMINAL_FONTS.forEach(font => {
      if (!SYSTEM_FONTS.has(font.id) && GOOGLE_FONTS_MAP[font.id]) {
        fontsToLoad.add(GOOGLE_FONTS_MAP[font.id])
      }
    })

    // Add UI fonts
    UI_FONTS.forEach(font => {
      if (!SYSTEM_FONTS.has(font.id) && GOOGLE_FONTS_MAP[font.id]) {
        fontsToLoad.add(GOOGLE_FONTS_MAP[font.id])
      }
    })

    // Create link tag for Google Fonts
    if (fontsToLoad.size > 0) {
      const fontsList = Array.from(fontsToLoad).join('&family=')
      const url = `https://fonts.googleapis.com/css2?family=${fontsList}:wght@400;500;600;700&display=swap`

      // Check if link already exists
      const existing = document.querySelector(`link[href="${url}"]`)
      if (!existing) {
        const link = document.createElement('link')
        link.rel = 'stylesheet'
        link.href = url
        document.head.appendChild(link)
      }
    }

    // Wait for all fonts to be loaded, then dispatch event
    document.fonts.ready.then(() => {
      window.dispatchEvent(new CustomEvent(FONTS_LOADED_EVENT))
    })
  }, [])

  return null
}

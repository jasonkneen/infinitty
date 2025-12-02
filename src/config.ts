/**
 * Terminal Interface Modes
 *
 * GHOSTTY: Pure terminal interface - exactly like Ghostty
 *          - Direct keyboard input to terminal
 *          - No AI features, no blocks
 *          - Traditional terminal experience
 *
 * OPENWARP: AI-enhanced interface - OpenWarp style
 *           - Input via bottom bar
 *           - Command blocks for output
 *           - AI mode toggle
 *           - Model selection
 */
export type InterfaceMode = 'ghostty' | 'openwarp'

interface Config {
  interfaceMode: InterfaceMode
}

function getInterfaceMode(): InterfaceMode {
  // Check Vite env variable
  const envMode = import.meta.env.VITE_INTERFACE_MODE?.toLowerCase()

  if (envMode === 'ghostty') return 'ghostty'
  if (envMode === 'openwarp') return 'openwarp'

  // Default to ghostty - pure terminal mode
  return 'ghostty'
}

export const config: Config = {
  interfaceMode: getInterfaceMode(),
}

export function isGhosttyMode(): boolean {
  return config.interfaceMode === 'ghostty'
}

export function isOpenWarpMode(): boolean {
  return config.interfaceMode === 'openwarp'
}

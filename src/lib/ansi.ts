/**
 * Strip ANSI escape codes from terminal output
 * This removes color codes, cursor movement, and other control sequences
 */
export function stripAnsi(str: string): string {
  // Match ANSI escape sequences
  // eslint-disable-next-line no-control-regex
  const ansiRegex = /[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g

  // Also match OSC sequences (like terminal title setting)
  // eslint-disable-next-line no-control-regex
  const oscRegex = /\u001b\][^\u0007]*\u0007/g

  // Match bracketed paste mode sequences
  const bracketedPasteRegex = /\[(\?2004[hl])/g

  return str
    .replace(ansiRegex, '')
    .replace(oscRegex, '')
    .replace(bracketedPasteRegex, '')
    .replace(/\r/g, '') // Remove carriage returns
}

/**
 * Clean terminal output for display in blocks
 * Removes command echo, prompts, and unnecessary whitespace
 */
export function cleanTerminalOutput(output: string, command: string): string {
  let cleaned = stripAnsi(output)

  // Split into lines
  const lines = cleaned.split('\n')

  // Filter out:
  // 1. Lines that are just the command echo
  // 2. Empty lines at start/end
  // 3. Shell prompt lines (ending with % or $ followed by nothing meaningful)
  const filteredLines = lines.filter((line, index) => {
    const trimmed = line.trim()

    // Skip empty lines at the very start
    if (index === 0 && trimmed === '') return false

    // Skip if it's just the command being echoed back
    if (trimmed === command) return false

    // Skip shell prompts (basic detection)
    if (/^.*[@:].*[%$#>]\s*$/.test(trimmed) && !trimmed.includes(command)) {
      return false
    }

    return true
  })

  // Remove trailing empty lines
  while (filteredLines.length > 0 && filteredLines[filteredLines.length - 1].trim() === '') {
    filteredLines.pop()
  }

  return filteredLines.join('\n')
}

// Types
export * from './types.js'

// Parsers
export { SkillParser } from './parsers/skill-parser.js'
export { parseSkillsDirectory } from './parsers/skills-directory-parser.js'

// Mermaid utilities (the Rosetta Stone)
export { mermaidToReactFlow, reactFlowToMermaid } from './mermaid/index.js'

// Export adapters (Mermaid → back to source formats)
export { exportToSkill, exportSkillsDirectory, autoExport } from './exporters/index.js'
export type { SkillExportOptions } from './exporters/index.js'

// Layout engine (ELK.js)
export { applyElkLayout, layoutGraph } from './layout/index.js'
export type { ElkLayoutOptions } from './layout/index.js'

// Main entry function
import { SkillParser } from './parsers/skill-parser.js'
import { parseSkillsDirectory } from './parsers/skills-directory-parser.js'
import type { MermaidDiagram } from './types.js'

export interface ToFlowsOptions {
  type: 'skill' | 'skills-directory'
  path: string
}

/**
 * Main entry point - converts source to Mermaid diagram
 */
export async function toFlows(options: ToFlowsOptions): Promise<MermaidDiagram> {
  switch (options.type) {
    case 'skill': {
      const parser = new SkillParser()
      const parsed = await parser.parse(options.path)
      return parser.toMermaid(parsed)
    }
    case 'skills-directory': {
      const result = await parseSkillsDirectory(options.path)
      return result.diagram
    }
    default:
      throw new Error(`Unknown type: ${options.type}`)
  }
}

/**
 * Auto-detect source type from path and convert to Mermaid
 */
export async function autoDetect(sourcePath: string): Promise<MermaidDiagram> {
  const fs = await import('fs/promises')
  const path = await import('path')

  const stats = await fs.stat(sourcePath)

  if (stats.isDirectory()) {
    // Check if it's a single skill (has SKILL.md) or a skills directory
    const skillMdPath = path.join(sourcePath, 'SKILL.md')
    try {
      await fs.access(skillMdPath)
      // It's a single skill directory
      return toFlows({ type: 'skill', path: sourcePath })
    } catch {
      // Might be a skills directory - check for subdirectories with SKILL.md
      const entries = await fs.readdir(sourcePath, { withFileTypes: true })
      const hasSkillSubdirs = await Promise.all(
        entries
          .filter(e => e.isDirectory())
          .map(async e => {
            try {
              await fs.access(path.join(sourcePath, e.name, 'SKILL.md'))
              return true
            } catch {
              return false
            }
          })
      )

      if (hasSkillSubdirs.some(Boolean)) {
        return toFlows({ type: 'skills-directory', path: sourcePath })
      }

      throw new Error(`Could not detect source type for: ${sourcePath}`)
    }
  } else if (stats.isFile()) {
    // Single file - assume it's a skill markdown
    if (sourcePath.endsWith('.md')) {
      return toFlows({ type: 'skill', path: sourcePath })
    }
    throw new Error(`Unsupported file type: ${sourcePath}`)
  }

  throw new Error(`Could not detect source type for: ${sourcePath}`)
}

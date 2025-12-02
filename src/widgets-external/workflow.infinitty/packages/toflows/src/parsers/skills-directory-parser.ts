import fs from 'fs/promises'
import path from 'path'
import { SkillParser } from './skill-parser.js'
import type { MermaidDiagram, ParsedSkill } from '../types.js'

export interface SkillsDirectoryResult {
  skills: Array<{ name: string; parsed: ParsedSkill }>
  diagram: MermaidDiagram
}

/**
 * Parse an entire skills directory (e.g., ~/.claude/skills)
 * Creates a unified Mermaid diagram showing all skills
 */
export async function parseSkillsDirectory(dirPath: string): Promise<SkillsDirectoryResult> {
  const skillParser = new SkillParser()
  const skills: Array<{ name: string; parsed: ParsedSkill }> = []

  // Find all skill directories (those containing SKILL.md)
  const entries = await fs.readdir(dirPath, { withFileTypes: true })

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      // Check for loose .md files that might be skills
      if (entry.name.endsWith('.md') && entry.name !== 'README.md') {
        try {
          const skillPath = path.join(dirPath, entry.name)
          const parsed = await skillParser.parse(skillPath)
          const name = parsed.frontmatter?.name || entry.name.replace('.md', '')
          skills.push({ name, parsed })
        } catch {
          // Skip files that don't parse as skills
        }
      }
      continue
    }

    const skillMdPath = path.join(dirPath, entry.name, 'SKILL.md')
    try {
      await fs.access(skillMdPath)
      const parsed = await skillParser.parse(skillMdPath)
      skills.push({ name: entry.name, parsed })
    } catch {
      // No SKILL.md in this directory, skip
    }
  }

  // Build combined Mermaid diagram
  const diagram = buildCombinedMermaid(skills, dirPath)

  return { skills, diagram }
}

/**
 * Build a combined Mermaid diagram from multiple skills
 */
function buildCombinedMermaid(
  skills: Array<{ name: string; parsed: ParsedSkill }>,
  sourcePath: string
): MermaidDiagram {
  const lines: string[] = []

  // Start flowchart
  lines.push('flowchart TB')
  lines.push('')

  // Styles
  lines.push('  %% Node styles')
  lines.push('  classDef skillsRoot fill:#1e1b4b,stroke:#312e81,color:#fff')
  lines.push('  classDef skill fill:#6366f1,stroke:#4f46e5,color:#fff')
  lines.push('  classDef principle fill:#818cf8,stroke:#6366f1,color:#fff')
  lines.push('  classDef workflow fill:#34d399,stroke:#10b981,color:#fff')
  lines.push('  classDef reference fill:#fbbf24,stroke:#f59e0b,color:#000')
  lines.push('')

  // Root node
  lines.push(`  root["📁 Skills (${skills.length})"]:::skillsRoot`)
  lines.push('')

  // Each skill as a subgraph
  skills.forEach((skill) => {
    const skillId = `skill_${sanitizeId(skill.name)}`
    const p = skill.parsed
    const displayName = p.frontmatter?.name || skill.name

    lines.push(`  subgraph ${skillId}["${escapeLabel(displayName)}"]`)
    lines.push('    direction TB')

    // Skill main node
    const mainId = `${skillId}_main`
    lines.push(`    ${mainId}["🎯 ${escapeLabel(displayName)}"]:::skill`)

    // Principles (collapsed summary)
    if (p.principles.length > 0) {
      const principlesId = `${skillId}_principles`
      lines.push(`    ${principlesId}["📋 ${p.principles.length} principles"]:::principle`)
      lines.push(`    ${mainId} --> ${principlesId}`)
    }

    // Workflows
    if (p.workflows.length > 0) {
      const workflowsId = `${skillId}_workflows`
      lines.push(`    ${workflowsId}["⚡ ${p.workflows.length} workflows"]:::workflow`)
      lines.push(`    ${mainId} --> ${workflowsId}`)
    }

    // References
    if (p.references.length > 0) {
      const refsId = `${skillId}_refs`
      lines.push(`    ${refsId}["📚 ${p.references.length} references"]:::reference`)
      lines.push(`    ${mainId} --> ${refsId}`)
    }

    lines.push('  end')
    lines.push(`  root --> ${skillId}`)
    lines.push('')
  })

  return {
    source: lines.join('\n'),
    type: 'flowchart',
    metadata: {
      sourceType: 'skills-directory',
      sourcePath,
      generatedAt: new Date().toISOString(),
      version: '0.1.0',
      originalData: skills.map(s => s.parsed),
    },
  }
}

function sanitizeId(str: string): string {
  return str.replace(/[^a-zA-Z0-9]/g, '_').toLowerCase()
}

function escapeLabel(str: string): string {
  return str.replace(/"/g, "'").replace(/\n/g, '\\n')
}

import fs from 'fs/promises'
import path from 'path'
import matter from 'gray-matter'
import { glob } from 'glob'
import type {
  Parser,
  ParsedSkill,
  SkillFrontmatter,
  SkillPrinciple,
  SkillRouting,
  SkillReference,
  SkillWorkflow,
  MermaidDiagram,
} from '../types.js'

export class SkillParser implements Parser<ParsedSkill> {
  /**
   * Parse a skill directory or SKILL.md file
   */
  async parse(sourcePath: string): Promise<ParsedSkill> {
    const stats = await fs.stat(sourcePath)
    const skillDir = stats.isDirectory() ? sourcePath : path.dirname(sourcePath)
    const skillFile = stats.isDirectory()
      ? path.join(sourcePath, 'SKILL.md')
      : sourcePath

    const content = await fs.readFile(skillFile, 'utf-8')
    const { data, content: rawContent } = matter(content)

    const frontmatter = data as SkillFrontmatter
    const principles = this.parsePrinciples(rawContent)
    const intake = this.parseIntake(rawContent)
    const routing = this.parseRouting(rawContent)
    const references = await this.findReferences(skillDir)
    const workflows = await this.findWorkflows(skillDir, rawContent)

    return {
      frontmatter,
      principles,
      intake,
      routing,
      references,
      workflows,
      rawContent,
    }
  }

  /**
   * Parse <principle name="...">...</principle> blocks
   */
  private parsePrinciples(content: string): SkillPrinciple[] {
    const principles: SkillPrinciple[] = []
    const regex = /<principle\s+name="([^"]+)">([\s\S]*?)<\/principle>/g
    let match

    while ((match = regex.exec(content)) !== null) {
      principles.push({
        name: match[1],
        content: match[2].trim(),
      })
    }

    return principles
  }

  /**
   * Parse <intake>...</intake> block
   */
  private parseIntake(content: string): string | undefined {
    const match = content.match(/<intake>([\s\S]*?)<\/intake>/)
    return match ? match[1].trim() : undefined
  }

  /**
   * Parse routing table from <routing>...</routing> block
   */
  private parseRouting(content: string): SkillRouting[] {
    const routing: SkillRouting[] = []
    const routingMatch = content.match(/<routing>([\s\S]*?)<\/routing>/)
    if (!routingMatch) return routing

    const tableContent = routingMatch[1]
    // Match markdown table rows: | response | workflow |
    const rowRegex = /\|\s*([^|]+?)\s*\|\s*`?([^|`]+)`?\s*\|/g
    let match

    while ((match = rowRegex.exec(tableContent)) !== null) {
      const response = match[1].trim()
      const workflow = match[2].trim()
      // Skip header row
      if (response.includes('---') || response.toLowerCase() === 'response') {
        continue
      }
      routing.push({ response, workflow })
    }

    return routing
  }

  /**
   * Find reference files in references/ directory
   */
  private async findReferences(skillDir: string): Promise<SkillReference[]> {
    const refsDir = path.join(skillDir, 'references')
    try {
      await fs.access(refsDir)
    } catch {
      return []
    }

    const files = await glob('**/*.md', { cwd: refsDir })
    return files.map(file => ({
      name: path.basename(file, '.md'),
      path: `references/${file}`,
    }))
  }

  /**
   * Find workflows from workflows/ directory and parse from content
   */
  private async findWorkflows(skillDir: string, content: string): Promise<SkillWorkflow[]> {
    const workflows: SkillWorkflow[] = []
    const workflowsDir = path.join(skillDir, 'workflows')

    // Check filesystem
    try {
      await fs.access(workflowsDir)
      const files = await glob('**/*.md', { cwd: workflowsDir })

      // Parse workflows_index from content to get purposes
      const indexMatch = content.match(/<workflows_index>([\s\S]*?)<\/workflows_index>/)
      const purposeMap = new Map<string, string>()

      if (indexMatch) {
        const rowRegex = /\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|/g
        let match
        while ((match = rowRegex.exec(indexMatch[1])) !== null) {
          const name = match[1].trim()
          const purpose = match[2].trim()
          if (!name.includes('---') && name.toLowerCase() !== 'workflow') {
            purposeMap.set(name, purpose)
          }
        }
      }

      for (const file of files) {
        const name = path.basename(file, '.md')
        workflows.push({
          name,
          path: `workflows/${file}`,
          purpose: purposeMap.get(file) || purposeMap.get(name),
        })
      }
    } catch {
      // No workflows directory
    }

    return workflows
  }

  /**
   * Convert parsed skill to Mermaid diagram
   */
  toMermaid(skill: ParsedSkill): MermaidDiagram {
    const lines: string[] = []
    const skillId = this.sanitizeId(skill.frontmatter.name)

    // Start flowchart
    lines.push('flowchart TB')
    lines.push('')

    // Subgraph styles (using Mermaid styling)
    lines.push('  %% Node styles')
    lines.push('  classDef skill fill:#6366f1,stroke:#4f46e5,color:#fff')
    lines.push('  classDef principle fill:#818cf8,stroke:#6366f1,color:#fff')
    lines.push('  classDef workflow fill:#34d399,stroke:#10b981,color:#fff')
    lines.push('  classDef reference fill:#fbbf24,stroke:#f59e0b,color:#000')
    lines.push('  classDef routing fill:#f472b6,stroke:#ec4899,color:#fff')
    lines.push('')

    // Root skill node
    lines.push(`  ${skillId}["🎯 ${skill.frontmatter.name}"]:::skill`)
    lines.push('')

    // Principles subgraph
    if (skill.principles.length > 0) {
      lines.push('  subgraph principles["📋 Principles"]')
      lines.push('    direction LR')
      skill.principles.forEach(p => {
        const pId = `principle_${this.sanitizeId(p.name)}`
        lines.push(`    ${pId}["${this.escapeLabel(p.name)}"]:::principle`)
      })
      lines.push('  end')
      lines.push(`  ${skillId} --> principles`)
      lines.push('')
    }

    // Workflows subgraph
    if (skill.workflows.length > 0) {
      lines.push('  subgraph workflows["⚡ Workflows"]')
      lines.push('    direction LR')
      skill.workflows.forEach(w => {
        const wId = `workflow_${this.sanitizeId(w.name)}`
        const label = w.purpose ? `${w.name}\\n${this.truncate(w.purpose, 30)}` : w.name
        lines.push(`    ${wId}["${this.escapeLabel(label)}"]:::workflow`)
      })
      lines.push('  end')
      lines.push(`  ${skillId} --> workflows`)
      lines.push('')
    }

    // References subgraph
    if (skill.references.length > 0) {
      lines.push('  subgraph refs["📚 References"]')
      lines.push('    direction LR')
      skill.references.forEach(r => {
        const rId = `ref_${this.sanitizeId(r.name)}`
        lines.push(`    ${rId}["${this.escapeLabel(r.name)}"]:::reference`)
      })
      lines.push('  end')
      lines.push(`  ${skillId} --> refs`)
      lines.push('')
    }

    // Routing connections
    if (skill.routing.length > 0) {
      lines.push('  %% Routing')
      skill.routing.forEach(route => {
        if (!route.workflow) return
        const workflowName = path.basename(route.workflow.replace(/`/g, ''), '.md')
        const wId = `workflow_${this.sanitizeId(workflowName)}`
        const routeLabel = this.truncate(route.response || '', 20)
        // Only add edge if workflow exists
        if (skill.workflows.some(w => w.name === workflowName)) {
          lines.push(`  ${skillId} -->|"${this.escapeLabel(routeLabel)}"| ${wId}`)
        }
      })
      lines.push('')
    }

    return {
      source: lines.join('\n'),
      type: 'flowchart',
      metadata: {
        sourceType: 'skill',
        sourcePath: skill.frontmatter.name,
        generatedAt: new Date().toISOString(),
        version: '0.1.0',
        originalData: skill,
      },
    }
  }

  private sanitizeId(str: string): string {
    return str.replace(/[^a-zA-Z0-9]/g, '_').toLowerCase()
  }

  private escapeLabel(str: string): string {
    return str.replace(/"/g, "'").replace(/\n/g, '\\n')
  }

  private truncate(str: string, len: number): string {
    return str.length > len ? str.substring(0, len) + '...' : str
  }
}

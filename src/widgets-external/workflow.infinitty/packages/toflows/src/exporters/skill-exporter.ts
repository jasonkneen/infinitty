/**
 * Skill Exporter
 *
 * Converts Mermaid diagrams back to Claude Code skill format (SKILL.md).
 * This enables round-trip editing: parse skill → edit visually → export back to SKILL.md
 */

import type { MermaidDiagram, ParsedSkill, SkillFrontmatter, SkillPrinciple, SkillWorkflow, SkillReference, SkillRouting } from '../types.js'
import { mermaidToReactFlow } from '../mermaid/parser.js'

export interface SkillExportOptions {
  /** Include YAML frontmatter */
  includeFrontmatter?: boolean
  /** Include principle content placeholders */
  includePrinciplePlaceholders?: boolean
  /** Include workflow index table */
  includeWorkflowIndex?: boolean
}

/**
 * Export a Mermaid diagram back to SKILL.md format
 */
export function exportToSkill(
  diagram: MermaidDiagram,
  options: SkillExportOptions = {}
): string {
  const {
    includeFrontmatter = true,
    includePrinciplePlaceholders = true,
    includeWorkflowIndex = true,
  } = options

  // Parse Mermaid to get structure
  const graph = mermaidToReactFlow(diagram.source, diagram.metadata)

  // Extract skill data from nodes
  const skillData = extractSkillData(graph.nodes, graph.edges)

  // Also use original data if available
  const originalData = diagram.metadata.originalData as ParsedSkill | undefined

  const lines: string[] = []

  // YAML frontmatter
  if (includeFrontmatter) {
    const frontmatter = originalData?.frontmatter || skillData.frontmatter
    lines.push('---')
    if (frontmatter.name) lines.push(`name: "${frontmatter.name}"`)
    if (frontmatter.description) lines.push(`description: "${frontmatter.description}"`)
    const version = frontmatter.version as string | undefined
    const author = frontmatter.author as string | undefined
    const tags = frontmatter.tags as string[] | undefined
    if (version) lines.push(`version: "${version}"`)
    if (author) lines.push(`author: "${author}"`)
    if (tags && Array.isArray(tags) && tags.length > 0) {
      lines.push('tags:')
      tags.forEach(tag => lines.push(`  - ${tag}`))
    }
    lines.push('---')
    lines.push('')
  }

  // Title
  const skillName = originalData?.frontmatter?.name || skillData.frontmatter.name || 'Skill'
  lines.push(`# ${skillName}`)
  lines.push('')

  // Description
  if (originalData?.frontmatter?.description || skillData.frontmatter.description) {
    lines.push(originalData?.frontmatter?.description || skillData.frontmatter.description || '')
    lines.push('')
  }

  // Intake section (from original if available)
  if (originalData?.intake) {
    lines.push('<intake>')
    lines.push(originalData.intake)
    lines.push('</intake>')
    lines.push('')
  }

  // Principles
  const principles = originalData?.principles || skillData.principles
  if (principles.length > 0) {
    lines.push('## Principles')
    lines.push('')

    for (const principle of principles) {
      lines.push(`<principle name="${principle.name}">`)
      if (principle.content || includePrinciplePlaceholders) {
        lines.push(principle.content || `<!-- ${principle.name} principle content -->`)
      }
      lines.push('</principle>')
      lines.push('')
    }
  }

  // Workflows index
  const workflows = originalData?.workflows || skillData.workflows
  if (workflows.length > 0 && includeWorkflowIndex) {
    lines.push('## Workflows')
    lines.push('')
    lines.push('<workflows_index>')
    lines.push('')
    lines.push('| Workflow | Purpose |')
    lines.push('|----------|---------|')

    for (const workflow of workflows) {
      lines.push(`| ${workflow.name} | ${workflow.purpose || ''} |`)
    }

    lines.push('')
    lines.push('</workflows_index>')
    lines.push('')
  }

  // Routing table
  const routing = originalData?.routing || skillData.routing
  if (routing.length > 0) {
    lines.push('## Routing')
    lines.push('')
    lines.push('<routing>')
    lines.push('')
    lines.push('| Response | Workflow |')
    lines.push('|----------|----------|')

    for (const route of routing) {
      lines.push(`| ${route.response} | \`${route.workflow}\` |`)
    }

    lines.push('')
    lines.push('</routing>')
    lines.push('')
  }

  // References note
  const references = originalData?.references || skillData.references
  if (references.length > 0) {
    lines.push('## References')
    lines.push('')
    lines.push('Reference files in `references/` directory:')
    lines.push('')

    for (const ref of references) {
      lines.push(`- [${ref.name}](${ref.path})`)
    }

    lines.push('')
  }

  return lines.join('\n')
}

interface ExtractedSkillData {
  frontmatter: Partial<SkillFrontmatter>
  principles: SkillPrinciple[]
  workflows: SkillWorkflow[]
  references: SkillReference[]
  routing: SkillRouting[]
}

/**
 * Extract skill data from ReactFlow nodes/edges
 */
function extractSkillData(
  nodes: Array<{ id: string; data: Record<string, unknown>; type?: string; parentId?: string }>,
  edges: Array<{ source: string; target: string; label?: string }>
): ExtractedSkillData {
  const result: ExtractedSkillData = {
    frontmatter: {},
    principles: [],
    workflows: [],
    references: [],
    routing: [],
  }

  // Find skill root node
  const skillNode = nodes.find(n =>
    n.data.nodeType === 'skill' ||
    (n.id.includes('skill') && !n.parentId)
  )

  if (skillNode) {
    const label = String(skillNode.data.label || '')
    // Remove emoji prefix if present
    result.frontmatter.name = label.replace(/^[🎯⚡📋📚]\s*/, '')
  }

  // Find principle nodes
  const principleNodes = nodes.filter(n =>
    n.data.nodeType === 'principle' ||
    n.id.includes('principle') ||
    n.parentId?.includes('principle')
  )

  for (const node of principleNodes) {
    const label = String(node.data.label || node.id)
    result.principles.push({
      name: label.replace(/^[📋]\s*/, ''),
      content: '', // Content not preserved in Mermaid
    })
  }

  // Find workflow nodes
  const workflowNodes = nodes.filter(n =>
    n.data.nodeType === 'workflow' ||
    n.id.includes('workflow') ||
    n.parentId?.includes('workflow')
  )

  for (const node of workflowNodes) {
    const label = String(node.data.label || node.id)
    const parts = label.split('\\n')
    result.workflows.push({
      name: parts[0].replace(/^[⚡]\s*/, ''),
      path: `workflows/${parts[0].replace(/^[⚡]\s*/, '')}.md`,
      purpose: parts[1] || undefined,
    })
  }

  // Find reference nodes
  const refNodes = nodes.filter(n =>
    n.data.nodeType === 'reference' ||
    n.id.includes('ref') ||
    n.parentId?.includes('ref')
  )

  for (const node of refNodes) {
    const label = String(node.data.label || node.id)
    result.references.push({
      name: label.replace(/^[📚]\s*/, ''),
      path: `references/${label.replace(/^[📚]\s*/, '')}.md`,
    })
  }

  // Extract routing from edges with labels pointing to workflows
  const routingEdges = edges.filter(e =>
    e.label &&
    workflowNodes.some(w => w.id === e.target)
  )

  for (const edge of routingEdges) {
    const targetWorkflow = workflowNodes.find(w => w.id === edge.target)
    if (targetWorkflow) {
      const workflowName = String(targetWorkflow.data.label || '').split('\\n')[0].replace(/^[⚡]\s*/, '')
      result.routing.push({
        response: edge.label || '',
        workflow: `workflows/${workflowName}.md`,
      })
    }
  }

  return result
}

/**
 * Export multiple skills from a skills-directory diagram
 */
export function exportSkillsDirectory(diagram: MermaidDiagram): Array<{ name: string; content: string }> {
  // For skills-directory type, the originalData contains array of parsed skills
  const originalData = diagram.metadata.originalData as Array<ParsedSkill> | undefined

  if (!originalData || !Array.isArray(originalData)) {
    // Fallback: parse from Mermaid and export single skill
    return [{ name: 'skill', content: exportToSkill(diagram) }]
  }

  return originalData.map((skillData, index) => {
    const skillDiagram: MermaidDiagram = {
      source: diagram.source, // Not perfect but works for extraction
      type: 'flowchart',
      metadata: {
        ...diagram.metadata,
        sourceType: 'skill',
        originalData: skillData,
      },
    }

    return {
      name: skillData.frontmatter?.name || `skill-${index + 1}`,
      content: exportToSkill(skillDiagram),
    }
  })
}

/**
 * Export Adapters
 *
 * Convert Mermaid diagrams back to original source formats.
 * This enables round-trip editing: source → Mermaid → visual edit → back to source
 */

export { exportToSkill, exportSkillsDirectory, type SkillExportOptions } from './skill-exporter.js'

// Future exporters can be added here:
// export { exportToAgent } from './agent-exporter.js'
// export { exportToSchema } from './schema-exporter.js'
// export { exportToWorkflow } from './workflow-exporter.js'

import type { MermaidDiagram } from '../types.js'
import { exportToSkill, exportSkillsDirectory } from './skill-exporter.js'

/**
 * Auto-detect source type and export back to original format
 */
export function autoExport(diagram: MermaidDiagram): string | Array<{ name: string; content: string }> {
  const sourceType = diagram.metadata.sourceType

  switch (sourceType) {
    case 'skill':
      return exportToSkill(diagram)

    case 'skills-directory':
      return exportSkillsDirectory(diagram)

    // Future source types:
    // case 'agent':
    //   return exportToAgent(diagram)
    // case 'schema':
    //   return exportToSchema(diagram)

    default:
      throw new Error(`No exporter available for source type: ${sourceType}`)
  }
}

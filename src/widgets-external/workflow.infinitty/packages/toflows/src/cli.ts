#!/usr/bin/env node

import { program } from 'commander'
import fs from 'fs/promises'
import path from 'path'
import { toFlows, autoDetect, autoExport } from './index.js'

program
  .name('toflows')
  .description('Transform structured data into Mermaid diagrams')
  .version('0.1.0')

program
  .command('skill <path>')
  .description('Parse a single skill (directory or SKILL.md file)')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('--json', 'Output full JSON with metadata (default: just Mermaid source)')
  .action(async (skillPath: string, options: { output?: string; json?: boolean }) => {
    try {
      const resolvedPath = path.resolve(skillPath)
      const diagram = await toFlows({ type: 'skill', path: resolvedPath })
      const output = options.json
        ? JSON.stringify(diagram, null, 2)
        : diagram.source

      if (options.output) {
        await fs.writeFile(options.output, output)
        console.log(`Mermaid diagram written to ${options.output}`)
      } else {
        console.log(output)
      }
    } catch (error) {
      console.error('Error:', error instanceof Error ? error.message : error)
      process.exit(1)
    }
  })

program
  .command('skills <directory>')
  .description('Parse an entire skills directory (e.g., ~/.claude/skills)')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('--json', 'Output full JSON with metadata (default: just Mermaid source)')
  .action(async (dirPath: string, options: { output?: string; json?: boolean }) => {
    try {
      const resolvedPath = path.resolve(dirPath.replace('~', process.env.HOME || ''))
      const diagram = await toFlows({ type: 'skills-directory', path: resolvedPath })
      const output = options.json
        ? JSON.stringify(diagram, null, 2)
        : diagram.source

      if (options.output) {
        await fs.writeFile(options.output, output)
        console.log(`Mermaid diagram written to ${options.output}`)
        console.log(`  - Source type: ${diagram.metadata.sourceType}`)
      } else {
        console.log(output)
      }
    } catch (error) {
      console.error('Error:', error instanceof Error ? error.message : error)
      process.exit(1)
    }
  })

program
  .command('auto <path>')
  .description('Auto-detect source type and generate Mermaid diagram')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('--json', 'Output full JSON with metadata (default: just Mermaid source)')
  .action(async (sourcePath: string, options: { output?: string; json?: boolean }) => {
    try {
      const resolvedPath = path.resolve(sourcePath.replace('~', process.env.HOME || ''))
      const diagram = await autoDetect(resolvedPath)
      const output = options.json
        ? JSON.stringify(diagram, null, 2)
        : diagram.source

      if (options.output) {
        await fs.writeFile(options.output, output)
        console.log(`Mermaid diagram written to ${options.output}`)
        console.log(`  - Detected type: ${diagram.metadata.sourceType}`)
      } else {
        console.log(output)
      }
    } catch (error) {
      console.error('Error:', error instanceof Error ? error.message : error)
      process.exit(1)
    }
  })

// Export command - convert Mermaid back to source format
program
  .command('export <mermaidFile>')
  .description('Export a Mermaid diagram back to its original source format')
  .option('-o, --output <file>', 'Output file path (default: stdout)')
  .option('--format <format>', 'Force output format (skill, agent, schema)')
  .action(async (mermaidFile: string, options: { output?: string; format?: string }) => {
    try {
      const resolvedPath = path.resolve(mermaidFile.replace('~', process.env.HOME || ''))
      const content = await fs.readFile(resolvedPath, 'utf-8')

      // Try to parse as JSON (full diagram with metadata) or plain Mermaid
      let diagram
      try {
        diagram = JSON.parse(content)
      } catch {
        // Plain Mermaid source - need to infer metadata
        diagram = {
          source: content,
          type: 'flowchart',
          metadata: {
            sourceType: options.format || 'skill',
            sourcePath: resolvedPath,
            generatedAt: new Date().toISOString(),
            version: '0.1.0',
          },
        }
      }

      const result = autoExport(diagram)

      if (Array.isArray(result)) {
        // Multiple files (skills-directory)
        if (options.output) {
          const outputDir = path.resolve(options.output)
          await fs.mkdir(outputDir, { recursive: true })
          for (const { name, content: skillContent } of result) {
            const filePath = path.join(outputDir, `${name}/SKILL.md`)
            await fs.mkdir(path.dirname(filePath), { recursive: true })
            await fs.writeFile(filePath, skillContent)
            console.log(`  - Written: ${filePath}`)
          }
          console.log(`Exported ${result.length} skills to ${outputDir}`)
        } else {
          // Print all to stdout
          for (const { name, content: skillContent } of result) {
            console.log(`\n--- ${name} ---\n`)
            console.log(skillContent)
          }
        }
      } else {
        // Single file
        if (options.output) {
          await fs.writeFile(options.output, result)
          console.log(`Exported to ${options.output}`)
        } else {
          console.log(result)
        }
      }
    } catch (error) {
      console.error('Error:', error instanceof Error ? error.message : error)
      process.exit(1)
    }
  })

program.parse()

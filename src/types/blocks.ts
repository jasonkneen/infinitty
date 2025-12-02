export type BlockType = 'command' | 'ai-response' | 'error' | 'system' | 'interactive' | 'tool-output'

// Simple commands that don't need a full terminal (output-only)
// Everything else runs in interactive mode with a real PTY
const SIMPLE_OUTPUT_COMMANDS = [
  'ls',
  'pwd',
  'echo',
  'cat',
  'head',
  'tail',
  'wc',
  'date',
  'whoami',
  'hostname',
  'which',
  'env',
  'printenv',
  'cd',
]

export function isInteractiveCommand(command: string): boolean {
  const cmd = command.trim().split(/\s+/)[0]
  // If it's a known simple command, run it in output-only mode
  // Everything else gets a full interactive terminal
  return !SIMPLE_OUTPUT_COMMANDS.includes(cmd)
}

export interface CommandBlock {
  id: string
  type: 'command'
  command: string
  output: string
  exitCode: number | null
  startTime: Date
  endTime: Date | null
  isRunning: boolean
  cwd: string
}

export interface ToolCall {
  id: string
  name: string
  input?: Record<string, unknown>
  output?: string
  status: 'pending' | 'running' | 'completed' | 'error'
  startTime?: Date
  endTime?: Date
}

export interface AIResponseBlock {
  id: string
  type: 'ai-response'
  prompt: string
  response: string
  model: string
  provider?: string
  isStreaming: boolean
  startTime: Date
  endTime: Date | null
  tokens?: {
    input?: number
    output?: number
    reasoning?: number
    cache?: { read?: number; write?: number }
  }
  cost?: number
  duration?: number // milliseconds
  toolCalls?: ToolCall[]
  thinking?: string // Extended thinking content (if enabled)
}

export interface ErrorBlock {
  id: string
  type: 'error'
  message: string
  timestamp: Date
}

export interface ToolOutputBlock {
  id: string
  type: 'tool-output'
  toolCall: ToolCall
  parentBlockId: string
  timestamp: Date
}

export interface SystemBlock {
  id: string
  type: 'system'
  message: string
  timestamp: Date
}

export interface InteractiveBlock {
  id: string
  type: 'interactive'
  command: string
  cwd: string
  startTime: Date
  endTime: Date | null
  isRunning: boolean
  exitCode: number | null
  dismissed?: boolean // When true, show minimal status line instead of full terminal
}

export type Block = CommandBlock | AIResponseBlock | ErrorBlock | SystemBlock | InteractiveBlock | ToolOutputBlock

export function createCommandBlock(command: string, cwd: string): CommandBlock {
  return {
    id: crypto.randomUUID(),
    type: 'command',
    command,
    output: '',
    exitCode: null,
    startTime: new Date(),
    endTime: null,
    isRunning: true,
    cwd,
  }
}

export function createAIResponseBlock(prompt: string, model: string): AIResponseBlock {
  return {
    id: crypto.randomUUID(),
    type: 'ai-response',
    prompt,
    response: '',
    model,
    isStreaming: true,
    startTime: new Date(),
    endTime: null,
  }
}

export function createInteractiveBlock(command: string, cwd: string): InteractiveBlock {
  return {
    id: crypto.randomUUID(),
    type: 'interactive',
    command,
    cwd,
    startTime: new Date(),
    endTime: null,
    isRunning: true,
    exitCode: null,
  }
}

import { z } from 'zod'

// Node types
export const NodeType = z.enum(['input', 'process', 'output', 'condition', 'llm', 'code', 'tool'])
export type NodeType = z.infer<typeof NodeType>

// Provider options for LLM nodes
export const LLMProvider = z.enum(['openai', 'anthropic', 'google', 'ollama', 'custom'])
export type LLMProvider = z.infer<typeof LLMProvider>

// Input node schema
export const InputNodeDataSchema = z.object({
  source: z.enum(['user', 'file', 'api', 'variable']).default('user'),
  variableName: z.string().default(''),
  defaultValue: z.string().default(''),
})
export type InputNodeData = z.infer<typeof InputNodeDataSchema>

// Process node schema
export const ProcessNodeDataSchema = z.object({
  operation: z.enum(['transform', 'filter', 'map', 'reduce', 'custom']).default('transform'),
  expression: z.string().default(''),
})
export type ProcessNodeData = z.infer<typeof ProcessNodeDataSchema>

// Output node schema
export const OutputNodeDataSchema = z.object({
  destination: z.enum(['display', 'file', 'api', 'variable']).default('display'),
  format: z.enum(['text', 'json', 'markdown']).default('text'),
})
export type OutputNodeData = z.infer<typeof OutputNodeDataSchema>

// Condition node schema
export const ConditionNodeDataSchema = z.object({
  conditionType: z.enum(['expression', 'contains', 'equals', 'regex']).default('expression'),
  expression: z.string().default(''),
  caseSensitive: z.boolean().default(true),
})
export type ConditionNodeData = z.infer<typeof ConditionNodeDataSchema>

// LLM node schema
export const LLMNodeDataSchema = z.object({
  provider: LLMProvider.default('openai'),
  model: z.string().default('gpt-4o'),
  apiKey: z.string().default(''),
  endpoint: z.string().default(''),
  systemPrompt: z.string().default(''),
  userPrompt: z.string().default('{{input}}'),
  temperature: z.number().min(0).max(2).default(0.7),
  maxTokens: z.number().min(1).max(128000).default(4096),
  stream: z.boolean().default(true),
})
export type LLMNodeData = z.infer<typeof LLMNodeDataSchema>

// Code node schema
export const CodeNodeDataSchema = z.object({
  language: z.enum(['javascript', 'typescript', 'python', 'shell']).default('javascript'),
  code: z.string().default(''),
  timeout: z.number().min(100).max(60000).default(5000),
  sandbox: z.boolean().default(true),
})
export type CodeNodeData = z.infer<typeof CodeNodeDataSchema>

// Tool groups and tools
export const ToolGroup = z.enum(['filesystem', 'search', 'coding', 'git', 'web', 'ai', 'system'])
export type ToolGroup = z.infer<typeof ToolGroup>

export interface ToolDefinition {
  id: string
  name: string
  group: ToolGroup
  description: string
  inputs: string[]
  outputs: string[]
}

export const TOOL_DEFINITIONS: ToolDefinition[] = [
  // Filesystem
  { id: 'read_file', name: 'Read File', group: 'filesystem', description: 'Read contents of a file', inputs: ['path'], outputs: ['content'] },
  { id: 'write_file', name: 'Write File', group: 'filesystem', description: 'Write content to a file', inputs: ['path', 'content'], outputs: ['success'] },
  { id: 'list_dir', name: 'List Directory', group: 'filesystem', description: 'List files in directory', inputs: ['path'], outputs: ['files'] },
  { id: 'delete_file', name: 'Delete File', group: 'filesystem', description: 'Delete a file or directory', inputs: ['path'], outputs: ['success'] },
  { id: 'copy_file', name: 'Copy File', group: 'filesystem', description: 'Copy file to destination', inputs: ['source', 'dest'], outputs: ['success'] },
  { id: 'move_file', name: 'Move File', group: 'filesystem', description: 'Move/rename file', inputs: ['source', 'dest'], outputs: ['success'] },
  // Search
  { id: 'grep', name: 'Grep Search', group: 'search', description: 'Search file contents with regex', inputs: ['pattern', 'path'], outputs: ['matches'] },
  { id: 'glob', name: 'Glob Pattern', group: 'search', description: 'Find files by pattern', inputs: ['pattern'], outputs: ['files'] },
  { id: 'find', name: 'Find Files', group: 'search', description: 'Find files by name/type', inputs: ['name', 'type'], outputs: ['files'] },
  { id: 'ripgrep', name: 'Ripgrep', group: 'search', description: 'Fast code search', inputs: ['query', 'path'], outputs: ['results'] },
  // Coding
  { id: 'lint', name: 'Lint Code', group: 'coding', description: 'Run linter on code', inputs: ['code', 'language'], outputs: ['issues'] },
  { id: 'format', name: 'Format Code', group: 'coding', description: 'Format code with prettier', inputs: ['code', 'language'], outputs: ['formatted'] },
  { id: 'parse_ast', name: 'Parse AST', group: 'coding', description: 'Parse code to AST', inputs: ['code', 'language'], outputs: ['ast'] },
  { id: 'type_check', name: 'Type Check', group: 'coding', description: 'Run TypeScript type checker', inputs: ['path'], outputs: ['errors'] },
  { id: 'test', name: 'Run Tests', group: 'coding', description: 'Execute test suite', inputs: ['path', 'pattern'], outputs: ['results'] },
  // Git
  { id: 'git_status', name: 'Git Status', group: 'git', description: 'Get git repository status', inputs: [], outputs: ['status'] },
  { id: 'git_diff', name: 'Git Diff', group: 'git', description: 'Show git diff', inputs: ['ref'], outputs: ['diff'] },
  { id: 'git_log', name: 'Git Log', group: 'git', description: 'Show commit history', inputs: ['count'], outputs: ['commits'] },
  { id: 'git_commit', name: 'Git Commit', group: 'git', description: 'Create git commit', inputs: ['message'], outputs: ['sha'] },
  { id: 'git_branch', name: 'Git Branch', group: 'git', description: 'Manage branches', inputs: ['name', 'action'], outputs: ['result'] },
  // Web
  { id: 'fetch_url', name: 'Fetch URL', group: 'web', description: 'HTTP request to URL', inputs: ['url', 'method'], outputs: ['response'] },
  { id: 'web_search', name: 'Web Search', group: 'web', description: 'Search the web', inputs: ['query'], outputs: ['results'] },
  { id: 'scrape', name: 'Scrape Page', group: 'web', description: 'Extract data from webpage', inputs: ['url', 'selector'], outputs: ['data'] },
  // AI
  { id: 'embed', name: 'Embed Text', group: 'ai', description: 'Generate embeddings', inputs: ['text'], outputs: ['embedding'] },
  { id: 'summarize', name: 'Summarize', group: 'ai', description: 'Summarize text content', inputs: ['text', 'length'], outputs: ['summary'] },
  { id: 'classify', name: 'Classify', group: 'ai', description: 'Classify text into categories', inputs: ['text', 'categories'], outputs: ['classification'] },
  { id: 'extract', name: 'Extract Data', group: 'ai', description: 'Extract structured data', inputs: ['text', 'schema'], outputs: ['data'] },
  // System
  { id: 'shell', name: 'Run Shell', group: 'system', description: 'Execute shell command', inputs: ['command'], outputs: ['stdout', 'stderr'] },
  { id: 'env', name: 'Environment', group: 'system', description: 'Get/set env variables', inputs: ['key'], outputs: ['value'] },
  { id: 'spawn', name: 'Spawn Process', group: 'system', description: 'Spawn background process', inputs: ['command', 'args'], outputs: ['pid'] },
  { id: 'kill', name: 'Kill Process', group: 'system', description: 'Terminate process', inputs: ['pid'], outputs: ['success'] },
]

// Get tools by group
export function getToolsByGroup(group: ToolGroup): ToolDefinition[] {
  return TOOL_DEFINITIONS.filter(t => t.group === group)
}

// Get all tool groups
export function getToolGroups(): { value: ToolGroup; label: string }[] {
  return [
    { value: 'filesystem', label: 'Filesystem' },
    { value: 'search', label: 'Search' },
    { value: 'coding', label: 'Coding' },
    { value: 'git', label: 'Git' },
    { value: 'web', label: 'Web' },
    { value: 'ai', label: 'AI' },
    { value: 'system', label: 'System' },
  ]
}

// Tool node schema
export const ToolNodeDataSchema = z.object({
  toolGroup: ToolGroup.default('filesystem'),
  toolId: z.string().default('read_file'),
  config: z.record(z.string(), z.unknown()).default({}),
  timeout: z.number().min(100).max(60000).default(10000),
})
export type ToolNodeData = z.infer<typeof ToolNodeDataSchema>

// Union of all node data types
export const NodeDataSchema = z.union([
  InputNodeDataSchema,
  ProcessNodeDataSchema,
  OutputNodeDataSchema,
  ConditionNodeDataSchema,
  LLMNodeDataSchema,
  CodeNodeDataSchema,
  ToolNodeDataSchema,
])
export type NodeData = z.infer<typeof NodeDataSchema>

// Map node type to its schema
export const NODE_DATA_SCHEMAS: Record<NodeType, z.ZodObject<z.ZodRawShape>> = {
  input: InputNodeDataSchema,
  process: ProcessNodeDataSchema,
  output: OutputNodeDataSchema,
  condition: ConditionNodeDataSchema,
  llm: LLMNodeDataSchema,
  code: CodeNodeDataSchema,
  tool: ToolNodeDataSchema,
}

// Parse and validate node data with defaults
export function parseNodeData<T extends NodeType>(
  nodeType: T,
  data: unknown
): z.infer<typeof NODE_DATA_SCHEMAS[T]> {
  const schema = NODE_DATA_SCHEMAS[nodeType]
  try {
    return schema.parse(data ?? {})
  } catch (error) {
    // Return defaults if parsing fails
    return schema.parse({})
  }
}

// Validate node data and return result with errors
export function validateNodeData<T extends NodeType>(
  nodeType: T,
  data: unknown
): { success: true; data: z.infer<typeof NODE_DATA_SCHEMAS[T]> } | { success: false; errors: z.ZodError } {
  const schema = NODE_DATA_SCHEMAS[nodeType]
  const result = schema.safeParse(data ?? {})
  if (result.success) {
    return { success: true, data: result.data }
  }
  return { success: false, errors: result.error }
}

// Get default data for a node type
export function getDefaultNodeData<T extends NodeType>(nodeType: T): z.infer<typeof NODE_DATA_SCHEMAS[T]> {
  return NODE_DATA_SCHEMAS[nodeType].parse({})
}

// Attribute types for UI rendering
export type AttributeType = 'text' | 'textarea' | 'number' | 'select' | 'checkbox' | 'radio' | 'slider' | 'button'

export interface AttributeOption {
  label: string
  value: string
}

export interface AttributeSchema {
  key: string
  label: string
  type: AttributeType
  placeholder?: string
  defaultValue?: unknown
  options?: AttributeOption[]
  min?: number
  max?: number
  step?: number
  rows?: number
  buttonAction?: string
  group?: string
}

// UI schemas for rendering forms (derived from Zod schemas)
export const NODE_UI_SCHEMAS: Record<NodeType, AttributeSchema[]> = {
  input: [
    {
      key: 'source',
      label: 'Input Source',
      type: 'select',
      options: [
        { label: 'User Input', value: 'user' },
        { label: 'File', value: 'file' },
        { label: 'API', value: 'api' },
        { label: 'Variable', value: 'variable' },
      ],
      defaultValue: 'user',
    },
    { key: 'variableName', label: 'Variable Name', type: 'text', placeholder: 'input_data' },
    { key: 'defaultValue', label: 'Default Value', type: 'textarea', rows: 2 },
  ],
  process: [
    {
      key: 'operation',
      label: 'Operation',
      type: 'select',
      options: [
        { label: 'Transform', value: 'transform' },
        { label: 'Filter', value: 'filter' },
        { label: 'Map', value: 'map' },
        { label: 'Reduce', value: 'reduce' },
        { label: 'Custom', value: 'custom' },
      ],
      defaultValue: 'transform',
    },
    { key: 'expression', label: 'Expression', type: 'textarea', placeholder: 'data => data.toUpperCase()', rows: 3 },
  ],
  output: [
    {
      key: 'destination',
      label: 'Output Destination',
      type: 'select',
      options: [
        { label: 'Display', value: 'display' },
        { label: 'File', value: 'file' },
        { label: 'API', value: 'api' },
        { label: 'Variable', value: 'variable' },
      ],
      defaultValue: 'display',
    },
    {
      key: 'format',
      label: 'Format',
      type: 'select',
      options: [
        { label: 'Text', value: 'text' },
        { label: 'JSON', value: 'json' },
        { label: 'Markdown', value: 'markdown' },
      ],
      defaultValue: 'text',
    },
  ],
  condition: [
    {
      key: 'conditionType',
      label: 'Condition Type',
      type: 'select',
      options: [
        { label: 'Expression', value: 'expression' },
        { label: 'Contains', value: 'contains' },
        { label: 'Equals', value: 'equals' },
        { label: 'Regex', value: 'regex' },
      ],
      defaultValue: 'expression',
    },
    { key: 'expression', label: 'Condition', type: 'textarea', placeholder: 'data.length > 0', rows: 2 },
    { key: 'caseSensitive', label: 'Case Sensitive', type: 'checkbox', defaultValue: true },
  ],
  llm: [
    {
      key: 'provider',
      label: 'Provider',
      type: 'select',
      options: [
        { label: 'OpenAI', value: 'openai' },
        { label: 'Anthropic', value: 'anthropic' },
        { label: 'Google', value: 'google' },
        { label: 'Ollama', value: 'ollama' },
        { label: 'Custom', value: 'custom' },
      ],
      defaultValue: 'openai',
      group: 'Provider',
    },
    {
      key: 'model',
      label: 'Model',
      type: 'select',
      options: [
        { label: 'GPT-4o', value: 'gpt-4o' },
        { label: 'GPT-4o Mini', value: 'gpt-4o-mini' },
        { label: 'Claude 3.5 Sonnet', value: 'claude-3-5-sonnet-20241022' },
        { label: 'Claude 3 Haiku', value: 'claude-3-haiku-20240307' },
        { label: 'Gemini Pro', value: 'gemini-pro' },
      ],
      defaultValue: 'gpt-4o',
      group: 'Provider',
    },
    { key: 'apiKey', label: 'API Key', type: 'text', placeholder: 'sk-...', group: 'Provider' },
    { key: 'endpoint', label: 'Endpoint (Optional)', type: 'text', placeholder: 'https://api.openai.com/v1', group: 'Provider' },
    { key: 'systemPrompt', label: 'System Prompt', type: 'textarea', placeholder: 'You are a helpful assistant...', rows: 3, group: 'Prompts' },
    { key: 'userPrompt', label: 'User Prompt Template', type: 'textarea', placeholder: '{{input}}', rows: 2, group: 'Prompts' },
    { key: 'temperature', label: 'Temperature', type: 'slider', min: 0, max: 2, step: 0.1, defaultValue: 0.7, group: 'Settings' },
    { key: 'maxTokens', label: 'Max Tokens', type: 'number', min: 1, max: 128000, defaultValue: 4096, group: 'Settings' },
    { key: 'stream', label: 'Stream Response', type: 'checkbox', defaultValue: true, group: 'Settings' },
  ],
  code: [
    {
      key: 'language',
      label: 'Language',
      type: 'select',
      options: [
        { label: 'JavaScript', value: 'javascript' },
        { label: 'TypeScript', value: 'typescript' },
        { label: 'Python', value: 'python' },
        { label: 'Shell', value: 'shell' },
      ],
      defaultValue: 'javascript',
    },
    { key: 'code', label: 'Code', type: 'textarea', placeholder: '// Your code here\nreturn input;', rows: 6 },
    { key: 'timeout', label: 'Timeout (ms)', type: 'number', min: 100, max: 60000, defaultValue: 5000 },
    { key: 'sandbox', label: 'Run in Sandbox', type: 'checkbox', defaultValue: true },
  ],
  tool: [
    {
      key: 'toolGroup',
      label: 'Tool Group',
      type: 'select',
      options: [
        { label: 'Filesystem', value: 'filesystem' },
        { label: 'Search', value: 'search' },
        { label: 'Coding', value: 'coding' },
        { label: 'Git', value: 'git' },
        { label: 'Web', value: 'web' },
        { label: 'AI', value: 'ai' },
        { label: 'System', value: 'system' },
      ],
      defaultValue: 'filesystem',
      group: 'Tool',
    },
    {
      key: 'toolId',
      label: 'Tool',
      type: 'select',
      options: [], // Dynamic - will be populated based on toolGroup
      defaultValue: 'read_file',
      group: 'Tool',
    },
    { key: 'timeout', label: 'Timeout (ms)', type: 'number', min: 100, max: 60000, defaultValue: 10000, group: 'Settings' },
  ],
}

// Serialize node data to JSON string
export function serializeNodeData(nodeType: NodeType, data: unknown): string {
  const parsed = parseNodeData(nodeType, data)
  return JSON.stringify(parsed, null, 2)
}

// Deserialize JSON string to validated node data
export function deserializeNodeData<T extends NodeType>(
  nodeType: T,
  json: string
): { success: true; data: z.infer<typeof NODE_DATA_SCHEMAS[T]> } | { success: false; error: string } {
  try {
    const parsed = JSON.parse(json)
    const result = validateNodeData(nodeType, parsed)
    if (result.success) {
      return { success: true, data: result.data }
    }
    return { success: false, error: result.errors.message }
  } catch (e) {
    return { success: false, error: e instanceof Error ? e.message : 'Invalid JSON' }
  }
}

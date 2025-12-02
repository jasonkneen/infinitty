// Provider and Model Types for AI Integration

export type ProviderType =
  | 'opencode'
  | 'anthropic'
  | 'openai'
  | 'claude-code'
  | 'codex'
  | 'cursor'
  | 'kilo-code'
  | 'local'

export interface ProviderModel {
  id: string
  name: string
  description?: string
  contextWindow?: number
  supportsStreaming?: boolean
  supportsTools?: boolean
  supportsVision?: boolean
  costPerInputToken?: number
  costPerOutputToken?: number
}

export interface Provider {
  id: ProviderType
  name: string
  description: string
  icon?: string
  isAgent?: boolean // True for CLI agents like opencode, claude-code
  requiresApiKey?: boolean
  apiKeyEnvVar?: string
  models: ProviderModel[]
  defaultModel?: string
}

// Default providers configuration
export const PROVIDERS: Provider[] = [
  {
    id: 'opencode',
    name: 'OpenCode',
    description: 'OpenCode CLI Agent',
    isAgent: true,
    models: [
      { id: 'auto', name: 'Auto', description: 'Automatically select best model' },
      { id: 'gpt-4o', name: 'GPT-4o', supportsVision: true, supportsTools: true },
      { id: 'gpt-4o-mini', name: 'GPT-4o Mini', supportsTools: true },
      { id: 'claude-3-5-sonnet', name: 'Claude 3.5 Sonnet', supportsTools: true },
      { id: 'claude-3-5-haiku', name: 'Claude 3.5 Haiku', supportsTools: true },
    ],
    defaultModel: 'auto',
  },
  {
    id: 'claude-code',
    name: 'Claude Code',
    description: 'Anthropic Claude Code Agent (via CLI)',
    isAgent: true,
    models: [
      { id: 'sonnet', name: 'Claude Sonnet', supportsTools: true, supportsVision: true },
      { id: 'opus', name: 'Claude Opus', supportsTools: true, supportsVision: true },
      { id: 'haiku', name: 'Claude Haiku', supportsTools: true },
    ],
    defaultModel: 'sonnet',
  },
  {
    id: 'anthropic',
    name: 'Anthropic',
    description: 'Direct Anthropic API',
    requiresApiKey: true,
    apiKeyEnvVar: 'ANTHROPIC_API_KEY',
    models: [
      { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', supportsTools: true, supportsVision: true },
      { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', supportsTools: true, supportsVision: true },
      { id: 'claude-3-5-sonnet-20241022', name: 'Claude 3.5 Sonnet', supportsTools: true, supportsVision: true },
      { id: 'claude-3-5-haiku-20241022', name: 'Claude 3.5 Haiku', supportsTools: true },
    ],
    defaultModel: 'claude-sonnet-4-20250514',
  },
  {
    id: 'openai',
    name: 'OpenAI',
    description: 'Direct OpenAI API',
    requiresApiKey: true,
    apiKeyEnvVar: 'OPENAI_API_KEY',
    models: [
      { id: 'gpt-4o', name: 'GPT-4o', supportsTools: true, supportsVision: true },
      { id: 'gpt-4o-mini', name: 'GPT-4o Mini', supportsTools: true, supportsVision: true },
      { id: 'gpt-4-turbo', name: 'GPT-4 Turbo', supportsTools: true, supportsVision: true },
      { id: 'o1', name: 'o1', description: 'Reasoning model' },
      { id: 'o1-mini', name: 'o1 Mini', description: 'Fast reasoning model' },
    ],
    defaultModel: 'gpt-4o',
  },
  {
    id: 'codex',
    name: 'Codex',
    description: 'OpenAI Codex Agent',
    isAgent: true,
    models: [
      { id: 'codex-default', name: 'Default', description: 'Default Codex model' },
    ],
    defaultModel: 'codex-default',
  },
  {
    id: 'cursor',
    name: 'Cursor',
    description: 'Cursor AI Agent',
    isAgent: true,
    models: [
      { id: 'cursor-default', name: 'Default', description: 'Default Cursor model' },
    ],
    defaultModel: 'cursor-default',
  },
  {
    id: 'kilo-code',
    name: 'Kilo Code',
    description: 'Kilo Code Agent',
    isAgent: true,
    models: [
      { id: 'kilo-default', name: 'Default', description: 'Default Kilo model' },
    ],
    defaultModel: 'kilo-default',
  },
  {
    id: 'local',
    name: 'Local',
    description: 'Local LLM (Ollama)',
    models: [
      { id: 'llama3.2', name: 'Llama 3.2', description: 'Meta Llama 3.2' },
      { id: 'codellama', name: 'Code Llama', description: 'Code-specialized Llama' },
      { id: 'deepseek-coder', name: 'DeepSeek Coder', description: 'DeepSeek coding model' },
    ],
    defaultModel: 'llama3.2',
  },
]

export function getProvider(id: ProviderType): Provider | undefined {
  return PROVIDERS.find(p => p.id === id)
}

export function getProviderModels(providerId: ProviderType): ProviderModel[] {
  const provider = getProvider(providerId)
  return provider?.models ?? []
}

export function getDefaultModel(providerId: ProviderType): string | undefined {
  const provider = getProvider(providerId)
  return provider?.defaultModel
}

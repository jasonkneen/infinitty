// Provider and Model Types for AI Integration

export type ProviderType =
  | 'opencode'
  | 'anthropic'
  | 'openai'
  | 'claude-code'
  | 'codex'
  | 'cursor'
  | 'kilo-code'
  | 'ollama'
  | 'lmstudio'

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
  isDynamic?: boolean // True for providers that fetch models dynamically (Ollama, LM Studio)
  models: ProviderModel[]
  defaultModel?: string
}

// Fetch models from Ollama
export async function fetchOllamaModels(baseUrl: string = 'http://localhost:11434'): Promise<ProviderModel[]> {
  try {
    const response = await fetch(`${baseUrl}/api/tags`)
    if (!response.ok) {
      console.error('[Ollama] Failed to fetch models:', response.status)
      return []
    }
    const data = await response.json()
    // Ollama returns { models: [{ name, modified_at, size, ... }] }
    return (data.models || []).map((m: { name: string; size?: number }) => ({
      id: m.name,
      name: m.name,
      description: m.size ? `${(m.size / 1e9).toFixed(1)}GB` : undefined,
    }))
  } catch (error) {
    console.error('[Ollama] Error fetching models:', error)
    return []
  }
}

// Fetch models from LM Studio
export async function fetchLMStudioModels(baseUrl: string = 'http://localhost:1234'): Promise<ProviderModel[]> {
  try {
    const response = await fetch(`${baseUrl}/v1/models`)
    if (!response.ok) {
      console.error('[LM Studio] Failed to fetch models:', response.status)
      return []
    }
    const data = await response.json()
    // LM Studio uses OpenAI-compatible API: { data: [{ id, object, owned_by, ... }] }
    return (data.data || []).map((m: { id: string; owned_by?: string }) => ({
      id: m.id,
      name: m.id,
      description: m.owned_by || 'LM Studio model',
    }))
  } catch (error) {
    console.error('[LM Studio] Error fetching models:', error)
    return []
  }
}

// Default providers configuration
export const PROVIDERS: Provider[] = [
  {
    id: 'opencode',
    name: 'OpenCode',
    description: 'OpenCode CLI Agent',
    isAgent: true,
    models: [
      { id: 'claude-3-5-sonnet', name: 'Claude 3.5 Sonnet', supportsTools: true, supportsVision: true },
      { id: 'claude-3-5-haiku', name: 'Claude 3.5 Haiku', supportsTools: true },
      { id: 'gpt-4o', name: 'GPT-4o', supportsVision: true, supportsTools: true },
      { id: 'gpt-4o-mini', name: 'GPT-4o Mini', supportsTools: true },
    ],
    defaultModel: 'claude-3-5-sonnet',
  },
  {
    id: 'claude-code',
    name: 'Claude Code',
    description: 'Anthropic Claude Code Agent (via CLI)',
    isAgent: true,
    models: [
      { id: 'haiku', name: 'Claude Haiku', supportsTools: true },
      { id: 'sonnet', name: 'Claude Sonnet', supportsTools: true, supportsVision: true },
      { id: 'opus', name: 'Claude Opus', supportsTools: true, supportsVision: true },
    ],
    defaultModel: 'haiku',
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
      { id: 'o4-mini', name: 'o4-mini', description: 'Fast and efficient' },
      { id: 'o3', name: 'o3', description: 'Most capable reasoning' },
      { id: 'gpt-4.1', name: 'GPT-4.1', description: 'Latest GPT-4 variant' },
    ],
    defaultModel: 'o4-mini',
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
    id: 'ollama',
    name: 'Ollama',
    description: 'Local Ollama models',
    isDynamic: true,
    models: [], // Fetched dynamically
    defaultModel: 'llama3.2',
  },
  {
    id: 'lmstudio',
    name: 'LM Studio',
    description: 'LM Studio local models',
    isDynamic: true,
    models: [], // Fetched dynamically
    defaultModel: 'default',
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

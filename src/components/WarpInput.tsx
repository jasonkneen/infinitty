import { useEffect, useRef, useState, useMemo, useCallback } from 'react'
import { createPortal } from 'react-dom'
import {
  MessageSquare,
  FolderOpen,
  Terminal,
  Sparkles,
  Send,
  ChevronRight,
  Slash,
  AtSign,
  Mic,
  Paperclip,
  Plus,
  Clock,
  Check,
  ClipboardList,
  Shield,
  Server,
  Lightbulb,
  Bot,
  X,
  Hash,
  Brain,
  File,
  Code,
} from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { detectNaturalLanguage, detectCLICommand } from '../hooks/useInputInterception'
import { PROVIDERS, getProviderModels, fetchOllamaModels, fetchLMStudioModels, type Provider, type ProviderType, type ProviderModel } from '../types/providers'
import { getProvidersAndModels, listSessions, type OpenCodeProvider, type OpenCodeSessionInfo } from '../services/opencode'
import { type ThinkingLevel, getThinkingLevelLabel } from '../services/claudecode'

// Context block reference for ghost chips
interface ContextBlock {
  id: string
  label: string
  type: string
}

// Custom context chip for hashtag-based context (e.g., #aisdk)
interface CustomContextChip {
  id: string
  tag: string
  enabled: boolean
}

// Event for opening the sessions picker from outside
export const OPEN_SESSIONS_PICKER_EVENT = 'open-sessions-picker'

export function triggerOpenSessionsPicker() {
  window.dispatchEvent(new CustomEvent(OPEN_SESSIONS_PICKER_EVENT))
}

// Event for opening the model picker from outside
export const OPEN_MODEL_PICKER_EVENT = 'open-model-picker'

export function triggerOpenModelPicker() {
  window.dispatchEvent(new CustomEvent(OPEN_MODEL_PICKER_EVENT))
}

// Storage keys for persisting provider/model selection
const STORAGE_KEY_PROVIDER = 'warp-input-provider'
const STORAGE_KEY_MODEL = 'warp-input-model'

// Default provider and model
const DEFAULT_PROVIDER_ID = 'opencode'
const DEFAULT_MODEL_ID = 'claude-4-5-haiku'

function getInitialProvider(): Provider {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_PROVIDER)
    if (stored) {
      const provider = PROVIDERS.find(p => p.id === stored)
      if (provider) return provider
    }
  } catch { /* ignore */ }
  // Default to opencode provider
  return PROVIDERS.find(p => p.id === DEFAULT_PROVIDER_ID) || PROVIDERS[0]
}

function getInitialModelId(provider: Provider): string {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_MODEL)
    if (stored) {
      // For opencode, we'll validate against dynamic models later, just use stored
      // For other providers, verify model exists
      const modelExists = provider.models.some(m => m.id === stored)
      if (modelExists) return stored
      // For opencode, trust the stored value (dynamic models loaded later)
      if (provider.id === 'opencode') return stored
    }
  } catch { /* ignore */ }
  // Default to claude-4-5-haiku for opencode, otherwise provider default
  if (provider.id === DEFAULT_PROVIDER_ID) return DEFAULT_MODEL_ID
  return provider.defaultModel || provider.models[0]?.id || DEFAULT_MODEL_ID
}

interface WarpInputProps {
  onSubmit: (command: string, isAI: boolean, providerId?: ProviderType, modelId?: string, contextBlocks?: ContextBlock[], thinkingLevel?: ThinkingLevel) => void
  onModelChange?: (modelId: string) => void
  onProviderChange?: (providerId: ProviderType) => void
  onInputFocus?: () => void
  pendingContextBlock?: ContextBlock | null
  onClearPendingContext?: () => void
  onConfirmContext?: () => void
  confirmedContextBlocks?: ContextBlock[]
  onRemoveConfirmedContext?: (blockId: string) => void
  onSessionSelect?: (sessionId: string) => void
}

const MODELS = [
  { id: 'claude-4-sonnet', name: 'Claude 4 Sonnet', description: 'Anthropic' },
  { id: 'claude-4.5-sonnet', name: 'Claude 4.5 Sonnet', description: 'Anthropic' },
  { id: 'claude-4.5-sonnet-thinking', name: 'Claude 4.5 Sonnet (thinking)', description: 'Extended thinking' },
  { id: 'claude-4.5-haiku', name: 'Claude 4.5 Haiku', description: 'Fast, efficient' },
  { id: 'claude-4.5-opus', name: 'Claude 4.5 Opus', description: 'Most capable' },
  { id: 'claude-4.5-opus-thinking', name: 'Claude 4.5 Opus (thinking)', description: 'Extended thinking' },
  { id: 'gpt-4o', name: 'GPT-4o', description: 'OpenAI' },
  { id: 'gpt-4o-mini', name: 'GPT-4o Mini', description: 'OpenAI, fast' },
  { id: 'gpt-5.1-low', name: 'GPT-5.1 (low reasoning)', description: 'Fast, cost-effective' },
  { id: 'gpt-5.1-medium', name: 'GPT-5.1 (medium reasoning)', description: 'Balanced performance' },
  { id: 'gpt-5.1-high', name: 'GPT-5.1 (high reasoning)', description: 'Best quality' },
  { id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro', description: 'Google' },
  { id: 'gemini-3-pro', name: 'Gemini 3 Pro', description: 'Google' },
]

type InputSize = 'small' | 'medium' | 'large'
const INPUT_SIZES: Record<InputSize, { rows: number; minHeight: string }> = {
  small: { rows: 2, minHeight: '48px' },
  medium: { rows: 5, minHeight: '120px' },
  large: { rows: 10, minHeight: '240px' },
}

export function WarpInput({
  onSubmit,
  onModelChange,
  onProviderChange,
  onInputFocus,
  pendingContextBlock,
  onClearPendingContext,
  onConfirmContext,
  confirmedContextBlocks = [],
  onRemoveConfirmedContext,
  onSessionSelect,
}: WarpInputProps) {
  const { settings } = useTerminalSettings()
  const [input, setInput] = useState('')
  const [selectedProvider, setSelectedProvider] = useState<Provider>(getInitialProvider)
  const [selectedModelId, setSelectedModelId] = useState(() => getInitialModelId(getInitialProvider()))
  const [showProviderPicker, setShowProviderPicker] = useState(false)
  const [showModelPicker, setShowModelPicker] = useState(false)
  const [showThinkingPicker, setShowThinkingPicker] = useState(false)
  const [isAIMode, setIsAIMode] = useState(true)
  const [thinkingLevel, setThinkingLevel] = useState<ThinkingLevel>('none')
  const [inputSize, setInputSize] = useState<InputSize>('small')
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const conversationBtnRef = useRef<HTMLDivElement>(null)
  const slashBtnRef = useRef<HTMLDivElement>(null)
  const mentionsBtnRef = useRef<HTMLDivElement>(null)
  const providerBtnRef = useRef<HTMLDivElement>(null)
  const modelBtnRef = useRef<HTMLDivElement>(null)
  const thinkingBtnRef = useRef<HTMLDivElement>(null)
  const [overlay, setOverlay] = useState<'conversations' | 'slash' | 'mentions' | null>(null)
  const [openCodeProviders, setOpenCodeProviders] = useState<OpenCodeProvider[]>([])
  const [ollamaModels, setOllamaModels] = useState<ProviderModel[]>([])
  const [lmStudioModels, setLMStudioModels] = useState<ProviderModel[]>([])
  const [customContextChips, setCustomContextChips] = useState<CustomContextChip[]>([])

  // Listen for external trigger to open sessions picker
  useEffect(() => {
    const handleOpenSessions = () => {
      setOverlay('conversations')
    }
    window.addEventListener(OPEN_SESSIONS_PICKER_EVENT, handleOpenSessions)
    return () => window.removeEventListener(OPEN_SESSIONS_PICKER_EVENT, handleOpenSessions)
  }, [])

  // Listen for external trigger to open model picker
  useEffect(() => {
    const handleOpenModel = () => {
      setShowModelPicker(true)
    }
    window.addEventListener(OPEN_MODEL_PICKER_EVENT, handleOpenModel)
    return () => window.removeEventListener(OPEN_MODEL_PICKER_EVENT, handleOpenModel)
  }, [])

  // Fetch OpenCode providers/models when needed
  const fetchOpenCodeModels = useCallback(async () => {
    if (openCodeProviders.length > 0) return // Already loaded
    try {
      const { providers } = await getProvidersAndModels()
      setOpenCodeProviders(providers)
    } catch (error) {
      console.error('Failed to fetch OpenCode models:', error)
    }
  }, [openCodeProviders.length])

  // Fetch Ollama models
  const fetchOllamaModelList = useCallback(async () => {
    if (ollamaModels.length > 0) return // Already loaded
    const models = await fetchOllamaModels(settings.providers.ollamaUrl)
    setOllamaModels(models)
  }, [ollamaModels.length, settings.providers.ollamaUrl])

  // Fetch LM Studio models
  const fetchLMStudioModelList = useCallback(async () => {
    if (lmStudioModels.length > 0) return // Already loaded
    const models = await fetchLMStudioModels(settings.providers.lmStudioUrl)
    setLMStudioModels(models)
  }, [lmStudioModels.length, settings.providers.lmStudioUrl])

  // Fetch OpenCode models when provider is opencode
  useEffect(() => {
    if (selectedProvider.id === 'opencode') {
      fetchOpenCodeModels()
    } else if (selectedProvider.id === 'ollama') {
      fetchOllamaModelList()
    } else if (selectedProvider.id === 'lmstudio') {
      fetchLMStudioModelList()
    }
  }, [selectedProvider.id, fetchOpenCodeModels, fetchOllamaModelList, fetchLMStudioModelList])

  // Get models for current provider (use dynamic models if available)
  const providerModels = useMemo((): ProviderModel[] => {
    if (selectedProvider.id === 'opencode' && openCodeProviders.length > 0) {
      // Flatten all OpenCode provider models into a list (no Auto option)
      const models: ProviderModel[] = []
      for (const provider of openCodeProviders) {
        for (const model of provider.models) {
          models.push({
            id: `${provider.id}/${model.id}`,  // Include provider ID in model ID
            name: model.name,
            description: provider.name,
          })
        }
      }
      return models
    }
    if (selectedProvider.id === 'ollama') {
      return ollamaModels.length > 0 ? ollamaModels : [{ id: 'loading', name: 'Loading models...', description: 'Connecting to Ollama' }]
    }
    if (selectedProvider.id === 'lmstudio') {
      return lmStudioModels.length > 0 ? lmStudioModels : [{ id: 'loading', name: 'Loading models...', description: 'Connecting to LM Studio' }]
    }
    return getProviderModels(selectedProvider.id)
  }, [selectedProvider.id, openCodeProviders, ollamaModels, lmStudioModels])

  const selectedModel = providerModels.find(m => m.id === selectedModelId) || providerModels[0]

  // Handle provider change
  const handleProviderChange = (provider: Provider) => {
    setSelectedProvider(provider)
    const newModelId = provider.id === DEFAULT_PROVIDER_ID 
      ? DEFAULT_MODEL_ID 
      : (provider.defaultModel || provider.models[0]?.id || 'auto')
    setSelectedModelId(newModelId)
    setShowProviderPicker(false)
    // Persist selection
    try {
      localStorage.setItem(STORAGE_KEY_PROVIDER, provider.id)
      localStorage.setItem(STORAGE_KEY_MODEL, newModelId)
    } catch { /* ignore */ }
    onProviderChange?.(provider.id)
  }

  // Handle model change
  const handleModelChange = (modelId: string) => {
    setSelectedModelId(modelId)
    setShowModelPicker(false)
    // Persist selection
    try {
      localStorage.setItem(STORAGE_KEY_MODEL, modelId)
    } catch { /* ignore */ }
    onModelChange?.(modelId)
  }

  const cycleInputSize = () => {
    setInputSize(prev => {
      if (prev === 'small') return 'medium'
      if (prev === 'medium') return 'large'
      return 'small'
    })
  }

  // Custom context chip management
  const addCustomContextChip = (tag: string) => {
    const normalizedTag = tag.toLowerCase().replace(/^#/, '')
    if (!normalizedTag) return
    // Don't add duplicates
    if (customContextChips.some(c => c.tag === normalizedTag)) return
    setCustomContextChips(prev => [...prev, {
      id: `custom-${Date.now()}-${normalizedTag}`,
      tag: normalizedTag,
      enabled: true,
    }])
  }

  const toggleCustomContextChip = (id: string) => {
    setCustomContextChips(prev => prev.map(chip =>
      chip.id === id ? { ...chip, enabled: !chip.enabled } : chip
    ))
  }

  const removeCustomContextChip = (id: string) => {
    setCustomContextChips(prev => prev.filter(chip => chip.id !== id))
  }

  // Detect hashtags in input and extract them
  const extractHashtags = (text: string): string[] => {
    const hashtagRegex = /#(\w+)/g
    const matches: string[] = []
    let match
    while ((match = hashtagRegex.exec(text)) !== null) {
      matches.push(match[1])
    }
    return matches
  }

  // Natural language detection
  const nlDetection = useMemo(() => detectNaturalLanguage(input), [input])
  const showNLHint = !isAIMode && nlDetection.isNaturalLanguage && nlDetection.confidence >= 0.6

  // CLI command detection with auto-mode switching
  const cliDetection = useMemo(() => detectCLICommand(input), [input])

  // Auto-switch modes based on detection (but don't fight user's explicit mode choice)
  useEffect(() => {
    if (cliDetection.forceTerminal && isAIMode) {
      setIsAIMode(false)
    } else if (cliDetection.forceAI && !isAIMode) {
      setIsAIMode(true)
    } else if (cliDetection.isCLICommand && isAIMode && cliDetection.confidence >= 0.7 && !cliDetection.forceAI) {
      // Auto-switch to terminal mode for high-confidence CLI commands
      setIsAIMode(false)
    }
  }, [cliDetection.forceTerminal, cliDetection.forceAI, cliDetection.isCLICommand, cliDetection.confidence, isAIMode])

  const handleSubmit = () => {
    if (!input.trim()) return

    // Extract hashtags and add them as custom context chips
    const hashtags = extractHashtags(input)
    hashtags.forEach(tag => addCustomContextChip(tag))

    // Remove hashtags from the input for the actual command
    const inputWithoutHashtags = input.replace(/#\w+/g, '').trim()

    // Use cleaned input (without ! or ? prefix) and determine mode from detection
    const finalInput = cliDetection.cleanedInput
      ? cliDetection.cleanedInput.replace(/#\w+/g, '').trim()
      : inputWithoutHashtags

    // If only hashtags were entered, don't submit
    if (!finalInput) {
      setInput('')
      return
    }

    const finalIsAI = cliDetection.forceAI || (!cliDetection.forceTerminal && isAIMode)
    // Include confirmed context blocks if sending to AI
    const contextBlocks = finalIsAI && confirmedContextBlocks.length > 0 ? confirmedContextBlocks : undefined
    // Pass thinking level only for Claude Code
    const finalThinkingLevel = selectedProvider.id === 'claude-code' ? thinkingLevel : undefined
    onSubmit(finalInput, finalIsAI, selectedProvider.id, selectedModelId, contextBlocks, finalThinkingLevel)
    setInput('')
    // Focus back on textarea after submission
    requestAnimationFrame(() => {
      textareaRef.current?.focus()
    })
  }


  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      handleSubmit()
    }
    // Tab to switch to AI mode when natural language is detected
    if (event.key === 'Tab' && showNLHint) {
      event.preventDefault()
      setIsAIMode(true)
    }
    // Escape to clear pending context block
    if (event.key === 'Escape' && pendingContextBlock) {
      event.preventDefault()
      onClearPendingContext?.()
    }
  }

  // Clear pending context when user starts typing
  const handleInputChange = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    const nextValue = event.target.value
    setInput(nextValue)
    // Clear pending context if user types - they've moved on
    if (pendingContextBlock && nextValue !== input) {
      onClearPendingContext?.()
    }

    // Lightweight inline triggers for @ and / to open pickers
    const triggerMatch = nextValue.match(/(?:^|\\s)([@/])(\\w*)$/)
    if (triggerMatch) {
      const symbol = triggerMatch[1]
      if (symbol === '@') {
        setOverlay('mentions')
      } else if (symbol === '/') {
        setOverlay('slash')
      }
    }
  }

  useEffect(() => {
    if (!textareaRef.current) return
    textareaRef.current.style.height = 'auto'
    textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 140) + 'px'
    textareaRef.current.style.overflowY = textareaRef.current.scrollHeight > 140 ? 'auto' : 'hidden'
  }, [input])

  useEffect(() => {
    const handleOutside = () => {
      setShowModelPicker(false)
      setShowProviderPicker(false)
      setShowThinkingPicker(false)
    }
    if (!showModelPicker && !showProviderPicker && !showThinkingPicker) return
    document.addEventListener('click', handleOutside)
    return () => document.removeEventListener('click', handleOutside)
  }, [showModelPicker, showProviderPicker, showThinkingPicker])

  useEffect(() => {
    if (!overlay) return
    const closeOnEsc = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setOverlay(null)
      }
    }
    window.addEventListener('keydown', closeOnEsc)
    return () => window.removeEventListener('keydown', closeOnEsc)
  }, [overlay])

  const displayModelName = selectedModel.name

  // Helper to get button position for portal rendering
  const getButtonPosition = (ref: React.RefObject<HTMLDivElement | null>) => {
    if (!ref.current) return { top: 0, left: 0 }
    const rect = ref.current.getBoundingClientRect()
    return { top: rect.top, left: rect.left, right: rect.right, bottom: rect.bottom }
  }

  return (
    <>
    <div style={{
      position: 'relative',
      padding: '12px',
      // Ensure it's above the blurred background
      zIndex: 10,
    }}>
      {/* Backdrop for closing dropdowns - portaled to escape stacking context */}
      {(overlay || showModelPicker || showProviderPicker || showThinkingPicker) && createPortal(
        <div
          style={{ position: 'fixed', inset: 0, zIndex: 999998 }}
          onClick={() => { setOverlay(null); setShowModelPicker(false); setShowProviderPicker(false); setShowThinkingPicker(false) }}
        />,
        document.body
      )}

      {/* Main input container */}
      <div
        style={{
          backgroundColor: 'transparent',
          backdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
          WebkitBackdropFilter: settings.window.opacity < 100 && settings.window.blur > 0 ? `blur(${settings.window.blur}px)` : 'none',
          border: `1px solid ${settings.theme.white}20`,
          borderRadius: '12px',
          boxShadow: '0 4px 24px rgba(0, 0, 0, 0.2)',
          overflow: 'hidden',
          transition: 'all 0.2s ease',
        }}
      >
        {/* Top toolbar row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', padding: '8px 12px', borderBottom: `1px solid ${settings.theme.white}25` }}>
            {/* Conversation button */}
            <div ref={conversationBtnRef}>
              <ToolbarPill
                filled
                onClick={() => setOverlay(overlay === 'conversations' ? null : 'conversations')}
                title="Conversations"
              >
                <MessageSquare size={14} />
              </ToolbarPill>
            </div>

            {/* Spacer to push context chips to the right */}
            <div style={{ flex: 1 }} />

            {/* Custom context chips (hashtag-based) */}
            {customContextChips.map((chip) => (
              <div
                key={chip.id}
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: '4px',
                  padding: '4px 8px',
                  fontSize: '11px',
                  fontFamily: settings.font.family,
                  fontWeight: 500,
                  color: chip.enabled ? settings.theme.yellow : settings.theme.white,
                  backgroundColor: chip.enabled ? `${settings.theme.yellow}15` : `${settings.theme.white}08`,
                  border: `1px solid ${chip.enabled ? settings.theme.yellow : settings.theme.white}30`,
                  borderRadius: '6px',
                  opacity: chip.enabled ? 1 : 0.6,
                  transition: 'all 0.15s ease',
                }}
              >
                <button
                  onClick={(e) => { e.stopPropagation(); toggleCustomContextChip(chip.id) }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '3px',
                    backgroundColor: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                    color: 'inherit',
                    padding: 0,
                  }}
                  title={chip.enabled ? 'Click to disable' : 'Click to enable'}
                >
                  <Hash size={10} style={{ opacity: 0.7 }} />
                  <span>{chip.tag}</span>
                </button>
                <button
                  onClick={(e) => { e.stopPropagation(); removeCustomContextChip(chip.id) }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    marginLeft: '2px',
                    padding: '2px',
                    backgroundColor: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                    color: chip.enabled ? `${settings.theme.yellow}99` : `${settings.theme.white}70`,
                    borderRadius: '50%',
                    flexShrink: 0,
                  }}
                  title="Remove"
                >
                  <X size={10} />
                </button>
              </div>
            ))}

            {/* Confirmed context chips (locked) */}
            {confirmedContextBlocks.map((block) => {
              const chipColor = block.type === 'ai-response' ? settings.theme.magenta
                : block.type === 'command' ? settings.theme.blue
                : block.type === 'interactive' ? settings.theme.cyan
                : settings.theme.brightBlack
              return (
                <div
                  key={block.id}
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '4px',
                    padding: '4px 10px',
                    fontSize: '11px',
                    fontFamily: settings.font.family,
                    fontWeight: 500,
                    color: chipColor,
                    backgroundColor: `${chipColor}15`,
                    border: `1px solid ${chipColor}40`,
                    borderRadius: '6px',
                    maxWidth: '150px',
                  }}
                >
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {block.label}
                  </span>
                  <button
                    onClick={(e) => { e.stopPropagation(); onRemoveConfirmedContext?.(block.id) }}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      marginLeft: '2px',
                      padding: '2px',
                      backgroundColor: 'transparent',
                      border: 'none',
                      cursor: 'pointer',
                      color: `${chipColor}99`,
                      borderRadius: '50%',
                      flexShrink: 0,
                    }}
                  >
                    <X size={10} />
                  </button>
                </div>
              )
            })}

            {/* Pending (ghost) context chip - only show if not already added */}
            {pendingContextBlock && !confirmedContextBlocks.some(b => b.id === pendingContextBlock.id) && (
              <button
                onClick={(e) => { e.stopPropagation(); onConfirmContext?.() }}
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: '4px',
                  padding: '4px 10px',
                  fontSize: '11px',
                  fontFamily: settings.font.family,
                  fontWeight: 500,
                  color: `${settings.theme.white}60`,
                  backgroundColor: `${settings.theme.white}08`,
                  border: `1px dashed ${settings.theme.white}30`,
                  borderRadius: '6px',
                  cursor: 'pointer',
                  transition: 'all 0.15s ease',
                  maxWidth: '150px',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.white}15`
                  e.currentTarget.style.borderStyle = 'solid'
                  e.currentTarget.style.color = settings.theme.white
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = `${settings.theme.white}08`
                  e.currentTarget.style.borderStyle = 'dashed'
                  e.currentTarget.style.color = `${settings.theme.white}60`
                }}
                title="Click to lock as context"
              >
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {pendingContextBlock.label}
                </span>
                <span style={{ opacity: 0.5, fontSize: '10px', flexShrink: 0 }}>+</span>
              </button>
            )}
          </div>

          {/* Main input area */}
          <div style={{ padding: '8px 12px', position: 'relative' }}>
            <textarea
              ref={textareaRef}
              value={input}
              onChange={handleInputChange}
              onKeyDown={handleKeyDown}
              onFocus={onInputFocus}
              placeholder="Type a command..."
              rows={INPUT_SIZES[inputSize].rows}
              style={{
                width: '100%',
                minHeight: INPUT_SIZES[inputSize].minHeight,
                resize: 'none',
                backgroundColor: 'transparent',
                fontSize: '15px',
                lineHeight: '1.6',
                color: settings.theme.foreground,
                border: 'none',
                outline: 'none',
                transition: 'min-height 0.15s ease',
              }}
            />
            {/* Size toggle button */}
            <button
              onClick={cycleInputSize}
              title={`Input size: ${inputSize} (click to cycle)`}
              style={{
                position: 'absolute',
                bottom: '8px',
                right: '8px',
                padding: '4px 8px',
                fontSize: '10px',
                fontWeight: 500,
                textTransform: 'uppercase',
                letterSpacing: '0.05em',
                backgroundColor: `${settings.theme.white}10`,
                color: settings.theme.brightBlack,
                border: 'none',
                borderRadius: '4px',
                cursor: 'pointer',
                opacity: 0.6,
                transition: 'opacity 0.15s ease',
              }}
              onMouseEnter={(e) => e.currentTarget.style.opacity = '1'}
              onMouseLeave={(e) => e.currentTarget.style.opacity = '0.6'}
            >
              {inputSize === 'small' ? 'S' : inputSize === 'medium' ? 'M' : 'L'}
            </button>
            {/* Natural language detection hint */}
            {showNLHint && (
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  marginTop: '8px',
                  padding: '8px 12px',
                  backgroundColor: `${settings.theme.yellow}15`,
                  borderRadius: '6px',
                  fontSize: '13px',
                  color: settings.theme.yellow,
                }}
              >
                <Lightbulb size={14} />
                <span>This looks like a question. Press <kbd style={{ padding: '2px 6px', backgroundColor: `${settings.theme.white}20`, borderRadius: '4px', fontFamily: 'monospace' }}>Tab</kbd> to send to AI instead.</span>
              </div>
            )}
          </div>

          {/* Bottom toolbar */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '6px 10px', borderTop: `1px solid ${settings.theme.white}25`, minHeight: '36px' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
              {/* Terminal / AI Mode Toggle */}
              <div style={{ display: 'flex', alignItems: 'center', borderRadius: '6px', overflow: 'hidden', border: `1px solid ${settings.theme.white}40`, height: '24px' }}>
                <button
                  onClick={() => setIsAIMode(false)}
                  style={{
                    padding: '4px 8px',
                    fontSize: '12px',
                    fontFamily: 'monospace',
                    backgroundColor: !isAIMode ? `${settings.theme.brightBlack}66` : 'transparent',
                    color: !isAIMode ? settings.theme.foreground : settings.theme.white,
                    border: 'none',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                  }}
                  title="Terminal mode"
                >
                  &gt;_
                </button>
                <button
                  onClick={() => setIsAIMode(true)}
                  style={{
                    padding: '4px 8px',
                    fontSize: '12px',
                    fontWeight: 600,
                    backgroundColor: isAIMode ? `${settings.theme.brightBlack}66` : 'transparent',
                    color: isAIMode ? settings.theme.foreground : settings.theme.white,
                    border: 'none',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                  }}
                  title="AI mode"
                >
                  AI
                </button>
              </div>

              {/* Divider */}
              <div style={{ width: '1px', height: '16px', backgroundColor: `${settings.theme.white}30` }} />

              {/* Action buttons */}
              <div style={{ display: 'flex', alignItems: 'center', gap: '2px' }}>
                <div ref={slashBtnRef}>
                  <ToolbarIcon onClick={() => setOverlay(overlay === 'slash' ? null : 'slash')} title="Slash commands">
                    <Slash size={13} />
                  </ToolbarIcon>
                </div>

                <ToolbarIcon title="Voice input">
                  <Mic size={13} />
                </ToolbarIcon>

                <div ref={mentionsBtnRef}>
                  <ToolbarIcon onClick={() => setOverlay(overlay === 'mentions' ? null : 'mentions')} title="Mentions">
                    <AtSign size={13} />
                  </ToolbarIcon>
                </div>

                <ToolbarIcon title="Attach files">
                  <Paperclip size={13} />
                </ToolbarIcon>
              </div>

              {/* Divider */}
              <div style={{ width: '1px', height: '16px', backgroundColor: `${settings.theme.white}30` }} />

              {/* Provider selector - icon only */}
              <div ref={providerBtnRef}>
                <button
                  onClick={(event) => {
                    event.stopPropagation()
                    setShowProviderPicker((prev) => !prev)
                  }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    width: '28px',
                    height: '28px',
                    borderRadius: '6px',
                    color: selectedProvider.isAgent ? settings.theme.cyan : settings.theme.white,
                    backgroundColor: selectedProvider.isAgent ? `${settings.theme.cyan}15` : 'transparent',
                    border: selectedProvider.isAgent ? `1px solid ${settings.theme.cyan}40` : 'none',
                    cursor: 'pointer',
                  }}
                  title={`Provider: ${selectedProvider.name}`}
                >
                  {selectedProvider.isAgent ? <Bot size={14} /> : <Server size={14} />}
                </button>
              </div>

              {/* Model selector - icon only */}
              <div ref={modelBtnRef}>
                <button
                  onClick={(event) => {
                    event.stopPropagation()
                    setShowModelPicker((prev) => !prev)
                  }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    width: '28px',
                    height: '28px',
                    borderRadius: '6px',
                    color: settings.theme.white,
                    backgroundColor: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                  }}
                  title={`Model: ${displayModelName}`}
                >
                  <Sparkles size={14} />
                </button>
              </div>

              {/* Thinking level selector - icon only, only for Claude Code */}
              {selectedProvider.id === 'claude-code' && (
                <div ref={thinkingBtnRef}>
                  <button
                    onClick={(event) => {
                      event.stopPropagation()
                      setShowThinkingPicker((prev) => !prev)
                    }}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      width: '28px',
                      height: '28px',
                      borderRadius: '6px',
                      color: thinkingLevel !== 'none' ? settings.theme.magenta : settings.theme.white,
                      backgroundColor: thinkingLevel !== 'none' ? `${settings.theme.magenta}15` : 'transparent',
                      border: thinkingLevel !== 'none' ? `1px solid ${settings.theme.magenta}40` : 'none',
                      cursor: 'pointer',
                    }}
                    title={`Thinking: ${thinkingLevel === 'none' ? 'Off' : getThinkingLevelLabel(thinkingLevel)}`}
                  >
                    <Brain size={14} />
                  </button>
                </div>
              )}

              {/* Model info label - next to icons */}
              <div style={{
                display: 'flex',
                alignItems: 'center',
                gap: '6px',
                marginLeft: '4px',
                padding: '4px 8px',
                borderRadius: '6px',
                backgroundColor: `${settings.theme.white}08`,
              }}>
                <span style={{
                  fontSize: '12px',
                  fontWeight: 500,
                  color: settings.theme.white,
                  opacity: 0.9,
                  maxWidth: '140px',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}>
                  {displayModelName}
                </span>
                {selectedProvider.id === 'claude-code' && thinkingLevel !== 'none' && (
                  <span style={{
                    fontSize: '10px',
                    fontWeight: 600,
                    color: settings.theme.magenta,
                    padding: '2px 6px',
                    borderRadius: '4px',
                    backgroundColor: `${settings.theme.magenta}20`,
                  }}>
                    {getThinkingLevelLabel(thinkingLevel).split(' ')[0]}
                  </span>
                )}
              </div>
            </div>

            {/* Send button */}
            <button
              onClick={handleSubmit}
              disabled={!input.trim()}
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                width: '36px',
                height: '36px',
                borderRadius: '8px',
                backgroundColor: input.trim() ? settings.theme.cyan : settings.theme.brightBlack,
                color: input.trim() ? settings.theme.background : settings.theme.brightBlack,
                border: 'none',
                cursor: input.trim() ? 'pointer' : 'not-allowed',
                transition: 'all 0.15s ease',
              }}
              title="Send"
            >
              <Send size={16} />
            </button>
          </div>
        </div>
      </div>

      {/* Portal-rendered pickers - always on top */}
      {overlay === 'conversations' && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(conversationBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(conversationBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <ConversationPicker 
            onClose={() => setOverlay(null)} 
            currentProvider={selectedProvider.id} 
            onSelectSession={(sessionId) => {
              setOverlay(null)
              onSessionSelect?.(sessionId)
            }}
          />
        </div>,
        document.body
      )}

      {overlay === 'slash' && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(slashBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(slashBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <SlashPicker onClose={() => setOverlay(null)} selectedProviderId={selectedProvider.id} />
        </div>,
        document.body
      )}

      {overlay === 'mentions' && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(mentionsBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(mentionsBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <MentionsPicker onClose={() => setOverlay(null)} onSelect={(item) => {
            // Insert the @ mention into the input
            setInput(prev => {
              // Find the last @ symbol and replace the partial match
              const atIndex = prev.lastIndexOf('@')
              if (atIndex >= 0) {
                return prev.slice(0, atIndex) + `@${item.name} `
              }
              return prev + `@${item.name} `
            })
          }} />
        </div>,
        document.body
      )}

      {showModelPicker && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(modelBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(modelBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <ModelPicker
            models={Array.from(new Map(providerModels.map(m => [m.id, { id: m.id, name: m.name, description: m.description || '' }])).values())}
            selectedModel={{ id: selectedModelId, name: selectedModel?.name || selectedModelId, description: selectedModel?.description || '' }}
            onSelectModel={(model) => {
              handleModelChange(model.id)
            }}
          />
        </div>,
        document.body
      )}

      {showProviderPicker && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(providerBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(providerBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <ProviderPicker
            providers={PROVIDERS}
            selectedProvider={selectedProvider}
            onSelectProvider={handleProviderChange}
          />
        </div>,
        document.body
      )}

      {showThinkingPicker && createPortal(
        <div
          style={{
            position: 'fixed',
            left: getButtonPosition(thinkingBtnRef).left,
            bottom: window.innerHeight - getButtonPosition(thinkingBtnRef).top + 8,
            zIndex: 999999,
          }}
        >
          <ThinkingPicker
            selectedLevel={thinkingLevel}
            onSelectLevel={(level) => {
              setThinkingLevel(level)
              setShowThinkingPicker(false)
            }}
          />
        </div>,
        document.body
      )}
    </>
  )
}

// Toolbar pill button - for top bar items
function ToolbarPill({
  children,
  filled = false,
  onClick,
  title,
}: {
  children: React.ReactNode
  filled?: boolean
  onClick?: (event: React.MouseEvent) => void
  title?: string
}) {
  const { settings } = useTerminalSettings()
  return (
    <button
      onClick={onClick}
      title={title}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '4px',
        padding: '6px 12px',
        borderRadius: '6px',
        backgroundColor: filled ? settings.theme.cyan : 'transparent',
        color: filled ? settings.theme.background : settings.theme.white,
        border: 'none',
        cursor: 'pointer',
        transition: 'all 0.15s ease',
      }}
    >
      {children}
    </button>
  )
}

// Toolbar icon button - for bottom bar action buttons
function ToolbarIcon({
  children,
  onClick,
  title,
}: {
  children: React.ReactNode
  onClick?: (event: React.MouseEvent) => void
  title?: string
}) {
  const { settings } = useTerminalSettings()
  return (
    <button
      onClick={onClick}
      title={title}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: '24px',
        height: '24px',
        borderRadius: '6px',
        color: settings.theme.white,
        backgroundColor: 'transparent',
        border: 'none',
        cursor: 'pointer',
        transition: 'all 0.15s ease',
      }}
    >
      {children}
    </button>
  )
}


interface ModelPickerProps {
  models: typeof MODELS
  selectedModel: typeof MODELS[0]
  onSelectModel: (model: typeof MODELS[0]) => void
}

function ModelPicker({ models, selectedModel, onSelectModel }: ModelPickerProps) {
  const { settings } = useTerminalSettings()
  const [search, setSearch] = useState('')
  const searchInputRef = useRef<HTMLInputElement>(null)
  const theme = settings.theme

  // Focus search on mount
  useEffect(() => {
    searchInputRef.current?.focus()
  }, [models])

  // Filter models based on search
  const filteredModels = useMemo(() => {
    if (!search.trim()) return models
    const lower = search.toLowerCase()
    return models.filter(m =>
      m.name.toLowerCase().includes(lower) ||
      (m.description && m.description.toLowerCase().includes(lower))
    )
  }, [models, search])

  return (
    <div
      onClick={(event) => event.stopPropagation()}
      style={{
        width: '320px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Search input */}
      <div style={{ padding: '10px 12px', borderBottom: `1px solid ${theme.brightBlack}40` }}>
        <div style={{ position: 'relative' }}>
          <input
            ref={searchInputRef}
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search models..."
            style={{
              width: '100%',
              padding: '8px 12px 8px 32px',
              backgroundColor: `${theme.brightBlack}20`,
              border: `1px solid ${theme.brightBlack}40`,
              borderRadius: '8px',
              color: theme.foreground,
              fontSize: '13px',
              outline: 'none',
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && filteredModels.length > 0) {
                onSelectModel(filteredModels[0])
              }
            }}
          />
          <svg
            style={{
              position: 'absolute',
              left: '10px',
              top: '50%',
              transform: 'translateY(-50%)',
              color: theme.brightBlack,
            }}
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="m21 21-4.3-4.3" />
          </svg>
        </div>
      </div>

      {/* Models list */}
      <div style={{ maxHeight: '340px', overflowY: 'auto', padding: '6px 0' }}>
        {filteredModels.length === 0 ? (
          <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
            No models found
          </div>
        ) : (
          filteredModels.map((model) => {
            const isSelected = selectedModel.id === model.id
            return (
              <button
                key={model.id}
                onClick={() => onSelectModel(model)}
                style={{
                  display: 'flex',
                  width: '100%',
                  alignItems: 'center',
                  gap: '10px',
                  padding: '10px 14px',
                  textAlign: 'left',
                  fontSize: '13px',
                  backgroundColor: isSelected ? theme.cyan : 'transparent',
                  color: isSelected ? theme.background : theme.foreground,
                  border: 'none',
                  cursor: 'pointer',
                  transition: 'background-color 0.1s ease',
                }}
                onMouseEnter={(e) => {
                  if (!isSelected) e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`
                }}
                onMouseLeave={(e) => {
                  if (!isSelected) e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                {isSelected && (
                  <Check size={14} style={{ color: theme.background, flexShrink: 0 }} />
                )}
                <div style={{ flex: 1, marginLeft: !isSelected ? '24px' : 0, minWidth: 0 }}>
                  <div style={{ fontWeight: 500 }}>{model.name}</div>
                  {model.description && (
                    <div style={{
                      fontSize: '11px',
                      opacity: 0.6,
                      marginTop: '2px',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      whiteSpace: 'nowrap',
                    }}>
                      {model.description}
                    </div>
                  )}
                </div>
              </button>
            )
          })
        )}
      </div>

      {/* Footer with count */}
      <div style={{
        padding: '8px 14px',
        borderTop: `1px solid ${theme.brightBlack}40`,
        fontSize: '11px',
        color: theme.brightBlack,
      }}>
        {filteredModels.length} model{filteredModels.length !== 1 ? 's' : ''} available
      </div>
    </div>
  )
}

interface ProviderPickerProps {
  providers: Provider[]
  selectedProvider: Provider
  onSelectProvider: (provider: Provider) => void
}

function ProviderPicker({ providers, selectedProvider, onSelectProvider }: ProviderPickerProps) {
  const { settings } = useTerminalSettings()

  // Group providers: agents first, then APIs
  const agents = providers.filter(p => p.isAgent)
  const apis = providers.filter(p => !p.isAgent)

  return (
    <div
      onClick={(event) => event.stopPropagation()}
      style={{
        width: '280px',
        backgroundColor: settings.theme.background,
        border: `1px solid ${settings.theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Agents section */}
      <div style={{ padding: '8px 0' }}>
        <div style={{ padding: '4px 16px', fontSize: '10px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: settings.theme.cyan }}>
          CLI Agents
        </div>
        {agents.map((provider) => {
          const isSelected = selectedProvider.id === provider.id
          return (
            <button
              key={provider.id}
              onClick={() => onSelectProvider(provider)}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                fontSize: '14px',
                backgroundColor: isSelected ? settings.theme.cyan : 'transparent',
                color: isSelected ? settings.theme.background : settings.theme.foreground,
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.1s ease',
              }}
            >
              <Bot size={16} style={{ color: isSelected ? settings.theme.background : settings.theme.cyan }} />
              <div style={{ flex: 1 }}>
                <div>{provider.name}</div>
                <div style={{ fontSize: '11px', opacity: 0.6, marginTop: '2px' }}>{provider.description}</div>
              </div>
              {isSelected && <Check size={14} />}
            </button>
          )
        })}
      </div>

      {/* APIs section */}
      <div style={{ padding: '8px 0', borderTop: `1px solid ${settings.theme.brightBlack}40` }}>
        <div style={{ padding: '4px 16px', fontSize: '10px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: settings.theme.brightBlack }}>
          Direct APIs
        </div>
        {apis.map((provider) => {
          const isSelected = selectedProvider.id === provider.id
          return (
            <button
              key={provider.id}
              onClick={() => onSelectProvider(provider)}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                fontSize: '14px',
                backgroundColor: isSelected ? settings.theme.cyan : 'transparent',
                color: isSelected ? settings.theme.background : settings.theme.foreground,
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.1s ease',
              }}
            >
              <Server size={16} style={{ color: isSelected ? settings.theme.background : settings.theme.brightBlack }} />
              <div style={{ flex: 1 }}>
                <div>{provider.name}</div>
                <div style={{ fontSize: '11px', opacity: 0.6, marginTop: '2px' }}>{provider.description}</div>
              </div>
              {isSelected && <Check size={14} />}
            </button>
          )
        })}
      </div>
    </div>
  )
}

interface ThinkingPickerProps {
  selectedLevel: ThinkingLevel
  onSelectLevel: (level: ThinkingLevel) => void
}

const THINKING_LEVELS: { id: ThinkingLevel; name: string; description: string; tokens: string }[] = [
  { id: 'none', name: 'Off', description: 'No extended thinking', tokens: '0' },
  { id: 'low', name: 'Low', description: 'Light reasoning', tokens: '~5k tokens' },
  { id: 'medium', name: 'Medium', description: 'Moderate reasoning', tokens: '~20k tokens' },
  { id: 'high', name: 'High', description: 'Deep reasoning', tokens: '~50k tokens' },
]

function ThinkingPicker({ selectedLevel, onSelectLevel }: ThinkingPickerProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme

  return (
    <div
      onClick={(event) => event.stopPropagation()}
      style={{
        width: '280px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      <div style={{ padding: '8px 0' }}>
        <div style={{ padding: '4px 16px 8px', fontSize: '10px', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.05em', color: theme.magenta }}>
          Extended Thinking
        </div>
        {THINKING_LEVELS.map((level) => {
          const isSelected = selectedLevel === level.id
          return (
            <button
              key={level.id}
              onClick={() => onSelectLevel(level.id)}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                fontSize: '14px',
                backgroundColor: isSelected ? theme.magenta : 'transparent',
                color: isSelected ? theme.background : theme.foreground,
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.1s ease',
              }}
            >
              <Brain size={16} style={{ color: isSelected ? theme.background : theme.magenta }} />
              <div style={{ flex: 1 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span>{level.name}</span>
                  <span style={{ fontSize: '11px', opacity: 0.6 }}>{level.tokens}</span>
                </div>
                <div style={{ fontSize: '11px', opacity: 0.6, marginTop: '2px' }}>{level.description}</div>
              </div>
              {isSelected && <Check size={14} />}
            </button>
          )
        })}
      </div>
      <div style={{ padding: '8px 16px', borderTop: `1px solid ${theme.brightBlack}40`, fontSize: '11px', color: theme.brightBlack }}>
        Higher levels = deeper reasoning but slower responses
      </div>
    </div>
  )
}

interface ConversationPickerProps {
  onClose: () => void
  currentProvider: string
  onSelectSession?: (sessionId: string) => void
}

interface ConversationItem {
  id: string
  title: string
  path: string
  date: string
  provider: string
}

function ConversationPicker({ onClose: _onClose, currentProvider, onSelectSession }: ConversationPickerProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [search, setSearch] = useState('')
  const [activeTab, setActiveTab] = useState<'provider' | 'all'>('provider')
  const [openCodeSessions, setOpenCodeSessions] = useState<OpenCodeSessionInfo[]>([])
  const [isLoading, setIsLoading] = useState(false)

  // Load OpenCode sessions when provider is opencode
  useEffect(() => {
    if (currentProvider === 'opencode') {
      setIsLoading(true)
      listSessions()
        .then((sessions) => {
          setOpenCodeSessions(sessions)
        })
        .catch((err) => {
          console.error('Failed to load OpenCode sessions:', err)
        })
        .finally(() => {
          setIsLoading(false)
        })
    }
  }, [currentProvider])

  // Helper to format relative time
  const formatRelativeTime = (date: Date): string => {
    const now = new Date()
    const diffMs = now.getTime() - date.getTime()
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24))
    
    if (diffDays === 0) return 'Today'
    if (diffDays === 1) return 'Yesterday'
    if (diffDays < 7) return `${diffDays} days ago`
    if (diffDays < 30) return `${Math.floor(diffDays / 7)} weeks ago`
    if (diffDays < 365) return `${Math.floor(diffDays / 30)} months ago`
    return `${Math.floor(diffDays / 365)} years ago`
  }

  // Convert OpenCode sessions to conversation items
  const openCodeConversations: ConversationItem[] = openCodeSessions.map((session) => ({
    id: session.id,
    title: session.title || 'Untitled session',
    path: session.directory,
    date: formatRelativeTime(session.updatedAt),
    provider: 'opencode',
  }))

  // Mock conversations for other providers
  const mockConversations: ConversationItem[] = [
    {
      id: 'mock-1',
      title: 'can you find out where my env vars are being defined on startup',
      path: '/Users/jkneen',
      date: '1 month ago',
      provider: 'claude-code'
    },
    {
      id: 'mock-2',
      title: "Fix the parse error near '@' in the JavaScript code",
      path: '/Users/jkneen/Documents/GitHub/flows/petersandmay/petersandmay',
      date: '2 months ago',
      provider: 'claude-code'
    },
    {
      id: 'mock-3',
      title: 'i have an installation somewhere of code that is vscode-oss-serv...',
      path: '/Users/jkneen',
      date: '2 months ago',
      provider: 'aider'
    },
    {
      id: 'mock-4',
      title: 'I need to get this running on web. mobile. ios android ASAP/User...',
      path: '/Users/jkneen',
      date: '2 months ago',
      provider: 'claude-code'
    },
  ]

  // Combine real OpenCode sessions with mock data for other providers
  const conversations: ConversationItem[] = currentProvider === 'opencode' 
    ? openCodeConversations 
    : [...openCodeConversations, ...mockConversations]

  // Filter conversations based on active tab and search
  const filteredConversations = conversations.filter(c => {
    const matchesSearch = !search || c.title.toLowerCase().includes(search.toLowerCase()) || c.path.toLowerCase().includes(search.toLowerCase())
    const matchesProvider = activeTab === 'all' || c.provider === currentProvider
    return matchesSearch && matchesProvider
  })

  // Get display name for provider tab
  const getProviderDisplayName = (id: string) => {
    const names: Record<string, string> = {
      'claude-code': 'Claude Code',
      'opencode': 'OpenCode',
      'aider': 'Aider',
      'codex': 'Codex',
      'gemini-cli': 'Gemini CLI',
    }
    return names[id] || id
  }

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{
        width: '580px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Header with search and tabs */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px', padding: '12px 16px', borderBottom: `1px solid ${theme.brightBlack}` }}>
        <span style={{ fontSize: '13px', color: theme.brightBlack }}>conversations:</span>
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search conversations"
          autoFocus
          style={{
            flex: 1,
            backgroundColor: 'transparent',
            fontSize: '13px',
            color: theme.foreground,
            border: 'none',
            outline: 'none',
          }}
        />
        {/* Tab switcher */}
        <div style={{ display: 'flex', backgroundColor: `${theme.brightBlack}30`, borderRadius: '6px', padding: '2px' }}>
          <button
            onClick={() => setActiveTab('provider')}
            style={{
              padding: '4px 10px',
              fontSize: '11px',
              fontWeight: 500,
              borderRadius: '4px',
              border: 'none',
              cursor: 'pointer',
              backgroundColor: activeTab === 'provider' ? theme.cyan : 'transparent',
              color: activeTab === 'provider' ? theme.background : theme.foreground,
              transition: 'all 0.15s ease',
            }}
          >
            {getProviderDisplayName(currentProvider)}
          </button>
          <button
            onClick={() => setActiveTab('all')}
            style={{
              padding: '4px 10px',
              fontSize: '11px',
              fontWeight: 500,
              borderRadius: '4px',
              border: 'none',
              cursor: 'pointer',
              backgroundColor: activeTab === 'all' ? theme.cyan : 'transparent',
              color: activeTab === 'all' ? theme.background : theme.foreground,
              transition: 'all 0.15s ease',
            }}
          >
            All
          </button>
        </div>
      </div>

      {/* New conversation button */}
      <div style={{ padding: '12px' }}>
        <button
          style={{
            display: 'flex',
            width: '100%',
            alignItems: 'center',
            gap: '12px',
            padding: '10px 16px',
            borderRadius: '8px',
            fontSize: '14px',
            fontWeight: 500,
            backgroundColor: theme.cyan,
            color: theme.background,
            border: 'none',
            cursor: 'pointer',
          }}
        >
          <Plus size={16} />
          New conversation
        </button>
      </div>

      {/* Past conversations */}
      <div style={{ paddingBottom: '8px' }}>
        <div style={{ padding: '8px 16px', fontSize: '12px', color: theme.brightBlack }}>
          {activeTab === 'provider' ? `${getProviderDisplayName(currentProvider)} conversations` : 'All conversations'}
        </div>
        <div style={{ maxHeight: '320px', overflowY: 'auto' }}>
          {isLoading ? (
            <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
              Loading sessions...
            </div>
          ) : filteredConversations.length === 0 ? (
            <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
              No conversations found
            </div>
          ) : filteredConversations.map((conversation) => (
            <button
              key={conversation.id}
              onClick={() => {
                console.log('[ConversationPicker] Session clicked:', conversation.id, conversation.title)
                onSelectSession?.(conversation.id)
              }}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'flex-start',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                backgroundColor: 'transparent',
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.15s ease',
              }}
            >
              <Clock size={16} style={{ color: theme.brightBlack, marginTop: '2px', flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: '14px', color: theme.foreground, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', paddingRight: '16px' }}>{conversation.title}</div>
                <div style={{ fontSize: '12px', color: theme.brightBlack, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', marginTop: '4px' }}>{conversation.path}</div>
              </div>
              <span style={{ fontSize: '12px', color: theme.brightBlack, flexShrink: 0 }}>{conversation.date}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

// Provider-specific slash commands
const PROVIDER_COMMANDS: Record<string, Array<{ icon: typeof Server; label: string; description: string }>> = {
  'claude-code': [
    { icon: Terminal, label: '/help', description: 'Get help with Claude Code' },
    { icon: Shield, label: '/allowed-tools', description: 'Show allowed tools' },
    { icon: Sparkles, label: '/config', description: 'View or modify configuration' },
    { icon: Code, label: '/diff', description: 'Show diff of pending changes' },
    { icon: Server, label: '/mcp', description: 'Configure MCP servers' },
    { icon: Sparkles, label: '/model', description: 'Change AI model' },
    { icon: ClipboardList, label: '/todo', description: 'Manage todo list' },
    { icon: Terminal, label: '/terminal', description: 'Run terminal commands' },
  ],
  'codex': [
    { icon: Terminal, label: '/help', description: 'Get help with OpenAI Codex' },
    { icon: Code, label: '/generate', description: 'Generate code from prompt' },
    { icon: Sparkles, label: '/explain', description: 'Explain code' },
    { icon: Code, label: '/edit', description: 'Edit code with instructions' },
    { icon: Terminal, label: '/shell', description: 'Run shell commands' },
  ],
  'default': [
    { icon: Server, label: '/add-mcp', description: 'Add new MCP server' },
    { icon: Server, label: '/create-environment', description: 'Create a Warp Environment (Docker image + repos)' },
    { icon: Sparkles, label: '/add-prompt', description: 'Add new Agent prompt' },
    { icon: Shield, label: '/add-rule', description: 'Add new rule' },
  ],
}

function SlashPicker({ onClose, selectedProviderId }: { onClose: () => void; selectedProviderId: string }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [search, setSearch] = useState('')
  const searchInputRef = useRef<HTMLInputElement>(null)

  // Focus search on mount
  useEffect(() => {
    searchInputRef.current?.focus()
  }, [])

  // Get provider-specific commands
  const commands = useMemo(() => {
    const providerCommands = PROVIDER_COMMANDS[selectedProviderId] || PROVIDER_COMMANDS['default']
    if (!search.trim()) return providerCommands
    const lower = search.toLowerCase()
    return providerCommands.filter(cmd =>
      cmd.label.toLowerCase().includes(lower) ||
      cmd.description.toLowerCase().includes(lower)
    )
  }, [selectedProviderId, search])

  const categories = [
    { icon: Sparkles, label: 'Prompts', hasSubmenu: true },
  ]

  return (
    <div
      style={{
        width: '400px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Search input */}
      <div style={{ padding: '10px 12px', borderBottom: `1px solid ${theme.brightBlack}40` }}>
        <input
          ref={searchInputRef}
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search commands..."
          style={{
            width: '100%',
            padding: '8px 12px',
            backgroundColor: `${theme.brightBlack}20`,
            border: `1px solid ${theme.brightBlack}40`,
            borderRadius: '8px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>

      {/* Provider label */}
      <div style={{ padding: '8px 16px', fontSize: '11px', color: theme.brightBlack, textTransform: 'uppercase' }}>
        {selectedProviderId === 'claude-code' ? 'Claude Code' : selectedProviderId === 'codex' ? 'Codex' : 'Commands'}
      </div>

      {/* Commands */}
      <div style={{ maxHeight: '300px', overflowY: 'auto', padding: '0 0 8px' }}>
        {commands.length === 0 ? (
          <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
            No commands found
          </div>
        ) : (
          commands.map((cmd, index) => (
            <button
              key={cmd.label}
              onClick={() => onClose()}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                backgroundColor: index === 0 ? theme.cyan : 'transparent',
                color: index === 0 ? theme.background : theme.foreground,
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.15s ease',
              }}
              onMouseEnter={(e) => {
                if (index !== 0) e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`
              }}
              onMouseLeave={(e) => {
                if (index !== 0) e.currentTarget.style.backgroundColor = 'transparent'
              }}
            >
              <cmd.icon size={16} style={{ color: index === 0 ? `${theme.background}99` : theme.brightBlack }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: '14px', fontWeight: 500 }}>{cmd.label}</div>
                {cmd.description && (
                  <div style={{ fontSize: '12px', marginTop: '2px', color: index === 0 ? `${theme.background}99` : theme.brightBlack }}>{cmd.description}</div>
                )}
              </div>
            </button>
          ))
        )}
      </div>

      {/* Categories with submenus */}
      <div style={{ padding: '8px 0', borderTop: `1px solid ${theme.brightBlack}` }}>
        {categories.map((cat) => (
          <button
            key={cat.label}
            style={{
              display: 'flex',
              width: '100%',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: '12px',
              padding: '10px 16px',
              textAlign: 'left',
              color: theme.foreground,
              backgroundColor: 'transparent',
              border: 'none',
              cursor: 'pointer',
              transition: 'background-color 0.15s ease',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <cat.icon size={16} style={{ color: theme.brightBlack }} />
              <span style={{ fontSize: '14px' }}>{cat.label}</span>
            </div>
            <ChevronRight size={14} style={{ color: theme.brightBlack }} />
          </button>
        ))}
      </div>
    </div>
  )
}

interface MentionItem {
  type: 'file' | 'folder' | 'agent'
  name: string
  path: string
  icon: typeof File
}

function MentionsPicker({ onClose, onSelect }: { onClose: () => void; onSelect?: (item: MentionItem) => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [search, setSearch] = useState('')
  const [files, setFiles] = useState<MentionItem[]>([])
  const [agents, setAgents] = useState<MentionItem[]>([])
  const [loading, setLoading] = useState(true)
  const searchInputRef = useRef<HTMLInputElement>(null)

  // Focus search on mount
  useEffect(() => {
    searchInputRef.current?.focus()
  }, [])

  // Load files and agents from working directory
  useEffect(() => {
    const loadItems = async () => {
      setLoading(true)
      try {
        // Try to get working directory files via Tauri
        const { readDir } = await import('@tauri-apps/plugin-fs')
        const { homeDir } = await import('@tauri-apps/api/path')

        // Get current working directory (fallback to home)
        const cwd = (window as unknown as { __TAURI_INTERNALS__?: { cwd?: string } }).__TAURI_INTERNALS__?.cwd || await homeDir()

        // Read working directory files
        const entries = await readDir(cwd)
        const fileItems: MentionItem[] = entries.slice(0, 50).map(entry => ({
          type: entry.isDirectory ? 'folder' : 'file',
          name: entry.name,
          path: `${cwd}/${entry.name}`,
          icon: entry.isDirectory ? FolderOpen : File,
        }))
        setFiles(fileItems)

        // Try to read .claude/agents directory
        try {
          const agentsDir = `${cwd}/.claude/agents`
          const agentEntries = await readDir(agentsDir)
          const agentItems: MentionItem[] = agentEntries
            .filter(e => e.name.endsWith('.md') || e.name.endsWith('.json'))
            .map(entry => ({
              type: 'agent' as const,
              name: entry.name.replace(/\.(md|json)$/, ''),
              path: `${agentsDir}/${entry.name}`,
              icon: Sparkles,
            }))
          setAgents(agentItems)
        } catch {
          // .claude/agents doesn't exist, that's fine
          setAgents([])
        }
      } catch {
        // Fallback to empty if we can't read filesystem
        setFiles([])
        setAgents([])
      }
      setLoading(false)
    }

    loadItems()
  }, [])

  // Filter items based on search
  const filteredItems = useMemo(() => {
    const allItems = [...agents, ...files]
    if (!search.trim()) return allItems.slice(0, 20)
    const lower = search.toLowerCase()
    return allItems.filter(item =>
      item.name.toLowerCase().includes(lower) ||
      item.path.toLowerCase().includes(lower)
    ).slice(0, 20)
  }, [files, agents, search])

  const categories = [
    { icon: FolderOpen, label: 'Files and folders' },
    { icon: Sparkles, label: 'Agents' },
    { icon: Terminal, label: 'Blocks' },
  ]

  return (
    <div
      style={{
        width: '380px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Search input */}
      <div style={{ padding: '10px 12px', borderBottom: `1px solid ${theme.brightBlack}40` }}>
        <input
          ref={searchInputRef}
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search files, folders, agents..."
          style={{
            width: '100%',
            padding: '8px 12px',
            backgroundColor: `${theme.brightBlack}20`,
            border: `1px solid ${theme.brightBlack}40`,
            borderRadius: '8px',
            color: theme.foreground,
            fontSize: '13px',
            outline: 'none',
          }}
        />
      </div>

      {/* Loading state */}
      {loading ? (
        <div style={{ padding: '24px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
          Loading...
        </div>
      ) : search.trim() ? (
        /* Search results */
        <div style={{ maxHeight: '320px', overflowY: 'auto', padding: '8px 0' }}>
          {filteredItems.length === 0 ? (
            <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
              No matches found
            </div>
          ) : (
            filteredItems.map((item, index) => (
              <button
                key={item.path}
                onClick={() => {
                  onSelect?.(item)
                  onClose()
                }}
                style={{
                  display: 'flex',
                  width: '100%',
                  alignItems: 'center',
                  gap: '12px',
                  padding: '8px 16px',
                  textAlign: 'left',
                  backgroundColor: index === 0 ? theme.cyan : 'transparent',
                  color: index === 0 ? theme.background : theme.foreground,
                  border: 'none',
                  cursor: 'pointer',
                  transition: 'background-color 0.15s ease',
                }}
                onMouseEnter={(e) => {
                  if (index !== 0) e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`
                }}
                onMouseLeave={(e) => {
                  if (index !== 0) e.currentTarget.style.backgroundColor = 'transparent'
                }}
              >
                <item.icon
                  size={16}
                  style={{
                    color: index === 0
                      ? `${theme.background}99`
                      : item.type === 'agent' ? theme.magenta
                      : item.type === 'folder' ? theme.yellow
                      : theme.brightBlack
                  }}
                />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: '13px', fontWeight: 500 }}>{item.name}</div>
                  <div style={{
                    fontSize: '11px',
                    marginTop: '2px',
                    color: index === 0 ? `${theme.background}99` : theme.brightBlack,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}>
                    {item.type === 'agent' ? 'Agent' : item.path}
                  </div>
                </div>
              </button>
            ))
          )}
        </div>
      ) : (
        /* Category view when not searching */
        <div style={{ padding: '8px 0' }}>
          {/* Show agents first if any */}
          {agents.length > 0 && (
            <>
              <div style={{ padding: '6px 16px', fontSize: '11px', color: theme.brightBlack, textTransform: 'uppercase' }}>
                Agents ({agents.length})
              </div>
              {agents.slice(0, 5).map((agent) => (
                <button
                  key={agent.path}
                  onClick={() => {
                    onSelect?.(agent)
                    onClose()
                  }}
                  style={{
                    display: 'flex',
                    width: '100%',
                    alignItems: 'center',
                    gap: '12px',
                    padding: '8px 16px',
                    textAlign: 'left',
                    backgroundColor: 'transparent',
                    color: theme.foreground,
                    border: 'none',
                    cursor: 'pointer',
                    transition: 'background-color 0.15s ease',
                  }}
                  onMouseEnter={(e) => e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`}
                  onMouseLeave={(e) => e.currentTarget.style.backgroundColor = 'transparent'}
                >
                  <Sparkles size={16} style={{ color: theme.magenta }} />
                  <span style={{ fontSize: '13px' }}>{agent.name}</span>
                </button>
              ))}
            </>
          )}

          {/* Category shortcuts */}
          <div style={{ borderTop: agents.length > 0 ? `1px solid ${theme.brightBlack}40` : 'none', padding: '8px 0' }}>
            {categories.map((cat) => (
              <button
                key={cat.label}
                style={{
                  display: 'flex',
                  width: '100%',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: '12px',
                  padding: '10px 16px',
                  textAlign: 'left',
                  backgroundColor: 'transparent',
                  color: theme.foreground,
                  border: 'none',
                  cursor: 'pointer',
                  transition: 'background-color 0.15s ease',
                }}
                onMouseEnter={(e) => e.currentTarget.style.backgroundColor = `${theme.brightBlack}20`}
                onMouseLeave={(e) => e.currentTarget.style.backgroundColor = 'transparent'}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
                  <cat.icon size={16} style={{ color: theme.brightBlack }} />
                  <span style={{ fontSize: '14px' }}>{cat.label}</span>
                </div>
                <ChevronRight size={14} style={{ color: theme.brightBlack }} />
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

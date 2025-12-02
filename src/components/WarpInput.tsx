import { useEffect, useRef, useState, useMemo, useCallback } from 'react'
import { createPortal } from 'react-dom'
import {
  MessageSquare,
  FolderOpen,
  Terminal,
  Sparkles,
  Send,
  ChevronDown,
  ChevronRight,
  Slash,
  AtSign,
  Mic,
  Paperclip,
  Plus,
  Clock,
  Check,
  Workflow,
  BookOpen,
  ClipboardList,
  Shield,
  Server,
  Lightbulb,
  Bot,
  X,
  Zap,
  Brain,
  DollarSign,
  BarChart3,
  Hash,
} from 'lucide-react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'
import { detectNaturalLanguage, detectCLICommand } from '../hooks/useInputInterception'
import { PROVIDERS, getProviderModels, type Provider, type ProviderType, type ProviderModel } from '../types/providers'
import { getProvidersAndModels, type OpenCodeProvider } from '../services/opencode'
import { type ThinkingLevel, getThinkingLevelLabel } from '../services/claudecode'
import trumpsCard from '../assets/trumps.png'

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
}

const MODELS = [
  { id: 'auto', name: 'auto', description: 'Auto will select the best model for the task' },
  { id: 'gpt-5.1-low', name: 'gpt-5.1 (low reasoning)', description: 'Fast, cost-effective' },
  { id: 'gpt-5.1-medium', name: 'gpt-5.1 (medium reasoning)', description: 'Balanced performance' },
  { id: 'gpt-5.1-high', name: 'gpt-5.1 (high reasoning)', description: 'Best quality' },
  { id: 'claude-4-sonnet', name: 'claude 4 sonnet', description: 'Anthropic' },
  { id: 'claude-4.5-sonnet', name: 'claude 4.5 sonnet', description: 'Anthropic' },
  { id: 'claude-4.5-sonnet-thinking', name: 'claude 4.5 sonnet (thinking)', description: 'Extended thinking' },
  { id: 'claude-4.5-haiku', name: 'claude 4.5 haiku', description: 'Fast, efficient' },
  { id: 'claude-4.5-opus', name: 'claude 4.5 opus', description: 'Most capable' },
  { id: 'claude-4.5-opus-thinking', name: 'claude 4.5 opus (thinking)', description: 'Extended thinking' },
  { id: 'claude-4.1-opus', name: 'claude 4.1 opus', description: 'Anthropic' },
  { id: 'gpt-5-low', name: 'gpt-5 (low reasoning)', description: 'OpenAI' },
  { id: 'gpt-5-medium', name: 'gpt-5 (medium reasoning)', description: 'OpenAI' },
  { id: 'gpt-5-high', name: 'gpt-5 (high reasoning)', description: 'OpenAI' },
  { id: 'gemini-3-pro', name: 'gemini 3 pro', description: 'Google' },
  { id: 'gemini-2.5-pro', name: 'gemini 2.5 pro', description: 'Google' },
  { id: 'glm-4.6', name: 'glm 4.6 (us-hosted)', description: 'GLM' },
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
}: WarpInputProps) {
  const { settings } = useTerminalSettings()
  const [input, setInput] = useState('')
  const [selectedProvider, setSelectedProvider] = useState<Provider>(PROVIDERS[0])
  const [selectedModelId, setSelectedModelId] = useState(PROVIDERS[0].defaultModel || PROVIDERS[0].models[0]?.id || 'auto')
  const [showProviderPicker, setShowProviderPicker] = useState(false)
  const [showModelPicker, setShowModelPicker] = useState(false)
  const [showThinkingPicker, setShowThinkingPicker] = useState(false)
  const [isAIMode, setIsAIMode] = useState(true)
  const [autoMode, setAutoMode] = useState<'responsive' | 'cost-efficient'>('responsive')
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
  const [customContextChips, setCustomContextChips] = useState<CustomContextChip[]>([])

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

  // Fetch OpenCode models when provider is opencode
  useEffect(() => {
    if (selectedProvider.id === 'opencode') {
      fetchOpenCodeModels()
    }
  }, [selectedProvider.id, fetchOpenCodeModels])

  // Get models for current provider (use OpenCode dynamic models if available)
  const providerModels = useMemo((): ProviderModel[] => {
    if (selectedProvider.id === 'opencode' && openCodeProviders.length > 0) {
      // Flatten all OpenCode provider models into a list
      const models: ProviderModel[] = [
        { id: 'auto', name: 'Auto', description: 'Automatically select best model' },
      ]
      for (const provider of openCodeProviders) {
        for (const model of provider.models) {
          models.push({
            id: model.id,
            name: model.name,
            description: provider.name,
          })
        }
      }
      return models
    }
    return getProviderModels(selectedProvider.id)
  }, [selectedProvider.id, openCodeProviders])

  const selectedModel = providerModels.find(m => m.id === selectedModelId) || providerModels[0]

  // Handle provider change
  const handleProviderChange = (provider: Provider) => {
    setSelectedProvider(provider)
    setSelectedModelId(provider.defaultModel || provider.models[0]?.id || 'auto')
    setShowProviderPicker(false)
    onProviderChange?.(provider.id)
  }

  // Handle model change
  const handleModelChange = (modelId: string) => {
    setSelectedModelId(modelId)
    setShowModelPicker(false)
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
    setInput(event.target.value)
    // Clear pending context if user types - they've moved on
    if (pendingContextBlock && event.target.value !== input) {
      onClearPendingContext?.()
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

  const displayModelName = selectedModel.id === 'auto'
    ? `auto (${autoMode})`
    : selectedModel.name

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

              {/* Provider selector */}
              <div ref={providerBtnRef}>
                <button
                  onClick={(event) => {
                    event.stopPropagation()
                    setShowProviderPicker((prev) => !prev)
                  }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '4px',
                    padding: '4px 8px',
                    borderRadius: '6px',
                    fontSize: '12px',
                    color: selectedProvider.isAgent ? settings.theme.cyan : settings.theme.white,
                    backgroundColor: selectedProvider.isAgent ? `${settings.theme.cyan}15` : 'transparent',
                    border: selectedProvider.isAgent ? `1px solid ${settings.theme.cyan}40` : 'none',
                    cursor: 'pointer',
                  }}
                  title="Select provider"
                >
                  {selectedProvider.isAgent ? <Bot size={12} /> : <Server size={12} />}
                  <span style={{ maxWidth: '80px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{selectedProvider.name}</span>
                  <ChevronDown size={10} style={{ opacity: 0.6, flexShrink: 0 }} />
                </button>
              </div>

              {/* Model selector */}
              <div ref={modelBtnRef}>
                <button
                  onClick={(event) => {
                    event.stopPropagation()
                    setShowModelPicker((prev) => !prev)
                  }}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '4px',
                    padding: '4px 8px',
                    borderRadius: '6px',
                    fontSize: '12px',
                    color: settings.theme.white,
                    backgroundColor: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                  }}
                  title="Select model"
                >
                  <Sparkles size={12} />
                  <span style={{ maxWidth: '120px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{displayModelName}</span>
                  <ChevronDown size={10} style={{ opacity: 0.6, flexShrink: 0 }} />
                </button>
              </div>

              {/* Thinking level selector - only for Claude Code */}
              {selectedProvider.id === 'claude-code' && (
                <>
                  <div style={{ width: '1px', height: '16px', backgroundColor: `${settings.theme.white}30` }} />
                  <div ref={thinkingBtnRef}>
                    <button
                      onClick={(event) => {
                        event.stopPropagation()
                        setShowThinkingPicker((prev) => !prev)
                      }}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: '4px',
                        padding: '4px 8px',
                        borderRadius: '6px',
                        fontSize: '12px',
                        color: thinkingLevel !== 'none' ? settings.theme.magenta : settings.theme.white,
                        backgroundColor: thinkingLevel !== 'none' ? `${settings.theme.magenta}15` : 'transparent',
                        border: thinkingLevel !== 'none' ? `1px solid ${settings.theme.magenta}40` : 'none',
                        cursor: 'pointer',
                      }}
                      title="Extended thinking"
                    >
                      <Brain size={12} />
                      <span>{thinkingLevel === 'none' ? 'Think' : getThinkingLevelLabel(thinkingLevel).split(' ')[0]}</span>
                      <ChevronDown size={10} style={{ opacity: 0.6, flexShrink: 0 }} />
                    </button>
                  </div>
                </>
              )}
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
          <ConversationPicker onClose={() => setOverlay(null)} currentProvider={selectedProvider.id} />
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
          <SlashPicker onClose={() => setOverlay(null)} />
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
          <MentionsPicker onClose={() => setOverlay(null)} />
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
            models={providerModels.map(m => ({ id: m.id, name: m.name, description: m.description || '' }))}
            selectedModel={{ id: selectedModelId, name: selectedModel?.name || selectedModelId, description: selectedModel?.description || '' }}
            autoMode={autoMode}
            onSelectModel={(model) => {
              handleModelChange(model.id)
            }}
            onAutoModeChange={setAutoMode}
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
  autoMode: 'responsive' | 'cost-efficient'
  onSelectModel: (model: typeof MODELS[0]) => void
  onAutoModeChange: (mode: 'responsive' | 'cost-efficient') => void
}

// Model stats for Top Trumps cards - extended stats with rarity and tagline
const MODEL_STATS_EXTENDED: Record<string, {
  displayName: string
  intelligence: number
  speed: number
  context: number
  value: number
  reasoning: number
  tagline: string
  rarity: 'common' | 'uncommon' | 'rare' | 'legendary' | 'mythic'
}> = {
  'auto': {
    displayName: 'Auto',
    intelligence: 75,
    speed: 75,
    context: 80,
    value: 80,
    reasoning: 75,
    tagline: 'Smart Selection',
    rarity: 'uncommon',
  },
  'gpt-5.1-low': {
    displayName: 'GPT-5.1 Low',
    intelligence: 70,
    speed: 95,
    context: 60,
    value: 90,
    reasoning: 50,
    tagline: 'Speed Racer',
    rarity: 'uncommon',
  },
  'gpt-5.1-medium': {
    displayName: 'GPT-5.1 Medium',
    intelligence: 85,
    speed: 75,
    context: 60,
    value: 65,
    reasoning: 70,
    tagline: 'Balanced Pro',
    rarity: 'rare',
  },
  'gpt-5.1-high': {
    displayName: 'GPT-5.1 High',
    intelligence: 95,
    speed: 50,
    context: 60,
    value: 30,
    reasoning: 92,
    tagline: 'The Thinker',
    rarity: 'legendary',
  },
  'claude-4-sonnet': {
    displayName: 'Claude 4 Sonnet',
    intelligence: 88,
    speed: 80,
    context: 85,
    value: 60,
    reasoning: 80,
    tagline: 'Reliable Genius',
    rarity: 'legendary',
  },
  'claude-4.5-sonnet': {
    displayName: 'Claude 4.5 Sonnet',
    intelligence: 92,
    speed: 75,
    context: 85,
    value: 65,
    reasoning: 88,
    tagline: 'Speed Meets Smarts',
    rarity: 'legendary',
  },
  'claude-4.5-sonnet-thinking': {
    displayName: 'Claude 4.5 Sonnet',
    intelligence: 95,
    speed: 40,
    context: 85,
    value: 35,
    reasoning: 96,
    tagline: 'Deep Thoughts',
    rarity: 'rare',
  },
  'claude-4.5-haiku': {
    displayName: 'Claude 4.5 Haiku',
    intelligence: 72,
    speed: 95,
    context: 85,
    value: 92,
    reasoning: 60,
    tagline: 'Lightning Fast',
    rarity: 'uncommon',
  },
  'claude-4.5-opus': {
    displayName: 'Claude 4.5 Opus',
    intelligence: 98,
    speed: 35,
    context: 85,
    value: 25,
    reasoning: 99,
    tagline: 'The Ultimate Mind',
    rarity: 'mythic',
  },
  'claude-4.5-opus-thinking': {
    displayName: 'Claude 4.5 Opus',
    intelligence: 99,
    speed: 30,
    context: 85,
    value: 20,
    reasoning: 100,
    tagline: 'Absolute Peak',
    rarity: 'mythic',
  },
  'claude-4.1-opus': {
    displayName: 'Claude 4.1 Opus',
    intelligence: 96,
    speed: 50,
    context: 85,
    value: 30,
    reasoning: 95,
    tagline: 'The Predecessor',
    rarity: 'legendary',
  },
  'gpt-5-low': {
    displayName: 'GPT-5 Low',
    intelligence: 65,
    speed: 90,
    context: 60,
    value: 85,
    reasoning: 45,
    tagline: 'Budget King',
    rarity: 'common',
  },
  'gpt-5-medium': {
    displayName: 'GPT-5 Medium',
    intelligence: 80,
    speed: 70,
    context: 60,
    value: 60,
    reasoning: 65,
    tagline: 'Solid Performer',
    rarity: 'rare',
  },
  'gpt-5-high': {
    displayName: 'GPT-5 High',
    intelligence: 92,
    speed: 45,
    context: 60,
    value: 25,
    reasoning: 90,
    tagline: 'Peak Thinker',
    rarity: 'legendary',
  },
  'gemini-3-pro': {
    displayName: 'Gemini 3 Pro',
    intelligence: 90,
    speed: 80,
    context: 95,
    value: 65,
    reasoning: 75,
    tagline: 'Context Master',
    rarity: 'legendary',
  },
  'gemini-2.5-pro': {
    displayName: 'Gemini 2.5 Pro',
    intelligence: 85,
    speed: 85,
    context: 100,
    value: 70,
    reasoning: 70,
    tagline: 'Context King',
    rarity: 'rare',
  },
  'glm-4.6': {
    displayName: 'GLM 4.6',
    intelligence: 78,
    speed: 88,
    context: 75,
    value: 75,
    reasoning: 65,
    tagline: 'The Challenger',
    rarity: 'uncommon',
  },
}

// Rarity colors and filters
const RARITY_COLORS: Record<string, { border: string; filter: string }> = {
  common: {
    border: '#6a6a7a',
    filter: 'grayscale(0.7) brightness(0.6)',
  },
  uncommon: {
    border: '#22c55e',
    filter: 'hue-rotate(85deg) saturate(1.2) brightness(0.75)',
  },
  rare: {
    border: '#3b82f6',
    filter: 'hue-rotate(200deg) saturate(1.3) brightness(0.8)',
  },
  legendary: {
    border: '#fbbf24',
    filter: 'hue-rotate(35deg) saturate(1.5) brightness(0.85)',
  },
  mythic: {
    border: '#a855f7',
    filter: 'hue-rotate(280deg) saturate(1.4) brightness(0.85)',
  },
}

function ModelPicker({ models, selectedModel, autoMode, onSelectModel, onAutoModeChange }: ModelPickerProps) {
  const { settings } = useTerminalSettings()
  const [hoveredModel, setHoveredModel] = useState<typeof MODELS[0] | null>(null)
  const [viewMode, setViewMode] = useState<'specs' | 'fun'>('specs')

  // Use hovered model for display, fall back to selected
  const displayModel = hoveredModel || selectedModel
  const isAutoModel = displayModel.id === 'auto'

  // Model stats lookup
  const modelStats: Record<string, { intelligence: number; speed: number; cost: number }> = {
    'auto': { intelligence: autoMode === 'responsive' ? 90 : 65, speed: autoMode === 'responsive' ? 85 : 55, cost: autoMode === 'responsive' ? 50 : 95 },
    'gpt-5.1-low': { intelligence: 70, speed: 95, cost: 90 },
    'gpt-5.1-medium': { intelligence: 85, speed: 75, cost: 60 },
    'gpt-5.1-high': { intelligence: 95, speed: 50, cost: 30 },
    'claude-4-sonnet': { intelligence: 88, speed: 80, cost: 55 },
    'claude-4.5-sonnet': { intelligence: 92, speed: 75, cost: 50 },
    'claude-4.5-sonnet-thinking': { intelligence: 95, speed: 40, cost: 35 },
    'claude-4.5-haiku': { intelligence: 75, speed: 95, cost: 85 },
    'claude-4.5-opus': { intelligence: 98, speed: 45, cost: 20 },
    'claude-4.5-opus-thinking': { intelligence: 99, speed: 30, cost: 15 },
    'claude-4.1-opus': { intelligence: 96, speed: 50, cost: 25 },
    'gpt-5-low': { intelligence: 65, speed: 90, cost: 85 },
    'gpt-5-medium': { intelligence: 80, speed: 70, cost: 55 },
    'gpt-5-high': { intelligence: 92, speed: 45, cost: 30 },
    'gemini-3-pro': { intelligence: 90, speed: 80, cost: 60 },
    'gemini-2.5-pro': { intelligence: 85, speed: 85, cost: 65 },
    'glm-4.6': { intelligence: 78, speed: 88, cost: 80 },
  }

  const stats = modelStats[displayModel.id] || { intelligence: 80, speed: 70, cost: 50 }
  const extendedStats = MODEL_STATS_EXTENDED[displayModel.id] || {
    displayName: displayModel.name,
    intelligence: stats.intelligence,
    speed: stats.speed,
    context: 75,
    value: 100 - stats.cost,
    reasoning: stats.intelligence,
    tagline: displayModel.description,
    rarity: 'common' as const,
  }
  const rarity = RARITY_COLORS[extendedStats.rarity]

  return (
    <div
      onClick={(event) => event.stopPropagation()}
      style={{
        display: 'flex',
        width: '580px',
        backgroundColor: settings.theme.background,
        border: `1px solid ${settings.theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      {/* Model list */}
      <div style={{ flex: 1, maxHeight: '380px', overflowY: 'auto', padding: '8px 0' }}>
        {models.map((model) => {
          const isSelected = selectedModel.id === model.id
          const isHovered = hoveredModel?.id === model.id
          return (
            <button
              key={model.id}
              onClick={() => onSelectModel(model)}
              onMouseEnter={() => setHoveredModel(model)}
              onMouseLeave={() => setHoveredModel(null)}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '12px',
                padding: '10px 16px',
                textAlign: 'left',
                fontSize: '14px',
                backgroundColor: isSelected ? settings.theme.cyan : isHovered ? settings.theme.cyan + '26' : 'transparent',
                color: isSelected ? settings.theme.background : settings.theme.foreground,
                border: 'none',
                cursor: 'pointer',
                transition: 'background-color 0.1s ease',
              }}
            >
              {isSelected && (
                <Check size={14} style={{ color: settings.theme.background }} />
              )}
              <span style={{ marginLeft: !isSelected ? '26px' : 0 }}>{model.name}</span>
            </button>
          )
        })}
      </div>

      {/* Model info panel */}
      <div style={{ width: '220px', padding: '16px', borderLeft: `1px solid ${settings.theme.brightBlack}` }}>
        <div style={{ marginBottom: '16px' }}>
          <div style={{ fontSize: '14px', fontWeight: 500, color: settings.theme.foreground, marginBottom: '8px' }}>
            {isAutoModel ? 'Auto mode' : displayModel.name}
          </div>
          <p style={{ fontSize: '12px', color: settings.theme.brightBlack, lineHeight: 1.5 }}>
            {isAutoModel
              ? 'Auto will select the best model for the task. Cost-efficiency optimizes for cost, Responsiveness optimizes for response speed.'
              : displayModel.description
            }
          </p>
        </div>

        {/* Auto mode toggle - only show for auto model */}
        {isAutoModel && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '4px', marginBottom: '20px' }}>
            <button
              onClick={() => onAutoModeChange('responsive')}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '8px',
                padding: '8px 12px',
                fontSize: '14px',
                borderRadius: '6px',
                backgroundColor: autoMode === 'responsive' ? '#2dd4bf' : 'transparent',
                color: autoMode === 'responsive' ? '#0a0e16' : 'rgba(255,255,255,0.5)',
                border: 'none',
                cursor: 'pointer',
                transition: 'all 0.15s ease',
              }}
            >
              {autoMode === 'responsive' && <Check size={14} />}
              <span style={{ marginLeft: autoMode !== 'responsive' ? '22px' : 0 }}>Responsive</span>
            </button>
            <button
              onClick={() => onAutoModeChange('cost-efficient')}
              style={{
                display: 'flex',
                width: '100%',
                alignItems: 'center',
                gap: '8px',
                padding: '8px 12px',
                fontSize: '14px',
                borderRadius: '6px',
                backgroundColor: autoMode === 'cost-efficient' ? '#2dd4bf' : 'transparent',
                color: autoMode === 'cost-efficient' ? '#0a0e16' : 'rgba(255,255,255,0.5)',
                border: 'none',
                cursor: 'pointer',
                transition: 'all 0.15s ease',
              }}
            >
              {autoMode === 'cost-efficient' && <Check size={14} />}
              <span style={{ marginLeft: autoMode !== 'cost-efficient' ? '22px' : 0 }}>Cost-efficient</span>
            </button>
          </div>
        )}

        {/* Specs/Fun toggle */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '4px', marginBottom: '12px' }}>
          <button
            onClick={() => setViewMode('specs')}
            style={{
              padding: '4px 8px',
              fontSize: '11px',
              fontWeight: viewMode === 'specs' ? 600 : 400,
              color: viewMode === 'specs' ? settings.theme.white : settings.theme.brightBlack,
              backgroundColor: viewMode === 'specs' ? `${settings.theme.brightBlack}40` : 'transparent',
              border: `1px solid ${viewMode === 'specs' ? settings.theme.brightBlack : 'transparent'}`,
              borderRadius: '3px 0 0 3px',
              cursor: 'pointer',
              transition: 'all 0.15s ease',
            }}
          >
            Specs
          </button>
          <button
            onClick={() => setViewMode('fun')}
            style={{
              padding: '4px 8px',
              fontSize: '11px',
              fontWeight: viewMode === 'fun' ? 600 : 400,
              color: viewMode === 'fun' ? settings.theme.white : settings.theme.brightBlack,
              backgroundColor: viewMode === 'fun' ? `${settings.theme.brightBlack}40` : 'transparent',
              border: `1px solid ${viewMode === 'fun' ? settings.theme.brightBlack : 'transparent'}`,
              borderRadius: '0 3px 3px 0',
              cursor: 'pointer',
              transition: 'all 0.15s ease',
            }}
          >
            Fun
          </button>
        </div>

        {/* Stats display - Specs or Fun mode */}
        {viewMode === 'specs' ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            <StatBar label="Intelligence" value={stats.intelligence} />
            <StatBar label="Speed" value={stats.speed} />
            <StatBar label="Cost" value={stats.cost} />
          </div>
        ) : (
          /* Top Trumps card in Fun mode */
          <div
            style={{
              position: 'relative',
              width: '188px',
              aspectRatio: '0.68',
              borderRadius: '8px',
              overflow: 'hidden',
              boxShadow: '0 0 20px rgba(0,0,0,0.3)',
            }}
          >
            {/* Background image with color filter */}
            <img
              src={trumpsCard}
              alt=""
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                height: '100%',
                objectFit: 'cover',
                filter: rarity.filter,
                pointerEvents: 'none',
              }}
            />

            {/* Content overlay */}
            <div
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                right: 0,
                bottom: 0,
                display: 'flex',
                flexDirection: 'column',
                padding: '12px 14px',
              }}
            >
              {/* Rarity badge */}
              <div style={{
                padding: '3px 8px',
                fontSize: '8px',
                fontWeight: 700,
                color: rarity.border,
                backgroundColor: `${rarity.border}30`,
                borderRadius: '3px',
                textTransform: 'uppercase',
                letterSpacing: '0.5px',
                border: `1px solid ${rarity.border}50`,
                alignSelf: 'fit-content',
                marginBottom: '4px',
              }}>
                {extendedStats.rarity}
              </div>

              {/* Center - model name and tagline */}
              <div style={{
                flex: 1,
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'center',
                alignItems: 'center',
                textAlign: 'center',
              }}>
                <div style={{
                  fontSize: '13px',
                  fontWeight: 800,
                  color: settings.theme.white,
                  letterSpacing: '-0.5px',
                  textShadow: '0 2px 6px rgba(0,0,0,0.5)',
                  marginBottom: '2px',
                  lineHeight: 1.2,
                }}>
                  {extendedStats.displayName}
                </div>
                <div style={{
                  fontSize: '7px',
                  color: rarity.border,
                  fontWeight: 600,
                  textTransform: 'uppercase',
                  letterSpacing: '1px',
                  textShadow: '0 1px 3px rgba(0,0,0,0.5)',
                }}>
                  {extendedStats.tagline}
                </div>
              </div>

              {/* Stats at bottom */}
              <div style={{
                display: 'flex',
                flexDirection: 'column',
                gap: '4px',
                marginTop: 'auto',
              }}>
                <CompactStatBar icon={Brain} label="INT" value={extendedStats.intelligence} color={settings.theme.magenta} />
                <CompactStatBar icon={Zap} label="SPD" value={extendedStats.speed} color={settings.theme.yellow} />
                <CompactStatBar icon={BarChart3} label="CTX" value={extendedStats.context} color={settings.theme.cyan} />
                <CompactStatBar icon={DollarSign} label="VAL" value={extendedStats.value} color={settings.theme.green} />
                <CompactStatBar icon={Sparkles} label="RSN" value={extendedStats.reasoning} color={settings.theme.blue} />
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function StatBar({ label, value }: { label: string; value: number }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
      <div style={{ fontSize: '14px', color: 'rgba(255,255,255,0.5)', width: '90px' }}>{label}</div>
      <div style={{ flex: 1, height: '4px', backgroundColor: 'rgba(255,255,255,0.05)', overflow: 'hidden', borderRadius: '2px' }}>
        <div
          style={{
            height: '100%',
            width: `${value}%`,
            background: 'linear-gradient(to right, rgba(45, 212, 191, 0.3), rgba(168, 85, 247, 0.3))',
            transition: 'width 0.3s ease',
            borderRadius: '2px',
          }}
        />
      </div>
    </div>
  )
}

function CompactStatBar({
  icon: Icon,
  label,
  value,
  color,
}: {
  icon: typeof Brain
  label: string
  value: number
  color: string
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
      <Icon size={8} style={{ color, flexShrink: 0 }} />
      <span style={{
        fontSize: '7px',
        color: '#aaa',
        width: '24px',
        flexShrink: 0,
        fontWeight: 600,
      }}>
        {label}
      </span>
      <div style={{
        flex: 1,
        height: '6px',
        backgroundColor: 'rgba(0,0,0,0.4)',
        borderRadius: '3px',
        overflow: 'hidden',
        border: '1px solid rgba(255,255,255,0.1)',
      }}>
        <div style={{
          width: `${value}%`,
          height: '100%',
          backgroundColor: color,
          borderRadius: '2px',
          transition: 'width 0.5s ease-out',
          boxShadow: `0 0 6px ${color}60`,
        }} />
      </div>
      <span style={{
        fontSize: '8px',
        fontWeight: 700,
        color: '#fff',
        width: '18px',
        textAlign: 'right',
        flexShrink: 0,
        textShadow: '0 1px 2px rgba(0,0,0,0.5)',
      }}>
        {value}
      </span>
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
}

function ConversationPicker({ onClose: _onClose, currentProvider }: ConversationPickerProps) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [search, setSearch] = useState('')
  const [activeTab, setActiveTab] = useState<'provider' | 'all'>('provider')

  // Mock conversations with provider info
  const conversations = [
    {
      title: 'can you find out where my env vars are being defined on startup',
      path: '/Users/jkneen',
      date: '1 month ago',
      provider: 'claude-code'
    },
    {
      title: 'we have just added a custom webview component that renders a list...',
      path: '/Users/jkneen/Documents/GitHub/langflow',
      date: '1 month ago',
      provider: 'opencode'
    },
    {
      title: "Fix the parse error near '@' in the JavaScript code",
      path: '/Users/jkneen/Documents/GitHub/flows/petersandmay/petersandmay',
      date: '2 months ago',
      provider: 'claude-code'
    },
    {
      title: "can you work out why we're getting errors adding shipping records",
      path: '/Users/jkneen/Documents/github/flows/petersandmay/petersandmay',
      date: '2 months ago',
      provider: 'opencode'
    },
    {
      title: 'i have an installation somewhere of code that is vscode-oss-serv...',
      path: '/Users/jkneen',
      date: '2 months ago',
      provider: 'aider'
    },
    {
      title: 'I need to get this running on web. mobile. ios android ASAP/User...',
      path: '/Users/jkneen',
      date: '2 months ago',
      provider: 'claude-code'
    },
  ]

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
          {filteredConversations.length === 0 ? (
            <div style={{ padding: '16px', textAlign: 'center', color: theme.brightBlack, fontSize: '13px' }}>
              No conversations found
            </div>
          ) : filteredConversations.map((conversation) => (
            <button
              key={conversation.title}
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

function SlashPicker({ onClose: _onClose }: { onClose: () => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const commands = [
    { icon: Server, label: '/add-mcp', description: 'Add new MCP server' },
    { icon: Server, label: '/create-environment', description: 'Create a Warp Environment (Docker image + repos)' },
    { icon: Sparkles, label: '/add-prompt', description: 'Add new Agent prompt' },
    { icon: Shield, label: '/add-rule', description: 'Add new rule' },
  ]

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
      {/* Commands */}
      <div style={{ padding: '8px 0' }}>
        {commands.map((cmd, index) => (
          <button
            key={cmd.label}
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
          >
            <cmd.icon size={16} style={{ color: index === 0 ? `${theme.background}99` : theme.brightBlack }} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: '14px' }}>{cmd.label}</div>
              {cmd.description && (
                <div style={{ fontSize: '12px', marginTop: '2px', color: index === 0 ? `${theme.background}99` : theme.brightBlack }}>{cmd.description}</div>
              )}
            </div>
          </button>
        ))}
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

function MentionsPicker({ onClose: _onClose }: { onClose: () => void }) {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const categories = [
    { icon: FolderOpen, label: 'Files and folders' },
    { icon: Terminal, label: 'Blocks' },
    { icon: Workflow, label: 'Workflows' },
    { icon: BookOpen, label: 'Notebooks' },
    { icon: ClipboardList, label: 'Plans' },
    { icon: Shield, label: 'Rules' },
  ]

  return (
    <div
      style={{
        width: '320px',
        backgroundColor: theme.background,
        border: `1px solid ${theme.brightBlack}`,
        borderRadius: '12px',
        boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
        overflow: 'hidden',
      }}
    >
      <div style={{ padding: '8px 0' }}>
        {categories.map((cat, index) => (
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
              backgroundColor: index === 0 ? theme.cyan : 'transparent',
              color: index === 0 ? theme.background : theme.foreground,
              border: 'none',
              cursor: 'pointer',
              transition: 'background-color 0.15s ease',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <cat.icon size={16} style={{ color: index === 0 ? `${theme.background}99` : theme.brightBlack }} />
              <span style={{ fontSize: '14px' }}>{cat.label}</span>
            </div>
            <ChevronRight size={14} style={{ color: index === 0 ? `${theme.background}66` : theme.brightBlack }} />
          </button>
        ))}
      </div>
    </div>
  )
}

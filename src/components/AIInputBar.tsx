import { useState, useRef, useEffect } from 'react'

interface AIInputBarProps {
  onSubmit?: (message: string, model: string) => void
  onTerminalMode?: () => void
}

const MODELS = [
  { id: 'gpt-4o', name: 'GPT-4o', provider: 'OpenAI' },
  { id: 'claude-3-5-sonnet', name: 'Claude 3.5 Sonnet', provider: 'Anthropic' },
  { id: 'claude-3-opus', name: 'Claude 3 Opus', provider: 'Anthropic' },
  { id: 'gemini-pro', name: 'Gemini Pro', provider: 'Google' },
]

export function AIInputBar({ onSubmit, onTerminalMode }: AIInputBarProps) {
  const [message, setMessage] = useState('')
  const [isFocused, setIsFocused] = useState(false)
  const [selectedModel, setSelectedModel] = useState(MODELS[0])
  const [showModelPicker, setShowModelPicker] = useState(false)
  const inputRef = useRef<HTMLTextAreaElement>(null)

  const handleSubmit = () => {
    if (message.trim()) {
      onSubmit?.(message.trim(), selectedModel.id)
      setMessage('')
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  // Auto-resize textarea
  useEffect(() => {
    if (inputRef.current) {
      inputRef.current.style.height = 'auto'
      inputRef.current.style.height = Math.min(inputRef.current.scrollHeight, 120) + 'px'
    }
  }, [message])

  // Close model picker on outside click
  useEffect(() => {
    const handleClick = () => setShowModelPicker(false)
    if (showModelPicker) {
      document.addEventListener('click', handleClick)
      return () => document.removeEventListener('click', handleClick)
    }
  }, [showModelPicker])

  return (
    <div
      style={{
        borderTop: '1px solid #292e42',
        backgroundColor: '#16161e',
        padding: '12px 16px',
      }}
    >
      {/* Icon Bar */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          marginBottom: '8px',
        }}
      >
        {/* Terminal Mode Button */}
        <button
          onClick={onTerminalMode}
          title="Terminal mode (bypass AI)"
          style={{
            padding: '6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: '#565f89',
            cursor: 'pointer',
            fontSize: '14px',
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
          }}
        >
          <span style={{ fontFamily: 'monospace' }}>&gt;_</span>
        </button>

        {/* Folder Button */}
        <button
          title="Open folder"
          style={{
            padding: '6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: '#565f89',
            cursor: 'pointer',
            fontSize: '14px',
          }}
        >
          📁
        </button>

        {/* Chat History Button */}
        <button
          title="Previous conversations"
          style={{
            padding: '6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: '#565f89',
            cursor: 'pointer',
            fontSize: '14px',
          }}
        >
          💬
        </button>

        {/* Slash Commands Button */}
        <button
          title="Slash commands"
          style={{
            padding: '6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: '#565f89',
            cursor: 'pointer',
            fontSize: '14px',
            fontFamily: 'monospace',
            fontWeight: 'bold',
          }}
        >
          /
        </button>

        {/* @ Mentions Button */}
        <button
          title="Mention context (@file, @folder, @url)"
          style={{
            padding: '6px 8px',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '4px',
            color: '#565f89',
            cursor: 'pointer',
            fontSize: '14px',
            fontFamily: 'monospace',
            fontWeight: 'bold',
          }}
        >
          @
        </button>

        <div style={{ flex: 1 }} />

        {/* Model Selector */}
        <div style={{ position: 'relative' }}>
          <button
            onClick={(e) => {
              e.stopPropagation()
              setShowModelPicker(!showModelPicker)
            }}
            style={{
              padding: '6px 10px',
              backgroundColor: '#1a1b26',
              border: '1px solid #292e42',
              borderRadius: '6px',
              color: '#a9b1d6',
              cursor: 'pointer',
              fontSize: '12px',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
            }}
          >
            <span>{selectedModel.name}</span>
            <span style={{ fontSize: '10px' }}>▼</span>
          </button>

          {showModelPicker && (
            <div
              style={{
                position: 'absolute',
                bottom: '100%',
                right: 0,
                marginBottom: '4px',
                backgroundColor: '#1a1b26',
                border: '1px solid #292e42',
                borderRadius: '8px',
                padding: '4px',
                minWidth: '200px',
                boxShadow: '0 4px 12px rgba(0, 0, 0, 0.3)',
                zIndex: 100,
              }}
              onClick={(e) => e.stopPropagation()}
            >
              {MODELS.map((model) => (
                <button
                  key={model.id}
                  onClick={() => {
                    setSelectedModel(model)
                    setShowModelPicker(false)
                  }}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    backgroundColor: selectedModel.id === model.id ? '#292e42' : 'transparent',
                    border: 'none',
                    borderRadius: '4px',
                    color: '#c0caf5',
                    cursor: 'pointer',
                    fontSize: '13px',
                    textAlign: 'left',
                    display: 'flex',
                    justifyContent: 'space-between',
                  }}
                >
                  <span>{model.name}</span>
                  <span style={{ color: '#565f89', fontSize: '11px' }}>{model.provider}</span>
                </button>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Input Area */}
      <div
        style={{
          display: 'flex',
          alignItems: 'flex-end',
          gap: '12px',
          backgroundColor: isFocused ? '#1a1b26' : '#1e1f2b',
          border: `1px solid ${isFocused ? '#7aa2f7' : '#292e42'}`,
          borderRadius: '12px',
          padding: '10px 14px',
          transition: 'border-color 0.2s, background-color 0.2s',
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            color: '#7aa2f7',
            fontSize: '14px',
            flexShrink: 0,
          }}
        >
          <span style={{ fontSize: '16px' }}>✨</span>
        </div>

        <textarea
          ref={inputRef}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          onKeyDown={handleKeyDown}
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          placeholder="Warp anything e.g. Build a REST API for my mobile app using FastAPI"
          rows={1}
          style={{
            flex: 1,
            backgroundColor: 'transparent',
            border: 'none',
            color: '#c0caf5',
            fontSize: '14px',
            lineHeight: '1.5',
            resize: 'none',
            outline: 'none',
            fontFamily: 'inherit',
            minHeight: '24px',
            maxHeight: '120px',
          }}
        />

        <button
          onClick={handleSubmit}
          disabled={!message.trim()}
          style={{
            backgroundColor: message.trim() ? '#7aa2f7' : '#292e42',
            border: 'none',
            borderRadius: '8px',
            padding: '8px 16px',
            color: message.trim() ? '#1a1b26' : '#565f89',
            fontSize: '13px',
            fontWeight: 600,
            cursor: message.trim() ? 'pointer' : 'default',
            transition: 'background-color 0.2s, color 0.2s',
            flexShrink: 0,
          }}
        >
          Send
        </button>
      </div>

      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginTop: '8px',
          fontSize: '11px',
          color: '#565f89',
        }}
      >
        <span>Press Enter to send, Shift+Enter for new line</span>
        <span style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
          <span style={{
            backgroundColor: '#292e42',
            padding: '2px 6px',
            borderRadius: '4px',
            fontSize: '10px',
          }}>
            auto (responsive)
          </span>
        </span>
      </div>
    </div>
  )
}

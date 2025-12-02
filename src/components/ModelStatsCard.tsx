import { useState } from 'react'
import { Zap, Brain, DollarSign, Sparkles, BarChart3 } from 'lucide-react'
import trumpsCard from '../assets/trumps.png'

// Model stats data - scores out of 100
const MODEL_STATS: Record<string, {
  displayName: string
  intelligence: number
  speed: number
  context: number
  value: number  // cost efficiency (100 = best value)
  reasoning: number
  tagline: string
  rarity: 'common' | 'uncommon' | 'rare' | 'legendary' | 'mythic'
}> = {
  'claude-opus-4-5-20251101': {
    displayName: 'Claude Opus 4.5',
    intelligence: 98,
    speed: 35,
    context: 85,
    value: 25,
    reasoning: 99,
    tagline: 'The Ultimate Mind',
    rarity: 'mythic',
  },
  'claude-sonnet-4-20250514': {
    displayName: 'Claude Sonnet 4',
    intelligence: 92,
    speed: 70,
    context: 85,
    value: 65,
    reasoning: 88,
    tagline: 'Speed Meets Smarts',
    rarity: 'legendary',
  },
  'claude-3-5-sonnet-20241022': {
    displayName: 'Claude 3.5 Sonnet',
    intelligence: 88,
    speed: 75,
    context: 85,
    value: 70,
    reasoning: 82,
    tagline: 'The Reliable Workhorse',
    rarity: 'rare',
  },
  'claude-3-5-haiku-20241022': {
    displayName: 'Claude 3.5 Haiku',
    intelligence: 72,
    speed: 95,
    context: 85,
    value: 92,
    reasoning: 60,
    tagline: 'Lightning Fast',
    rarity: 'uncommon',
  },
  'gpt-4o': {
    displayName: 'GPT-4o',
    intelligence: 90,
    speed: 65,
    context: 60,
    value: 55,
    reasoning: 75,
    tagline: 'The Multimodal Master',
    rarity: 'legendary',
  },
  'gpt-4o-mini': {
    displayName: 'GPT-4o Mini',
    intelligence: 75,
    speed: 90,
    context: 60,
    value: 88,
    reasoning: 55,
    tagline: 'Quick & Capable',
    rarity: 'uncommon',
  },
  'o1': {
    displayName: 'o1',
    intelligence: 96,
    speed: 15,
    context: 60,
    value: 10,
    reasoning: 100,
    tagline: 'The Deep Thinker',
    rarity: 'mythic',
  },
  'o1-mini': {
    displayName: 'o1-mini',
    intelligence: 85,
    speed: 40,
    context: 60,
    value: 45,
    reasoning: 92,
    tagline: 'Compact Genius',
    rarity: 'rare',
  },
  'gemini-2.0-flash': {
    displayName: 'Gemini 2.0 Flash',
    intelligence: 82,
    speed: 88,
    context: 90,
    value: 80,
    reasoning: 70,
    tagline: 'The Speed Demon',
    rarity: 'rare',
  },
  'gemini-1.5-pro': {
    displayName: 'Gemini 1.5 Pro',
    intelligence: 86,
    speed: 60,
    context: 100,
    value: 60,
    reasoning: 78,
    tagline: 'Context King',
    rarity: 'legendary',
  },
  'deepseek-chat': {
    displayName: 'DeepSeek V3',
    intelligence: 88,
    speed: 70,
    context: 75,
    value: 95,
    reasoning: 85,
    tagline: 'The Dark Horse',
    rarity: 'rare',
  },
  'deepseek-reasoner': {
    displayName: 'DeepSeek R1',
    intelligence: 94,
    speed: 25,
    context: 75,
    value: 88,
    reasoning: 98,
    tagline: 'Deep Thoughts',
    rarity: 'legendary',
  },
}

// Fallback for unknown models
const DEFAULT_STATS = {
  displayName: 'Unknown Model',
  intelligence: 50,
  speed: 50,
  context: 50,
  value: 50,
  reasoning: 50,
  tagline: 'Mystery Box',
  rarity: 'common' as const,
}

// Rarity colors and filters for the card background
const RARITY_COLORS: Record<string, { gradient: string; glow: string; border: string; filter: string }> = {
  common: {
    gradient: 'linear-gradient(135deg, #3a3a4a 0%, #2a2a3a 100%)',
    glow: 'none',
    border: '#6a6a7a',
    filter: 'grayscale(0.7) brightness(0.6)',
  },
  uncommon: {
    gradient: 'linear-gradient(135deg, #1a4a3a 0%, #0a3a2a 100%)',
    glow: '0 0 20px rgba(34, 197, 94, 0.3)',
    border: '#22c55e',
    filter: 'hue-rotate(85deg) saturate(1.2) brightness(0.75)',
  },
  rare: {
    gradient: 'linear-gradient(135deg, #1a3a5a 0%, #0a2a4a 100%)',
    glow: '0 0 20px rgba(59, 130, 246, 0.3)',
    border: '#3b82f6',
    filter: 'hue-rotate(200deg) saturate(1.3) brightness(0.8)',
  },
  legendary: {
    gradient: 'linear-gradient(135deg, #4a3a1a 0%, #3a2a0a 100%)',
    glow: '0 0 25px rgba(251, 191, 36, 0.4)',
    border: '#fbbf24',
    filter: 'hue-rotate(35deg) saturate(1.5) brightness(0.85)',
  },
  mythic: {
    gradient: 'linear-gradient(135deg, #4a1a4a 0%, #3a0a3a 100%)',
    glow: '0 0 30px rgba(168, 85, 247, 0.5)',
    border: '#a855f7',
    filter: 'hue-rotate(280deg) saturate(1.4) brightness(0.85)',
  },
}

interface ModelStatsCardProps {
  modelId: string
  provider?: string
  tokens?: {
    input?: number
    output?: number
    reasoning?: number
  }
  cost?: number
  duration?: number
  theme: {
    foreground: string
    white: string
    brightBlack: string
    magenta: string
    cyan: string
    green: string
    blue: string
    yellow: string
    red: string
  }
  fontFamily: string
}

export function ModelStatsCard({
  modelId,
  provider,
  tokens,
  cost,
  duration,
  theme,
  fontFamily,
}: ModelStatsCardProps) {
  const [mode, setMode] = useState<'specs' | 'fun'>('specs')

  // Find model stats (try exact match, then partial match)
  const stats = MODEL_STATS[modelId] ||
    Object.entries(MODEL_STATS).find(([key]) =>
      modelId.toLowerCase().includes(key.toLowerCase()) ||
      key.toLowerCase().includes(modelId.toLowerCase())
    )?.[1] ||
    { ...DEFAULT_STATS, displayName: modelId }

  const rarity = RARITY_COLORS[stats.rarity]

  // Calculate actual speed from duration if available
  const actualSpeed = duration && tokens?.output
    ? Math.round((tokens.output / (duration / 1000)))
    : null

  return (
    <div style={{ width: '100%' }}>
      {/* Toggle */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          marginBottom: mode === 'fun' ? '12px' : '0',
        }}
      >
        <button
          onClick={() => setMode('specs')}
          style={{
            padding: '3px 8px',
            fontSize: '10px',
            fontFamily,
            fontWeight: mode === 'specs' ? 600 : 400,
            color: mode === 'specs' ? theme.white : theme.brightBlack,
            backgroundColor: mode === 'specs' ? `${theme.brightBlack}40` : 'transparent',
            border: `1px solid ${mode === 'specs' ? theme.brightBlack : 'transparent'}`,
            borderRadius: '4px 0 0 4px',
            cursor: 'pointer',
            transition: 'all 0.15s ease',
          }}
        >
          Specs
        </button>
        <button
          onClick={() => setMode('fun')}
          style={{
            padding: '3px 8px',
            fontSize: '10px',
            fontFamily,
            fontWeight: mode === 'fun' ? 600 : 400,
            color: mode === 'fun' ? theme.white : theme.brightBlack,
            backgroundColor: mode === 'fun' ? `${theme.brightBlack}40` : 'transparent',
            border: `1px solid ${mode === 'fun' ? theme.brightBlack : 'transparent'}`,
            borderRadius: '0 4px 4px 0',
            cursor: 'pointer',
            transition: 'all 0.15s ease',
          }}
        >
          Fun
        </button>
      </div>

      {mode === 'specs' ? (
        /* Specs Mode - Clean stats */
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            width: '100%',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <span style={{ color: theme.magenta, fontWeight: 500 }}>
              {provider || 'opencode'}
            </span>
            <span style={{ color: theme.foreground }}>
              {modelId}
            </span>
          </div>

          {(tokens || cost !== undefined || duration) && (
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              {tokens && (tokens.input || tokens.output) && (
                <span title="Input / Output tokens" style={{ display: 'inline-flex', alignItems: 'center', gap: '6px' }}>
                  {tokens.input && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: '2px' }}>
                      <span style={{ color: theme.green, opacity: 0.7 }}>↑</span>
                      <span style={{ color: theme.green }}>{tokens.input.toLocaleString()}</span>
                    </span>
                  )}
                  {tokens.output && (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: '2px' }}>
                      <span style={{ color: theme.blue, opacity: 0.7 }}>↓</span>
                      <span style={{ color: theme.blue }}>{tokens.output.toLocaleString()}</span>
                    </span>
                  )}
                </span>
              )}
              {cost !== undefined && cost > 0 && (
                <span style={{ color: theme.yellow }}>
                  ${cost.toFixed(4)}
                </span>
              )}
              {duration && (
                <span style={{ color: theme.brightBlack }}>
                  {(duration / 1000).toFixed(2)}s
                </span>
              )}
            </div>
          )}
        </div>
      ) : (
        /* Fun Mode - Top Trumps Card */
        <div
          style={{
            position: 'relative',
            width: '280px',
            aspectRatio: '0.68',
            boxShadow: rarity.glow,
            borderRadius: '12px',
            overflow: 'hidden',
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
              padding: '16px 20px',
            }}
          >
            {/* Header with name and rarity badge */}
            <div style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'flex-start',
              marginBottom: '8px',
            }}>
              <div style={{
                padding: '4px 10px',
                fontSize: '9px',
                fontWeight: 700,
                color: rarity.border,
                backgroundColor: `${rarity.border}30`,
                borderRadius: '4px',
                textTransform: 'uppercase',
                letterSpacing: '0.5px',
                fontFamily,
                border: `1px solid ${rarity.border}50`,
              }}>
                {stats.rarity}
              </div>
            </div>

            {/* Center circle area - model name and tagline */}
            <div style={{
              flex: 1,
              display: 'flex',
              flexDirection: 'column',
              justifyContent: 'center',
              alignItems: 'center',
              textAlign: 'center',
              marginTop: '-10px',
            }}>
              <div style={{
                fontSize: '18px',
                fontWeight: 800,
                color: theme.white,
                fontFamily,
                letterSpacing: '-0.5px',
                textShadow: '0 2px 8px rgba(0,0,0,0.5)',
                marginBottom: '4px',
              }}>
                {stats.displayName}
              </div>
              <div style={{
                fontSize: '10px',
                color: rarity.border,
                fontFamily,
                fontWeight: 600,
                textTransform: 'uppercase',
                letterSpacing: '1.5px',
                textShadow: '0 1px 4px rgba(0,0,0,0.5)',
              }}>
                {stats.tagline}
              </div>
            </div>

            {/* Stats area - positioned at bottom */}
            <div style={{
              display: 'flex',
              flexDirection: 'column',
              gap: '6px',
              marginTop: 'auto',
              paddingTop: '12px',
            }}>
              <StatBar icon={Brain} label="INT" value={stats.intelligence} color={theme.magenta} fontFamily={fontFamily} compact />
              <StatBar icon={Zap} label="SPD" value={stats.speed} color={theme.yellow} fontFamily={fontFamily} actualValue={actualSpeed ? `${actualSpeed}` : undefined} compact />
              <StatBar icon={BarChart3} label="CTX" value={stats.context} color={theme.cyan} fontFamily={fontFamily} compact />
              <StatBar icon={DollarSign} label="VAL" value={stats.value} color={theme.green} fontFamily={fontFamily} compact />
              <StatBar icon={Sparkles} label="RSN" value={stats.reasoning} color={theme.blue} fontFamily={fontFamily} compact />
            </div>

            {/* Footer with actual stats from this run */}
            {(tokens || cost !== undefined || duration) && (
              <div style={{
                marginTop: '10px',
                paddingTop: '8px',
                borderTop: `1px solid ${theme.white}20`,
                display: 'flex',
                justifyContent: 'center',
                gap: '12px',
                fontSize: '9px',
                color: theme.brightBlack,
                fontFamily,
              }}>
                {tokens?.output && (
                  <span style={{ color: theme.blue }}>{tokens.output.toLocaleString()} tok</span>
                )}
                {cost !== undefined && cost > 0 && (
                  <span style={{ color: theme.yellow }}>${cost.toFixed(4)}</span>
                )}
                {duration && (
                  <span style={{ color: theme.green }}>{(duration / 1000).toFixed(1)}s</span>
                )}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

// Stat bar component
function StatBar({
  icon: Icon,
  label,
  value,
  color,
  fontFamily,
  actualValue,
  compact,
}: {
  icon: typeof Brain
  label: string
  value: number
  color: string
  fontFamily: string
  actualValue?: string
  compact?: boolean
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: compact ? '6px' : '8px' }}>
      <Icon size={compact ? 10 : 12} style={{ color, flexShrink: 0 }} />
      <div style={{
        flex: 1,
        display: 'flex',
        alignItems: 'center',
        gap: compact ? '6px' : '8px',
        minWidth: 0,
      }}>
        <span style={{
          fontSize: compact ? '9px' : '10px',
          color: '#aaa',
          fontFamily,
          width: compact ? '28px' : '65px',
          flexShrink: 0,
          fontWeight: 600,
        }}>
          {label}
        </span>
        <div style={{
          flex: 1,
          height: compact ? '8px' : '6px',
          backgroundColor: 'rgba(0,0,0,0.4)',
          borderRadius: '4px',
          overflow: 'hidden',
          border: '1px solid rgba(255,255,255,0.1)',
        }}>
          <div style={{
            width: `${value}%`,
            height: '100%',
            backgroundColor: color,
            borderRadius: '3px',
            transition: 'width 0.5s ease-out',
            boxShadow: `0 0 8px ${color}60`,
          }} />
        </div>
        <span style={{
          fontSize: compact ? '10px' : '11px',
          fontWeight: 700,
          color: '#fff',
          fontFamily,
          width: actualValue ? (compact ? '40px' : '70px') : '20px',
          textAlign: 'right',
          flexShrink: 0,
          textShadow: '0 1px 2px rgba(0,0,0,0.5)',
        }}>
          {actualValue || value}
        </span>
      </div>
    </div>
  )
}

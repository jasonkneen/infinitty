/**
 * {{WIDGET_NAME}}
 * {{WIDGET_DESCRIPTION}}
 */

import { useState } from 'react'
import {
  defineWidget,
  useTheme,
  useConfig,
  useTool,
  useCommand,
  useWidgetSDK,
} from '@infinitty/widget-sdk'
import type { WidgetComponentProps } from '@infinitty/widget-sdk'

// ============================================
// Configuration Types
// ============================================

interface {{WIDGET_CONFIG_TYPE}} {
  // Add your config properties here
  exampleOption?: string
}

// ============================================
// Widget Component
// ============================================

function {{WIDGET_COMPONENT_NAME}}({ api }: WidgetComponentProps) {
  const theme = useTheme()
  const config = useConfig<{{WIDGET_CONFIG_TYPE}}>()
  const { context: { log } } = useWidgetSDK()

  const [count, setCount] = useState(0)

  // Example tool registration
  useTool(
    {
      name: '{{WIDGET_TOOL_PREFIX}}_example',
      description: 'An example tool',
      inputSchema: {
        type: 'object',
        properties: {
          message: { type: 'string', description: 'A message to process' },
        },
        required: ['message'],
      },
    },
    async (args) => {
      const { message } = args as { message: string }
      log.info('Tool called with:', message)
      return { success: true, message: `Processed: ${message}` }
    }
  )

  // Example command registration
  useCommand('{{WIDGET_TYPE}}.action', () => {
    api.showMessage('Command executed!', 'info')
  })

  return (
    <div
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: theme.background,
        color: theme.foreground,
        padding: 24,
        gap: 16,
      }}
    >
      <h1 style={{ margin: 0, fontSize: 24 }}>{{WIDGET_NAME}}</h1>

      <p style={{ margin: 0, color: theme.brightBlack }}>
        {{WIDGET_DESCRIPTION}}
      </p>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <button
          onClick={() => setCount(c => c - 1)}
          style={{
            padding: '8px 16px',
            backgroundColor: theme.red,
            color: '#fff',
            border: 'none',
            borderRadius: 6,
            cursor: 'pointer',
            fontSize: 16,
          }}
        >
          -
        </button>

        <span style={{ fontSize: 32, fontWeight: 600, minWidth: 60, textAlign: 'center' }}>
          {count}
        </span>

        <button
          onClick={() => setCount(c => c + 1)}
          style={{
            padding: '8px 16px',
            backgroundColor: theme.green,
            color: '#fff',
            border: 'none',
            borderRadius: 6,
            cursor: 'pointer',
            fontSize: 16,
          }}
        >
          +
        </button>
      </div>

      <button
        onClick={() => api.showMessage(`Count is ${count}`, 'info')}
        style={{
          padding: '8px 24px',
          backgroundColor: theme.cyan,
          color: theme.background,
          border: 'none',
          borderRadius: 6,
          cursor: 'pointer',
          fontSize: 14,
          fontWeight: 500,
        }}
      >
        Show Message
      </button>
    </div>
  )
}

// ============================================
// Widget Definition
// ============================================

export default defineWidget({
  id: '{{WIDGET_ID}}',
  name: '{{WIDGET_NAME}}',
  version: '1.0.0',
  description: '{{WIDGET_DESCRIPTION}}',

  activate: (context) => {
    context.log.info('{{WIDGET_NAME}} activated')
  },

  deactivate: () => {
    console.log('{{WIDGET_NAME}} deactivated')
  },

  Component: {{WIDGET_COMPONENT_NAME}},
})
